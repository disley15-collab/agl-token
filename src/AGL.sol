// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";

/// Parte da PoolAGL que o token usa.
interface IPoolAGL {
    /// @notice PoolManager do Uniswap v4 desta rede.
    function poolManager() external view returns (address);
    /// @notice Consome cota de entrada de AGL no PoolManager (só o token chama).
    function consumirEntrada(uint256 v) external;
    /// @notice Consome cota de saída de AGL do PoolManager (só o token chama).
    function consumirSaida(uint256 v) external;
}

/// @title AGL — token da AgroLastro
/// @author AgroLastro (Solidity Brasil)
/// @custom:security-contact t.me/agrolastro
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
///    recebem AGL (nem o guardião libera).
/// 3. Nenhum contrato com "cara de pool do AGL" (ver `_parecePoolDoAgl`: Uniswap/Pancake
///    v2/v3, Aerodrome, Curve, LFJ, Maverick, iZiSwap, DODO e clones) recebe AGL, a não ser
///    que o guardião o tenha liberado (as pools que o próprio emissor criar).
/// Carteiras (inclusive EIP-7702), agregadores, roteadores e carteiras inteligentes recebem
/// normalmente.
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
    error CriacaoNoPoolManager();

    // Cofres de DEX com taxa livre (mesmo endereço nas redes onde existem; conferidos em 07/11).
    address internal constant PANCAKE_INFINITY_VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    address internal constant BALANCER_V2_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address internal constant BALANCER_V3_VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
    address internal constant EKUBO_CORE = 0xe0e0e08A6A4b9Dc7bD67BCB7aadE5cF48157d444;
    uint256 internal constant GAS_SONDA = 10_000;
    error SoGuardiao();
    error EnderecoZero();

    event Permitido(address indexed contrato);
    event GuardiaoTrocado(address indexed guardiao);

    constructor(address pool_, address guardiao_, address endpoint_, address donoPonte)
        OFT("AgroLastro", "AGL", endpoint_, donoPonte)
        ERC20Permit("AgroLastro")
        Ownable(donoPonte)
    {
        if (!redeAceita(block.chainid)) revert RedeForaDaLista(block.chainid);
        if (pool_ == address(0) || guardiao_ == address(0)) revert EnderecoZero();
        pool = IPoolAGL(pool_);
        poolManager = IPoolAGL(pool_).poolManager();
        guardiao = guardiao_;
        permitido[pool_] = true;
        emit Permitido(pool_);
        _mint(pool_, SUPPLY_POR_REDE);
    }

    /// @notice 9 casas: 1 sextilhão em unidades (1e30) cabe no int128 do Uniswap v4.
    function decimals() public pure override returns (uint8) {
        return 9;
    }

    /// @notice Casas compartilhadas da ponte = 0: só AGL inteiro viaja (até 1,8e19 por envio).
    function sharedDecimals() public pure override returns (uint8) {
        return 0;
    }

    /// @notice Liga várias redes de uma vez: em rede EVM o par é este mesmo endereço.
    function ligarRedesEVM(uint32[] calldata eids) external onlyOwner {
        bytes32 eu = bytes32(uint256(uint160(address(this))));
        for (uint256 i; i < eids.length; i++) {
            _setPeer(eids[i], eu);
        }
    }

    /// @notice BSC, Base, Arbitrum, Polygon, Optimism, Avalanche, Celo e Ethereum.
    function redeAceita(uint256 id) public pure returns (bool) {
        return id == 56 || id == 8453 || id == 42161 || id == 137 || id == 10 || id == 43114 || id == 42220 || id == 1;
    }

    /// @notice Libera uma pool criada pelo emissor (ex.: AGL/USDC na Uniswap v3 ou Pancake v3)
    /// para receber AGL. Não há como desfazer.
    function permitir(address[] calldata contratos_) external {
        if (msg.sender != guardiao) revert SoGuardiao();
        for (uint256 i; i < contratos_.length; i++) {
            permitido[contratos_[i]] = true;
            emit Permitido(contratos_[i]);
        }
    }

    /// @notice Passa o papel de guardião (só ele chama).
    /// @param novo Novo guardião (não pode ser o endereço zero).
    function trocarGuardiao(address novo) external {
        if (msg.sender != guardiao) revert SoGuardiao();
        if (novo == address(0)) revert EnderecoZero();
        guardiao = novo;
        emit GuardiaoTrocado(novo);
    }

    function _update(address de, address para, uint256 valor) internal override {
        address pm = poolManager;
        if (para == pm) {
            // criação (ponte) direto no PoolManager nunca: a cota de outro swap a capturaria
            if (de == address(0)) revert CriacaoNoPoolManager();
            pool.consumirEntrada(valor);
        } else {
            if (de == pm) pool.consumirSaida(valor);
            if (para != address(0) && _ehContrato(para)) {
                // cofres de DEX com taxa livre: bloqueados sempre (nem o guardião libera)
                if (_ehCofreDeDex(para)) revert CofreDeDexBloqueado(para);
                if (!permitido[para] && _parecePoolDoAgl(para)) revert PoolNaoAutorizada(para);
            }
        }
        super._update(de, para, valor);
    }

    function _ehCofreDeDex(address a) internal pure returns (bool) {
        return a == PANCAKE_INFINITY_VAULT || a == BALANCER_V2_VAULT || a == BALANCER_V3_VAULT || a == EKUBO_CORE;
    }

    /// Pool do AGL = responde, com este token, alguma das interfaces de par usadas pelos DEX
    /// que os agregadores indexam: token0/token1 (Uniswap e Pancake v2/v3, Aerodrome,
    /// Velodrome, Camelot, Sushi e clones), coins(i) (Curve), getTokenX/getTokenY (LFJ
    /// Liquidity Book), tokenA/tokenB (Maverick), tokenX/tokenY (iZiSwap), _BASE_TOKEN_ e
    /// _QUOTE_TOKEN_ (DODO). Limite conhecido: um AMM feito sob medida para enganar a sonda
    /// passa, mas não é indexado pelos agregadores.
    function _parecePoolDoAgl(address a) internal view returns (bool) {
        // seletores sem argumento (10) e coins(uint256) com 0 e 1
        return _sonda(a, 0x0dfe1681, false, 0) // token0()
            || _sonda(a, 0xd21220a7, false, 0) // token1()
            || _sonda(a, 0x05e8746d, false, 0) // getTokenX()
            || _sonda(a, 0xda10610c, false, 0) // getTokenY()
            || _sonda(a, 0x0fc63d10, false, 0) // tokenA()
            || _sonda(a, 0x5f64b55b, false, 0) // tokenB()
            || _sonda(a, 0x16dc165b, false, 0) // tokenX()
            || _sonda(a, 0xb7d19fc4, false, 0) // tokenY()
            || _sonda(a, 0x4a248d2a, false, 0) // _BASE_TOKEN_()
            || _sonda(a, 0xd4b97046, false, 0) // _QUOTE_TOKEN_()
            || _sonda(a, 0xc6610657, true, 0) // coins(0)
            || _sonda(a, 0xc6610657, true, 1); // coins(1)
    }

    /// staticcall com gás limitado que copia NO MÁXIMO 32 bytes de resposta (sem "return
    /// bomb": um contrato que devolve dados enormes não encarece a transferência).
    function _sonda(address a, bytes4 sel, bool comArg, uint256 arg) internal view returns (bool r) {
        uint256 gas_ = GAS_SONDA;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, sel)
            mstore(add(p, 4), arg)
            let tam := 4
            if comArg { tam := 36 }
            let ok := staticcall(gas_, a, p, tam, p, 32)
            r := and(ok, and(eq(returndatasize(), 32), eq(mload(p), address())))
        }
    }

    /// Contrato = tem código. Contas EIP-7702 (código 0xef0100 || alvo) também passam pela
    /// sonda: delegadas a uma carteira normal recebem; delegadas a código de pool, não.
    function _ehContrato(address a) internal view returns (bool) {
        return a.code.length > 0;
    }
}
