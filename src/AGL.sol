// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// Parte da PoolAGL que o token usa.
interface IPoolAGL {
    function poolManager() external view returns (address);
    function consumirEntrada(uint256 _v) external;
    function consumirSaida(uint256 _v) external;
}

/// @title AGL — token da AgroLastro
/// @notice Mesmo endereço em todas as redes. Em cada rede: 1 sextilhão, 100% na pool
/// oficial (Uniswap v4, pareada com USDC, liquidez travada). Sem ponte.
///
/// TRAVA "só a pool oficial": o token só entra no PoolManager do Uniswap v4, ou sai
/// dele, dentro da cota que a pool oficial abre naquela transação (compra/venda na
/// pool oficial, lançamento e coleta de taxas). Assim, pools de terceiros do AGL no v4
/// não conseguem receber nem entregar AGL. E nenhum contrato fora da lista recebe AGL,
/// o que impede pools v2/v3 e outras DEX. Carteiras comuns (inclusive EIP-7702)
/// recebem normalmente.
///
/// @dev Invariantes (provados em test/):
/// 1. Supply fixo de 1e30 unidades por rede, criado uma vez no construtor, todo para a
///    pool. Sem emitir, queimar, pausar, congelar, taxar transferência ou renomear.
/// 2. A lista de contratos permitidos só CRESCE (`permitir`): o guardião nunca consegue
///    bloquear ninguém nem tirar AGL de ninguém.
/// 3. Transferência de/para o PoolManager só dentro da cota da pool oficial.
contract AGL is ERC20Permit {
    /// @notice 1 sextilhão de tokens (9 casas) EM CADA REDE.
    uint256 public constant SUPPLY_POR_REDE = 1e21 * 1e9;

    IPoolAGL public immutable pool;
    address public immutable poolManager;
    address public guardiao;
    mapping(address => bool) public permitido;

    error RedeForaDaLista(uint256 chainid);
    error ContratoNaoPermitido(address destino);
    error SoGuardiao();
    error EnderecoZero();

    event Permitido(address indexed contrato);
    event GuardiaoTrocado(address indexed guardiao);

    constructor(address _pool, address _guardiao) ERC20("AgroLastro", "AGL") ERC20Permit("AgroLastro") {
        if (!redeAceita(block.chainid)) revert RedeForaDaLista(block.chainid);
        if (_pool == address(0) || _guardiao == address(0)) revert EnderecoZero();
        pool = IPoolAGL(_pool);
        poolManager = IPoolAGL(_pool).poolManager();
        guardiao = _guardiao;
        permitido[_pool] = true;
        emit Permitido(_pool);
        _mint(_pool, SUPPLY_POR_REDE);
    }

    function decimals() public pure override returns (uint8) {
        return 9;
    }

    /// @notice BSC, Base, Arbitrum, Polygon, Optimism, Avalanche, Celo e Ethereum.
    function redeAceita(uint256 _id) public pure returns (bool) {
        return _id == 56 || _id == 8453 || _id == 42161 || _id == 137 || _id == 10 || _id == 43114 || _id == 42220
            || _id == 1;
    }

    /// @notice Libera um contrato para receber AGL (ex.: escrow/registro da plataforma,
    /// roteador oficial, carteira multisig). Não há como desfazer.
    function permitir(address[] calldata _contratos) external {
        if (msg.sender != guardiao) revert SoGuardiao();
        for (uint256 i; i < _contratos.length; i++) {
            permitido[_contratos[i]] = true;
            emit Permitido(_contratos[i]);
        }
    }

    function trocarGuardiao(address _novo) external {
        if (msg.sender != guardiao) revert SoGuardiao();
        if (_novo == address(0)) revert EnderecoZero();
        guardiao = _novo;
        emit GuardiaoTrocado(_novo);
    }

    function _update(address _de, address _para, uint256 _valor) internal override {
        address pm = poolManager;
        if (_para == pm) {
            pool.consumirEntrada(_valor);
        } else {
            if (_de == pm) pool.consumirSaida(_valor);
            if (_para != address(0) && !permitido[_para] && _ehContrato(_para)) revert ContratoNaoPermitido(_para);
        }
        super._update(_de, _para, _valor);
    }

    /// Contrato = tem código e NÃO é carteira comum delegada por EIP-7702
    /// (código de 23 bytes começando com 0xef0100).
    function _ehContrato(address _a) internal view returns (bool) {
        uint256 n = _a.code.length;
        if (n == 0) return false;
        if (n != 23) return true;
        bytes3 prefixo;
        assembly {
            let p := mload(0x40)
            extcodecopy(_a, p, 0, 3)
            prefixo := mload(p)
        }
        return prefixo != 0xef0100;
    }
}
