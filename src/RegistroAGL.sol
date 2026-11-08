// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

interface IPoolAGLLeitura {
    /// @notice Chave da pool oficial.
    function chave() external view returns (PoolKey memory);
    /// @notice PoolManager desta rede.
    function poolManager() external view returns (IPoolManager);
    /// @notice Endereço do AGL.
    function token() external view returns (Currency);
    /// @notice true se o AGL é a currency0.
    function tokenEhMoeda0() external view returns (bool);
}

/// @title RegistroAGL — selo de KYC, serviços pagos em AGL e contratos assinados
///
/// - SELO: o provedor de KYC verifica a pessoa/empresa fora da blockchain; aqui fica só
///   "carteira X verificada até Y" (sem dados pessoais).
/// - SERVIÇOS (cadastro, KYC, KYB, contato, informação extra): preço em moeda (USDC),
///   pago em AGL pela cotação da pool oficial, com teto do pagador (`maxAgl`). O AGL vai
///   para a carteira de recebimento.
/// - CONTATO/INFORMAÇÃO: quem pede paga; o AGL fica reservado até o dono dos dados
///   responder. Aceitou → AGL ao recebedor e a plataforma revela fora da blockchain.
///   Recusou ou não respondeu em 7 dias → AGL de volta a quem pediu.
/// - CONTRATO: comprador e vendedor (com KYC) assinam (transação = assinatura) o hash do
///   contrato cifrado. A chave é (hash, comprador, vendedor): ninguém "sequestra" o hash de
///   outros. O escrow só abre ordem com contrato assinado pelos dois; o cofre só entrega o
///   arquivo a quem assinou (ou ao supervisor).
///
/// Cotação: preço da pool, com piso no preço de lançamento — abaixo dele não existe
/// liquidez e o preço só chega lá "empurrado" de graça, então não vale como cotação.
/// @author AgroLastro (Solidity Brasil)
/// @custom:security-contact t.me/agrolastro
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

    /// Campos ordenados para caber em 3 slots (antes, 5).
    struct Pedido {
        address quem;
        Servico servico;
        uint64 ate;
        bool fechado;
        address alvo;
        uint256 valorAgl;
    }

    struct Contrato {
        address comprador;
        address vendedor;
        bool assinouComprador;
        bool assinouVendedor;
    }

    uint64 public constant PRAZO_RESPOSTA = 7 days;

    IPoolAGLLeitura public immutable pool;
    // dados da pool gravados na criação (sem 3 chamadas externas a cada cobrança)
    IPoolManager internal immutable pmCache;
    bytes32 internal immutable idPool;
    bool internal immutable aglEhMoeda0;
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

    constructor(IPoolAGLLeitura pool_, address recebedor_, address supervisor_, address atestador_, uint160 sqrtPiso_) {
        if (recebedor_ == address(0) || supervisor_ == address(0) || atestador_ == address(0)) revert EnderecoZero();
        pool = pool_;
        pmCache = pool_.poolManager();
        idPool = PoolId.unwrap(pool_.chave().toId());
        aglEhMoeda0 = pool_.tokenEhMoeda0();
        agl = IERC20(Currency.unwrap(pool_.token()));
        recebedor = recebedor_;
        supervisor = supervisor_;
        atestador = atestador_;
        sqrtPiso = sqrtPiso_;
    }

    // ------------------------------------------------------------ selo

    /// @notice true se a carteira tem selo de KYC válido agora.
    /// @param c Carteira.
    function verificado(address c) public view returns (bool) {
        return verificadoAte[c] >= block.timestamp;
    }

    /// @notice Grava (ou revoga, com `ate_` = 0) o selo de KYC (só o atestador).
    /// @param carteiras Carteiras verificadas.
    /// @param ate_ Validade do selo (timestamp).
    function atestar(address[] calldata carteiras, uint64 ate_) external {
        if (msg.sender != atestador) revert SoAtestador();
        for (uint256 i; i < carteiras.length; i++) {
            verificadoAte[carteiras[i]] = ate_;
            emit Verificado(carteiras[i], ate_);
        }
    }

    // ------------------------------------------------------------ preço

    /// @notice Define o preço de um serviço em unidades da moeda da pool (só o supervisor).
    /// @param s Serviço.
    /// @param precoMoeda_ Preço (ex.: 25e6 = US$25 com USDC de 6 casas).
    function definirPreco(Servico s, uint256 precoMoeda_) external {
        if (msg.sender != supervisor) revert SoSupervisor();
        precoMoeda[s] = precoMoeda_;
        emit PrecoDefinido(s, precoMoeda_);
    }

    /// @notice Quanto AGL custa o serviço agora (preço da pool, com piso no lançamento).
    function precoEmAgl(Servico s) public view returns (uint256) {
        uint256 p = precoMoeda[s];
        if (p == 0) revert PrecoNaoDefinido();
        // slither-disable-next-line unused-return
        (uint160 sp,,,) = pmCache.getSlot0(PoolId.wrap(idPool));
        bool t0 = aglEhMoeda0;
        // token0: preço do AGL sobe com sqrtP; piso = sqrtPiso. token1: espelhado.
        if (t0 ? sp < sqrtPiso : sp > sqrtPiso) sp = sqrtPiso;
        // moeda por AGL (unidades) = sp^2 / 2^192 (token0)  →  AGL = moeda * 2^192 / sp^2
        uint256 q96 = 1 << 96;
        if (t0) return FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(p, q96, sp), q96, sp);
        return FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(p, sp, q96), sp, q96);
    }

    // ------------------------------------------------------------ serviços

    /// @notice Paga cadastro, KYC ou KYB em AGL (aprovar antes). `ref` = protocolo do
    /// pedido no provedor de KYC.
    function pagarServico(Servico s, bytes32 ref, uint256 maxAgl) external nonReentrant {
        if (s == Servico.Contato || s == Servico.InfoExtra) revert ServicoErrado();
        uint256 v = _cobrar(s, maxAgl);
        agl.safeTransferFrom(msg.sender, recebedor, v);
        emit ServicoPago(msg.sender, s, ref, v);
    }

    /// @notice Pede o contato (ou uma informação extra) de `alvo_`. O AGL fica reservado
    /// aqui até `alvo_` responder.
    function pedir(address alvo_, Servico s, uint256 maxAgl) external nonReentrant returns (uint256 id) {
        if (s != Servico.Contato && s != Servico.InfoExtra) revert ServicoErrado();
        if (!verificado(msg.sender)) revert SemKYC(msg.sender);
        if (!verificado(alvo_)) revert SemKYC(alvo_);
        uint256 v = _cobrar(s, maxAgl);
        id = ++totalPedidos;
        pedidos[id] = Pedido(msg.sender, s, uint64(block.timestamp) + PRAZO_RESPOSTA, false, alvo_, v);
        agl.safeTransferFrom(msg.sender, address(this), v);
        emit PedidoCriado(id, msg.sender, alvo_, s, v);
    }

    /// @notice O dono dos dados aceita (AGL ao recebedor; a plataforma revela) ou recusa
    /// (AGL de volta a quem pediu).
    function responder(uint256 id, bool aceito) external nonReentrant {
        Pedido storage p = pedidos[id];
        if (msg.sender != p.alvo) revert SoAlvo();
        if (p.fechado) revert PedidoFechado();
        if (block.timestamp > p.ate) revert PrazoVencido();
        p.fechado = true;
        agl.safeTransfer(aceito ? recebedor : p.quem, p.valorAgl);
        emit PedidoRespondido(id, aceito);
    }

    /// @notice Sem resposta no prazo, qualquer um devolve o AGL a quem pediu.
    function devolver(uint256 id) external nonReentrant {
        Pedido storage p = pedidos[id];
        if (p.fechado) revert PedidoFechado();
        if (block.timestamp <= p.ate) revert PrazoNaoVenceu();
        p.fechado = true;
        agl.safeTransfer(p.quem, p.valorAgl);
        emit PedidoDevolvido(id);
    }

    function _cobrar(Servico s, uint256 maxAgl) internal view returns (uint256 v) {
        v = precoEmAgl(s);
        if (v > maxAgl) revert AcimaDoTeto(v, maxAgl);
    }

    // ------------------------------------------------------------ contrato

    /// @notice Registra o hash do contrato comercial (PDF cifrado no cofre) e as partes;
    /// quem registra já assina.
    function chaveContrato(bytes32 hash, address comprador_, address vendedor_) public pure returns (bytes32) {
        return keccak256(abi.encode(hash, comprador_, vendedor_));
    }

    /// @notice Assina o contrato `hash` entre `comprador_` e `vendedor_` (quem chama tem de
    /// ser um dos dois, com KYC). O primeiro a assinar cria o registro.
    function assinar(bytes32 hash, address comprador_, address vendedor_) external {
        if (hash == bytes32(0) || comprador_ == address(0) || vendedor_ == address(0) || comprador_ == vendedor_) {
            revert EnderecoZero();
        }
        if (msg.sender != comprador_ && msg.sender != vendedor_) revert SoParte();
        if (!verificado(msg.sender)) revert SemKYC(msg.sender);
        bytes32 k = chaveContrato(hash, comprador_, vendedor_);
        Contrato storage c = contratos[k];
        if (c.comprador == address(0)) {
            (c.comprador, c.vendedor) = (comprador_, vendedor_);
            emit ContratoRegistrado(hash, comprador_, vendedor_);
        }
        if (msg.sender == comprador_) c.assinouComprador = true;
        else c.assinouVendedor = true;
        emit ContratoAssinado(hash, msg.sender);
    }

    /// @notice true se comprador e vendedor assinaram o contrato `hash`.
    function contratoAssinado(bytes32 hash, address comprador_, address vendedor_) external view returns (bool) {
        Contrato storage c = contratos[chaveContrato(hash, comprador_, vendedor_)];
        return c.assinouComprador && c.assinouVendedor;
    }

    /// @notice Quem pode abrir o contrato cifrado (o cofre consulta antes de entregar):
    /// a parte que assinou, ou o supervisor quando as duas partes assinaram.
    function podeAbrir(bytes32 hash, address comprador_, address vendedor_, address carteira)
        external
        view
        returns (bool)
    {
        Contrato storage c = contratos[chaveContrato(hash, comprador_, vendedor_)];
        if (carteira == address(0)) return false;
        if (carteira == comprador_) return c.assinouComprador;
        if (carteira == vendedor_) return c.assinouVendedor;
        return carteira == supervisor && c.assinouComprador && c.assinouVendedor;
    }

    // ------------------------------------------------------------ chaves

    /// @notice Troca a carteira que grava os selos de KYC (só o supervisor).
    /// @param novo Novo atestador.
    function trocarAtestador(address novo) external {
        if (msg.sender != supervisor) revert SoSupervisor();
        if (novo == address(0)) revert EnderecoZero();
        atestador = novo;
        emit AtestadorTrocado(novo);
    }

    /// @notice Passa a supervisão (preços e atestador) (só o supervisor).
    /// @param novo Novo supervisor.
    function trocarSupervisor(address novo) external {
        if (msg.sender != supervisor) revert SoSupervisor();
        if (novo == address(0)) revert EnderecoZero();
        supervisor = novo;
        emit SupervisorTrocado(novo);
    }
}
