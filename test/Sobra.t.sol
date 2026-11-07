// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolAGL } from "../src/PoolAGL.sol";
import { AGL } from "../src/AGL.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BaseAGL } from "./BaseAGL.sol";

/// O último degrau recebe o que sobrar, mesmo que a escada enviada diga menos: a pool
/// fica com 100% dos 95%.
contract SobraTest is BaseAGL {
    function test_ultimo_degrau_recebe_a_sobra() public {
        pool = _publicarPool();
        json = _escada(_enderecoToken());
        PoolAGL.Faixa[] memory fx = _faixas();
        uint256 n = fx.length;
        fx[n - 1].quantidade = 1; // escada "curta"
        vm.prank(DEPLOYER);
        pool.lancar(_saltToken(), int24(vm.parseJsonInt(json, ".tickInicial")), fx);
        t = AGL(Currency.unwrap(pool.token()));
        PoolAGL.Faixa[] memory g = pool.todasAsFaixas();
        uint256 soma;
        for (uint256 i; i < n; i++) soma += g[i].quantidade;
        uint256 parte = t.supplyDaRede(chainid);
        assertEq(soma, parte - parte * 5 / 100, "escada guardada = 95%");
        assertLt(t.balanceOf(address(pool)), soma / 1e9, "quase nada fica fora da pool");
    }
}
