// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolAGL } from "../src/PoolAGL.sol";
import { ICreateX } from "../src/ICreateX.sol";

/// Publica o AGL numa rede, em 2 transações:
///   1. PoolAGL (hook) pela CreateX, salt protegido pela carteira de publicação;
///   2. PoolAGL.lancar: publica o token, cria a pool e deposita a escada (tudo junto).
/// Retomável: se a PoolAGL já existe, pula a 1.
/// env: AGL_PK, SALT_POOL, SALT_TOKEN, PM, MOEDA, DONO, ESCADA (json do script/escada.py)
contract Publicar is Script {
    address constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    function run() external {
        uint256 pk = vm.envUint("AGL_PK");
        address eu = vm.addr(pk);
        bytes32 saltPool = vm.envBytes32("SALT_POOL");
        bytes32 saltToken = vm.envBytes32("SALT_TOKEN");
        address pm = vm.envAddress("PM");
        address moeda = vm.envAddress("MOEDA");
        address dono = vm.envAddress("DONO");
        string memory json = vm.readFile(vm.envString("ESCADA"));

        address previsto = ICreateX(CREATEX).computeCreate3Address(keccak256(abi.encode(eu, saltPool)));
        vm.startBroadcast(pk);
        PoolAGL pool;
        if (previsto.code.length == 0) {
            bytes memory init = abi.encodePacked(type(PoolAGL).creationCode, abi.encode(IPoolManager(pm), eu, moeda, dono));
            pool = PoolAGL(ICreateX(CREATEX).deployCreate3(saltPool, init));
        } else {
            pool = PoolAGL(previsto);
        }
        require(address(pool) == previsto, "endereco da pool");
        if (!pool.lancado()) {
            uint256 n = vm.parseJsonUint(json, ".degraus");
            PoolAGL.Faixa[] memory fx = new PoolAGL.Faixa[](n);
            for (uint256 i; i < n; i++) {
                string memory p = string.concat(".faixas[", vm.toString(i), "]");
                fx[i] = PoolAGL.Faixa(
                    int24(vm.parseJsonInt(json, string.concat(p, ".inferior"))),
                    int24(vm.parseJsonInt(json, string.concat(p, ".superior"))),
                    vm.parseJsonUint(json, string.concat(p, ".quantidade"))
                );
            }
            pool.lancar(saltToken, int24(vm.parseJsonInt(json, ".tickInicial")), fx);
        }
        vm.stopBroadcast();
        console2.log("pool/hook", address(pool));
        console2.log("token", Currency.unwrap(pool.token()));
    }
}
