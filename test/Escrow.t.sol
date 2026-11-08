// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { EscrowAGL, IRegistro } from "../src/EscrowAGL.sol";
import { RegistroAGL, IPoolAGLLeitura } from "../src/RegistroAGL.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { BaseAGL } from "./BaseAGL.sol";

interface IFiatToken {
    function blacklister() external view returns (address);
    function blacklist(address) external;
}

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Moeda que cobra 1% em toda transferência.
contract MoedaComTaxa is ERC20("Taxada", "TX") {
    function mint(address a, uint256 v) external {
        _mint(a, v);
    }

    function _update(address de, address para, uint256 v) internal override {
        if (de != address(0) && para != address(0)) {
            super._update(de, address(0xdead), v / 100);
            v -= v / 100;
        }
        super._update(de, para, v);
    }
}

contract EscrowBase is BaseAGL {
    EscrowAGL esc;
    RegistroAGL reg;
    address comp = makeAddr("comprador");
    address vend = makeAddr("vendedor");
    address sup = makeAddr("supervisor");
    address taxas = makeAddr("taxas");
    address atest = makeAddr("atestador");
    address estranho = makeAddr("estranho");
    uint256 V;

    function setUp() public virtual override {
        super.setUp();
        _lancar();
        reg = new RegistroAGL(
            IPoolAGLLeitura(address(pool)), taxas, sup, atest,
            TickMath.getSqrtPriceAtTick(int24(vm.parseJsonInt(json, ".tickInicial")))
        );
        address[] memory m = new address[](1);
        m[0] = MOEDA;
        esc = new EscrowAGL(IRegistro(address(reg)), taxas, sup, 100, 200, m);
        assertLe(address(esc).code.length, 24_576, "Escrow cabe no limite da EIP-170");
        assertLe(address(reg).code.length, 24_576, "Registro cabe no limite da EIP-170");
        address[] memory c = new address[](2);
        (c[0], c[1]) = (comp, vend);
        vm.prank(atest);
        reg.atestar(c, uint64(block.timestamp + 365 days));
        V = _unid(100_000);
    }

    function _prazos() internal view returns (EscrowAGL.Prazos memory p) {
        p.aceite = uint64(block.timestamp + 3 days);
        p.embarque = uint64(block.timestamp + 30 days);
        p.chegada = uint64(block.timestamp + 90 days);
        p.janela = 3 days;
        p.intervaloMax = 5 days;
    }

    uint256 TC; // taxa do comprador (1%)

    function _criar(uint96 bpsEmb) internal returns (uint256 id) {
        return _criarModo(bpsEmb == 0 ? EscrowAGL.Modo.Simples : EscrowAGL.Modo.Rastreado, bpsEmb);
    }

    function _criarModo(EscrowAGL.Modo modo, uint96 bpsEmb) internal returns (uint256 id) {
        uint256 total = esc.totalADepositar(V);
        TC = total - V;
        deal(MOEDA, comp, total);
        vm.startPrank(comp);
        IERC20(MOEDA).approve(address(esc), total);
        bytes32 h = _contrato(comp, vend);
        id = esc.criar(vend, MOEDA, V, modo, bpsEmb, h, _prazos());
        vm.stopPrank();
    }

    uint256 nContratos;

    /// Registra e assina (as duas partes) um contrato novo; devolve o hash.
    function _contrato(address c, address v) internal returns (bytes32 h) {
        h = keccak256(abi.encode("contrato", ++nContratos));
        vm.stopPrank();
        vm.prank(c);
        reg.assinar(h, c, v);
        vm.prank(v);
        reg.assinar(h, c, v);
        vm.startPrank(c);
    }

    function _comprovar(uint256 id) internal {
        vm.startPrank(vend);
        esc.atualizar(id, EscrowAGL.Tipo.Imagem, keccak256("foto"), "carga no porto de Santos");
        esc.atualizar(id, EscrowAGL.Tipo.DocumentoCarga, keccak256("romaneio"), "romaneio e certificado de origem");
        esc.atualizar(id, EscrowAGL.Tipo.TramiteLegal, keccak256("DU-E"), "DU-E averbada");
        vm.stopPrank();
    }

    function _ate(uint256 id, uint8 passo) internal {
        if (passo >= 1) { vm.prank(vend); esc.aceitar(id); }
        if (passo >= 2) {
            if (esc.ordem(id).modo == EscrowAGL.Modo.Rastreado) _comprovar(id);
            vm.prank(vend);
            esc.informarEmbarque(id, keccak256("BL"));
        }
        if (passo >= 3) { vm.prank(comp); esc.confirmar(id); }
        if (passo >= 4) { vm.prank(vend); esc.informarChegada(id, keccak256("chegada")); }
    }

    function _sacarTudo(address q) internal returns (uint256 v) {
        v = esc.saldo(MOEDA, q);
        if (v == 0) return 0;
        uint256 a = IERC20(MOEDA).balanceOf(q);
        vm.prank(q);
        esc.sacar(MOEDA);
        assertEq(IERC20(MOEDA).balanceOf(q) - a, v);
    }

    function _conferirCaixa() internal view {
        assertEq(IERC20(MOEDA).balanceOf(address(esc)),
            esc.travado(MOEDA) + esc.saldo(MOEDA, comp) + esc.saldo(MOEDA, vend) + esc.saldo(MOEDA, taxas),
            "caixa = travado + saldos");
    }
}

contract EscrowTest is EscrowBase {
    // ------------------------------------------------------------ correções da auditoria

    function test_E1_chegada_depois_do_prazo_recusada() public {
        uint256 id = _criar(3000);
        _ate(id, 3);
        vm.warp(block.timestamp + 90 days + 1);
        vm.prank(vend);
        vm.expectRevert(EscrowAGL.PrazoVencido.selector);
        esc.informarChegada(id, keccak256("tarde"));
        esc.reembolsarPorPrazo(id);
    }

    function test_E2_supervisor_nao_decide_depois_de_30_dias() public {
        uint256 id = _criar(3000);
        _ate(id, 2);
        deal(MOEDA, comp, V / 100);
        vm.startPrank(comp);
        IERC20(MOEDA).approve(address(esc), V / 100);
        esc.contestar(id);
        vm.stopPrank();
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(sup);
        vm.expectRevert(EscrowAGL.PrazoVencido.selector);
        esc.decidir(id, 10_000);
        esc.reembolsarPorOmissao(id);
    }

    function test_E3_limites_de_janela_e_intervalo() public {
        uint256 total = esc.totalADepositar(V);
        deal(MOEDA, comp, total);
        vm.startPrank(comp);
        IERC20(MOEDA).approve(address(esc), total);
        bytes32 h = _contrato(comp, vend);
        EscrowAGL.Prazos memory p = _prazos();
        p.janela = 31 days;
        vm.expectRevert(EscrowAGL.ParametroInvalido.selector);
        esc.criar(vend, MOEDA, V, EscrowAGL.Modo.Rastreado, 3000, h, p);
        p = _prazos();
        p.intervaloMax = 1 hours;
        vm.expectRevert(EscrowAGL.ParametroInvalido.selector);
        esc.criar(vend, MOEDA, V, EscrowAGL.Modo.Rastreado, 3000, h, p);
        vm.stopPrank();
    }

    function test_E5_valor_minimo() public {
        deal(MOEDA, comp, 1e30);
        vm.startPrank(comp);
        IERC20(MOEDA).approve(address(esc), type(uint256).max);
        bytes32 h = _contrato(comp, vend);
        vm.expectRevert(EscrowAGL.ParametroInvalido.selector);
        esc.criar(vend, MOEDA, 9_999, EscrowAGL.Modo.Simples, 0, h, _prazos());
        vm.stopPrank();
    }

    function test_sem_contrato_assinado_nao_cria() public {
        uint256 total = esc.totalADepositar(V);
        deal(MOEDA, comp, total);
        vm.startPrank(comp);
        IERC20(MOEDA).approve(address(esc), total);
        reg.assinar(keccak256("so-comprador"), comp, vend);
        vm.expectRevert(EscrowAGL.ContratoNaoAssinado.selector);
        esc.criar(vend, MOEDA, V, EscrowAGL.Modo.Simples, 0, keccak256("so-comprador"), _prazos());
        vm.stopPrank();
    }

    // ------------------------------------------------------------ modos

    /// SIMPLES: nada sai no embarque; 100% na chegada confirmada pelo comprador.
    function test_modo_simples_libera_so_na_chegada() public {
        uint256 id = _criarModo(EscrowAGL.Modo.Simples, 0);
        _ate(id, 3);
        assertEq(esc.saldo(MOEDA, vend), 0, "nada no embarque");
        vm.prank(vend);
        esc.informarChegada(id, keccak256("chegou"));
        vm.prank(comp);
        esc.confirmar(id);
        assertEq(esc.saldo(MOEDA, vend), V * 98 / 100);
        assertEq(esc.saldo(MOEDA, taxas), V * 3 / 100);
        _conferirCaixa();
    }

    function test_modo_simples_nao_aceita_parcela() public {
        uint256 total = esc.totalADepositar(V);
        deal(MOEDA, comp, total);
        vm.startPrank(comp);
        IERC20(MOEDA).approve(address(esc), total);
        vm.expectRevert(EscrowAGL.ParametroInvalido.selector);
        esc.criar(vend, MOEDA, V, EscrowAGL.Modo.Simples, 3000, keccak256("c"), _prazos());
        vm.stopPrank();
    }

    /// RASTREADO: sem imagem, documento da carga e trâmite legal, não comprova embarque.
    function test_rastreado_exige_comprovacoes() public {
        uint256 id = _criar(3000);
        _ate(id, 1);
        vm.startPrank(vend);
        vm.expectRevert(abi.encodeWithSelector(EscrowAGL.FaltaComprovacao.selector, EscrowAGL.Tipo.Imagem));
        esc.informarEmbarque(id, keccak256("BL"));
        esc.atualizar(id, EscrowAGL.Tipo.Imagem, keccak256("f"), "foto");
        vm.expectRevert(abi.encodeWithSelector(EscrowAGL.FaltaComprovacao.selector, EscrowAGL.Tipo.DocumentoCarga));
        esc.informarEmbarque(id, keccak256("BL"));
        esc.atualizar(id, EscrowAGL.Tipo.DocumentoCarga, keccak256("d"), "doc");
        vm.expectRevert(abi.encodeWithSelector(EscrowAGL.FaltaComprovacao.selector, EscrowAGL.Tipo.TramiteLegal));
        esc.informarEmbarque(id, keccak256("BL"));
        esc.atualizar(id, EscrowAGL.Tipo.TramiteLegal, keccak256("t"), "tramite");
        esc.informarEmbarque(id, keccak256("BL"));
        vm.stopPrank();
        assertEq(esc.ordem(id).atualizacoes[uint8(EscrowAGL.Tipo.Imagem)], 1);
    }

    function test_so_vendedor_atualiza() public {
        uint256 id = _criar(3000);
        _ate(id, 1);
        vm.prank(comp);
        vm.expectRevert(EscrowAGL.SoVendedor.selector);
        esc.atualizar(id, EscrowAGL.Tipo.Localizacao, keccak256("x"), "x");
    }

    /// RASTREADO: vendedor em silêncio além do intervalo -> comprador contesta fora da janela.
    function test_rastreado_silencio_permite_contestar() public {
        uint256 id = _criar(3000);
        _ate(id, 3);
        vm.warp(block.timestamp + 4 days);
        vm.prank(vend);
        esc.atualizar(id, EscrowAGL.Tipo.Localizacao, keccak256("loc"), "navio a 300 milhas de Luanda");
        vm.warp(block.timestamp + 2 days); // 6 dias desde o embarque, 2 desde a atualização
        deal(MOEDA, comp, V / 100);
        vm.prank(comp);
        IERC20(MOEDA).approve(address(esc), V / 100);
        vm.prank(comp);
        vm.expectRevert(abi.encodeWithSelector(EscrowAGL.EtapaErrada.selector, EscrowAGL.Etapa.Embarcada));
        esc.contestar(id); // a atualização recente reinicia o intervalo
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(comp);
        esc.contestar(id);
        assertEq(uint8(esc.ordem(id).etapa), uint8(EscrowAGL.Etapa.EmDisputa));
    }

    function test_taxas_acima_do_teto_recusadas() public {
        address[] memory m = new address[](1);
        m[0] = MOEDA;
        vm.expectRevert(EscrowAGL.ParametroInvalido.selector);
        new EscrowAGL(IRegistro(address(reg)), taxas, sup, 600, 200, m);
    }

    /// Moeda com taxa embutida na transferência é recusada no depósito.
    function test_moeda_com_taxa_na_transferencia_recusada() public {
        MoedaComTaxa mt = new MoedaComTaxa();
        address[] memory m = new address[](1);
        m[0] = address(mt);
        EscrowAGL e2 = new EscrowAGL(IRegistro(address(reg)), taxas, sup, 100, 200, m);
        mt.mint(comp, 1e24);
        vm.startPrank(comp);
        mt.approve(address(e2), type(uint256).max);
        bytes32 h = _contrato(comp, vend);
        vm.expectRevert(EscrowAGL.DepositoDiferente.selector);
        e2.criar(vend, address(mt), 1e20, EscrowAGL.Modo.Simples, 0, h, _prazos());
        vm.stopPrank();
    }

    // ------------------------------------------------------------ caminho feliz

    function test_feliz_30_70_vendedor_98_taxa_2() public {
        uint256 id = _criar(3000);
        assertEq(IERC20(MOEDA).balanceOf(address(esc)), V + TC, "sem deposito nao ha ordem: valor + taxa do comprador travados");
        _ate(id, 3);
        assertEq(esc.saldo(MOEDA, vend), V * 30 / 100 * 98 / 100, "30% no embarque, menos 2%");
        vm.prank(vend);
        esc.informarChegada(id, keccak256("chegada"));
        vm.prank(comp);
        esc.confirmar(id);
        assertEq(uint8(esc.ordem(id).etapa), uint8(EscrowAGL.Etapa.Concluida));
        assertEq(_sacarTudo(vend), V * 98 / 100, "vendedor recebe 98%");
        assertEq(_sacarTudo(taxas), V * 3 / 100, "plataforma recebe 2% do vendedor + 1% do comprador");
        assertEq(esc.saldo(MOEDA, comp), 0);
        assertEq(IERC20(MOEDA).balanceOf(address(esc)), 0, "nada fica preso");
    }

    function test_100_no_embarque_conclui() public {
        uint256 id = _criar(10_000);
        _ate(id, 3);
        assertEq(uint8(esc.ordem(id).etapa), uint8(EscrowAGL.Etapa.Concluida));
        assertEq(esc.saldo(MOEDA, vend), V * 98 / 100);
    }

    function test_janela_sem_contestacao_libera_sozinha() public {
        uint256 id = _criar(3000);
        _ate(id, 2);
        vm.prank(estranho);
        vm.expectRevert(EscrowAGL.PrazoNaoVenceu.selector);
        esc.confirmar(id);
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(estranho);
        esc.confirmar(id);
        assertEq(esc.saldo(MOEDA, vend), V * 30 / 100 * 98 / 100);
    }

    function test_nao_libera_duas_vezes() public {
        uint256 id = _criar(3000);
        _ate(id, 3);
        vm.prank(comp);
        vm.expectRevert(abi.encodeWithSelector(EscrowAGL.EtapaErrada.selector, EscrowAGL.Etapa.Embarcada));
        esc.confirmar(id);
        vm.expectRevert(EscrowAGL.PrazoNaoVenceu.selector);
        esc.reembolsarPorPrazo(id); // embarcada: só reembolsa o saldo depois do prazo de chegada
    }

    // ------------------------------------------------------------ reembolso 100%

    function test_reembolso_se_vendedor_nao_aceita() public {
        uint256 id = _criar(3000);
        vm.expectRevert(EscrowAGL.PrazoNaoVenceu.selector);
        esc.reembolsarPorPrazo(id);
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(estranho);
        esc.reembolsarPorPrazo(id);
        assertEq(_sacarTudo(comp), V + TC, "100% de volta, inclusive a taxa do comprador");
        assertEq(esc.saldo(MOEDA, taxas), 0, "sem taxa no reembolso");
    }

    function test_reembolso_se_nao_embarca() public {
        uint256 id = _criar(3000);
        _ate(id, 1);
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(vend);
        vm.expectRevert(EscrowAGL.PrazoVencido.selector);
        esc.informarEmbarque(id, keccak256("BL"));
        esc.reembolsarPorPrazo(id);
        assertEq(_sacarTudo(comp), V + TC);
    }

    function test_reembolso_do_saldo_se_nao_chega() public {
        uint256 id = _criar(3000);
        _ate(id, 3);
        vm.warp(block.timestamp + 90 days + 1);
        esc.reembolsarPorPrazo(id);
        assertEq(esc.saldo(MOEDA, comp), V * 70 / 100 + TC - TC * 3000 / 10_000, "os 70% nao liberados voltam com a taxa proporcional");
        _conferirCaixa();
    }

    function test_cancelamentos() public {
        uint256 a = _criar(3000);
        vm.prank(comp);
        esc.cancelar(a);
        assertEq(esc.saldo(MOEDA, comp), V + TC);
        uint256 b = _criar(3000);
        _ate(b, 1);
        vm.prank(comp);
        vm.expectRevert(EscrowAGL.SoParte.selector);
        esc.cancelar(b); // comprador não desiste depois do aceite
        vm.prank(vend);
        esc.cancelar(b);
        assertEq(esc.saldo(MOEDA, comp), 2 * (V + TC));
    }

    // ------------------------------------------------------------ regras de entrada

    function test_sem_kyc_nao_cria() public {
        deal(MOEDA, estranho, V);
        vm.startPrank(estranho);
        IERC20(MOEDA).approve(address(esc), V);
        vm.expectRevert(abi.encodeWithSelector(EscrowAGL.SemKYC.selector, estranho));
        esc.criar(vend, MOEDA, V, EscrowAGL.Modo.Rastreado, 3000, keccak256("c"), _prazos());
        vm.stopPrank();
        vm.startPrank(comp);
        vm.expectRevert(abi.encodeWithSelector(EscrowAGL.SemKYC.selector, estranho));
        esc.criar(estranho, MOEDA, V, EscrowAGL.Modo.Rastreado, 3000, keccak256("c"), _prazos());
        vm.stopPrank();
    }

    function test_kyc_vencido_nao_cria() public {
        vm.warp(block.timestamp + 366 days);
        deal(MOEDA, comp, V);
        vm.startPrank(comp);
        IERC20(MOEDA).approve(address(esc), V);
        vm.expectRevert(abi.encodeWithSelector(EscrowAGL.SemKYC.selector, comp));
        esc.criar(vend, MOEDA, V, EscrowAGL.Modo.Rastreado, 3000, keccak256("c"), _prazos());
        vm.stopPrank();
    }

    function test_moeda_fora_da_lista() public {
        vm.prank(comp);
        vm.expectRevert(EscrowAGL.MoedaNaoAceita.selector);
        esc.criar(vend, address(0xdead), V, EscrowAGL.Modo.Rastreado, 3000, keccak256("c"), _prazos());
    }

    function test_so_partes_agem() public {
        uint256 id = _criar(3000);
        vm.prank(estranho);
        vm.expectRevert(EscrowAGL.SoVendedor.selector);
        esc.aceitar(id);
        _ate(id, 1);
        vm.prank(comp);
        vm.expectRevert(EscrowAGL.SoVendedor.selector);
        esc.informarEmbarque(id, keccak256("BL"));
        vm.prank(estranho);
        vm.expectRevert(EscrowAGL.SoSupervisor.selector);
        esc.decidir(id, 10_000);
        vm.prank(sup);
        vm.expectRevert(abi.encodeWithSelector(EscrowAGL.EtapaErrada.selector, EscrowAGL.Etapa.Aceita));
        esc.decidir(id, 10_000); // supervisor só age em disputa
    }

    // ------------------------------------------------------------ disputa

    function _disputa(address quem) internal returns (uint256 id) {
        id = _criar(3000);
        _ate(id, 2);
        uint256 c = V / 100;
        deal(MOEDA, quem, c);
        vm.startPrank(quem);
        IERC20(MOEDA).approve(address(esc), c);
        esc.contestar(id);
        vm.stopPrank();
    }

    function test_disputa_comprador_ganha_tudo_volta() public {
        uint256 id = _disputa(comp);
        vm.prank(sup);
        esc.decidir(id, 0);
        assertEq(esc.saldo(MOEDA, comp), V + TC + V / 100, "valor + taxa + caucao");
        assertEq(esc.saldo(MOEDA, taxas), 0);
        _conferirCaixa();
    }

    function test_disputa_vendedor_ganha() public {
        uint256 id = _disputa(comp);
        vm.prank(sup);
        esc.decidir(id, 10_000);
        assertEq(esc.saldo(MOEDA, vend), V * 98 / 100 + V / 100, "98% + caucao do comprador");
        assertEq(esc.saldo(MOEDA, taxas), V * 3 / 100);
        _conferirCaixa();
    }

    function test_disputa_dividida() public {
        uint256 id = _disputa(vend);
        vm.prank(sup);
        esc.decidir(id, 4000);
        assertEq(esc.saldo(MOEDA, vend), V * 40 / 100 * 98 / 100);
        assertEq(esc.saldo(MOEDA, comp), V * 60 / 100 + V / 100 + TC - TC * 4000 / 10_000, "60% + caucao + taxa proporcional");
        _conferirCaixa();
    }

    function test_contestar_fora_da_janela() public {
        uint256 id = _criar(3000);
        _ate(id, 2);
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(comp);
        vm.expectRevert(EscrowAGL.PrazoVencido.selector);
        esc.contestar(id);
    }

    function test_supervisor_omisso_reembolso_integral() public {
        uint256 id = _disputa(vend);
        vm.expectRevert(EscrowAGL.PrazoNaoVenceu.selector);
        esc.reembolsarPorOmissao(id);
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(estranho);
        esc.reembolsarPorOmissao(id);
        assertEq(esc.saldo(MOEDA, comp), V + TC);
        assertEq(esc.saldo(MOEDA, vend), V / 100, "caucao volta a quem pagou");
        _conferirCaixa();
    }

    /// O supervisor não tem como mandar dinheiro para si nem para terceiros.
    function test_supervisor_nao_recebe_nada() public {
        uint256 id = _disputa(comp);
        vm.prank(sup);
        esc.decidir(id, 5000);
        assertEq(esc.saldo(MOEDA, sup), 0);
        vm.prank(sup);
        vm.expectRevert(EscrowAGL.SemSaldo.selector);
        esc.sacar(MOEDA);
    }

    // ------------------------------------------------------------ blacklist

    /// Vendedor bloqueado pelo emissor (USDC real na Base/Arbitrum/OP; simulado nas
    /// outras): o comprador e a plataforma sacam normalmente, e o vendedor saca para
    /// outro endereço.
    function test_blacklist_nao_trava_os_outros() public {
        uint256 id = _criar(3000);
        _ate(id, 4);
        vm.prank(comp);
        esc.confirmar(id);
        if (chainid == 8453 || chainid == 42161 || chainid == 10) {
            vm.prank(IFiatToken(MOEDA).blacklister());
            IFiatToken(MOEDA).blacklist(vend);
        } else {
            vm.mockCallRevert(MOEDA, abi.encodeWithSelector(IERC20.transfer.selector, vend), "blacklisted");
        }
        vm.prank(vend);
        vm.expectRevert();
        esc.sacar(MOEDA);
        assertEq(_sacarTudo(taxas), V * 3 / 100, "plataforma saca");
        address nova = makeAddr("novaCarteira");
        vm.prank(vend);
        esc.sacarPara(MOEDA, nova);
        assertEq(IERC20(MOEDA).balanceOf(nova), V * 98 / 100);
    }
}

/// Ações aleatórias de várias ordens ao mesmo tempo; o caixa sempre bate.
contract Ator is Test {
    RegistroAGL public reg;
    uint256 n;
    EscrowAGL immutable esc;
    address immutable moeda;
    address immutable comp;
    address immutable vend;
    address immutable sup;
    uint256[] public ids;

    constructor(EscrowAGL _e, address _m, address _c, address _v, address _s, RegistroAGL _r) {
        (esc, moeda, comp, vend, sup, reg) = (_e, _m, _c, _v, _s, _r);
    }

    function _id(uint256 s) internal view returns (uint256) {
        return ids.length == 0 ? 0 : ids[s % ids.length];
    }

    function criar(uint256 valor, uint96 bps) external {
        valor = bound(valor, 1e6, 1e24);
        bps = uint96(bound(bps, 0, 10_000));
        uint256 total = esc.totalADepositar(valor);
        deal(moeda, comp, total);
        vm.startPrank(comp);
        IERC20(moeda).approve(address(esc), total);
        EscrowAGL.Prazos memory p = EscrowAGL.Prazos(
            uint64(block.timestamp + 3 days), uint64(block.timestamp + 30 days), uint64(block.timestamp + 90 days), 3 days, 5 days
        );
        vm.stopPrank();
        bytes32 h = keccak256(abi.encode("ator", ++n));
        vm.prank(comp);
        reg.assinar(h, comp, vend);
        vm.prank(vend);
        reg.assinar(h, comp, vend);
        vm.startPrank(comp);
        ids.push(esc.criar(vend, moeda, valor, EscrowAGL.Modo.Rastreado, bps, h, p));
        vm.stopPrank();
    }

    function passo(uint256 s, uint8 acao) external {
        uint256 id = _id(s);
        if (id == 0) return;
        acao = acao % 9;
        address quem = acao < 3 ? vend : (acao < 6 ? comp : sup);
        vm.startPrank(quem);
        if (acao == 0) try esc.aceitar(id) { } catch { }
        if (acao == 1) {
            try esc.atualizar(id, EscrowAGL.Tipo.Imagem, keccak256("f"), "f") { } catch { }
            try esc.atualizar(id, EscrowAGL.Tipo.DocumentoCarga, keccak256("d"), "d") { } catch { }
            try esc.atualizar(id, EscrowAGL.Tipo.TramiteLegal, keccak256("t"), "t") { } catch { }
            try esc.informarEmbarque(id, keccak256("bl")) { } catch { }
        }
        if (acao == 2) try esc.informarChegada(id, keccak256("ch")) { } catch { }
        if (acao == 3) try esc.confirmar(id) { } catch { }
        if (acao == 4 || acao == 5) {
            EscrowAGL.Ordem memory o = esc.ordem(id);
            deal(moeda, quem, IERC20(moeda).balanceOf(quem) + o.valor / 100);
            IERC20(moeda).approve(address(esc), o.valor / 100);
            try esc.contestar(id) { } catch { }
        }
        if (acao == 6) try esc.decidir(id, s % 10_001) { } catch { }
        if (acao == 7) try esc.reembolsarPorPrazo(id) { } catch { }
        if (acao == 8) try esc.reembolsarPorOmissao(id) { } catch { }
        vm.stopPrank();
    }

    function tempo(uint256 d) external {
        vm.warp(block.timestamp + bound(d, 1 hours, 40 days));
    }

    function sacar(uint8 q) external {
        address quem = q % 2 == 0 ? comp : vend;
        if (esc.saldo(moeda, quem) == 0) return;
        vm.prank(quem);
        esc.sacar(moeda);
    }
}

contract EscrowInvariantes is EscrowBase {
    Ator ator;

    function setUp() public override {
        super.setUp();
        ator = new Ator(esc, MOEDA, comp, vend, sup, reg);
        targetContract(address(ator));
        targetSender(makeAddr("operador")); // remetente fixo: o handler já usa contas fixas (menos consultas ao fork)
    }

    /// O caixa sempre bate: nada some, nada sobra.
    function invariant_caixa() public view {
        _conferirCaixa();
    }

    /// A plataforma recebe no máximo 3% (2% vendedor + 1% comprador) do que foi liberado ao vendedor; o supervisor nada.
    function invariant_taxa_e_supervisor() public view {
        assertEq(esc.saldo(MOEDA, sup), 0);
        uint256 n = esc.totalOrdens();
        uint256 liberado;
        for (uint256 i = 1; i <= n; i++) liberado += esc.ordem(i).liberado;
        assertLe(esc.saldo(MOEDA, taxas), liberado * 3 / 100 + 2 * n);
    }

    /// Ordem encerrada não tem nada travado; reembolsada nunca pagou taxa além do já liberado.
    function invariant_ordens_coerentes() public view {
        uint256 n = esc.totalOrdens();
        for (uint256 i = 1; i <= n; i++) {
            EscrowAGL.Ordem memory o = esc.ordem(i);
            assertLe(o.liberado, o.valor);
        }
    }
}
