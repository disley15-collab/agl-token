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
import { ModifyLiquidityParams, SwapParams } from "v4-core/types/PoolOperation.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { TransientStateLibrary } from "v4-core/libraries/TransientStateLibrary.sol";
import { LiquidityAmounts } from "v4-periphery/libraries/LiquidityAmounts.sol";
import { ICreateX } from "./ICreateX.sol";
import { AGL } from "./AGL.sol";

/// @title PoolAGL — publica o AGL e a pool oficial dele (Uniswap v4, AGL/USDC, taxa 2%)
/// na MESMA transação, com 100% do supply da rede na escada e a liquidez travada PARA SEMPRE.
///
/// @dev Invariantes:
/// 1. `lancar` cria o token (CreateX CREATE3, salt protegido por este contrato), recebe
///    o supply inteiro da rede, cria a pool e deposita TUDO na escada, numa transação só.
/// 2. Só este contrato cria a pool e põe liquidez nela: o PoolManager não chama o hook
///    quando quem age é o próprio hook; para qualquer outro, `beforeInitialize` e
///    `beforeAddLiquidity` recusam (fecha pré-inicialização e JIT de terceiros).
/// 3. COTA LÍQUIDA: a cada swap na pool oficial, `afterSwap` soma numa cota transitória
///    (EIP-1153, com sinal) o AGL que o operador deve ao PoolManager (+) ou recebe dele (−).
///    O token só aceita entrada/saída física do PoolManager dentro dessa cota. Ida e volta
///    na pool oficial zera a cota (não fabrica cota grátis). Lançamento e coleta abrem a
///    própria cota.
///    LIMITE CONHECIDO (auditoria 07/11): a trava age na transferência física. Quem compensa
///    saldos dentro do PoolManager (mesmo unlock) ou usa claims ERC-6909 consegue levar AGL
///    a outra pool sem transferir. Ninguém perde AGL nem taxa com isso; quem pode perder é
///    quem compra numa pool falsa por um front-end malicioso.
/// 4. A liquidez de cada degrau nunca diminui: não existe função que tire liquidez.
/// 5. As taxas (nas duas moedas) vêm para este contrato por `coletarTaxas` (qualquer um) e
///    só saem por `sacarTaxas`, chamado pelo recebedor, moeda a moeda, para o destino que
///    ele escolher: blacklist ou destino recusado numa moeda não trava a outra.
///
/// Endereço publicado pela CreateX com bits de hook exatamente
/// BEFORE_INITIALIZE | BEFORE_ADD_LIQUIDITY | AFTER_SWAP (o construtor confere).
contract PoolAGL is IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;

    uint24 public constant TAXA = 20_000; // 2% (em milionésimos)
    int24 public constant ESPACAMENTO = 10;
    ICreateX public constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
    /// @notice EndpointV2 da LayerZero (mesmo endereço nas 8 redes, conferido em 07/11).
    address public constant ENDPOINT_LZ = 0x1a44076050125825900e736c501f859c50fE728c;
    uint160 internal constant BITS_HOOK =
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG;
    // slot transitório da cota líquida: keccak256("agl.cota.entrada")
    bytes32 internal constant SLOT_ENTRADA = 0xa11c6e133e7e4c4b04f33b5b1bde052706392775ae91fd6cef2a6accd76d39f6;

    struct Faixa {
        int24 inferior;
        int24 superior;
        uint256 quantidade; // tokens do degrau (o último recebe o que sobrar)
    }

    IPoolManager public immutable poolManager;
    address public immutable lancador;
    Currency public immutable moeda;
    address public immutable guardiaoToken;

    Currency public token;
    address public recebedorTaxas;
    bool public lancado;
    Faixa[] internal faixas;
    /// @notice Taxas já coletadas, à espera de `sacarTaxas`, por moeda.
    mapping(address => uint256) public aSacar;

    uint8 internal constant LANCAR = 1;
    uint8 internal constant COLETAR = 2;

    error EnderecoDeHookErrado();
    error EnderecoZero();
    error SoLancador();
    error JaLancado();
    error SoPoolManager();
    error SoToken();
    error SoRecebedor();
    error SoEstaPool();
    error TokenNaoRecebido();
    error EscadaVazia();
    error FaixaFora(uint256 faixa);
    error SobraNegativa();
    error LiquidezZero(uint256 faixa);
    error ForaDaCota(uint256 pedido, int256 cota);
    error SaltSemProtecao();

    event Lancado(address indexed token, PoolId indexed id, uint256 faixas, uint256 tokens);
    event TaxasColetadas(uint256 emToken, uint256 emMoeda);
    event TaxasSacadas(address indexed moeda, address indexed para, uint256 valor);
    event RecebedorTransferido(address indexed recebedor);

    constructor(
        IPoolManager _poolManager,
        address _lancador,
        address _moeda,
        address _recebedorTaxas,
        address _guardiaoToken
    ) {
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != BITS_HOOK) revert EnderecoDeHookErrado();
        if (
            _lancador == address(0) || _recebedorTaxas == address(0) || _moeda == address(0)
                || _guardiaoToken == address(0)
        ) revert EnderecoZero();
        poolManager = _poolManager;
        lancador = _lancador;
        moeda = Currency.wrap(_moeda);
        recebedorTaxas = _recebedorTaxas;
        guardiaoToken = _guardiaoToken;
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

    /// Soma na cota líquida o AGL que este swap move: o que o operador deve ao PoolManager
    /// (+) ou recebe dele (−). Só a pool oficial usa este hook (as outras não passam do
    /// `beforeInitialize`).
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta _delta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        if (msg.sender != address(poolManager)) revert SoPoolManager();
        int128 a = tokenEhMoeda0() ? _delta.amount0() : _delta.amount1();
        _somar(-int256(a));
        return (this.afterSwap.selector, 0);
    }

    // ------------------------------------------------------------- cota (token)

    /// AGL entrando no PoolManager: precisa de cota positiva.
    function consumirEntrada(uint256 _v) external {
        if (msg.sender != Currency.unwrap(token)) revert SoToken();
        int256 c = _ler();
        if (c < 0 || uint256(c) < _v) revert ForaDaCota(_v, c);
        _gravar(c - int256(_v));
    }

    /// AGL saindo do PoolManager: precisa de cota negativa.
    function consumirSaida(uint256 _v) external {
        if (msg.sender != Currency.unwrap(token)) revert SoToken();
        int256 c = _ler();
        if (c > 0 || uint256(-c) < _v) revert ForaDaCota(_v, c);
        _gravar(c + int256(_v));
    }

    function cota() external view returns (int256) {
        return _ler();
    }

    function _somar(int256 _v) internal {
        _gravar(_ler() + _v);
    }

    function _gravar(int256 _c) internal {
        bytes32 slot = SLOT_ENTRADA;
        assembly {
            tstore(slot, _c)
        }
    }

    function _ler() internal view returns (int256 c) {
        bytes32 slot = SLOT_ENTRADA;
        assembly {
            c := tload(slot)
        }
    }

    // ------------------------------------------------------------- entrada

    /// @notice Publica o token, cria a pool no `_tickInicial` e deposita a escada inteira.
    /// Todo degrau tem de ficar inteiro do lado do token (acima do preço inicial). O último
    /// degrau recebe tudo o que sobrar: a pool fica com 100% do supply da rede.
    function lancar(bytes32 _saltToken, int24 _tickInicial, Faixa[] calldata _faixas) external {
        if (msg.sender != lancador) revert SoLancador();
        if (lancado) revert JaLancado();
        if (_faixas.length == 0) revert EscadaVazia();
        // salt protegido: 20 primeiros bytes = este contrato, byte 21 = 0x00 (mesmo endereço
        // em toda rede e ninguém mais publica nele)
        if (address(bytes20(_saltToken)) != address(this) || _saltToken[20] != 0x00) revert SaltSemProtecao();
        lancado = true;

        address t = CREATEX.deployCreate3(
            _saltToken, abi.encodePacked(type(AGL).creationCode, abi.encode(address(this), guardiaoToken, ENDPOINT_LZ, lancador))
        );
        token = Currency.wrap(t);
        uint256 saldo = IERC20(t).balanceOf(address(this));
        if (saldo != AGL(t).SUPPLY_POR_REDE()) revert TokenNaoRecebido();

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

    /// @notice Qualquer um pode chamar: traz as taxas acumuladas para este contrato.
    function coletarTaxas() external {
        poolManager.unlock(abi.encode(COLETAR, int24(0)));
    }

    /// @notice O recebedor saca as taxas de UMA moeda (token ou moeda da pool) para `_para`.
    function sacarTaxas(Currency _c, address _para) external {
        if (msg.sender != recebedorTaxas) revert SoRecebedor();
        if (_para == address(0)) revert EnderecoZero();
        address m = Currency.unwrap(_c);
        uint256 v = aSacar[m];
        aSacar[m] = 0;
        if (v > 0) IERC20(m).safeTransfer(_para, v);
        emit TaxasSacadas(m, _para, v);
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
            uint256 emToken = _sacar(token, true);
            uint256 emMoeda = _sacar(moeda, false);
            emit TaxasColetadas(emToken, emMoeda);
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
            _somar(-d);
            poolManager.sync(token);
            IERC20(Currency.unwrap(token)).safeTransfer(address(poolManager), uint256(-d));
            poolManager.settle();
        }
        return "";
    }

    function _sacar(Currency _c, bool _ehToken) internal returns (uint256 v) {
        int256 d = poolManager.currencyDelta(address(this), _c);
        if (d > 0) {
            v = uint256(d);
            if (_ehToken) _somar(-int256(v));
            poolManager.take(_c, address(this), v);
            aSacar[Currency.unwrap(_c)] += v;
        }
    }
}
