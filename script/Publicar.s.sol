// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { ILayerZeroEndpointV2 } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import { UlnConfig } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import { ExecutorConfig } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/SendLibBase.sol";
import { EnforcedOptionParam } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolAGL } from "../src/PoolAGL.sol";
import { AGL } from "../src/AGL.sol";
import { RegistroAGL, IPoolAGLLeitura } from "../src/RegistroAGL.sol";
import { EscrowAGL, IRegistro } from "../src/EscrowAGL.sol";
import { ICreateX } from "../src/ICreateX.sol";

interface IUlnLeitura {
    function getUlnConfig(address oapp, uint32 eid) external view returns (UlnConfig memory);
    function getExecutorConfig(address oapp, uint32 eid) external view returns (ExecutorConfig memory);
}

/// Publica a pilha AGL numa rede. Retomável (pula o que já existe).
///   1. PoolAGL (hook) pela CreateX — salt protegido pela carteira de publicação;
///   2. PoolAGL.lancar: token + pool AGL/USDC + escada, na mesma transação;
///   3. RegistroAGL e EscrowAGL pela CreateX (mesmo endereço em toda rede);
///   4. libera o Registro no token e define os preços dos serviços;
///   5. entrega guardião do token e supervisor do Registro ao DONO;
///   6. ponte LayerZero (igual ao SDBR): liga as outras 7 redes, FIXA bibliotecas,
///      verificadores, executor e gás de entrega, e entrega dono + delegate da ponte a um
///      Timelock de 7 dias (o DONO propõe; qualquer um executa depois do prazo).
/// A carteira de publicação começa como guardião/supervisor só para os passos 4 e 5.
/// env: EIDS (as outras redes, por vírgula), AGL_PK, SALT_POOL, SALT_TOKEN, SALT_REGISTRO, SALT_ESCROW, SALT_CAGL (Ethereum), PM, MOEDA, CASAS_MOEDA, ESCADA
contract Publicar is Script {
    address constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    address constant DONO = 0x979514BddD0346FdD218c49B8242b92C1A6D0ffC;
    uint256 constant TAXA_COMPRADOR_BPS = 100; // 1%
    uint256 constant TAXA_VENDEDOR_BPS = 200; // 2%
    address constant EP = 0x1a44076050125825900e736c501f859c50fE728c;
    uint256 constant ATRASO_TIMELOCK = 7 days;
    uint128 constant GAS_ENTREGA = 300_000; // mint + sondas da trava (auditoria: até ~220k em contrato pesado)
    uint8 constant NIL_DVN = type(uint8).max;

    function _endereco(address _eu, bytes32 _salt) internal view returns (address) {
        return ICreateX(CREATEX).computeCreate3Address(keccak256(abi.encode(_eu, _salt)));
    }

    function run() external {
        uint256 pk = vm.envUint("AGL_PK");
        address eu = vm.addr(pk);
        address pm = vm.envAddress("PM");
        address moeda = vm.envAddress("MOEDA");
        uint256 um = 10 ** vm.envUint("CASAS_MOEDA");
        string memory json = vm.readFile(vm.envString("ESCADA"));
        int24 tickInicial = int24(vm.parseJsonInt(json, ".tickInicial"));

        vm.startBroadcast(pk);
        // 1. pool/hook
        address pPool = _endereco(eu, vm.envBytes32("SALT_POOL"));
        if (pPool.code.length == 0) {
            ICreateX(CREATEX).deployCreate3(
                vm.envBytes32("SALT_POOL"),
                abi.encodePacked(type(PoolAGL).creationCode, abi.encode(IPoolManager(pm), eu, moeda, DONO, eu))
            );
        }
        PoolAGL pool = PoolAGL(pPool);
        // 2. token + pool + escada
        if (!pool.lancado()) {
            uint256 n = vm.parseJsonUint(json, ".degraus");
            PoolAGL.Faixa[] memory fx = new PoolAGL.Faixa[](n);
            for (uint256 i; i < n; i++) {
                string memory p = string.concat(".faixas[", vm.toString(i), "]");
                fx[i] = PoolAGL.Faixa(
                    int24(vm.parseJsonInt(json, string.concat(p, ".inferior"))),
                    int24(vm.parseJsonInt(json, string.concat(p, ".superior"))),
                    vm.parseJsonUint(json, string.concat(p, ".quantidade"))
                );
            }
            pool.lancar(vm.envBytes32("SALT_TOKEN"), tickInicial, fx);
        }
        AGL t = AGL(Currency.unwrap(pool.token()));
        // 3. registro e escrow
        address pReg = _endereco(eu, vm.envBytes32("SALT_REGISTRO"));
        if (pReg.code.length == 0) {
            ICreateX(CREATEX).deployCreate3(
                vm.envBytes32("SALT_REGISTRO"),
                abi.encodePacked(
                    type(RegistroAGL).creationCode,
                    abi.encode(IPoolAGLLeitura(pPool), DONO, eu, DONO, TickMath.getSqrtPriceAtTick(tickInicial))
                )
            );
        }
        RegistroAGL reg = RegistroAGL(pReg);
        address pEsc = _endereco(eu, vm.envBytes32("SALT_ESCROW"));
        if (pEsc.code.length == 0) {
            address[] memory moedas = new address[](1);
            moedas[0] = moeda;
            ICreateX(CREATEX).deployCreate3(
                vm.envBytes32("SALT_ESCROW"),
                abi.encodePacked(
                    type(EscrowAGL).creationCode,
                    abi.encode(IRegistro(pReg), DONO, DONO, TAXA_COMPRADOR_BPS, TAXA_VENDEDOR_BPS, moedas)
                )
            );
        }
        // 4. libera no token o registro e, no Ethereum, o endereço do cAGL (camada
        //    confidencial, publicada depois por zama/script/PublicarConfidencial.s.sol)
        if (!t.permitido(pReg)) {
            address[] memory lista = new address[](block.chainid == 1 ? 2 : 1);
            lista[0] = pReg;
            if (block.chainid == 1) lista[1] = _endereco(eu, vm.envBytes32("SALT_CAGL"));
            t.permitir(lista);
        }
        if (reg.supervisor() == eu) {
            reg.definirPreco(RegistroAGL.Servico.Cadastro, 25 * um);
            reg.definirPreco(RegistroAGL.Servico.KycPessoa, 25 * um);
            reg.definirPreco(RegistroAGL.Servico.KybEmpresa, 75 * um);
            reg.definirPreco(RegistroAGL.Servico.Contato, 15 * um);
            reg.definirPreco(RegistroAGL.Servico.InfoExtra, 10 * um);
            // 5. entrega as chaves ao dono
            reg.trocarSupervisor(DONO);
        }
        if (t.guardiao() == eu) t.trocarGuardiao(DONO);
        // 6. ponte — só na 2ª etapa (LIGAR_PONTE=1), depois que as 8 redes foram publicadas e
        //    conferidas: antes disso a chave de publicação poria um AGL falso numa rede ainda vazia
        if (vm.envOr("LIGAR_PONTE", false) && t.owner() == eu) {
            uint256[] memory outras = vm.envUint("EIDS", ",");
            uint32[] memory eids = new uint32[](outras.length);
            for (uint256 i; i < outras.length; i++) eids[i] = uint32(outras[i]);
            if (!_redesLigadas(t, eids)) t.ligarRedesEVM(eids);
            _fixarPonte(t, eids);
            address[] memory propoe = new address[](1);
            propoe[0] = DONO;
            address[] memory executa = new address[](1); // address(0) = qualquer um, depois do prazo
            TimelockController tl = new TimelockController(ATRASO_TIMELOCK, propoe, executa, address(0));
            t.setDelegate(address(tl));
            t.transferOwnership(address(tl));
            console2.log("timelock", address(tl));
        }
        vm.stopBroadcast();
        console2.log("pool/hook", pPool);
        console2.log("token", address(t));
        console2.log("registro", pReg);
        console2.log("escrow", pEsc);
    }

    function _redesLigadas(AGL _t, uint32[] memory _eids) internal view returns (bool) {
        for (uint256 i; i < _eids.length; i++) {
            if (_t.peers(_eids[i]) != bytes32(uint256(uint160(address(_t))))) return false;
        }
        return true;
    }

    /// Grava explicitamente a configuração que hoje é o padrão da LayerZero (igual ao SDBR):
    /// mudança futura no padrão deles não afeta o AGL; só o Timelock muda.
    function _fixarPonte(AGL _t, uint32[] memory _eids) internal {
        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(EP);
        EnforcedOptionParam[] memory opts = new EnforcedOptionParam[](_eids.length * 2);
        bytes memory gas = abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), GAS_ENTREGA);
        for (uint256 i; i < _eids.length; i++) {
            uint32 e = _eids[i];
            // cada passo é idempotente (retomável depois de falha no meio)
            address envio = ep.getSendLibrary(address(_t), e);
            if (ep.isDefaultSendLibrary(address(_t), e)) ep.setSendLibrary(address(_t), e, envio);
            (address recebe, bool padrao) = ep.getReceiveLibrary(address(_t), e);
            if (padrao) ep.setReceiveLibrary(address(_t), e, recebe, 0);
            SetConfigParam[] memory pe = new SetConfigParam[](2);
            pe[0] = SetConfigParam(e, 1, abi.encode(IUlnLeitura(envio).getExecutorConfig(address(_t), e)));
            pe[1] = SetConfigParam(e, 2, abi.encode(_explicita(IUlnLeitura(envio).getUlnConfig(address(_t), e))));
            ep.setConfig(address(_t), envio, pe);
            SetConfigParam[] memory pr = new SetConfigParam[](1);
            pr[0] = SetConfigParam(e, 2, abi.encode(_explicita(IUlnLeitura(recebe).getUlnConfig(address(_t), e))));
            ep.setConfig(address(_t), recebe, pr);
            opts[2 * i] = EnforcedOptionParam(e, 1, gas); // SEND
            opts[2 * i + 1] = EnforcedOptionParam(e, 2, gas); // SEND_AND_CALL
        }
        _t.setEnforcedOptions(opts);
    }

    /// Na ULN, contagem 0 = "use o padrão": troca por NIL para fixar "nenhum".
    function _explicita(UlnConfig memory c) internal pure returns (UlnConfig memory) {
        require(c.confirmations > 0 && c.requiredDVNCount > 0 && c.requiredDVNCount != NIL_DVN, "ULN sem padrao fixavel");
        if (c.optionalDVNCount == 0) {
            c.optionalDVNCount = NIL_DVN;
            c.optionalDVNThreshold = 0;
        }
        return c;
    }
}
