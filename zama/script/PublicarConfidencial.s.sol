// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AGLConfidencial} from "../src/AGLConfidencial.sol";

interface ICreateX3 {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);
    function computeCreate3Address(bytes32 salt) external view returns (address);
}

interface IAGLLista {
    function permitido(address) external view returns (bool);
}

/// Publica o cAGL no Ethereum, no endereço que a publicação principal já liberou no token.
/// env: AGL_PK, SALT_CAGL, TOKEN
contract PublicarConfidencial is Script {
    ICreateX3 constant CREATEX = ICreateX3(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    function run() external {
        require(block.chainid == 1, "so Ethereum");
        uint256 pk = vm.envUint("AGL_PK");
        address eu = vm.addr(pk);
        bytes32 salt = vm.envBytes32("SALT_CAGL");
        address token = vm.envAddress("TOKEN");
        address previsto = CREATEX.computeCreate3Address(keccak256(abi.encode(eu, salt)));
        require(IAGLLista(token).permitido(previsto), "cAGL nao liberado no token");
        if (previsto.code.length == 0) {
            vm.startBroadcast(pk);
            CREATEX.deployCreate3(salt, abi.encodePacked(type(AGLConfidencial).creationCode, abi.encode(IERC20(token))));
            vm.stopBroadcast();
        }
        AGLConfidencial c = AGLConfidencial(previsto);
        require(address(c.underlying()) == token && c.rate() == 1e9, "cAGL errado");
        console2.log("cAGL", previsto);
    }
}
