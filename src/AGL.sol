// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";

/// Parte da PoolAGL que o token usa.
interface IPoolAGL {
    function poolManager() external view returns (address);
    function consumirEntrada(uint256 _v) external;
    function consumirSaida(uint256 _v) external;
}

/// @title AGL — token da AgroLastro
/// @notice Mesmo endereço em todas as redes. Em cada rede nasce 1 sextilhão, 100% na pool
/// oficial (Uniswap v4, pareada com USDC, liquidez travada).
///
/// PONTE (igual ao SDBR): LayerZero OFT. Enviar para outra rede QUEIMA aqui e CRIA lá; a soma
/// das 8 redes nunca muda (8 sextilhões). O dono da ponte (peers, bibliotecas, verificadores)
/// e o delegate ficam num Timelock de 7 dias. Casas compartilhadas = 0: só AGL inteiro viaja,
/// até 1,8e19 AGL por envio.
///
/// TRAVA "só as nossas pools" (lógica inversa reforçada):
/// 1. Uniswap v4: o AGL só entra/sai do PoolManager dentro da cota que a pool oficial abre
///    (compra/venda nela, lançamento e coleta).
/// 2. Cofres de DEX com taxa livre (PancakeSwap Infinity, Balancer v2/v3, Ekubo) nunca
///    recebem AGL.
/// 3. Nenhum contrato com "cara de pool do AGL" (token0/token1 ou coins(0)/coins(1) = AGL,
///    como pools Uniswap/Pancake v2/v3, Aerodrome, Curve e clones) recebe AGL, a não ser
///    que o guardião o tenha liberado (as pools que o próprio emissor criar).
/// Carteiras, agregadores, roteadores e carteiras inteligentes recebem normalmente.
///
/// @dev Invariantes (provados em test/):
/// 1. Cada rede cria 1e30 unidades uma vez, no construtor, todas para a pool. Depois disso o
///    supply só muda pela ponte (queima aqui = cria lá). Sem emitir fora da ponte, pausar,
///    congelar, taxar transferência ou renomear.
/// 2. A lista de liberados só CRESCE (`permitir`): o guardião nunca bloqueia ninguém.
/// 3. Transferência de/para o PoolManager só dentro da cota da pool oficial.
contract AGL is OFT, ERC20Permit {
    /// @notice 1 sextilhão de tokens (9 casas) EM CADA REDE.
    uint256 public constant SUPPLY_POR_REDE = 1e21 * 1e9;

    IPoolAGL public immutable pool;
    address public immutable poolManager;
    address public guardiao;
    mapping(address => bool) public permitido;

    error RedeForaDaLista(uint256 chainid);
    error PoolNaoAutorizada(address destino);
    error CofreDeDexBloqueado(address destino);

    // Cofres de DEX com taxa livre (mesmo endereço nas redes onde existem; conferidos em 07/11).
    address internal constant PANCAKE_INFINITY_VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    address internal constant BALANCER_V2_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address internal constant BALANCER_V3_VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
    address internal constant EKUBO_CORE = 0xe0e0e08A6A4b9Dc7bD67BCB7aadE5cF48157d444;
    uint256 internal constant GAS_SONDA = 30_000;
    error SoGuardiao();
    error EnderecoZero();

    event Permitido(address indexed contrato);
    event GuardiaoTrocado(address indexed guardiao);

    constructor(address _pool, address _guardiao, address _endpoint, address _donoPonte)
        OFT("AgroLastro", "AGL", _endpoint, _donoPonte)
        ERC20Permit("AgroLastro")
        Ownable(_donoPonte)
    {
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

    function sharedDecimals() public pure override returns (uint8) {
        return 0;
    }

    /// @notice Liga várias redes de uma vez: em rede EVM o par é este mesmo endereço.
    function ligarRedesEVM(uint32[] calldata _eids) external onlyOwner {
        bytes32 eu = bytes32(uint256(uint160(address(this))));
        for (uint256 i; i < _eids.length; i++) _setPeer(_eids[i], eu);
    }

    /// @notice BSC, Base, Arbitrum, Polygon, Optimism, Avalanche, Celo e Ethereum.
    function redeAceita(uint256 _id) public pure returns (bool) {
        return _id == 56 || _id == 8453 || _id == 42161 || _id == 137 || _id == 10 || _id == 43114 || _id == 42220
            || _id == 1;
    }

    /// @notice Libera uma pool criada pelo emissor (ex.: AGL/USDC na Uniswap v3 ou Pancake v3)
    /// para receber AGL. Não há como desfazer.
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
            if (_para != address(0) && !permitido[_para] && _ehContrato(_para)) {
                if (
                    _para == PANCAKE_INFINITY_VAULT || _para == BALANCER_V2_VAULT || _para == BALANCER_V3_VAULT
                        || _para == EKUBO_CORE
                ) revert CofreDeDexBloqueado(_para);
                if (_parecePoolDoAgl(_para)) revert PoolNaoAutorizada(_para);
            }
        }
        super._update(_de, _para, _valor);
    }

    /// Pool do AGL = responde token0()/token1() ou coins(0)/coins(1) com este token.
    function _parecePoolDoAgl(address _a) internal view returns (bool) {
        return _sonda(_a, abi.encodeWithSignature("token0()")) || _sonda(_a, abi.encodeWithSignature("token1()"))
            || _sonda(_a, abi.encodeWithSignature("coins(uint256)", 0))
            || _sonda(_a, abi.encodeWithSignature("coins(uint256)", 1));
    }

    function _sonda(address _a, bytes memory _chamada) internal view returns (bool) {
        (bool ok, bytes memory r) = _a.staticcall{ gas: GAS_SONDA }(_chamada);
        return ok && r.length == 32 && abi.decode(r, (uint256)) == uint256(uint160(address(this)));
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
