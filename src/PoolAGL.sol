// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {ICreateX} from "./ICreateX.sol";

interface IAGLSupply {
    /// @notice Supply criado em cada rede.
    // slither-disable-next-line naming-convention (getter da constante SUPPLY_POR_REDE do AGL)
    function SUPPLY_POR_REDE() external view returns (uint256);
}

/// @title PoolAGL — publica o AGL e a pool oficial dele (Uniswap v4, AGL/USDC, taxa 2%)
/// @author AgroLastro (Solidity Brasil)
/// @custom:security-contact t.me/agrolastro
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
    /// @notice keccak256 do código de criação EXATO do AGL (código + argumentos). Gravado na
    /// criação da pool: `lancar` só publica um token com este código (a pool não carrega o
    /// código do token dentro dela — limite de 24 KB da EIP-170).
    bytes32 public immutable hashInitToken;
    /// @notice Salt (protegido por este contrato) com que `lancar` publica o token.
    bytes32 public immutable saltToken;
    /// Endereço do token, calculado na criação (CREATE3 é determinístico): imutável, sem
    /// leitura de storage em cada swap e em cada transferência pela cota.
    address internal immutable aglToken;
    bool internal immutable aglEhMoeda0;

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
    error CodigoDoTokenErrado();
    error PagamentoDiferente();
    error TickInicialDiferente();
    error IntervaloInvalido();

    event Lancado(address indexed token, PoolId indexed id, uint256 faixas, uint256 tokens);
    event TaxasColetadas(uint256 emToken, uint256 emMoeda);
    event TaxasSacadas(address indexed moeda, address indexed para, uint256 valor);
    event RecebedorTransferido(address indexed recebedor);

    constructor(
        IPoolManager poolManager_,
        address lancador_,
        address moeda_,
        address recebedorTaxas_,
        address guardiaoToken_,
        bytes32 hashInitToken_,
        bytes32 saltToken_
    ) {
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != BITS_HOOK) {
            revert EnderecoDeHookErrado();
        }
        if (
            lancador_ == address(0) || recebedorTaxas_ == address(0) || moeda_ == address(0)
                || guardiaoToken_ == address(0)
        ) revert EnderecoZero();
        poolManager = poolManager_;
        lancador = lancador_;
        moeda = Currency.wrap(moeda_);
        recebedorTaxas = recebedorTaxas_;
        guardiaoToken = guardiaoToken_;
        hashInitToken = hashInitToken_;
        // salt protegido: 20 primeiros bytes = este contrato, byte 21 = 0x00 (mesmo endereço
        // em toda rede e ninguém mais publica nele)
        if (address(bytes20(saltToken_)) != address(this) || saltToken_[20] != 0x00) revert SaltSemProtecao();
        saltToken = saltToken_;
        address t = CREATEX.computeCreate3Address(keccak256(abi.encode(address(this), saltToken_)));
        if (t == address(0)) revert EnderecoZero();
        aglToken = t;
        aglEhMoeda0 = t < moeda_;
    }

    /// @notice O AGL desta rede (o endereço existe antes de `lancar`; o código, depois).
    function token() public view returns (Currency) {
        return Currency.wrap(aglToken);
    }

    /// @notice true se o AGL é a currency0 do par (endereço menor que o da moeda).
    function tokenEhMoeda0() public view returns (bool) {
        return aglEhMoeda0;
    }

    /// @notice Chave (PoolKey) da pool oficial AGL/moeda.
    /// @return k currency0, currency1, taxa 2%, espaçamento 10 e este contrato como hook.
    function chave() public view returns (PoolKey memory k) {
        (k.currency0, k.currency1) = aglEhMoeda0 ? (token(), moeda) : (moeda, token());
        k.fee = TAXA;
        k.tickSpacing = ESPACAMENTO;
        k.hooks = IHooks(address(this));
    }

    /// @notice Todos os degraus da escada (ticks e quantidade de AGL de cada um).
    function todasAsFaixas() external view returns (Faixa[] memory) {
        return faixas;
    }

    // ---------------------------------------------------------------- hook

    /// Só chega aqui quem NÃO é este contrato: recusa.
    /// @notice Hook do Uniswap v4: recusa criar pool com este hook (só este contrato cria).
    function beforeInitialize(address, PoolKey calldata, uint160) external view returns (bytes4) {
        if (msg.sender != address(poolManager)) revert SoPoolManager();
        revert SoEstaPool();
    }

    /// Só chega aqui quem NÃO é este contrato: recusa.
    /// @notice Hook do Uniswap v4: recusa liquidez de terceiros (fecha JIT).
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
    /// @notice Hook do Uniswap v4: abre a cota transitória do AGL movido pelo swap.
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta delta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        if (msg.sender != address(poolManager)) revert SoPoolManager();
        int128 a = aglEhMoeda0 ? delta.amount0() : delta.amount1();
        _somar(-int256(a));
        return (this.afterSwap.selector, 0);
    }

    // ------------------------------------------------------------- cota (token)

    /// AGL entrando no PoolManager: precisa de cota positiva.
    /// @notice AGL entrando no PoolManager: precisa de cota positiva (só o token chama).
    /// @param v_ Quantidade em unidades.
    function consumirEntrada(uint256 v_) external {
        if (msg.sender != aglToken) revert SoToken();
        int256 c = _ler();
        if (c < 0 || uint256(c) < v_) revert ForaDaCota(v_, c);
        _gravar(c - int256(v_));
    }

    /// AGL saindo do PoolManager: precisa de cota negativa.
    /// @notice AGL saindo do PoolManager: precisa de cota negativa (só o token chama).
    /// @param v_ Quantidade em unidades.
    function consumirSaida(uint256 v_) external {
        if (msg.sender != aglToken) revert SoToken();
        int256 c = _ler();
        if (c > 0 || uint256(-c) < v_) revert ForaDaCota(v_, c);
        _gravar(c + int256(v_));
    }

    /// @notice Cota transitória atual (positiva = entrada pendente; negativa = saída).
    function cota() external view returns (int256) {
        return _ler();
    }

    function _somar(int256 v_) internal {
        _gravar(_ler() + v_);
    }

    function _gravar(int256 c_) internal {
        bytes32 slot = SLOT_ENTRADA;
        assembly {
            tstore(slot, c_)
        }
    }

    function _ler() internal view returns (int256 c) {
        bytes32 slot = SLOT_ENTRADA;
        assembly {
            c := tload(slot)
        }
    }

    // ------------------------------------------------------------- entrada

    /// @notice Publica o token, cria a pool no `tickInicial` e deposita a escada inteira.
    /// Todo degrau tem de ficar inteiro do lado do token (acima do preço inicial). O último
    /// degrau recebe tudo o que sobrar: a pool fica com 100% do supply da rede.
    function lancar(bytes calldata initToken, int24 tickInicial, Faixa[] calldata faixas_) external {
        if (msg.sender != lancador) revert SoLancador();
        if (lancado) revert JaLancado();
        if (faixas_.length == 0) revert EscadaVazia();
        if (keccak256(initToken) != hashInitToken) revert CodigoDoTokenErrado();
        lancado = true;

        address t = CREATEX.deployCreate3(saltToken, initToken);
        if (t != aglToken) revert TokenNaoRecebido();
        uint256 saldo = IERC20(t).balanceOf(address(this));
        if (saldo != IAGLSupply(t).SUPPLY_POR_REDE()) revert TokenNaoRecebido();

        bool t0 = aglEhMoeda0;
        uint256 soma = 0;
        for (uint256 i; i < faixas_.length; i++) {
            Faixa calldata f = faixas_[i];
            bool dentro = t0 ? f.inferior >= tickInicial : f.superior <= tickInicial;
            if (!dentro || f.inferior >= f.superior) revert FaixaFora(i);
            faixas.push(f);
            if (i + 1 < faixas_.length) soma += f.quantidade;
        }
        if (soma >= saldo) revert SobraNegativa();
        faixas[faixas_.length - 1].quantidade = saldo - soma;

        // slither-disable-next-line unused-return
        poolManager.unlock(abi.encode(LANCAR, tickInicial));
        emit Lancado(t, chave().toId(), faixas_.length, saldo);
    }

    /// @notice Qualquer um pode chamar: traz as taxas acumuladas de todos os degraus para este
    /// contrato.
    function coletarTaxas() external {
        _coletar(0, faixas.length);
    }

    /// @notice Coleta só dos degraus [`de`, `ate`) — mais barato quando o volume está num
    /// degrau só (ex.: o 1º).
    function coletarTaxasFaixas(uint256 de, uint256 ate) external {
        if (de >= ate || ate > faixas.length) revert IntervaloInvalido();
        _coletar(de, ate);
    }

    function _coletar(uint256 de, uint256 ate) internal {
        // slither-disable-next-line unused-return
        poolManager.unlock(abi.encode(COLETAR, de, ate));
    }

    /// @notice O recebedor saca as taxas de UMA moeda (token ou moeda da pool) para `para`.
    function sacarTaxas(Currency c_, address para) external {
        if (msg.sender != recebedorTaxas) revert SoRecebedor();
        if (para == address(0)) revert EnderecoZero();
        address m = Currency.unwrap(c_);
        uint256 v = aSacar[m];
        aSacar[m] = 0;
        if (v > 0) IERC20(m).safeTransfer(para, v);
        emit TaxasSacadas(m, para, v);
    }

    /// @notice Troca a carteira que saca as taxas (só o recebedor atual chama).
    /// @param novo Novo recebedor (não pode ser o endereço zero).
    function transferirRecebedor(address novo) external {
        if (msg.sender != recebedorTaxas) revert SoRecebedor();
        if (novo == address(0)) revert EnderecoZero();
        recebedorTaxas = novo;
        emit RecebedorTransferido(novo);
    }

    // ------------------------------------------------------------ callback

    /// @notice Callback do PoolManager (lançamento e coleta). Só o PoolManager chama.
    function unlockCallback(bytes calldata dados) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert SoPoolManager();
        PoolKey memory k = chave();
        if (uint8(dados[31]) == COLETAR) {
            (, uint256 de, uint256 ate) = abi.decode(dados, (uint8, uint256, uint256));
            for (uint256 i = de; i < ate; i++) {
                // liquidez 0 = só "cutuca" a posição: as taxas acumuladas viram saldo a sacar.
                // slither-disable-next-line unused-return
                poolManager.modifyLiquidity(k, ModifyLiquidityParams(faixas[i].inferior, faixas[i].superior, 0, 0), "");
            }
            // efeitos (saldos a sacar) de AMBAS as moedas antes de qualquer interação
            Currency tk = token();
            uint256 emToken = _aSacar(tk);
            uint256 emMoeda = _aSacar(moeda);
            if (emToken > 0) {
                _somar(-int256(emToken));
                poolManager.take(tk, address(this), emToken);
            }
            if (emMoeda > 0) poolManager.take(moeda, address(this), emMoeda);
            emit TaxasColetadas(emToken, emMoeda);
            return "";
        }
        (, int24 tickInicial) = abi.decode(dados, (uint8, int24));
        // Só este contrato inicializa (o hook recusa os outros): a pool é nova.
        if (poolManager.initialize(k, TickMath.getSqrtPriceAtTick(tickInicial)) != tickInicial) {
            revert TickInicialDiferente();
        }
        bool t0 = aglEhMoeda0;
        uint256 n = faixas.length;
        for (uint256 i; i < n; i++) {
            Faixa memory f = faixas[i];
            uint160 a = TickMath.getSqrtPriceAtTick(f.inferior);
            uint160 b = TickMath.getSqrtPriceAtTick(f.superior);
            uint128 liq = t0
                ? LiquidityAmounts.getLiquidityForAmount0(a, b, f.quantidade)
                : LiquidityAmounts.getLiquidityForAmount1(a, b, f.quantidade);
            if (liq == 0) revert LiquidezZero(i);
            // slither-disable-next-line unused-return
            poolManager.modifyLiquidity(k, ModifyLiquidityParams(f.inferior, f.superior, int256(uint256(liq)), 0), "");
        }
        // Paga o token devido (o arredondamento deixa poeira, que fica neste contrato).
        Currency tk = token();
        int256 d = poolManager.currencyDelta(address(this), tk);
        if (d < 0) {
            _somar(-d);
            poolManager.sync(tk);
            IERC20(aglToken).safeTransfer(address(poolManager), uint256(-d));
            if (poolManager.settle() != uint256(-d)) revert PagamentoDiferente();
        }
        return "";
    }

    /// Registra no saldo a sacar o que o PoolManager deve a este contrato em `c_`.
    function _aSacar(Currency c_) internal returns (uint256 v) {
        int256 d = poolManager.currencyDelta(address(this), c_);
        if (d > 0) {
            v = uint256(d);
            aSacar[Currency.unwrap(c_)] += v;
        }
    }
}
