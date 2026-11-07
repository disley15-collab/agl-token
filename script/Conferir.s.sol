// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { AGL } from "../src/AGL.sol";
import { PoolAGL } from "../src/PoolAGL.sol";

/// Confere na rede (só leitura) o que a publicação tem de ter deixado. Falha no 1º erro.
/// env: POOL, TOKEN, PM, MOEDA, ESCADA, DEPLOYER
contract Conferir is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 ok;

    function _c(bool _cond, string memory _o) internal {
        require(_cond, _o);
        ok++;
    }

    function run() external {
        PoolAGL pool = PoolAGL(vm.envAddress("POOL"));
        AGL t = AGL(vm.envAddress("TOKEN"));
        IPoolManager pm = IPoolManager(vm.envAddress("PM"));
        string memory json = vm.readFile(vm.envString("ESCADA"));
        address dono = 0x979514BddD0346FdD218c49B8242b92C1A6D0ffC;

        _c(address(pool).code.length > 0, "pool sem codigo");
        _c(uint160(address(pool)) & Hooks.ALL_HOOK_MASK == (Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG), "bits de hook");
        _c(address(pool.poolManager()) == address(pm), "poolManager");
        _c(pool.lancador() == vm.envAddress("DEPLOYER"), "lancador");
        _c(Currency.unwrap(pool.moeda()) == vm.envAddress("MOEDA"), "moeda");
        _c(pool.recebedorTaxas() == dono, "recebedor");
        _c(pool.lancado(), "nao lancado");
        _c(Currency.unwrap(pool.token()) == address(t), "token da pool");
        _c(address(t).code.length > 0, "token sem codigo");
        _c(keccak256(bytes(t.symbol())) == keccak256("AGL"), "simbolo");
        _c(keccak256(bytes(t.name())) == keccak256("AgroLastro"), "nome");
        _c(t.decimals() == 9, "casas");
        uint256 parte = t.SUPPLY_POR_REDE();
        _c(parte == 1e30, "1 sextilhao");
        _c(t.totalSupply() == parte, "supply");
        _c(t.guardiao() == dono, "guardiao");
        _c(address(t.pool()) == address(pool), "pool no token");
        _c(t.poolManager() == address(pm), "poolManager no token");
        _c(t.redeAceita(block.chainid), "rede aceita");
        _c(pool.tokenEhMoeda0() == vm.parseJsonBool(json, ".tokenEhMoeda0"), "ordem do par");
        PoolKey memory k = pool.chave();
        _c(k.fee == 20_000 && k.tickSpacing == 10 && address(k.hooks) == address(pool), "chave");
        (uint160 sp,,,) = pm.getSlot0(k.toId());
        _c(sp != 0, "pool nao inicializada");
        PoolAGL.Faixa[] memory fx = pool.todasAsFaixas();
        _c(fx.length == vm.parseJsonUint(json, ".degraus"), "degraus");
        uint256 soma;
        for (uint256 i; i < fx.length; i++) {
            string memory p = string.concat(".faixas[", vm.toString(i), "]");
            _c(fx[i].inferior == int24(vm.parseJsonInt(json, string.concat(p, ".inferior"))), "inferior");
            _c(fx[i].superior == int24(vm.parseJsonInt(json, string.concat(p, ".superior"))), "superior");
            bytes32 pos = keccak256(abi.encodePacked(address(pool), fx[i].inferior, fx[i].superior, bytes32(0)));
            _c(pm.getPositionLiquidity(k.toId(), pos) > 0, "degrau sem liquidez");
            soma += fx[i].quantidade;
        }
        _c(soma == parte, "escada = 100%");
        _c(t.balanceOf(address(pool)) < soma / 1e9, "poeira");
        console2.log("checagens OK:", ok);
    }
}
