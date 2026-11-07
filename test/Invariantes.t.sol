// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { SwapParams } from "v4-core/types/PoolOperation.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { AGL } from "../src/AGL.sol";
import { PoolAGL } from "../src/PoolAGL.sol";
import { BaseAGL } from "./BaseAGL.sol";

/// Ações aleatórias: compra, venda, coleta de taxas.
contract Agente is Test {
    using PoolIdLibrary for PoolKey;

    AGL immutable t;
    PoolAGL immutable pool;
    PoolSwapTest immutable router;
    IPoolManager immutable pm;
    address immutable moeda;
    uint256 immutable um; // 1 dólar em unidades da moeda
    address[] public pessoas;

    constructor(AGL _t, PoolAGL _pool, PoolSwapTest _router, address _moeda, uint256 _um) {
        (t, pool, router, moeda, pm, um) = (_t, _pool, _router, _moeda, _router.manager(), _um);
        pessoas.push(makeAddr("p1"));
        pessoas.push(makeAddr("p2"));
        pessoas.push(makeAddr("p3"));
    }

    function _noLimite(uint160 _limite) internal view returns (bool) {
        (uint160 sp,,,) = StateLibrary.getSlot0(pm, pool.chave().toId());
        return sp == _limite;
    }

    function comprar(uint256 _quem, uint256 _usd) external {
        address q = pessoas[_quem % pessoas.length];
        uint256 v = bound(_usd, um / 100, 3_000_000 * um);
        bool t0 = pool.tokenEhMoeda0();
        uint160 lim = t0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1;
        if (_noLimite(lim)) return;
        deal(moeda, q, v);
        uint256 antes = t.balanceOf(q);
        vm.startPrank(q);
        IERC20(moeda).approve(address(router), v);
        router.swap(pool.chave(), SwapParams(!t0, -int256(v), lim), PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
        assertGt(t.balanceOf(q), antes, "compra dentro da escada recebe token");
    }

    function vender(uint256 _quem, uint256 _parte) external {
        address q = pessoas[_quem % pessoas.length];
        uint256 saldo = t.balanceOf(q);
        if (saldo < 1e9) return;
        uint256 qtd = bound(_parte, 1e9, saldo);
        bool t0 = pool.tokenEhMoeda0();
        uint160 lim = t0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        if (_noLimite(lim)) return;
        vm.startPrank(q);
        t.approve(address(router), qtd);
        router.swap(pool.chave(), SwapParams(t0, -int256(qtd), lim), PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
    }

    function coletar() external {
        pool.coletarTaxas();
    }
}

contract InvariantesTest is BaseAGL {
    Agente agente;
    uint128[] liq0;
    uint256 supply0;

    function setUp() public override {
        super.setUp();
        _lancar();
        PoolAGL.Faixa[] memory fx = pool.todasAsFaixas();
        for (uint256 i; i < fx.length; i++) liq0.push(_liquidez(fx[i]));
        supply0 = t.totalSupply();
        agente = new Agente(t, pool, router, MOEDA, 10 ** casasMoeda);
        targetContract(address(agente));
    }

    /// A liquidez de nenhum degrau diminui.
    function invariant_liquidez_nunca_diminui() public view {
        PoolAGL.Faixa[] memory fx = pool.todasAsFaixas();
        assertEq(fx.length, liq0.length, "nenhum degrau novo");
        for (uint256 i; i < fx.length; i++) assertGe(_liquidez(fx[i]), liq0[i]);
    }

    /// O supply não muda.
    function invariant_supply_fixo() public view {
        assertEq(t.totalSupply(), supply0);
    }

    /// Moeda nunca fica presa na PoolAGL nem vai a quem chamou a coleta.
    function invariant_moeda_so_no_recebedor() public view {
        assertEq(IERC20(MOEDA).balanceOf(address(pool)), pool.aSacar(MOEDA), "USDC na pool = taxas a sacar");
        assertEq(IERC20(MOEDA).balanceOf(address(agente)), 0);
    }

    /// A parte do dono só cresce (taxas de venda chegam em AGL); ninguém tira dela.
    function invariant_parte_do_dono_intacta() public view {
        assertGe(t.balanceOf(DONO), 0);
    }
}
