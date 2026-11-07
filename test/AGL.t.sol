// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { ModifyLiquidityParams, SwapParams } from "v4-core/types/PoolOperation.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { AGL } from "../src/AGL.sol";
import { PoolAGL } from "../src/PoolAGL.sol";
import { ICreateX } from "../src/ICreateX.sol";
import { BaseAGL } from "./BaseAGL.sol";

/// Faz vários swaps numa transação só e lê a cota no fim (transient storage).
contract Sequencia {
    receive() external payable { } // o roteador de teste devolve saldo nativo que já exista no endereço dele
    function compraEVenda(PoolSwapTest r, PoolAGL p, AGL t, address moeda, uint256 v) external returns (int256, int256) {
        bool t0 = p.tokenEhMoeda0();
        IERC20(moeda).approve(address(r), type(uint256).max);
        t.approve(address(r), type(uint256).max);
        uint256 antes = t.balanceOf(address(this));
        r.swap(p.chave(), SwapParams(!t0, -int256(v), t0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false), "");
        int256 depoisCompra = p.cota();
        uint256 q = t.balanceOf(address(this)) - antes;
        r.swap(p.chave(), SwapParams(t0, -int256(q), t0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false), "");
        return (depoisCompra, p.cota());
    }
}

/// Pool falsa: responde token0()/token1() com o AGL (como pools v2/v3 e clones).
contract PoolFalsaAGL {
    address public token0;
    address public token1;

    constructor(address _agl, address _outro) {
        (token0, token1) = (_outro, _agl);
    }
}

/// Pool estilo Curve: coins(i).
contract PoolCurveAGL {
    address immutable agl;

    constructor(address _agl) {
        agl = _agl;
    }

    function coins(uint256 i) external view returns (address) {
        return i == 0 ? agl : address(0xdead);
    }
}

/// Contrato que responde token0() com lixo (não é endereço): não pode travar a transferência.
contract RespostaEstranha {
    function token0() external pure returns (uint256) {
        return type(uint256).max;
    }
}

/// Simula um contrato qualquer (executor de agregador, carteira inteligente...).
contract PoolQualquer {
    function receber() external { }
}

contract AGLTest is BaseAGL {
    uint256 constant SUPPLY = 1e30;

    // ------------------------------------------------------------ lançamento

    function test_lancamento_100pct_na_pool_numa_transacao() public {
        _lancar();
        assertEq(t.totalSupply(), SUPPLY, "1 sextilhao nesta rede");
        uint256 noPM = t.balanceOf(address(PM));
        uint256 poeira = t.balanceOf(address(pool));
        assertEq(noPM + poeira, SUPPLY, "100% na pool");
        assertLt(poeira, SUPPLY / 1e9, "poeira de arredondamento");
        assertEq(t.balanceOf(DONO), 0, "dono nao tem reserva");
        assertEq(pool.cota(), 0, "cota zerada depois do lancamento");
        assertEq(t.decimals(), 9);
        assertEq(t.symbol(), "AGL");
        PoolAGL.Faixa[] memory fx = pool.todasAsFaixas();
        assertEq(fx.length, 20);
        for (uint256 i; i < fx.length; i++) assertGt(_liquidez(fx[i]), 0);
        assertEq(_tick(), int24(vm.parseJsonInt(json, ".tickInicial")));
        assertEq(Currency.unwrap(pool.moeda()), MOEDA, "pareada com USDC");
    }

    function test_rede_fora_da_lista() public {
        pool = _publicarPool();
        vm.chainId(5);
        vm.expectRevert(abi.encodeWithSelector(AGL.RedeForaDaLista.selector, uint256(5)));
        new AGL(address(pool), DONO, 0x1a44076050125825900e736c501f859c50fE728c, DONO);
    }

    function test_so_lancador_e_uma_vez() public {
        pool = _publicarPool();
        json = _escada(_enderecoToken());
        PoolAGL.Faixa[] memory fx = _faixas();
        int24 ti = int24(vm.parseJsonInt(json, ".tickInicial"));
        vm.prank(atacante);
        vm.expectRevert(PoolAGL.SoLancador.selector);
        pool.lancar(_saltToken(), ti, fx);
        vm.prank(DEPLOYER);
        pool.lancar(_saltToken(), ti, fx);
        vm.prank(DEPLOYER);
        vm.expectRevert(PoolAGL.JaLancado.selector);
        pool.lancar(_saltToken(), ti, fx);
    }

    function test_degrau_abaixo_do_preco_recusado() public {
        pool = _publicarPool();
        json = _escada(_enderecoToken());
        PoolAGL.Faixa[] memory fx = _faixas();
        int24 ti = int24(vm.parseJsonInt(json, ".tickInicial"));
        bool t0 = _enderecoToken() < MOEDA;
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(PoolAGL.FaixaFora.selector, uint256(0)));
        pool.lancar(_saltToken(), t0 ? ti + 10 : ti - 10, fx);
    }

    function test_ultimo_degrau_recebe_a_sobra() public {
        pool = _publicarPool();
        json = _escada(_enderecoToken());
        PoolAGL.Faixa[] memory fx = _faixas();
        fx[fx.length - 1].quantidade = 1;
        vm.prank(DEPLOYER);
        pool.lancar(_saltToken(), int24(vm.parseJsonInt(json, ".tickInicial")), fx);
        PoolAGL.Faixa[] memory g = pool.todasAsFaixas();
        uint256 soma;
        for (uint256 i; i < g.length; i++) soma += g[i].quantidade;
        assertEq(soma, SUPPLY);
    }

    function test_S3_salt_do_token_precisa_ser_protegido() public {
        pool = _publicarPool();
        json = _escada(_enderecoToken());
        PoolAGL.Faixa[] memory fx = _faixas();
        bytes32 semProtecao = bytes32(uint256(_saltToken()) & ((1 << 96) - 1)); // 20 bytes zerados
        vm.prank(DEPLOYER);
        vm.expectRevert(PoolAGL.SaltSemProtecao.selector);
        pool.lancar(semProtecao, int24(vm.parseJsonInt(json, ".tickInicial")), fx);
    }

    function test_endereco_de_hook_errado_recusado() public {
        vm.expectRevert(PoolAGL.EnderecoDeHookErrado.selector);
        new PoolAGL(PM, DEPLOYER, MOEDA, DONO, DONO);
    }

    function test_atacante_nao_toma_endereco_do_token() public {
        pool = _publicarPool();
        address previsto = _enderecoToken();
        vm.prank(atacante);
        address dele = ICreateX(CREATEX).deployCreate3(_saltToken(), type(PoolQualquer).creationCode);
        assertTrue(dele != previsto);
        _lancarNaPool();
        assertEq(address(t), previsto);
    }

    function _lancarNaPool() internal {
        json = _escada(_enderecoToken());
        PoolAGL.Faixa[] memory fx = _faixas();
        vm.prank(DEPLOYER);
        pool.lancar(_saltToken(), int24(vm.parseJsonInt(json, ".tickInicial")), fx);
        t = AGL(Currency.unwrap(pool.token()));
    }

    // ------------------------------------------------------------ pré-inicialização e JIT

    function test_pre_inicializacao_recusada() public {
        pool = _publicarPool();
        address tk = _enderecoToken();
        (Currency c0, Currency c1) =
            tk < MOEDA ? (Currency.wrap(tk), Currency.wrap(MOEDA)) : (Currency.wrap(MOEDA), Currency.wrap(tk));
        vm.prank(atacante);
        vm.expectRevert();
        PM.initialize(PoolKey(c0, c1, 20_000, 10, IHooks(address(pool))), TickMath.getSqrtPriceAtTick(0));
    }

    function test_liquidez_de_terceiro_recusada() public {
        _lancar();
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(PM);
        deal(MOEDA, atacante, _unid(1000));
        vm.startPrank(atacante);
        IERC20(MOEDA).approve(address(lp), type(uint256).max);
        int24 tk = (_tick() / 10) * 10;
        PoolKey memory k = pool.chave();
        vm.expectRevert();
        lp.modifyLiquidity(k, ModifyLiquidityParams(tk - 1000, tk - 500, 1e15, 0), "");
        vm.stopPrank();
    }

    // ------------------------------------------------------------ comprar, vender, taxa

    function test_compra_venda_e_preco_estavel() public {
        _lancar();
        uint256 r = _comprar(comprador, _unid(1_000_000));
        // US$ 1 mi a US$ 1e-9 = ~9,8e14 AGL (com 2% de taxa) = 9,8e23 unidades
        assertApproxEqRel(r, 980_000_000_000_000 * 1e9, 0.001e18, "preco ~US$1e-9");
        int24 depois = _tick();
        int24 antes = int24(vm.parseJsonInt(json, ".tickInicial"));
        int24 dif = depois > antes ? depois - antes : antes - depois;
        assertLt(dif, 5, "US$1 mi quase nao mexe no preco");
        uint256 v = _vender(comprador, r);
        assertGt(v, _unid(1_000_000) * 95 / 100);
    }

    function test_taxa_2pct_para_o_dono() public {
        _lancar();
        _comprar(comprador, _unid(10_000));
        uint256 antes = IERC20(MOEDA).balanceOf(DONO);
        vm.prank(atacante);
        pool.coletarTaxas(); // qualquer um traz as taxas; só o recebedor saca
        Currency m = pool.moeda();
        vm.prank(atacante);
        vm.expectRevert(PoolAGL.SoRecebedor.selector);
        pool.sacarTaxas(m, atacante);
        vm.prank(DONO);
        pool.sacarTaxas(m, DONO);
        assertApproxEqRel(IERC20(MOEDA).balanceOf(DONO) - antes, _unid(200), 0.001e18);
        // taxa da venda chega em AGL
        _vender(comprador, t.balanceOf(comprador));
        pool.coletarTaxas();
        Currency tk = pool.token();
        vm.prank(DONO);
        pool.sacarTaxas(tk, DONO);
        assertGt(t.balanceOf(DONO), 0);
    }

    function test_saque_de_taxas_nao_repete() public {
        _lancar();
        _comprar(comprador, _unid(10_000));
        pool.coletarTaxas();
        Currency m = pool.moeda();
        vm.startPrank(DONO);
        pool.sacarTaxas(m, DONO);
        uint256 depois = IERC20(MOEDA).balanceOf(DONO);
        pool.sacarTaxas(m, DONO); // segunda vez: nada a sacar
        vm.stopPrank();
        assertEq(IERC20(MOEDA).balanceOf(DONO), depois);
        assertEq(pool.aSacar(MOEDA), 0);
    }

    /// C1/C2 (auditoria): destino recusado numa moeda não trava a outra.
    function test_C1_saque_por_moeda_nao_trava() public {
        _lancar();
        uint256 r = _comprar(comprador, _unid(10_000));
        _vender(comprador, r / 2);
        pool.coletarTaxas();
        PoolFalsaAGL cofre = new PoolFalsaAGL(address(t), MOEDA); // destino que recusa AGL
        (Currency tk, Currency m) = (pool.token(), pool.moeda());
        vm.startPrank(DONO);
        vm.expectRevert(abi.encodeWithSelector(AGL.PoolNaoAutorizada.selector, address(cofre)));
        pool.sacarTaxas(tk, address(cofre));
        pool.sacarTaxas(m, address(cofre)); // USDC sai normalmente
        pool.sacarTaxas(tk, DONO); // AGL para outro destino
        vm.stopPrank();
        assertGt(IERC20(MOEDA).balanceOf(address(cofre)), 0);
        assertGt(t.balanceOf(DONO), 0);
    }

    /// A2 (auditoria): ida e volta na pool oficial não fabrica cota.
    function test_A2_ida_e_volta_nao_deixa_cota() public {
        _lancar();
        assertEq(pool.cota(), 0);
        Sequencia sq = new Sequencia();
        address[] memory l = new address[](1);
        l[0] = address(sq);
        vm.prank(DONO);
        t.permitir(l);
        deal(MOEDA, address(sq), _unid(1000));
        (int256 c1, int256 c2) = sq.compraEVenda(router, pool, t, MOEDA, _unid(1000));
        assertEq(c1, 0, "compra liquidada consome toda a cota");
        assertEq(c2, 0, "venda liquidada consome toda a cota");
    }

    function test_liquidez_travada() public {
        _lancar();
        PoolAGL.Faixa[] memory fx = pool.todasAsFaixas();
        uint128 l0 = _liquidez(fx[0]);
        uint256 r = _comprar(comprador, _unid(100_000));
        pool.coletarTaxas();
        _vender(comprador, r);
        pool.coletarTaxas();
        assertEq(_liquidez(fx[0]), l0);
    }

    // ------------------------------------------------------------ TRAVA: outras pools

    /// Pool v4 de terceiro (sem hook, taxa 94%) para o AGL: pode ser criada, mas não
    /// recebe AGL (o token recusa entrada no PoolManager fora da cota da pool oficial).
    function test_pool_v4_de_terceiro_nao_recebe_agl() public {
        _lancar();
        uint256 r = _comprar(atacante, _unid(1000));
        address tk = address(t);
        (Currency c0, Currency c1) =
            tk < MOEDA ? (Currency.wrap(tk), Currency.wrap(MOEDA)) : (Currency.wrap(MOEDA), Currency.wrap(tk));
        PoolKey memory falsa = PoolKey(c0, c1, 940_000, 60, IHooks(address(0)));
        PM.initialize(falsa, TickMath.getSqrtPriceAtTick(_tick()));
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(PM);
        vm.prank(DONO);
        address[] memory p = new address[](1);
        p[0] = address(lp);
        t.permitir(p); // mesmo com o roteador liberado, o PoolManager recusa
        vm.startPrank(atacante);
        t.approve(address(lp), type(uint256).max);
        IERC20(MOEDA).approve(address(lp), type(uint256).max);
        int24 tk0 = (_tick() / 60) * 60;
        vm.expectRevert();
        lp.modifyLiquidity(falsa, ModifyLiquidityParams(tk0 + 60, tk0 + 6000, 1e20, 0), "");
        vm.stopPrank();
        assertGt(r, 0);
    }

    /// Pool v2/v3/clone (token0/token1 = AGL) e pool estilo Curve não recebem AGL.
    function test_pool_de_terceiro_nao_recebe() public {
        _lancar();
        uint256 r = _comprar(atacante, _unid(100));
        PoolFalsaAGL pf = new PoolFalsaAGL(address(t), MOEDA);
        PoolCurveAGL pc = new PoolCurveAGL(address(t));
        vm.startPrank(atacante);
        vm.expectRevert(abi.encodeWithSelector(AGL.PoolNaoAutorizada.selector, address(pf)));
        t.transfer(address(pf), r);
        vm.expectRevert(abi.encodeWithSelector(AGL.PoolNaoAutorizada.selector, address(pc)));
        t.transfer(address(pc), r);
        vm.stopPrank();
    }

    /// Contratos comuns (executor de agregador, carteira inteligente, pool de OUTROS tokens,
    /// contrato com resposta estranha) recebem AGL sem liberação.
    function test_contratos_comuns_recebem_sem_liberacao() public {
        _lancar();
        uint256 r = _comprar(atacante, _unid(100));
        PoolQualquer exec = new PoolQualquer();
        PoolFalsaAGL outra = new PoolFalsaAGL(address(0xbeef), MOEDA); // pool de outros tokens
        RespostaEstranha est = new RespostaEstranha();
        vm.startPrank(atacante);
        t.transfer(address(exec), r / 4);
        t.transfer(address(outra), r / 4);
        t.transfer(address(est), r / 4);
        vm.stopPrank();
        assertEq(t.balanceOf(address(exec)), r / 4);
        assertEq(t.balanceOf(address(outra)), r / 4);
        assertEq(t.balanceOf(address(est)), r / 4);
    }

    /// Cofres de DEX com taxa livre não recebem AGL (nas redes onde existem).
    function test_cofres_de_dex_bloqueados() public {
        _lancar();
        uint256 r = _comprar(atacante, _unid(100));
        address[4] memory cofres = [
            0x238a358808379702088667322f80aC48bAd5e6c4,
            0xBA12222222228d8Ba445958a75a0704d566BF2C8,
            0xbA1333333333a1BA1108E8412f11850A5C319bA9,
            0xe0e0e08A6A4b9Dc7bD67BCB7aadE5cF48157d444
        ];
        uint256 testados;
        for (uint256 i; i < 4; i++) {
            if (cofres[i].code.length == 0) continue;
            testados++;
            vm.prank(atacante);
            vm.expectRevert(abi.encodeWithSelector(AGL.CofreDeDexBloqueado.selector, cofres[i]));
            t.transfer(cofres[i], r);
        }
        assertGt(testados, 0, "toda rede tem ao menos um cofre");
    }

    /// Carteira comum e carteira EIP-7702 recebem normalmente.
    function test_carteiras_recebem() public {
        _lancar();
        uint256 r = _comprar(atacante, _unid(100));
        address eoa = makeAddr("eoa");
        address delegada = makeAddr("7702");
        vm.etch(delegada, abi.encodePacked(hex"ef0100", address(0x1234)));
        vm.startPrank(atacante);
        t.transfer(eoa, r / 2);
        t.transfer(delegada, r / 4);
        vm.stopPrank();
        assertEq(t.balanceOf(delegada), r / 4);
    }

    /// Guardião só ADICIONA à lista (ex.: a pool v3 do próprio emissor); não bloqueia ninguém.
    function test_guardiao_so_adiciona() public {
        _lancar();
        PoolFalsaAGL pq = new PoolFalsaAGL(address(t), MOEDA);
        address[] memory p = new address[](1);
        p[0] = address(pq);
        vm.prank(atacante);
        vm.expectRevert(AGL.SoGuardiao.selector);
        t.permitir(p);
        vm.prank(DONO);
        t.permitir(p);
        uint256 r = _comprar(atacante, _unid(100));
        vm.prank(atacante);
        t.transfer(address(pq), r);
        assertEq(t.balanceOf(address(pq)), r);
    }

    /// Ninguém além do token consome a cota; transferir direto ao PoolManager falha.
    function test_cota_so_pelo_token() public {
        _lancar();
        vm.prank(atacante);
        vm.expectRevert(PoolAGL.SoToken.selector);
        pool.consumirEntrada(0);
        uint256 r = _comprar(atacante, _unid(100));
        vm.prank(atacante);
        vm.expectRevert(abi.encodeWithSelector(PoolAGL.ForaDaCota.selector, r, 0));
        t.transfer(address(PM), r);
    }
}
