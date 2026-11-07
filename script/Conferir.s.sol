// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { LiquidityAmounts } from "v4-periphery/libraries/LiquidityAmounts.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { AGL } from "../src/AGL.sol";
import { PoolAGL } from "../src/PoolAGL.sol";
import { RegistroAGL } from "../src/RegistroAGL.sol";
import { EscrowAGL } from "../src/EscrowAGL.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { ILayerZeroEndpointV2 } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

interface IDelegates {
    function delegates(address oapp) external view returns (address);
}

/// Confere na rede (só leitura) o que a publicação tem de ter deixado. Falha no 1º erro.
/// env: POOL, TOKEN, PM, MOEDA, ESCADA, DEPLOYER
contract Conferir is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 ok;

    function _c(bool _cond, string memory _o) internal {
        require(_cond, _o);
        ok++;
    }

    function run() external {
        PoolAGL pool = PoolAGL(vm.envAddress("POOL"));
        AGL t = AGL(vm.envAddress("TOKEN"));
        IPoolManager pm = IPoolManager(vm.envAddress("PM"));
        string memory json = vm.readFile(vm.envString("ESCADA"));
        address dono = 0x979514BddD0346FdD218c49B8242b92C1A6D0ffC;

        _c(address(pool).code.length > 0, "pool sem codigo");
        _c(uint160(address(pool)) & Hooks.ALL_HOOK_MASK == (Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG), "bits de hook");
        _c(address(pool.poolManager()) == address(pm), "poolManager");
        _c(pool.lancador() == vm.envAddress("DEPLOYER"), "lancador");
        _c(pool.guardiaoToken() == vm.envAddress("DEPLOYER"), "guardiao inicial = publicacao");
        _c(Currency.unwrap(pool.moeda()) == vm.envAddress("MOEDA"), "moeda");
        _c(pool.recebedorTaxas() == dono, "recebedor");
        _c(pool.lancado(), "nao lancado");
        _c(Currency.unwrap(pool.token()) == address(t), "token da pool");
        _c(address(t).code.length > 0, "token sem codigo");
        _c(keccak256(bytes(t.symbol())) == keccak256("AGL"), "simbolo");
        _c(keccak256(bytes(t.name())) == keccak256("AgroLastro"), "nome");
        _c(t.decimals() == 9, "casas");
        uint256 parte = t.SUPPLY_POR_REDE();
        _c(parte == 1e30, "1 sextilhao");
        if (vm.envOr("RECEM_PUBLICADO", true)) _c(t.totalSupply() == parte, "supply");
        _c(t.guardiao() == dono, "guardiao entregue ao dono");
        _c(address(t.pool()) == address(pool), "pool no token");
        _c(t.poolManager() == address(pm), "poolManager no token");
        _c(t.redeAceita(block.chainid), "rede aceita");
        _c(pool.tokenEhMoeda0() == vm.parseJsonBool(json, ".tokenEhMoeda0"), "ordem do par");
        PoolKey memory k = pool.chave();
        _c(k.fee == 20_000 && k.tickSpacing == 10 && address(k.hooks) == address(pool), "chave");
        (uint160 sp, int24 tk,,) = pm.getSlot0(k.toId());
        _c(sp != 0, "pool nao inicializada");
        int24 ti = int24(vm.parseJsonInt(json, ".tickInicial"));
        // logo após a publicação ninguém operou: preço = preço de lançamento
        if (vm.envOr("RECEM_PUBLICADO", true)) _c(tk == ti, "tick inicial");
        _c(pool.cota() == 0, "cota zerada");
        PoolAGL.Faixa[] memory fx = pool.todasAsFaixas();
        _c(fx.length == vm.parseJsonUint(json, ".degraus"), "degraus");
        uint256 soma;
        for (uint256 i; i < fx.length; i++) {
            string memory p = string.concat(".faixas[", vm.toString(i), "]");
            _c(fx[i].inferior == int24(vm.parseJsonInt(json, string.concat(p, ".inferior"))), "inferior");
            _c(fx[i].superior == int24(vm.parseJsonInt(json, string.concat(p, ".superior"))), "superior");
            bytes32 pos = keccak256(abi.encodePacked(address(pool), fx[i].inferior, fx[i].superior, bytes32(0)));
            uint128 liq = pm.getPositionLiquidity(k.toId(), pos);
            uint160 a = TickMath.getSqrtPriceAtTick(fx[i].inferior);
            uint160 b = TickMath.getSqrtPriceAtTick(fx[i].superior);
            uint128 esperado = pool.tokenEhMoeda0()
                ? LiquidityAmounts.getLiquidityForAmount0(a, b, fx[i].quantidade)
                : LiquidityAmounts.getLiquidityForAmount1(a, b, fx[i].quantidade);
            _c(liq == esperado && liq > 0, "liquidez do degrau = quantidade da escada");
            soma += fx[i].quantidade;
        }
        _c(soma == parte, "escada = 100%");
        if (vm.envOr("RECEM_PUBLICADO", true)) _c(t.balanceOf(address(pool)) < soma / 1e9, "poeira");
        // registro e escrow
        RegistroAGL reg = RegistroAGL(vm.envAddress("REGISTRO"));
        EscrowAGL esc = EscrowAGL(vm.envAddress("ESCROW"));
        _c(address(reg).code.length > 0 && address(esc).code.length > 0, "registro/escrow sem codigo");
        _c(address(reg.pool()) == address(pool) && address(reg.agl()) == address(t), "registro aponta pool/token");
        _c(reg.recebedor() == dono && reg.supervisor() == dono && reg.atestador() == dono, "chaves do registro");
        _c(t.permitido(address(reg)), "registro liberado no token");
        uint256 um = 10 ** vm.envUint("CASAS_MOEDA");
        _c(reg.precoMoeda(RegistroAGL.Servico.Cadastro) == 25 * um, "preco cadastro");
        _c(reg.precoMoeda(RegistroAGL.Servico.KycPessoa) == 25 * um, "preco KYC");
        _c(reg.sqrtPiso() == TickMath.getSqrtPriceAtTick(ti), "piso do registro = lancamento");
        _c(reg.precoMoeda(RegistroAGL.Servico.KybEmpresa) == 75 * um, "preco KYB");
        _c(reg.precoMoeda(RegistroAGL.Servico.Contato) == 15 * um, "preco contato");
        _c(reg.precoMoeda(RegistroAGL.Servico.InfoExtra) == 10 * um, "preco info");
        _c(reg.precoEmAgl(RegistroAGL.Servico.KycPessoa) > 0, "cotacao em AGL");
        _c(address(esc.registro()) == address(reg), "escrow aponta registro");
        _c(esc.carteiraTaxas() == dono && esc.supervisor() == dono, "chaves do escrow");
        _c(esc.taxaCompradorBps() == 100 && esc.taxaVendedorBps() == 200, "taxas do escrow");
        _c(esc.moedaAceita(vm.envAddress("MOEDA")), "moeda aceita");
        if (vm.envOr("RECEM_PUBLICADO", true)) _c(esc.totalOrdens() == 0, "escrow sem ordens");
        _c(address(reg).code.length > 0 && t.permitido(address(pool)), "pool liberada no token");
        // ponte (etapa 2): só quando TIMELOCK é informado
        if (vm.envOr("TIMELOCK", address(0)) == address(0)) {
            console2.log("checagens OK:", ok);
            console2.log("(ponte ainda nao ligada: etapa 1)");
            return;
        }
        TimelockController tl = TimelockController(payable(vm.envAddress("TIMELOCK")));
        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(0x1a44076050125825900e736c501f859c50fE728c);
        _c(address(tl).code.length > 0 && tl.getMinDelay() == 7 days, "timelock 7 dias");
        _c(tl.hasRole(tl.PROPOSER_ROLE(), dono), "dono propoe no timelock");
        _c(!tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), vm.envAddress("DEPLOYER")), "publicacao sem admin no timelock");
        _c(!tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), dono), "dono sem admin no timelock");
        _c(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), address(tl)), "timelock e admin de si mesmo");
        _c(tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "qualquer um executa depois do prazo");
        _c(!tl.hasRole(tl.PROPOSER_ROLE(), vm.envAddress("DEPLOYER")), "publicacao nao propoe");
        _c(t.owner() == address(tl), "dono da ponte = timelock");
        _c(IDelegates(address(ep)).delegates(address(t)) == address(tl), "delegate da ponte = timelock");
        _c(t.sharedDecimals() == 0 && address(t.endpoint()) == address(ep), "ponte: casas e endpoint");
        uint256[] memory outras = vm.envUint("EIDS", ",");
        _c(outras.length == 7, "7 outras redes");
        for (uint256 i; i < outras.length; i++) {
            uint32 e = uint32(outras[i]);
            _c(t.peers(e) == bytes32(uint256(uint160(address(t)))), "par da ponte = mesmo endereco");
            _c(!ep.isDefaultSendLibrary(address(t), e), "biblioteca de envio fixada");
            (, bool recPadrao) = ep.getReceiveLibrary(address(t), e);
            _c(!recPadrao, "biblioteca de recebimento fixada");
            _c(t.enforcedOptions(e, 1).length > 0 && t.enforcedOptions(e, 2).length > 0, "gas de entrega fixado");
        }
        console2.log("checagens OK:", ok);
    }
}
