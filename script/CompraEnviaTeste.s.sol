// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SendParam, MessagingFee} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {AGL} from "../src/AGL.sol";
import {PoolAGL} from "../src/PoolAGL.sol";

interface IUniversalRouterT {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2T {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

struct ExactInputSingleParamsT {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

/// Teste REAL da ponte depois da etapa 2: compra AGL com `VALOR_MOEDA` de USDC na pool
/// oficial (Universal Router da Uniswap) e envia todo o AGL inteiro para `EID_DESTINO`.
/// env: AGL_PK, POOL, UR, VALOR_MOEDA, EID_DESTINO, SO_COMPRAR (opcional)
contract CompraEnviaTeste is Script {
    IPermit2T constant PERMIT2 = IPermit2T(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    function run() external {
        uint256 pk = vm.envUint("AGL_PK");
        address eu = vm.addr(pk);
        PoolAGL pool = PoolAGL(vm.envAddress("POOL"));
        AGL t = AGL(Currency.unwrap(pool.token()));
        IUniversalRouterT ur = IUniversalRouterT(vm.envAddress("UR"));
        uint128 valor = uint128(vm.envUint("VALOR_MOEDA"));
        PoolKey memory k = pool.chave();
        bool t0 = pool.tokenEhMoeda0();
        address moeda = Currency.unwrap(pool.moeda());

        vm.startBroadcast(pk);
        if (t.balanceOf(eu) < 1e9) {
            IERC20(moeda).approve(address(PERMIT2), valor);
            PERMIT2.approve(moeda, address(ur), valor, uint48(block.timestamp + 1 hours));
            bytes memory acoes = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
            bytes[] memory p = new bytes[](3);
            p[0] = abi.encode(ExactInputSingleParamsT(k, !t0, valor, 1, ""));
            p[1] = abi.encode(pool.moeda(), uint256(valor));
            p[2] = abi.encode(pool.token(), uint256(1));
            bytes[] memory inputs = new bytes[](1);
            inputs[0] = abi.encode(acoes, p);
            ur.execute(abi.encodePacked(uint8(0x10)), inputs, block.timestamp + 600);
        }
        uint256 agl = t.balanceOf(eu);
        console2.log("AGL comprado (unidades)", agl);
        if (!vm.envOr("SO_COMPRAR", false)) {
            uint256 v = (agl / 1e9) * 1e9;
            SendParam memory sp = SendParam(uint32(vm.envUint("EID_DESTINO")), bytes32(uint256(uint160(eu))), v, v, "", "", "");
            MessagingFee memory taxa = t.quoteSend(sp, false);
            console2.log("taxa LayerZero (nativo, wei)", taxa.nativeFee);
            t.send{value: taxa.nativeFee}(sp, taxa, eu);
            console2.log("enviado (unidades)", v);
        }
        vm.stopBroadcast();
    }
}
