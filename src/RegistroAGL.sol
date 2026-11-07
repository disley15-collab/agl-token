// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { FullMath } from "v4-core/libraries/FullMath.sol";

interface IPoolAGLLeitura {
    function chave() external view returns (PoolKey memory);
    function poolManager() external view returns (IPoolManager);
    function token() external view returns (Currency);
    function tokenEhMoeda0() external view returns (bool);
}

/// @title RegistroAGL — selo de KYC, serviços pagos em AGL e contratos assinados
///
/// - SELO: o provedor de KYC verifica a pessoa/empresa fora da blockchain; aqui fica só
///   "carteira X verificada até Y" (sem dados pessoais).
/// - SERVIÇOS (cadastro, KYC, KYB, contato, informação extra): preço em moeda (USDC),
///   pago em AGL pela cotação da pool oficial, com teto do pagador (`_maxAgl`). O AGL vai
///   para a carteira de recebimento.
/// - CONTATO/INFORMAÇÃO: quem pede paga; o AGL fica reservado até o dono dos dados
///   responder. Aceitou → AGL ao recebedor e a plataforma revela fora da blockchain.
///   Recusou ou não respondeu em 7 dias → AGL de volta a quem pediu.
/// - CONTRATO: comprador e vendedor assinam (transação = assinatura) o hash do contrato
///   cifrado; o escrow só abre ordem com contrato assinado pelos dois. O cofre de
///   documentos só entrega o arquivo a carteira que esteja em `partes`.
///
/// Cotação: preço da pool, com piso no preço de lançamento — abaixo dele não existe
/// liquidez e o preço só chega lá "empurrado" de graça, então não vale como cotação.
contract RegistroAGL is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    enum Servico {
        Cadastro,
        KycPessoa,
        KybEmpresa,
        Contato,
        InfoExtra
    }

    struct Pedido {
        address quem;
        address alvo;
        Servico servico;
        uint64 ate;
        uint256 agl;
        bool fechado;
    }

    struct Contrato {
        address comprador;
        address vendedor;
        bool assinouComprador;
        bool assinouVendedor;
    }

    uint64 public constant PRAZO_RESPOSTA = 7 days;

    IPoolAGLLeitura public immutable pool;
    IERC20 public immutable agl;
    address public immutable recebedor;
    uint160 public immutable sqrtPiso; // sqrtPrice do lançamento
    address public supervisor;
    address public atestador;

    mapping(address => uint64) public verificadoAte;
    mapping(Servico => uint256) public precoMoeda; // em unidades da moeda da pool
    uint256 public totalPedidos;
    mapping(uint256 => Pedido) public pedidos;
    mapping(bytes32 => Contrato) public contratos;

    error SoSupervisor();
    error SoAtestador();
    error SoAlvo();
    error SoParte();
    error EnderecoZero();
    error SemKYC(address);
    error PrecoNaoDefinido();
    error AcimaDoTeto(uint256 agl, uint256 teto);
    error PedidoFechado();
    error PrazoNaoVenceu();
    error PrazoVencido();
    error ServicoErrado();
    error ContratoExiste();

    event Verificado(address indexed carteira, uint64 ate);
    event PrecoDefinido(Servico indexed servico, uint256 precoMoeda);
    event ServicoPago(address indexed quem, Servico indexed servico, bytes32 ref, uint256 agl);
    event PedidoCriado(uint256 indexed id, address indexed quem, address indexed alvo, Servico servico, uint256 agl);
    event PedidoRespondido(uint256 indexed id, bool aceito);
    event PedidoDevolvido(uint256 indexed id);
    event ContratoRegistrado(bytes32 indexed hash, address indexed comprador, address indexed vendedor);
    event ContratoAssinado(bytes32 indexed hash, address indexed por);
    event AtestadorTrocado(address indexed atestador);
    event SupervisorTrocado(address indexed supervisor);

    constructor(IPoolAGLLeitura _pool, address _recebedor, address _supervisor, address _atestador, uint160 _sqrtPiso) {
        if (_recebedor == address(0) || _supervisor == address(0) || _atestador == address(0)) revert EnderecoZero();
        pool = _pool;
        agl = IERC20(Currency.unwrap(_pool.token()));
        recebedor = _recebedor;
        supervisor = _supervisor;
        atestador = _atestador;
        sqrtPiso = _sqrtPiso;
    }

    // ------------------------------------------------------------ selo

    function verificado(address _c) public view returns (bool) {
        return verificadoAte[_c] >= block.timestamp;
    }

    function atestar(address[] calldata _carteiras, uint64 _ate) external {
        if (msg.sender != atestador) revert SoAtestador();
        for (uint256 i; i < _carteiras.length; i++) {
            verificadoAte[_carteiras[i]] = _ate;
            emit Verificado(_carteiras[i], _ate);
        }
    }

    // ------------------------------------------------------------ preço

    function definirPreco(Servico _s, uint256 _precoMoeda) external {
        if (msg.sender != supervisor) revert SoSupervisor();
        precoMoeda[_s] = _precoMoeda;
        emit PrecoDefinido(_s, _precoMoeda);
    }

    /// @notice Quanto AGL custa o serviço agora (preço da pool, com piso no lançamento).
    function precoEmAgl(Servico _s) public view returns (uint256) {
        uint256 p = precoMoeda[_s];
        if (p == 0) revert PrecoNaoDefinido();
        (uint160 sp,,,) = pool.poolManager().getSlot0(pool.chave().toId());
        bool t0 = pool.tokenEhMoeda0();
        // token0: preço do AGL sobe com sqrtP; piso = sqrtPiso. token1: espelhado.
        if (t0 ? sp < sqrtPiso : sp > sqrtPiso) sp = sqrtPiso;
        // moeda por AGL (unidades) = sp^2 / 2^192 (token0)  →  AGL = moeda * 2^192 / sp^2
        uint256 q96 = 1 << 96;
        if (t0) return FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(p, q96, sp), q96, sp);
        return FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(p, sp, q96), sp, q96);
    }

    // ------------------------------------------------------------ serviços

    /// @notice Paga cadastro, KYC ou KYB em AGL (aprovar antes). `_ref` = protocolo do
    /// pedido no provedor de KYC.
    function pagarServico(Servico _s, bytes32 _ref, uint256 _maxAgl) external nonReentrant {
        if (_s == Servico.Contato || _s == Servico.InfoExtra) revert ServicoErrado();
        uint256 v = _cobrar(_s, _maxAgl);
        agl.safeTransferFrom(msg.sender, recebedor, v);
        emit ServicoPago(msg.sender, _s, _ref, v);
    }

    /// @notice Pede o contato (ou uma informação extra) de `_alvo`. O AGL fica reservado
    /// aqui até `_alvo` responder.
    function pedir(address _alvo, Servico _s, uint256 _maxAgl) external nonReentrant returns (uint256 id) {
        if (_s != Servico.Contato && _s != Servico.InfoExtra) revert ServicoErrado();
        if (!verificado(msg.sender)) revert SemKYC(msg.sender);
        if (!verificado(_alvo)) revert SemKYC(_alvo);
        uint256 v = _cobrar(_s, _maxAgl);
        id = ++totalPedidos;
        pedidos[id] = Pedido(msg.sender, _alvo, _s, uint64(block.timestamp) + PRAZO_RESPOSTA, v, false);
        agl.safeTransferFrom(msg.sender, address(this), v);
        emit PedidoCriado(id, msg.sender, _alvo, _s, v);
    }

    /// @notice O dono dos dados aceita (AGL ao recebedor; a plataforma revela) ou recusa
    /// (AGL de volta a quem pediu).
    function responder(uint256 _id, bool _aceito) external nonReentrant {
        Pedido storage p = pedidos[_id];
        if (msg.sender != p.alvo) revert SoAlvo();
        if (p.fechado) revert PedidoFechado();
        if (block.timestamp > p.ate) revert PrazoVencido();
        p.fechado = true;
        agl.safeTransfer(_aceito ? recebedor : p.quem, p.agl);
        emit PedidoRespondido(_id, _aceito);
    }

    /// @notice Sem resposta no prazo, qualquer um devolve o AGL a quem pediu.
    function devolver(uint256 _id) external nonReentrant {
        Pedido storage p = pedidos[_id];
        if (p.fechado) revert PedidoFechado();
        if (block.timestamp <= p.ate) revert PrazoNaoVenceu();
        p.fechado = true;
        agl.safeTransfer(p.quem, p.agl);
        emit PedidoDevolvido(_id);
    }

    function _cobrar(Servico _s, uint256 _maxAgl) internal view returns (uint256 v) {
        v = precoEmAgl(_s);
        if (v > _maxAgl) revert AcimaDoTeto(v, _maxAgl);
    }

    // ------------------------------------------------------------ contrato

    /// @notice Registra o hash do contrato comercial (PDF cifrado no cofre) e as partes;
    /// quem registra já assina.
    function registrarContrato(bytes32 _hash, address _comprador, address _vendedor) external {
        if (_hash == bytes32(0) || _comprador == address(0) || _vendedor == address(0) || _comprador == _vendedor) {
            revert EnderecoZero();
        }
        if (msg.sender != _comprador && msg.sender != _vendedor) revert SoParte();
        if (contratos[_hash].comprador != address(0)) revert ContratoExiste();
        contratos[_hash] = Contrato(_comprador, _vendedor, false, false);
        emit ContratoRegistrado(_hash, _comprador, _vendedor);
        _assinar(_hash);
    }

    function assinar(bytes32 _hash) external {
        _assinar(_hash);
    }

    function _assinar(bytes32 _hash) internal {
        Contrato storage c = contratos[_hash];
        if (msg.sender == c.comprador) c.assinouComprador = true;
        else if (msg.sender == c.vendedor) c.assinouVendedor = true;
        else revert SoParte();
        emit ContratoAssinado(_hash, msg.sender);
    }

    function contratoAssinado(bytes32 _hash, address _comprador, address _vendedor) external view returns (bool) {
        Contrato storage c = contratos[_hash];
        return c.comprador == _comprador && c.vendedor == _vendedor && c.assinouComprador && c.assinouVendedor;
    }

    /// @notice Quem pode abrir o contrato cifrado (o cofre consulta antes de entregar).
    function podeAbrir(bytes32 _hash, address _c) external view returns (bool) {
        Contrato storage c = contratos[_hash];
        return _c != address(0) && (_c == c.comprador || _c == c.vendedor || _c == supervisor);
    }

    // ------------------------------------------------------------ chaves

    function trocarAtestador(address _novo) external {
        if (msg.sender != supervisor) revert SoSupervisor();
        if (_novo == address(0)) revert EnderecoZero();
        atestador = _novo;
        emit AtestadorTrocado(_novo);
    }

    function trocarSupervisor(address _novo) external {
        if (msg.sender != supervisor) revert SoSupervisor();
        if (_novo == address(0)) revert EnderecoZero();
        supervisor = _novo;
        emit SupervisorTrocado(_novo);
    }
}
