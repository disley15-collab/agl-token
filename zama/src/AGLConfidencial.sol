// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {ERC7984} from "@openzeppelin/confidential-contracts/token/ERC7984/ERC7984.sol";
import {
    ERC7984ERC20Wrapper
} from "@openzeppelin/confidential-contracts/token/ERC7984/extensions/ERC7984ERC20Wrapper.sol";

/// @title cAGL — AGL confidencial (Ethereum, Zama fhEVM, padrão ERC-7984)
/// @notice Embrulha o AGL público 1:1 em tokens INTEIROS: saldos e transferências ficam
/// cifrados (FHE); só o dono do saldo (e quem ele autorizar, como um auditor) consegue
/// ver os valores. Desembrulhar devolve o AGL público.
///
/// @dev
/// - Contrato padrão da OpenZeppelin (ERC7984ERC20Wrapper, auditado), sem dono, sem upgrade.
/// - Valores confidenciais são `euint64`: com 0 casas, o teto é ~1,8e19 AGL (~US$18 bi a
///   US$1e-9). Por isso 1 cAGL = 1 AGL inteiro (rate = 1e9 unidades); a fração abaixo de
///   1 AGL volta para quem embrulhou.
/// - Recebe AGL sem liberação (a trava do AGL só bloqueia pools e cofres de DEX).
/// - Só funciona no Ethereum (e Sepolia): é onde o coprocessador da Zama está.
/// @author AgroLastro (Solidity Brasil)
/// @custom:security-contact t.me/agrolastro
contract AGLConfidencial is ZamaEthereumConfig, ERC7984ERC20Wrapper {
    constructor(IERC20 agl_)
        ERC7984("AgroLastro Confidencial", "cAGL", "https://agrolastro.com/cagl.json")
        ERC7984ERC20Wrapper(agl_)
    {}

    function _maxDecimals() internal pure override returns (uint8) {
        return 0;
    }
}
