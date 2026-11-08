// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {AGL} from "../src/AGL.sol";
import {PoolAGL} from "../src/PoolAGL.sol";
import {BaseAGL} from "./BaseAGL.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// Formato do Universal Router PUBLICADO (v2.0): sem o campo minHopPriceX36 do código novo.
struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

/// Roteador que PAGA ANTES de trocar (sync/transfer/settle e só depois swap).
contract RoteadorPagaAntes is IUnlockCallback {
    IPoolManager immutable pm;
    PoolKey k;
    bool t0;
    uint256 qtd;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function vender(PoolKey memory _k, bool _t0, uint256 _q) external {
        (k, t0, qtd) = (_k, _t0, _q);
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        Currency tok = t0 ? k.currency0 : k.currency1;
        pm.sync(tok);
        IERC20(Currency.unwrap(tok)).transfer(address(pm), qtd); // entra ANTES da troca: sem cota
        pm.settle();
        pm.swap(k, SwapParams(t0, -int256(qtd), t0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), "");
        return "";
    }
}

/// Integração com o que existe na rede: Universal Router + Permit2 da Uniswap.
contract IntegracaoTest is BaseAGL {
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    function _ur() internal view returns (IUniversalRouter) {
        if (block.chainid == 56) return IUniversalRouter(0x1906c1d672b88cD1B9aC7593301cA990F94Eae07);
        if (block.chainid == 8453) return IUniversalRouter(0x6fF5693b99212Da76ad316178A184AB56D299b43);
        if (block.chainid == 42161) return IUniversalRouter(0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3);
        if (block.chainid == 137) return IUniversalRouter(0x1095692A6237d83C6a72F3F5eFEdb9A670C49223);
        if (block.chainid == 10) return IUniversalRouter(0x851116D9223fabED8E56C0E6b8Ad0c31d98B3507);
        if (block.chainid == 43114) return IUniversalRouter(0x94b75331AE8d42C1b61065089B7d48FE14aA73b7);
        if (block.chainid == 42220) return IUniversalRouter(0xcb695bc5D3Aa22cAD1E6DF07801b061a05A0233A);
        return IUniversalRouter(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);
    }

    function _swapUR(address quem, bool comprar, uint128 qtd) internal {
        IUniversalRouter ur = _ur();
        PoolKey memory k = pool.chave();
        bool t0 = pool.tokenEhMoeda0();
        bool zfo = comprar ? !t0 : t0;
        (Currency cin, Currency cout) = zfo ? (k.currency0, k.currency1) : (k.currency1, k.currency0);
        bytes memory acoes = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encode(ExactInputSingleParams(k, zfo, qtd, 0, ""));
        p[1] = abi.encode(cin, uint256(qtd));
        p[2] = abi.encode(cout, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(acoes, p);
        vm.startPrank(quem);
        IERC20(Currency.unwrap(cin)).approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(Currency.unwrap(cin), address(ur), type(uint160).max, uint48(block.timestamp + 1 days));
        ur.execute(abi.encodePacked(uint8(0x10)), inputs, block.timestamp + 60);
        vm.stopPrank();
    }

    /// Comprar e vender pelo Universal Router oficial (o que o site da Uniswap usa).
    function test_universal_router_compra_e_vende() public {
        _lancar();
        address u = makeAddr("usuario");
        deal(MOEDA, u, _unid(1000));
        _swapUR(u, true, uint128(_unid(1000)));
        uint256 r = t.balanceOf(u);
        assertApproxEqRel(r, 980_000_000_000 * 1e9, 0.001e18, "US$1000 compram ~9,8e11 AGL");
        _swapUR(u, false, uint128(r));
        assertGt(IERC20(MOEDA).balanceOf(u), _unid(1000) * 95 / 100, "vende de volta");
        assertEq(t.balanceOf(u), 0);
        assertEq(pool.cota(), 0, "nada de cota sobrando");
    }

    /// Agregador que recebe o token num contrato intermediário (executor): funciona
    /// sem liberação (lógica inversa).
    function test_executor_de_agregador_recebe_sem_liberacao() public {
        _lancar();
        address u = makeAddr("usuario");
        deal(MOEDA, u, _unid(100));
        _swapUR(u, true, uint128(_unid(100)));
        RoteadorPagaAntes executor = new RoteadorPagaAntes(PM); // qualquer contrato
        uint256 r = t.balanceOf(u);
        vm.prank(u);
        t.transfer(address(executor), r);
        assertEq(t.balanceOf(address(executor)), r);
    }

    /// Roteador que paga antes de trocar NÃO consegue vender AGL (a cota só abre depois
    /// da troca), mesmo liberado na lista. Comprar funciona (a saída vem depois da troca).
    function test_roteador_que_paga_antes_nao_vende() public {
        _lancar();
        RoteadorPagaAntes rot = new RoteadorPagaAntes(PM);
        address[] memory l = new address[](1);
        l[0] = address(rot);
        vm.prank(DONO);
        t.permitir(l);
        address u = makeAddr("usuario");
        deal(MOEDA, u, _unid(100));
        _swapUR(u, true, uint128(_unid(100)));
        uint256 r = t.balanceOf(u);
        vm.prank(u);
        t.transfer(address(rot), r);
        PoolKey memory k = pool.chave();
        bool t0 = pool.tokenEhMoeda0();
        vm.expectRevert();
        rot.vender(k, t0, r);
    }
}
