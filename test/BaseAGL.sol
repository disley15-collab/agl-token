// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { SwapParams } from "v4-core/types/PoolOperation.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { AGL } from "../src/AGL.sol";
import { PoolAGL } from "../src/PoolAGL.sol";
import { ICreateX } from "../src/ICreateX.sol";

/// Base dos testes. Fork MAINNET da rede em REDE (padrão bsc; ver script/redes.tsv):
/// PoolManager v4, moeda, CreateX reais; carteira de publicação e salts de script/salt-*.json.
abstract contract BaseAGL is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    address constant DEPLOYER = 0x4a5beD839b3cb0736c03fB3A7eb096701E8A89c8;
    address constant DONO = 0x979514BddD0346FdD218c49B8242b92C1A6D0ffC;

    string rede;
    uint256 chainid;
    IPoolManager PM;
    address MOEDA;
    uint8 casasMoeda;
    bytes32 SALT_POOL;
    bytes32 SALT_TOKEN;

    address comprador = makeAddr("comprador");
    address atacante = makeAddr("atacante");

    AGL t;
    PoolAGL pool;
    PoolSwapTest router;
    string json;

    function setUp() public virtual {
        rede = vm.envOr("REDE", string("bsc"));
        string memory tsv = vm.readFile("script/redes.tsv");
        string[] memory linhas = vm.split(tsv, "\n");
        for (uint256 i; i < linhas.length; i++) {
            string[] memory c = vm.split(linhas[i], "\t");
            if (c.length < 6 || keccak256(bytes(c[0])) != keccak256(bytes(rede))) continue;
            chainid = vm.parseUint(c[1]);
            vm.createSelectFork(c[2]);
            PM = IPoolManager(vm.parseAddress(c[3]));
            MOEDA = vm.parseAddress(c[4]);
            casasMoeda = uint8(vm.parseUint(c[5]));
        }
        require(chainid == block.chainid, "rede nao achada ou chainid errado");
        SALT_POOL = vm.parseJsonBytes32(vm.readFile("script/salt-pool.json"), ".salt");
        SALT_TOKEN = vm.parseJsonBytes32(vm.readFile("script/salt-token.json"), ".salt");
        router = new PoolSwapTest(PM);
    }

    function _publicarPool() internal returns (PoolAGL) {
        bytes memory init = abi.encodePacked(type(PoolAGL).creationCode, abi.encode(PM, DEPLOYER, MOEDA, DONO));
        vm.prank(DEPLOYER);
        return PoolAGL(ICreateX(CREATEX).deployCreate3(SALT_POOL, init));
    }

    /// Salt do token protegido pela pool (os 20 primeiros bytes = endereço da pool).
    function _saltToken() internal view returns (bytes32) {
        return bytes32((uint256(uint160(address(pool))) << 96) | (uint256(SALT_TOKEN) & ((1 << 88) - 1)));
    }

    function _enderecoToken() internal view returns (address) {
        bytes32 guardado = keccak256(abi.encode(address(pool), _saltToken()));
        return ICreateX(CREATEX).computeCreate3Address(guardado);
    }

    function _escada(address _token) internal returns (string memory) {
        string[] memory c = new string[](10);
        (c[0], c[1], c[2], c[3]) = ("python3", "script/escada.py", "--token", vm.toString(_token));
        (c[4], c[5], c[6], c[7]) = ("--moeda", vm.toString(MOEDA), "--casas-moeda", vm.toString(uint256(casasMoeda)));
        (c[8], c[9]) = ("--chainid", vm.toString(chainid));
        return string(vm.ffi(c));
    }

    function _faixas() internal view returns (PoolAGL.Faixa[] memory fx) {
        uint256 n = vm.parseJsonUint(json, ".degraus");
        fx = new PoolAGL.Faixa[](n);
        for (uint256 i; i < n; i++) {
            string memory p = string.concat(".faixas[", vm.toString(i), "]");
            fx[i] = PoolAGL.Faixa(
                int24(vm.parseJsonInt(json, string.concat(p, ".inferior"))),
                int24(vm.parseJsonInt(json, string.concat(p, ".superior"))),
                vm.parseJsonUint(json, string.concat(p, ".quantidade"))
            );
        }
    }

    /// Igual ao script de publicação: pool (tx 1), depois token + pool + escada (tx 2).
    function _lancar() internal {
        pool = _publicarPool();
        json = _escada(_enderecoToken());
        PoolAGL.Faixa[] memory fx = _faixas();
        vm.prank(DEPLOYER);
        pool.lancar(_saltToken(), int24(vm.parseJsonInt(json, ".tickInicial")), fx);
        t = AGL(Currency.unwrap(pool.token()));
        assertEq(address(t), _enderecoToken(), "endereco do token previsto");
    }

    function _unid(uint256 _usd) internal view returns (uint256) {
        return _usd * 10 ** casasMoeda;
    }

    function _comprar(address _quem, uint256 _moeda) internal returns (uint256 recebido) {
        bool t0 = pool.tokenEhMoeda0();
        deal(MOEDA, _quem, _moeda);
        uint256 antes = t.balanceOf(_quem);
        vm.startPrank(_quem);
        IERC20(MOEDA).approve(address(router), _moeda);
        router.swap(
            pool.chave(),
            SwapParams(!t0, -int256(_moeda), t0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
        return t.balanceOf(_quem) - antes;
    }

    /// Compra exata de `_qtd` tokens (saída exata).
    function _comprarTokens(address _quem, uint256 _qtd) internal returns (uint256 pago) {
        bool t0 = pool.tokenEhMoeda0();
        uint256 muito = type(uint128).max / 4;
        deal(MOEDA, _quem, muito);
        vm.startPrank(_quem);
        IERC20(MOEDA).approve(address(router), muito);
        router.swap(
            pool.chave(),
            SwapParams(!t0, int256(_qtd), t0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
        pago = muito - IERC20(MOEDA).balanceOf(_quem);
        deal(MOEDA, _quem, 0);
    }

    function _vender(address _quem, uint256 _qtd) internal returns (uint256 recebido) {
        bool t0 = pool.tokenEhMoeda0();
        uint256 antes = IERC20(MOEDA).balanceOf(_quem);
        vm.startPrank(_quem);
        t.approve(address(router), _qtd);
        router.swap(
            pool.chave(),
            SwapParams(t0, -int256(_qtd), t0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
        return IERC20(MOEDA).balanceOf(_quem) - antes;
    }

    function _liquidez(PoolAGL.Faixa memory f) internal view returns (uint128) {
        bytes32 pos = keccak256(abi.encodePacked(address(pool), f.inferior, f.superior, bytes32(0)));
        return PM.getPositionLiquidity(pool.chave().toId(), pos);
    }

    function _tick() internal view returns (int24 tk) {
        (, tk,,) = PM.getSlot0(pool.chave().toId());
    }
}
