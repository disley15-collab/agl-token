// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title RegistroAGL — selo de KYC das carteiras da AgroLastro (sem dados pessoais)
/// @notice O provedor de KYC verifica a pessoa/empresa fora da blockchain; aqui fica só
/// "carteira X verificada até a data Y". O escrow só aceita carteiras com selo válido.
/// @dev O atestador (carteira do servidor da plataforma) grava e revoga selos; o
/// supervisor troca o atestador (se a chave do servidor vazar) e transfere a supervisão.
contract RegistroAGL {
    address public supervisor;
    address public atestador;
    mapping(address => uint64) public verificadoAte;

    error SoSupervisor();
    error SoAtestador();
    error EnderecoZero();

    event Verificado(address indexed carteira, uint64 ate);
    event AtestadorTrocado(address indexed atestador);
    event SupervisorTrocado(address indexed supervisor);

    constructor(address _supervisor, address _atestador) {
        if (_supervisor == address(0) || _atestador == address(0)) revert EnderecoZero();
        supervisor = _supervisor;
        atestador = _atestador;
    }

    function verificado(address _c) external view returns (bool) {
        return verificadoAte[_c] >= block.timestamp;
    }

    /// @notice Grava (ou revoga, com `_ate` = 0) o selo de várias carteiras.
    function atestar(address[] calldata _carteiras, uint64 _ate) external {
        if (msg.sender != atestador) revert SoAtestador();
        for (uint256 i; i < _carteiras.length; i++) {
            verificadoAte[_carteiras[i]] = _ate;
            emit Verificado(_carteiras[i], _ate);
        }
    }

    function trocarAtestador(address _novo) external {
        if (msg.sender != supervisor) revert SoSupervisor();
        if (_novo == address(0)) revert EnderecoZero();
        atestador = _novo;
        emit AtestadorTrocado(_novo);
    }

    function trocarSupervisor(address _novo) external {
        if (msg.sender != supervisor) revert SoSupervisor();
        if (_novo == address(0)) revert EnderecoZero();
        supervisor = _novo;
        emit SupervisorTrocado(_novo);
    }
}
