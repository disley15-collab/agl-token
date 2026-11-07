// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { ModifyLiquidityParams } from "v4-core/types/PoolOperation.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { TransientStateLibrary } from "v4-core/libraries/TransientStateLibrary.sol";
import { LiquidityAmounts } from "v4-periphery/libraries/LiquidityAmounts.sol";
import { ICreateX } from "./ICreateX.sol";
import { AGL } from "./AGL.sol";

/// @title PoolAGL — publica o AGL e a pool dele (Uniswap v4, taxa 2%) na MESMA transação,
/// com a escada inteira e a liquidez travada PARA SEMPRE.
///
/// @dev Invariantes:
/// 1. `lancar` cria o token (CreateX CREATE3, salt protegido por este contrato), recebe
///    95% da parte da rede, cria a pool e deposita TODO esse saldo na escada, numa
///    transação só. Antes dela o token não existe; depois dela a pool já tem liquidez.
/// 2. Só este contrato cria a pool e põe liquidez nela: ele é o hook da pool e o
///    PoolManager não chama o hook quando quem age é o próprio hook; para qualquer outro
///    `beforeInitialize` e `beforeAddLiquidity` recusam. Isso fecha a pré-inicialização
///    com preço falso e a diluição das taxas por liquidez de terceiros (JIT).
///    Comprar e vender são livres (o hook não roda no swap).
/// 3. A liquidez de cada degrau nunca diminui: não existe função que tire liquidez.
/// 4. As taxas (nas duas moedas) só saem para `recebedorTaxas`, por `coletarTaxas`.
///
/// Publicado pela CreateX num endereço cujos bits de hook são exatamente
/// BEFORE_INITIALIZE | BEFORE_ADD_LIQUIDITY (o construtor confere).
contract PoolAGL is IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;

    uint24 public constant TAXA = 20_000; // 2% (em milionésimos)
    int24 public constant ESPACAMENTO = 10;
    ICreateX public constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
    uint160 internal constant BITS_HOOK = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG;

    struct Faixa {
        int24 inferior;
        int24 superior;
        uint256 quantidade; // tokens do degrau (o último recebe o que sobrar)
    }

    IPoolManager public immutable poolManager;
    address public immutable lancador;
    Currency public immutable moeda;

    Currency public token;
    address public recebedorTaxas;
    bool public lancado;
    Faixa[] internal faixas;

    uint8 internal constant LANCAR = 1;
    uint8 internal constant COLETAR = 2;

    error EnderecoDeHookErrado();
    error EnderecoZero();
    error SoLancador();
    error JaLancado();
    error SoPoolManager();
    error SoRecebedor();
    error SoEstaPool();
    error TokenNaoRecebido();
    error EscadaVazia();
    error FaixaFora(uint256 faixa);
    error SobraNegativa();
    error LiquidezZero(uint256 faixa);

    event Lancado(address indexed token, PoolId indexed id, uint256 faixas, uint256 tokens);
    event TaxasColetadas(address indexed para, uint256 emToken, uint256 emMoeda);
    event RecebedorTransferido(address indexed recebedor);

    constructor(IPoolManager _poolManager, address _lancador, address _moeda, address _recebedorTaxas) {
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != BITS_HOOK) revert EnderecoDeHookErrado();
        if (_lancador == address(0) || _recebedorTaxas == address(0) || _moeda == address(0)) revert EnderecoZero();
        poolManager = _poolManager;
        lancador = _lancador;
        moeda = Currency.wrap(_moeda);
        recebedorTaxas = _recebedorTaxas;
    }

    function tokenEhMoeda0() public view returns (bool) {
        return Currency.unwrap(token) < Currency.unwrap(moeda);
    }

    function chave() public view returns (PoolKey memory k) {
        (k.currency0, k.currency1) = tokenEhMoeda0() ? (token, moeda) : (moeda, token);
        k.fee = TAXA;
        k.tickSpacing = ESPACAMENTO;
        k.hooks = IHooks(address(this));
    }

    function todasAsFaixas() external view returns (Faixa[] memory) {
        return faixas;
    }

    // ---------------------------------------------------------------- hook

    /// Só chega aqui quem NÃO é este contrato: recusa.
    function beforeInitialize(address, PoolKey calldata, uint160) external view returns (bytes4) {
        if (msg.sender != address(poolManager)) revert SoPoolManager();
        revert SoEstaPool();
    }

    /// Só chega aqui quem NÃO é este contrato: recusa.
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != address(poolManager)) revert SoPoolManager();
        revert SoEstaPool();
    }

    // ------------------------------------------------------------- entrada

    /// @notice Publica o token, cria a pool no `_tickInicial` e deposita a escada inteira.
    /// Todo degrau tem de ficar inteiro do lado do token (acima do preço inicial). O último
    /// degrau recebe tudo o que sobrar: a pool fica com 100% do que este contrato recebeu.
    function lancar(bytes32 _saltToken, int24 _tickInicial, Faixa[] calldata _faixas) external {
        if (msg.sender != lancador) revert SoLancador();
        if (lancado) revert JaLancado();
        if (_faixas.length == 0) revert EscadaVazia();
        lancado = true;

        address t = CREATEX.deployCreate3(_saltToken, abi.encodePacked(type(AGL).creationCode, abi.encode(address(this))));
        token = Currency.wrap(t);
        uint256 saldo = IERC20(t).balanceOf(address(this));
        uint256 esperado = AGL(t).supplyDaRede(block.chainid);
        if (saldo != esperado - esperado * AGL(t).PARTE_DONO_BPS() / 10_000) revert TokenNaoRecebido();

        bool t0 = tokenEhMoeda0();
        uint256 soma;
        for (uint256 i; i < _faixas.length; i++) {
            Faixa calldata f = _faixas[i];
            bool dentro = t0 ? f.inferior >= _tickInicial : f.superior <= _tickInicial;
            if (!dentro || f.inferior >= f.superior) revert FaixaFora(i);
            faixas.push(f);
            if (i + 1 < _faixas.length) soma += f.quantidade;
        }
        if (soma >= saldo) revert SobraNegativa();
        faixas[_faixas.length - 1].quantidade = saldo - soma;

        poolManager.unlock(abi.encode(LANCAR, _tickInicial));
        emit Lancado(t, chave().toId(), _faixas.length, saldo);
    }

    /// @notice Qualquer um pode chamar; as taxas vão sempre para `recebedorTaxas`.
    function coletarTaxas() external {
        poolManager.unlock(abi.encode(COLETAR, int24(0)));
    }

    function transferirRecebedor(address _novo) external {
        if (msg.sender != recebedorTaxas) revert SoRecebedor();
        if (_novo == address(0)) revert EnderecoZero();
        recebedorTaxas = _novo;
        emit RecebedorTransferido(_novo);
    }

    // ------------------------------------------------------------ callback

    function unlockCallback(bytes calldata _dados) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert SoPoolManager();
        (uint8 op, int24 tickInicial) = abi.decode(_dados, (uint8, int24));
        PoolKey memory k = chave();
        if (op == COLETAR) {
            for (uint256 i; i < faixas.length; i++) {
                // liquidez 0 = só "cutuca" a posição: as taxas acumuladas viram saldo a sacar.
                poolManager.modifyLiquidity(k, ModifyLiquidityParams(faixas[i].inferior, faixas[i].superior, 0, 0), "");
            }
            uint256 emToken = _sacar(token);
            uint256 emMoeda = _sacar(moeda);
            emit TaxasColetadas(recebedorTaxas, emToken, emMoeda);
            return "";
        }
        // Só este contrato inicializa (o hook recusa os outros): a pool é nova.
        poolManager.initialize(k, TickMath.getSqrtPriceAtTick(tickInicial));
        bool t0 = tokenEhMoeda0();
        for (uint256 i; i < faixas.length; i++) {
            Faixa memory f = faixas[i];
            uint160 a = TickMath.getSqrtPriceAtTick(f.inferior);
            uint160 b = TickMath.getSqrtPriceAtTick(f.superior);
            uint128 liq = t0
                ? LiquidityAmounts.getLiquidityForAmount0(a, b, f.quantidade)
                : LiquidityAmounts.getLiquidityForAmount1(a, b, f.quantidade);
            if (liq == 0) revert LiquidezZero(i);
            poolManager.modifyLiquidity(k, ModifyLiquidityParams(f.inferior, f.superior, int256(uint256(liq)), 0), "");
        }
        // Paga o token devido (o arredondamento deixa poeira, que fica neste contrato).
        int256 d = poolManager.currencyDelta(address(this), token);
        if (d < 0) {
            poolManager.sync(token);
            IERC20(Currency.unwrap(token)).safeTransfer(address(poolManager), uint256(-d));
            poolManager.settle();
        }
        return "";
    }

    function _sacar(Currency _c) internal returns (uint256 v) {
        int256 d = poolManager.currencyDelta(address(this), _c);
        if (d > 0) {
            v = uint256(d);
            poolManager.take(_c, recebedorTaxas, v);
        }
    }
}
