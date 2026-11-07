// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolAGL } from "../src/PoolAGL.sol";
import { AGL } from "../src/AGL.sol";
import { RegistroAGL, IPoolAGLLeitura } from "../src/RegistroAGL.sol";
import { EscrowAGL, IRegistro } from "../src/EscrowAGL.sol";
import { ICreateX } from "../src/ICreateX.sol";

/// Publica a pilha AGL numa rede. Retomável (pula o que já existe).
///   1. PoolAGL (hook) pela CreateX — salt protegido pela carteira de publicação;
///   2. PoolAGL.lancar: token + pool AGL/USDC + escada, na mesma transação;
///   3. RegistroAGL e EscrowAGL pela CreateX (mesmo endereço em toda rede);
///   4. libera o Registro no token e define os preços dos serviços;
///   5. entrega guardião do token e supervisor do Registro ao DONO.
/// A carteira de publicação começa como guardião/supervisor só para os passos 4 e 5.
/// env: AGL_PK, SALT_POOL, SALT_TOKEN, SALT_REGISTRO, SALT_ESCROW, SALT_CAGL (Ethereum), PM, MOEDA, CASAS_MOEDA, ESCADA
contract Publicar is Script {
    address constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    address constant DONO = 0x979514BddD0346FdD218c49B8242b92C1A6D0ffC;
    uint256 constant TAXA_COMPRADOR_BPS = 100; // 1%
    uint256 constant TAXA_VENDEDOR_BPS = 200; // 2%

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
        vm.stopBroadcast();
        console2.log("pool/hook", pPool);
        console2.log("token", address(t));
        console2.log("registro", pReg);
        console2.log("escrow", pEsc);
    }
}
