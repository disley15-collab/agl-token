// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// Parte da CreateX (0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed) usada aqui.
interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract);
    function deployCreate2(bytes32 salt, bytes memory initCode) external payable returns (address newContract);
    function computeCreate3Address(bytes32 salt, address deployer) external pure returns (address computedAddress);
    function computeCreate3Address(bytes32 salt) external view returns (address computedAddress);
}
