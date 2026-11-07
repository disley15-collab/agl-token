// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title AGL — token da AgroLastro
/// @notice Mesmo endereço nas 7 redes. Cada rede tem a SUA parte do supply e a SUA pool,
/// e não existe ponte: AGL de uma rede não passa para outra. Por isso não há
/// arbitragem do token entre redes.
///
/// @dev Invariantes (provados em test/):
/// 1. 1 sextilhão no total, dividido em 7 partes iguais (a BSC fica com a unidade que
///    sobra da divisão). A parte da rede é criada UMA vez, no construtor; rede fora da
///    lista recusa. Não existe função de emitir, queimar, pausar, congelar, taxar ou
///    renomear, e não há dono.
/// 2. Da parte de cada rede: 5% para `DONO`, 95% para a pool (quem publica o token).
/// 3. ERC-20 puro (OpenZeppelin 5) + ERC-2612 `permit`: nenhuma regra em transfer.
///
/// 9 casas: 1 sextilhão em unidades (1e30) cabe no int128 do Uniswap v4; com 18 casas
/// (1e39) não cabe.
contract AGL is ERC20Permit {
    /// @notice 1 sextilhão de tokens (9 casas), somando as 7 redes.
    uint256 public constant SUPPLY_TOTAL = 1e21 * 1e9;
    uint256 public constant REDES = 7;
    /// @notice Carteira do emissor: recebe 5% da parte de cada rede.
    address public constant DONO = 0x979514BddD0346FdD218c49B8242b92C1A6D0ffC;
    uint256 public constant PARTE_DONO_BPS = 500; // 5%

    error RedeForaDaLista(uint256 chainid);

    constructor(address _pool) ERC20("AgroLastro", "AGL") ERC20Permit("AgroLastro") {
        uint256 parte = supplyDaRede(block.chainid);
        uint256 dono = parte * PARTE_DONO_BPS / 10_000;
        _mint(DONO, dono);
        _mint(_pool, parte - dono);
    }

    function decimals() public pure override returns (uint8) {
        return 9;
    }

    /// @notice Parte do supply de cada rede (em unidades de 9 casas).
    function supplyDaRede(uint256 _chainid) public pure returns (uint256) {
        uint256 parte = SUPPLY_TOTAL / REDES;
        if (_chainid == 56) return parte + SUPPLY_TOTAL % REDES; // BSC fica com o resto
        if (
            _chainid == 8453 || _chainid == 42161 || _chainid == 137 || _chainid == 10 || _chainid == 43114
                || _chainid == 42220
        ) return parte;
        revert RedeForaDaLista(_chainid);
    }
}
