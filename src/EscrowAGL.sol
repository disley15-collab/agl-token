// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IRegistro {
    function verificado(address) external view returns (bool);
}

/// @title EscrowAGL — escrow de comércio agro em stablecoin, sem custódia da plataforma
///
/// Fluxo: o comprador cria a ordem JÁ depositando 100% (sem depósito não há ordem) →
/// o vendedor aceita → informa o embarque (hash dos documentos) → parcela do embarque
/// liberada → chegada → saldo liberado. Cada etapa tem prazo; o comprador confirma ou
/// contesta dentro da janela; sem contestação, a etapa libera sozinha.
///
/// @dev Invariantes (provados em test/):
/// 1. Sem dono, sem upgrade, sem pausa. Ninguém move o dinheiro para fora do par
///    comprador/vendedor, exceto a taxa de 2% (só sobre o que vai ao VENDEDOR).
/// 2. Todo reembolso devolve 100% ao comprador, sem taxa.
/// 3. O supervisor só decide disputas, e só divide entre comprador e vendedor; se não
///    decidir no prazo, qualquer um aciona o reembolso integral ao comprador.
/// 4. Pagamento por "puxar" (saldo a sacar): a blacklist de uma carteira na stablecoin
///    não trava as outras, e o titular pode sacar para outro endereço.
/// 5. Saldo do contrato em cada moeda = soma do que está travado + saldos a sacar.
contract EscrowAGL is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant TAXA_BPS = 200; // 2%, paga pelo vendedor
    uint256 public constant BPS = 10_000;
    uint256 public constant CAUCAO_DISPUTA_BPS = 100; // 1% do negócio
    uint64 public constant PRAZO_DECISAO = 30 days;
    uint64 public constant JANELA_MIN = 2 days;

    enum Etapa {
        Nenhuma,
        Depositada,
        Aceita,
        EmbarqueInformado,
        Embarcada,
        ChegadaInformada,
        EmDisputa,
        Concluida,
        Reembolsada
    }

    struct Prazos {
        uint64 aceite; // data-limite para o vendedor aceitar
        uint64 embarque; // data-limite para informar o embarque
        uint64 chegada; // data-limite para informar a chegada (após o embarque)
        uint64 janela; // tempo para o comprador contestar cada etapa informada
    }

    struct Ordem {
        address comprador;
        address vendedor;
        address moeda;
        uint96 bpsEmbarque; // parcela liberada no embarque (0..10000)
        uint256 valor; // depositado pelo comprador
        uint256 liberado; // já liberado ao vendedor (bruto, antes da taxa)
        bytes32 hashContrato; // contrato comercial (PDF cifrado fora da chain)
        bytes32 hashDocs; // documentos da etapa informada
        Prazos prazos;
        uint64 informadoEm; // quando a etapa atual foi informada
        uint64 disputaEm;
        Etapa etapa;
        Etapa etapaAntesDaDisputa;
        address quemContestou;
        uint256 caucao;
    }

    IRegistro public immutable registro;
    address public immutable carteiraTaxas;
    address public supervisor;
    mapping(address => bool) public moedaAceita;

    uint256 public totalOrdens;
    mapping(uint256 => Ordem) internal ordens;
    /// @notice Saldo a sacar por moeda e titular.
    mapping(address moeda => mapping(address titular => uint256)) public saldo;
    /// @notice Total travado em ordens abertas, por moeda.
    mapping(address => uint256) public travado;

    error MoedaNaoAceita();
    error SemKYC(address carteira);
    error ParametroInvalido();
    error EtapaErrada(Etapa atual);
    error SoComprador();
    error SoVendedor();
    error SoSupervisor();
    error SoParte();
    error PrazoNaoVenceu();
    error PrazoVencido();
    error DepositoDiferente();
    error SemSaldo();
    error EnderecoZero();

    event OrdemCriada(
        uint256 indexed id, address indexed comprador, address indexed vendedor, address moeda, uint256 valor, bytes32 hashContrato
    );
    event Aceita(uint256 indexed id);
    event EtapaInformada(uint256 indexed id, Etapa etapa, bytes32 hashDocs);
    event Liberado(uint256 indexed id, uint256 aoVendedor, uint256 taxa);
    event Reembolsado(uint256 indexed id, uint256 aoComprador);
    event Contestada(uint256 indexed id, address indexed por, uint256 caucao);
    event Decidida(uint256 indexed id, uint256 bpsAoVendedor);
    event Saque(address indexed moeda, address indexed titular, address para, uint256 valor);
    event SupervisorTrocado(address indexed supervisor);

    constructor(IRegistro _registro, address _carteiraTaxas, address _supervisor, address[] memory _moedas) {
        if (_carteiraTaxas == address(0) || _supervisor == address(0) || address(_registro) == address(0)) {
            revert EnderecoZero();
        }
        registro = _registro;
        carteiraTaxas = _carteiraTaxas;
        supervisor = _supervisor;
        for (uint256 i; i < _moedas.length; i++) moedaAceita[_moedas[i]] = true;
    }

    function ordem(uint256 _id) external view returns (Ordem memory) {
        return ordens[_id];
    }

    // ------------------------------------------------------------ criar e aceitar

    /// @notice Cria a ordem depositando 100% do valor (aprovar `_valor` antes).
    function criar(
        address _vendedor,
        address _moeda,
        uint256 _valor,
        uint96 _bpsEmbarque,
        bytes32 _hashContrato,
        Prazos calldata _prazos
    ) external nonReentrant returns (uint256 id) {
        if (!moedaAceita[_moeda]) revert MoedaNaoAceita();
        if (!registro.verificado(msg.sender)) revert SemKYC(msg.sender);
        if (!registro.verificado(_vendedor)) revert SemKYC(_vendedor);
        if (
            _vendedor == msg.sender || _valor == 0 || _bpsEmbarque > BPS || _hashContrato == bytes32(0)
                || _prazos.janela < JANELA_MIN || _prazos.aceite <= block.timestamp || _prazos.embarque <= _prazos.aceite
                || _prazos.chegada <= _prazos.embarque
        ) revert ParametroInvalido();

        id = ++totalOrdens;
        Ordem storage o = ordens[id];
        o.comprador = msg.sender;
        o.vendedor = _vendedor;
        o.moeda = _moeda;
        o.bpsEmbarque = _bpsEmbarque;
        o.valor = _valor;
        o.hashContrato = _hashContrato;
        o.prazos = _prazos;
        o.etapa = Etapa.Depositada;
        travado[_moeda] += _valor;

        uint256 antes = IERC20(_moeda).balanceOf(address(this));
        IERC20(_moeda).safeTransferFrom(msg.sender, address(this), _valor);
        if (IERC20(_moeda).balanceOf(address(this)) - antes != _valor) revert DepositoDiferente();
        emit OrdemCriada(id, msg.sender, _vendedor, _moeda, _valor, _hashContrato);
    }

    /// @notice O vendedor aceita a ordem (e o contrato de hash `hashContrato`).
    function aceitar(uint256 _id) external {
        Ordem storage o = ordens[_id];
        if (msg.sender != o.vendedor) revert SoVendedor();
        _exigir(o, Etapa.Depositada);
        if (block.timestamp > o.prazos.aceite) revert PrazoVencido();
        o.etapa = Etapa.Aceita;
        emit Aceita(_id);
    }

    // ------------------------------------------------------------ embarque e chegada

    /// @notice O vendedor informa o embarque com o hash dos documentos (B/L a bordo,
    /// inspeção, fitossanitário; apólice se CIF). Abre a janela de contestação.
    function informarEmbarque(uint256 _id, bytes32 _hashDocs) external {
        Ordem storage o = ordens[_id];
        if (msg.sender != o.vendedor) revert SoVendedor();
        _exigir(o, Etapa.Aceita);
        if (block.timestamp > o.prazos.embarque) revert PrazoVencido();
        if (_hashDocs == bytes32(0)) revert ParametroInvalido();
        o.etapa = Etapa.EmbarqueInformado;
        o.hashDocs = _hashDocs;
        o.informadoEm = uint64(block.timestamp);
        emit EtapaInformada(_id, Etapa.EmbarqueInformado, _hashDocs);
    }

    /// @notice O vendedor informa a chegada (ou entrega) com o hash dos documentos.
    function informarChegada(uint256 _id, bytes32 _hashDocs) external {
        Ordem storage o = ordens[_id];
        if (msg.sender != o.vendedor) revert SoVendedor();
        _exigir(o, Etapa.Embarcada);
        if (_hashDocs == bytes32(0)) revert ParametroInvalido();
        o.etapa = Etapa.ChegadaInformada;
        o.hashDocs = _hashDocs;
        o.informadoEm = uint64(block.timestamp);
        emit EtapaInformada(_id, Etapa.ChegadaInformada, _hashDocs);
    }

    /// @notice O comprador confirma a etapa informada (libera na hora), ou qualquer um
    /// libera depois que a janela passou sem contestação.
    function confirmar(uint256 _id) external nonReentrant {
        Ordem storage o = ordens[_id];
        if (o.etapa != Etapa.EmbarqueInformado && o.etapa != Etapa.ChegadaInformada) revert EtapaErrada(o.etapa);
        if (msg.sender != o.comprador && block.timestamp <= o.informadoEm + o.prazos.janela) revert PrazoNaoVenceu();
        if (o.etapa == Etapa.EmbarqueInformado) {
            o.etapa = Etapa.Embarcada;
            _liberar(_id, o, o.valor * o.bpsEmbarque / BPS);
            if (o.liberado == o.valor) _concluir(o);
        } else {
            _liberar(_id, o, o.valor - o.liberado);
            _concluir(o);
        }
    }

    // ------------------------------------------------------------ reembolso

    /// @notice Reembolso integral ao comprador quando um prazo vence sem a etapa:
    /// vendedor não aceitou, não informou o embarque ou não informou a chegada.
    /// Qualquer um pode acionar; o dinheiro vai sempre ao comprador.
    function reembolsarPorPrazo(uint256 _id) external nonReentrant {
        Ordem storage o = ordens[_id];
        uint64 limite;
        if (o.etapa == Etapa.Depositada) limite = o.prazos.aceite;
        else if (o.etapa == Etapa.Aceita) limite = o.prazos.embarque;
        else if (o.etapa == Etapa.Embarcada) limite = o.prazos.chegada;
        else revert EtapaErrada(o.etapa);
        if (block.timestamp <= limite) revert PrazoNaoVenceu();
        _reembolsar(_id, o);
    }

    /// @notice O comprador desiste antes do aceite, ou o vendedor desiste antes do
    /// embarque: reembolso integral ao comprador.
    function cancelar(uint256 _id) external nonReentrant {
        Ordem storage o = ordens[_id];
        bool ok = (msg.sender == o.comprador && o.etapa == Etapa.Depositada)
            || (msg.sender == o.vendedor && (o.etapa == Etapa.Depositada || o.etapa == Etapa.Aceita));
        if (!ok) revert SoParte();
        _reembolsar(_id, o);
    }

    // ------------------------------------------------------------ disputa

    /// @notice Comprador ou vendedor contesta a etapa informada, dentro da janela,
    /// depositando caução de 1% (volta a quem ganhar). Aprovar a caução antes.
    function contestar(uint256 _id) external nonReentrant {
        Ordem storage o = ordens[_id];
        if (msg.sender != o.comprador && msg.sender != o.vendedor) revert SoParte();
        if (o.etapa != Etapa.EmbarqueInformado && o.etapa != Etapa.ChegadaInformada) revert EtapaErrada(o.etapa);
        if (block.timestamp > o.informadoEm + o.prazos.janela) revert PrazoVencido();
        uint256 caucao = o.valor * CAUCAO_DISPUTA_BPS / BPS;
        o.etapaAntesDaDisputa = o.etapa;
        o.etapa = Etapa.EmDisputa;
        o.disputaEm = uint64(block.timestamp);
        o.quemContestou = msg.sender;
        o.caucao = caucao;
        travado[o.moeda] += caucao;
        uint256 antes = IERC20(o.moeda).balanceOf(address(this));
        IERC20(o.moeda).safeTransferFrom(msg.sender, address(this), caucao);
        if (IERC20(o.moeda).balanceOf(address(this)) - antes != caucao) revert DepositoDiferente();
        emit Contestada(_id, msg.sender, caucao);
    }

    /// @notice O supervisor decide: `_bpsAoVendedor` do que ainda está travado vai ao
    /// vendedor (com a taxa de 2%) e o resto volta ao comprador. A caução vai a quem
    /// ganhou: ao contestante se a decisão o favoreceu (mais da metade para o seu lado),
    /// senão à outra parte.
    function decidir(uint256 _id, uint256 _bpsAoVendedor) external nonReentrant {
        if (msg.sender != supervisor) revert SoSupervisor();
        Ordem storage o = ordens[_id];
        _exigir(o, Etapa.EmDisputa);
        if (_bpsAoVendedor > BPS) revert ParametroInvalido();
        uint256 resto = o.valor - o.liberado;
        uint256 aoVendedor = resto * _bpsAoVendedor / BPS;
        bool vendedorGanhou = _bpsAoVendedor * 2 > BPS;
        address ganhador = vendedorGanhou ? o.vendedor : o.comprador;
        _pagarCaucao(o, ganhador);
        if (aoVendedor > 0) _liberar(_id, o, aoVendedor);
        uint256 aoComprador = resto - aoVendedor;
        if (aoComprador > 0) {
            travado[o.moeda] -= aoComprador;
            saldo[o.moeda][o.comprador] += aoComprador;
            emit Reembolsado(_id, aoComprador);
        }
        _concluir(o);
        emit Decidida(_id, _bpsAoVendedor);
    }

    /// @notice Se o supervisor não decidir em 30 dias, qualquer um aciona o reembolso
    /// integral ao comprador (a caução volta a quem a pagou).
    function reembolsarPorOmissao(uint256 _id) external nonReentrant {
        Ordem storage o = ordens[_id];
        _exigir(o, Etapa.EmDisputa);
        if (block.timestamp <= o.disputaEm + PRAZO_DECISAO) revert PrazoNaoVenceu();
        _pagarCaucao(o, o.quemContestou);
        _reembolsar(_id, o);
    }

    function trocarSupervisor(address _novo) external {
        if (msg.sender != supervisor) revert SoSupervisor();
        if (_novo == address(0)) revert EnderecoZero();
        supervisor = _novo;
        emit SupervisorTrocado(_novo);
    }

    // ------------------------------------------------------------ saque

    function sacar(address _moeda) external {
        sacarPara(_moeda, msg.sender);
    }

    /// @notice Saca o próprio saldo para outro endereço (ex.: carteira bloqueada pelo
    /// emissor da stablecoin).
    function sacarPara(address _moeda, address _para) public nonReentrant {
        uint256 v = saldo[_moeda][msg.sender];
        if (v == 0) revert SemSaldo();
        if (_para == address(0)) revert EnderecoZero();
        saldo[_moeda][msg.sender] = 0;
        IERC20(_moeda).safeTransfer(_para, v);
        emit Saque(_moeda, msg.sender, _para, v);
    }

    // ------------------------------------------------------------ interno

    function _exigir(Ordem storage o, Etapa e) internal view {
        if (o.etapa != e) revert EtapaErrada(o.etapa);
    }

    /// Libera `_bruto` ao vendedor: 98% para ele, 2% para a carteira de taxas.
    function _liberar(uint256 _id, Ordem storage o, uint256 _bruto) internal {
        if (_bruto == 0) return;
        uint256 taxa = _bruto * TAXA_BPS / BPS;
        o.liberado += _bruto;
        travado[o.moeda] -= _bruto;
        saldo[o.moeda][o.vendedor] += _bruto - taxa;
        saldo[o.moeda][carteiraTaxas] += taxa;
        emit Liberado(_id, _bruto - taxa, taxa);
    }

    function _reembolsar(uint256 _id, Ordem storage o) internal {
        uint256 resto = o.valor - o.liberado;
        o.etapa = Etapa.Reembolsada;
        travado[o.moeda] -= resto;
        saldo[o.moeda][o.comprador] += resto;
        emit Reembolsado(_id, resto);
    }

    function _concluir(Ordem storage o) internal {
        o.etapa = Etapa.Concluida;
    }

    function _pagarCaucao(Ordem storage o, address _para) internal {
        uint256 c = o.caucao;
        if (c == 0) return;
        o.caucao = 0;
        travado[o.moeda] -= c;
        saldo[o.moeda][_para] += c;
    }
}
