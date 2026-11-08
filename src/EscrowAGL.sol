// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IRegistro {
    /// @notice true se a carteira tem selo de KYC válido.
    function verificado(address) external view returns (bool);
    /// @notice true se as duas partes assinaram o contrato.
    function contratoAssinado(bytes32 hash, address comprador, address vendedor) external view returns (bool);
}

/// @title EscrowAGL — escrow de comércio agro em stablecoin, sem custódia da plataforma
/// @author AgroLastro (Solidity Brasil)
/// @custom:security-contact t.me/agrolastro
///
/// Dois modos:
/// - SIMPLES: o vendedor comprova o embarque (nota/conhecimento de transporte); o
///   pagamento sai inteiro quando a carga chega e o comprador confirma (ou a janela de
///   contestação passa sem contestação).
/// - RASTREADO: o vendedor tem de registrar imagens, documentos da carga e cópias dos
///   trâmites legais ANTES de comprovar o embarque, e atualizar a carga em trânsito no
///   máximo a cada `intervaloMax`; se ficar em silêncio, o comprador pode contestar a
///   qualquer momento. Libera uma parcela no embarque e o resto na chegada.
///
/// Sem depósito não há ordem: o comprador cria a ordem já depositando valor + taxa dele.
/// Se o vendedor não comprovar o embarque no prazo, o comprador pega 100% de volta.
///
/// @dev Invariantes (provados em test/):
/// 1. Sem dono, sem upgrade, sem pausa. O dinheiro só vai ao comprador, ao vendedor ou
///    (taxas, só quando há liberação ao vendedor) à carteira de taxas.
/// 2. Todo reembolso devolve 100% ao comprador, inclusive a taxa dele.
/// 3. O supervisor só decide disputas e só divide entre comprador e vendedor; se não
///    decidir em 30 dias, qualquer um aciona o reembolso integral ao comprador.
/// 4. Pagamento por "puxar": a blacklist de uma carteira na stablecoin não trava as
///    outras, e o titular pode sacar para outro endereço.
/// 5. Saldo do contrato em cada moeda = travado + saldos a sacar.
contract EscrowAGL is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant TAXA_MAX_BPS = 500; // teto de 5% para cada lado
    uint256 public constant CAUCAO_DISPUTA_BPS = 100; // 1% do negócio
    uint64 public constant PRAZO_DECISAO = 30 days;
    uint64 public constant JANELA_MIN = 2 days;
    uint64 public constant JANELA_MAX = 30 days;
    uint64 public constant INTERVALO_MIN = 1 days;
    uint64 public constant INTERVALO_MAX = 30 days;
    /// @notice Valor mínimo da ordem (unidades da moeda): abaixo disso as taxas arredondam a zero.
    uint256 public constant VALOR_MIN = BPS;
    /// @notice Valor máximo da ordem: metade do uint128, para valor + taxa + caução caberem.
    uint256 public constant VALOR_MAX = type(uint128).max / 2;

    enum Modo {
        Simples,
        Rastreado
    }

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

    /// Tipos de atualização do vendedor (o arquivo fica no cofre de documentos; aqui só o hash).
    enum Tipo {
        Localizacao,
        Imagem,
        DocumentoCarga,
        TramiteLegal,
        Outro
    }

    struct Prazos {
        uint64 aceite; // data-limite para o vendedor aceitar
        uint64 embarque; // data-limite para comprovar o embarque
        uint64 chegada; // data-limite para informar a chegada
        uint32 janela; // tempo para contestar cada etapa informada (segundos)
        uint32 intervaloMax; // RASTREADO: tempo máximo sem atualização em trânsito (segundos)
    }

    /// Campos ordenados para caber em 11 slots de storage (antes, ~21).
    struct Ordem {
        // slot 0
        address comprador;
        Modo modo;
        Etapa etapa;
        Etapa etapaAntesDaDisputa;
        uint16 bpsEmbarque; // RASTREADO: parcela liberada no embarque (0..10000)
        // slot 1
        address vendedor;
        uint64 informadoEm;
        // slot 2
        address moeda;
        uint64 ultimaAtualizacao;
        // slot 3
        address quemContestou;
        uint64 disputaEm;
        // slot 4
        uint128 valor; // valor da mercadoria
        uint128 taxaComprador; // travada junto com o valor; devolvida no reembolso
        // slot 5
        uint128 liberado; // já liberado ao vendedor (bruto, antes da taxa)
        uint128 taxaCompradorUsada; // parte da taxa do comprador já paga ou devolvida
        // slot 6
        uint128 caucao;
        // slot 7
        Prazos prazos;
        // slots 8, 9, 10
        bytes32 hashContrato;
        bytes32 hashDocs;
        uint32[5] atualizacoes; // contagem por Tipo
    }

    IRegistro public immutable registro;
    address public immutable carteiraTaxas;
    uint256 public immutable taxaCompradorBps;
    uint256 public immutable taxaVendedorBps;
    address public supervisor;
    mapping(address => bool) public moedaAceita;

    uint256 public totalOrdens;
    mapping(uint256 => Ordem) internal ordens;
    mapping(address moeda => mapping(address titular => uint256)) public saldo;
    mapping(address => uint256) public travado;

    error MoedaNaoAceita();
    error SemKYC(address carteira);
    error ParametroInvalido();
    error EtapaErrada(Etapa atual);
    error SoVendedor();
    error SoSupervisor();
    error SoParte();
    error PrazoNaoVenceu();
    error PrazoVencido();
    error FaltaComprovacao(Tipo tipo);
    error DepositoDiferente();
    error ContratoNaoAssinado();
    error SemSaldo();
    error EnderecoZero();

    event OrdemCriada(
        uint256 indexed id,
        address indexed comprador,
        address indexed vendedor,
        address moeda,
        uint256 valor,
        Modo modo,
        bytes32 hashContrato
    );
    event Aceita(uint256 indexed id);
    event Atualizacao(uint256 indexed id, Tipo indexed tipo, bytes32 hash, string descricao);
    event EtapaInformada(uint256 indexed id, Etapa etapa, bytes32 hashDocs);
    event Liberado(uint256 indexed id, uint256 aoVendedor, uint256 taxaVendedor, uint256 taxaComprador);
    event Reembolsado(uint256 indexed id, uint256 aoComprador);
    event Contestada(uint256 indexed id, address indexed por, uint256 caucao);
    event Decidida(uint256 indexed id, uint256 bpsAoVendedor);
    event Saque(address indexed moeda, address indexed titular, address para, uint256 valor);
    event SupervisorTrocado(address indexed supervisor);

    constructor(
        IRegistro registro_,
        address carteiraTaxas_,
        address supervisor_,
        uint256 taxaCompradorBps_,
        uint256 taxaVendedorBps_,
        address[] memory moedas
    ) {
        if (carteiraTaxas_ == address(0) || supervisor_ == address(0) || address(registro_) == address(0)) {
            revert EnderecoZero();
        }
        if (taxaCompradorBps_ > TAXA_MAX_BPS || taxaVendedorBps_ > TAXA_MAX_BPS) revert ParametroInvalido();
        registro = registro_;
        carteiraTaxas = carteiraTaxas_;
        supervisor = supervisor_;
        taxaCompradorBps = taxaCompradorBps_;
        taxaVendedorBps = taxaVendedorBps_;
        for (uint256 i; i < moedas.length; i++) {
            moedaAceita[moedas[i]] = true;
        }
    }

    /// @notice Todos os dados de uma ordem.
    /// @param id Número da ordem.
    function ordem(uint256 id) external view returns (Ordem memory) {
        return ordens[id];
    }

    /// @notice Quanto o comprador deposita para uma ordem de `valor_`.
    function totalADepositar(uint256 valor_) public view returns (uint256) {
        return valor_ + valor_ * taxaCompradorBps / BPS;
    }

    // ------------------------------------------------------------ criar e aceitar

    /// @notice Cria a ordem depositando valor + taxa do comprador (aprovar
    /// `totalADepositar(valor_)` antes). No modo SIMPLES `bpsEmbarque_` tem de ser 0.
    function criar(
        address vendedor_,
        address moeda_,
        uint256 valor_,
        Modo modo_,
        uint16 bpsEmbarque_,
        bytes32 hashContrato_,
        Prazos calldata prazos_
    ) external nonReentrant returns (uint256 id) {
        if (!moedaAceita[moeda_]) revert MoedaNaoAceita();
        if (!registro.verificado(msg.sender)) revert SemKYC(msg.sender);
        if (!registro.verificado(vendedor_)) revert SemKYC(vendedor_);
        if (
            vendedor_ == msg.sender || valor_ < VALOR_MIN || valor_ > VALOR_MAX || bpsEmbarque_ > BPS
                || hashContrato_ == bytes32(0) || prazos_.janela < JANELA_MIN || prazos_.janela > JANELA_MAX
                || prazos_.aceite <= block.timestamp || prazos_.embarque <= prazos_.aceite
                || prazos_.chegada <= prazos_.embarque || (modo_ == Modo.Simples && bpsEmbarque_ != 0)
                || (modo_ == Modo.Rastreado
                    && (prazos_.intervaloMax < INTERVALO_MIN || prazos_.intervaloMax > INTERVALO_MAX))
        ) revert ParametroInvalido();
        if (!registro.contratoAssinado(hashContrato_, msg.sender, vendedor_)) revert ContratoNaoAssinado();

        id = ++totalOrdens;
        Ordem storage o = ordens[id];
        o.comprador = msg.sender;
        o.vendedor = vendedor_;
        o.moeda = moeda_;
        o.modo = modo_;
        o.bpsEmbarque = bpsEmbarque_;
        o.valor = uint128(valor_); // <= VALOR_MAX
        o.taxaComprador = uint128(valor_ * taxaCompradorBps / BPS);
        o.hashContrato = hashContrato_;
        o.prazos = prazos_;
        o.etapa = Etapa.Depositada;
        uint256 total = valor_ + o.taxaComprador;
        travado[moeda_] += total;

        uint256 antes = IERC20(moeda_).balanceOf(address(this));
        IERC20(moeda_).safeTransferFrom(msg.sender, address(this), total);
        if (IERC20(moeda_).balanceOf(address(this)) - antes != total) revert DepositoDiferente();
        emit OrdemCriada(id, msg.sender, vendedor_, moeda_, valor_, modo_, hashContrato_);
    }

    /// @notice O vendedor aceita a ordem (e o contrato de hash `hashContrato`).
    function aceitar(uint256 id) external {
        Ordem storage o = ordens[id];
        if (msg.sender != o.vendedor) revert SoVendedor();
        _exigir(o, Etapa.Depositada);
        if (block.timestamp > o.prazos.aceite) revert PrazoVencido();
        o.etapa = Etapa.Aceita;
        o.ultimaAtualizacao = uint64(block.timestamp);
        emit Aceita(id);
    }

    // ------------------------------------------------------------ rastreio

    /// @notice O vendedor registra uma atualização: localização, imagem, documento da carga
    /// ou cópia de trâmite legal (o arquivo vai para o cofre de documentos; aqui fica o hash).
    function atualizar(uint256 id, Tipo tipo, bytes32 hash, string calldata descricao) external {
        Ordem storage o = ordens[id];
        if (msg.sender != o.vendedor) revert SoVendedor();
        if (o.etapa != Etapa.Aceita && o.etapa != Etapa.EmbarqueInformado && o.etapa != Etapa.Embarcada) {
            revert EtapaErrada(o.etapa);
        }
        if (hash == bytes32(0) || bytes(descricao).length > 280) revert ParametroInvalido();
        o.atualizacoes[uint8(tipo)] += 1;
        o.ultimaAtualizacao = uint64(block.timestamp);
        emit Atualizacao(id, tipo, hash, descricao);
    }

    // ------------------------------------------------------------ embarque e chegada

    /// @notice O vendedor comprova o embarque com o hash dos documentos (nota/conhecimento
    /// de transporte a bordo, inspeção, fitossanitário; apólice se CIF). No modo RASTREADO,
    /// exige antes ao menos uma imagem, um documento da carga e um trâmite legal.
    function informarEmbarque(uint256 id, bytes32 hashDocs_) external {
        Ordem storage o = ordens[id];
        if (msg.sender != o.vendedor) revert SoVendedor();
        _exigir(o, Etapa.Aceita);
        if (block.timestamp > o.prazos.embarque) revert PrazoVencido();
        if (hashDocs_ == bytes32(0)) revert ParametroInvalido();
        if (o.modo == Modo.Rastreado) {
            if (o.atualizacoes[uint8(Tipo.Imagem)] == 0) revert FaltaComprovacao(Tipo.Imagem);
            if (o.atualizacoes[uint8(Tipo.DocumentoCarga)] == 0) revert FaltaComprovacao(Tipo.DocumentoCarga);
            if (o.atualizacoes[uint8(Tipo.TramiteLegal)] == 0) revert FaltaComprovacao(Tipo.TramiteLegal);
        }
        o.etapa = Etapa.EmbarqueInformado;
        o.hashDocs = hashDocs_;
        o.informadoEm = uint64(block.timestamp);
        o.ultimaAtualizacao = uint64(block.timestamp);
        emit EtapaInformada(id, Etapa.EmbarqueInformado, hashDocs_);
    }

    /// @notice O vendedor informa a chegada (ou entrega) com o hash dos documentos.
    function informarChegada(uint256 id, bytes32 hashDocs_) external {
        Ordem storage o = ordens[id];
        if (msg.sender != o.vendedor) revert SoVendedor();
        _exigir(o, Etapa.Embarcada);
        if (block.timestamp > o.prazos.chegada) revert PrazoVencido();
        if (hashDocs_ == bytes32(0)) revert ParametroInvalido();
        o.etapa = Etapa.ChegadaInformada;
        o.hashDocs = hashDocs_;
        o.informadoEm = uint64(block.timestamp);
        o.ultimaAtualizacao = uint64(block.timestamp);
        emit EtapaInformada(id, Etapa.ChegadaInformada, hashDocs_);
    }

    /// @notice O comprador confirma a etapa informada (libera na hora), ou qualquer um
    /// avança depois que a janela passou sem contestação.
    function confirmar(uint256 id) external nonReentrant {
        Ordem storage o = ordens[id];
        if (o.etapa != Etapa.EmbarqueInformado && o.etapa != Etapa.ChegadaInformada) revert EtapaErrada(o.etapa);
        if (msg.sender != o.comprador && block.timestamp <= o.informadoEm + o.prazos.janela) revert PrazoNaoVenceu();
        if (o.etapa == Etapa.EmbarqueInformado) {
            o.etapa = Etapa.Embarcada;
            o.ultimaAtualizacao = uint64(block.timestamp);
            _liberar(id, o, uint256(o.valor) * o.bpsEmbarque / BPS);
            if (o.liberado >= o.valor) o.etapa = Etapa.Concluida;
        } else {
            _liberar(id, o, o.valor - o.liberado);
            o.etapa = Etapa.Concluida;
        }
    }

    // ------------------------------------------------------------ reembolso

    /// @notice Reembolso integral ao comprador quando um prazo vence sem a etapa: vendedor
    /// não aceitou, não comprovou o embarque ou não informou a chegada. Qualquer um pode
    /// acionar; o dinheiro (valor + taxa do comprador ainda travados) vai ao comprador.
    function reembolsarPorPrazo(uint256 id) external nonReentrant {
        Ordem storage o = ordens[id];
        uint64 limite = 0;
        if (o.etapa == Etapa.Depositada) limite = o.prazos.aceite;
        else if (o.etapa == Etapa.Aceita) limite = o.prazos.embarque;
        else if (o.etapa == Etapa.Embarcada) limite = o.prazos.chegada;
        else revert EtapaErrada(o.etapa);
        if (block.timestamp <= limite) revert PrazoNaoVenceu();
        _reembolsar(id, o);
    }

    /// @notice O comprador desiste antes do aceite, ou o vendedor desiste antes do embarque.
    function cancelar(uint256 id) external nonReentrant {
        Ordem storage o = ordens[id];
        bool ok = (msg.sender == o.comprador && o.etapa == Etapa.Depositada)
            || (msg.sender == o.vendedor && (o.etapa == Etapa.Depositada || o.etapa == Etapa.Aceita));
        if (!ok) revert SoParte();
        _reembolsar(id, o);
    }

    // ------------------------------------------------------------ disputa

    /// @notice Contesta a etapa informada dentro da janela. No modo RASTREADO, o comprador
    /// também pode contestar a carga em trânsito se o vendedor ficou mais de `intervaloMax`
    /// sem atualizar. Caução de 1% (volta a quem ganhar); aprovar antes.
    function contestar(uint256 id) external nonReentrant {
        Ordem storage o = ordens[id];
        if (msg.sender != o.comprador && msg.sender != o.vendedor) revert SoParte();
        bool informada = o.etapa == Etapa.EmbarqueInformado || o.etapa == Etapa.ChegadaInformada;
        bool silencio = o.modo == Modo.Rastreado && o.etapa == Etapa.Embarcada && msg.sender == o.comprador
            && block.timestamp > o.ultimaAtualizacao + o.prazos.intervaloMax;
        if (!informada && !silencio) revert EtapaErrada(o.etapa);
        if (informada && block.timestamp > o.informadoEm + o.prazos.janela) revert PrazoVencido();
        uint256 caucao = o.valor * CAUCAO_DISPUTA_BPS / BPS;
        o.etapaAntesDaDisputa = o.etapa;
        o.etapa = Etapa.EmDisputa;
        o.disputaEm = uint64(block.timestamp);
        o.quemContestou = msg.sender;
        o.caucao = uint128(caucao);
        travado[o.moeda] += caucao;
        uint256 antes = IERC20(o.moeda).balanceOf(address(this));
        IERC20(o.moeda).safeTransferFrom(msg.sender, address(this), caucao);
        if (IERC20(o.moeda).balanceOf(address(this)) - antes != caucao) revert DepositoDiferente();
        emit Contestada(id, msg.sender, caucao);
    }

    /// @notice O supervisor decide: `bpsAoVendedor` do valor ainda travado vai ao vendedor
    /// (com as taxas proporcionais) e o resto volta ao comprador (com a taxa dele). A caução
    /// vai a quem ganhou (mais da metade para o seu lado).
    function decidir(uint256 id, uint256 bpsAoVendedor) external nonReentrant {
        if (msg.sender != supervisor) revert SoSupervisor();
        Ordem storage o = ordens[id];
        _exigir(o, Etapa.EmDisputa);
        if (block.timestamp > o.disputaEm + PRAZO_DECISAO) revert PrazoVencido();
        if (bpsAoVendedor > BPS) revert ParametroInvalido();
        uint256 resto = o.valor - o.liberado;
        uint256 aoVendedor = resto * bpsAoVendedor / BPS;
        _pagarCaucao(o, bpsAoVendedor * 2 > BPS ? o.vendedor : o.comprador);
        _liberar(id, o, aoVendedor);
        _reembolsar(id, o);
        if (aoVendedor > 0) o.etapa = Etapa.Concluida;
        emit Decidida(id, bpsAoVendedor);
    }

    /// @notice Se o supervisor não decidir em 30 dias, qualquer um aciona o reembolso
    /// integral ao comprador (a caução volta a quem a pagou).
    function reembolsarPorOmissao(uint256 id) external nonReentrant {
        Ordem storage o = ordens[id];
        _exigir(o, Etapa.EmDisputa);
        if (block.timestamp <= o.disputaEm + PRAZO_DECISAO) revert PrazoNaoVenceu();
        _pagarCaucao(o, o.quemContestou);
        _reembolsar(id, o);
    }

    /// @notice Passa a supervisão das disputas (só o supervisor chama).
    /// @param novo Novo supervisor.
    function trocarSupervisor(address novo) external {
        if (msg.sender != supervisor) revert SoSupervisor();
        if (novo == address(0)) revert EnderecoZero();
        supervisor = novo;
        emit SupervisorTrocado(novo);
    }

    // ------------------------------------------------------------ saque

    /// @notice Saca o próprio saldo de `moeda_` para a própria carteira.
    /// @param moeda_ Stablecoin a sacar.
    function sacar(address moeda_) external {
        sacarPara(moeda_, msg.sender);
    }

    /// @notice Saca o próprio saldo para outro endereço (ex.: carteira bloqueada pelo
    /// emissor da stablecoin).
    function sacarPara(address moeda_, address para) public nonReentrant {
        uint256 v = saldo[moeda_][msg.sender];
        if (v == 0) revert SemSaldo();
        if (para == address(0)) revert EnderecoZero();
        saldo[moeda_][msg.sender] = 0;
        IERC20(moeda_).safeTransfer(para, v);
        emit Saque(moeda_, msg.sender, para, v);
    }

    // ------------------------------------------------------------ interno

    function _exigir(Ordem storage o, Etapa e) internal view {
        if (o.etapa != e) revert EtapaErrada(o.etapa);
    }

    /// Libera `bruto` do valor ao vendedor: ele recebe `bruto` menos a taxa dele; a
    /// carteira de taxas recebe a taxa do vendedor + a parte proporcional da taxa do comprador.
    function _liberar(uint256 id, Ordem storage o, uint256 bruto) internal {
        // slither-disable-next-line incorrect-equality (retorno antecipado: nada a liberar)
        if (bruto == 0) return;
        uint256 tv = bruto * taxaVendedorBps / BPS;
        uint256 tc = o.liberado + bruto >= o.valor
            ? o.taxaComprador - o.taxaCompradorUsada
            : uint256(o.taxaComprador) * bruto / o.valor;
        o.liberado += uint128(bruto);
        travado[o.moeda] -= bruto + tc;
        saldo[o.moeda][o.vendedor] += bruto - tv;
        saldo[o.moeda][carteiraTaxas] += tv + tc;
        o.taxaCompradorUsada += uint128(tc);
        emit Liberado(id, bruto - tv, tv, tc);
    }

    /// Devolve ao comprador o valor ainda não liberado + a taxa dele ainda travada.
    function _reembolsar(uint256 id, Ordem storage o) internal {
        uint256 resto = o.valor - o.liberado;
        uint256 tc = o.taxaComprador - o.taxaCompradorUsada;
        o.etapa = Etapa.Reembolsada;
        uint256 total = resto + tc;
        if (total == 0) return;
        o.taxaCompradorUsada += uint128(tc); // nada mais travado desta ordem
        travado[o.moeda] -= total;
        saldo[o.moeda][o.comprador] += total;
        emit Reembolsado(id, total);
    }

    function _pagarCaucao(Ordem storage o, address para) internal {
        uint256 c = o.caucao;
        if (c == 0) return;
        o.caucao = 0;
        travado[o.moeda] -= c;
        saldo[o.moeda][para] += c;
    }
}
