// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Auditoria independente v3 — trava "lógica inversa reforçada" + ponte LayerZero OFT.
// Rodar (uma rede por vez; --isolate = cada chamada de topo é uma transação):
//   REDE=base      forge test --isolate --threads 1 --match-contract AuditoriaV3 -vv
//   REDE=avalanche forge test --isolate --threads 1 --match-contract AuditoriaV3 -vv   (inclui LFJ real)

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { SwapParams } from "v4-core/types/PoolOperation.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { TransientStateLibrary } from "v4-core/libraries/TransientStateLibrary.sol";
import { Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { SendParam, MessagingFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { EnforcedOptionParam } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { AGL } from "../../src/AGL.sol";
import { Publicar } from "../../script/Publicar.s.sol";
import { UlnConfig } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import { PoolAGL } from "../../src/PoolAGL.sol";
import { BaseAGL } from "../BaseAGL.sol";

interface IEndpointV2 {
    function verify(Origin calldata _origin, address _receiver, bytes32 _payloadHash) external;
    function lzReceive(Origin calldata, address, bytes32, bytes calldata, bytes calldata) external payable;
    function getReceiveLibrary(address, uint32) external view returns (address, bool);
    function inboundPayloadHash(address, uint32, bytes32, uint64) external view returns (bytes32);
}

/// AMM de produto constante "caseiro": não expõe token0/token1/coins (usa tokenA/tokenB).
contract PoolXY {
    IERC20 public immutable tokenA;
    IERC20 public immutable tokenB;
    uint256 public rA;
    uint256 public rB;

    constructor(IERC20 _a, IERC20 _b) {
        (tokenA, tokenB) = (_a, _b);
    }

    function sincronizar() external {
        (rA, rB) = (tokenA.balanceOf(address(this)), tokenB.balanceOf(address(this)));
    }

    /// Vende o que entrou de A (ou B) e paga o outro lado (x*y=k, sem taxa).
    function trocar(bool _aPorB, address _para) external returns (uint256 sai) {
        uint256 bA = tokenA.balanceOf(address(this));
        uint256 bB = tokenB.balanceOf(address(this));
        if (_aPorB) {
            uint256 entra = bA - rA;
            sai = rB * entra / (rA + entra);
            tokenB.transfer(_para, sai);
        } else {
            uint256 entra = bB - rB;
            sai = rA * entra / (rB + entra);
            tokenA.transfer(_para, sai);
        }
        (rA, rB) = (tokenA.balanceOf(address(this)), tokenB.balanceOf(address(this)));
    }
}

/// Clone v2 "disfarçado": para qualquer leitor responde token0 = AGL (aparece como par do AGL
/// para indexadores/agregadores), mas para o próprio AGL responde outro endereço.
contract ParDisfarcado {
    address immutable agl;

    constructor(address _agl) {
        agl = _agl;
    }

    function token0() external view returns (address) {
        return msg.sender == agl ? address(0xdead) : agl;
    }

    function token1() external view returns (address) {
        return address(0xbeef);
    }
}

/// Variante por gasleft: com os 30k da sonda responde outra coisa.
contract ParPorGas {
    address immutable agl;

    constructor(address _agl) {
        agl = _agl;
    }

    function token0() external view returns (address) {
        return gasleft() > 40_000 ? agl : address(0xdead);
    }
}

/// Contrato com fallback que consome todo o gás que recebe (qualquer contrato "pesado").
contract Pesado {
    uint256 x;

    fallback() external {
        while (true) x++;
    }
}

interface ILBFactory {
    function createLBPair(address tokenX, address tokenY, uint24 activeId, uint16 binStep) external returns (address);
}

interface ILBPair {
    function mint(address to, bytes32[] calldata liquidityConfigs, address refundTo)
        external
        returns (bytes32, bytes32, uint256[] memory);
    function swap(bool swapForY, address to) external returns (bytes32);
    function getTokenX() external view returns (address);
    function getActiveId() external view returns (uint24);
}

interface ISafeFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address);
}

contract AuditoriaV3 is BaseAGL, IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    address constant EP = 0x1a44076050125825900e736c501f859c50fE728c;
    uint32 constant EID_BSC = 30102;
    address vitima = makeAddr("vitima");

    // estado do callback de unlock (P1)
    Origin origemP1;
    bytes msgP1;
    uint256 vendaP1;

    function setUp() public override {
        super.setUp();
        _lancar();
    }

    // ===================================================================== T: trava

    /// T1 (CORRIGIDO): AMM com tokenA/tokenB agora é reconhecido pela sonda e não recebe AGL.
    function test_T1_amm_sem_token0_mao_dupla() public {
        uint256 a = _comprar(atacante, _unid(1000));
        PoolXY p = new PoolXY(IERC20(address(t)), IERC20(MOEDA));
        vm.prank(atacante);
        vm.expectRevert(abi.encodeWithSelector(AGL.PoolNaoAutorizada.selector, address(p)));
        t.transfer(address(p), a);
    }

    /// T2: a sonda é enganada por msg.sender ou por gasleft (clone v2 que se apresenta como
    /// par do AGL a todo mundo, menos ao próprio AGL).
    function test_T2_sonda_enganada_por_msg_sender_e_gasleft() public {
        ParDisfarcado pd = new ParDisfarcado(address(t));
        ParPorGas pg = new ParPorGas(address(t));
        assertEq(pd.token0(), address(t), "para o mundo, e par do AGL");
        assertEq(pg.token0(), address(t), "para o mundo, e par do AGL");
        uint256 a = _comprar(atacante, _unid(10));
        vm.startPrank(atacante);
        t.transfer(address(pd), a / 2);
        t.transfer(address(pg), a / 2);
        vm.stopPrank();
        assertEq(t.balanceOf(address(pd)), a / 2, "par disfarcado recebeu AGL");
        assertEq(t.balanceOf(address(pg)), a / 2, "par por gas recebeu AGL");
    }

    /// T3 (CORRIGIDO): par REAL do LFJ Liquidity Book v2.2 (getTokenX/Y) não recebe AGL.
    function test_T3_lfj_liquidity_book_real_mao_dupla() public {
        vm.skip(block.chainid != 43114 && block.chainid != 42161);
        ILBFactory f = ILBFactory(0xb43120c4745967fa9b93E79C149E66B0f2D6Fe0c);
        uint24 ativo = 8_377_542;
        ILBPair par = ILBPair(f.createLBPair(address(t), MOEDA, ativo, 25));
        assertEq(par.getTokenX(), address(t));
        uint256 a = _comprar(atacante, _unid(1000));
        vm.prank(atacante);
        vm.expectRevert(abi.encodeWithSelector(AGL.PoolNaoAutorizada.selector, address(par)));
        t.transfer(address(par), a);
    }

    /// T4: o guardião PODE liberar um cofre de DEX "bloqueado" (o `permitido` é testado antes
    /// da lista de cofres) — o comentário diz "nunca recebem".
    function test_T4_guardiao_libera_cofre_de_dex() public {
        address bal = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
        vm.skip(bal.code.length == 0);
        uint256 a = _comprar(atacante, _unid(10));
        vm.prank(atacante);
        vm.expectRevert(abi.encodeWithSelector(AGL.CofreDeDexBloqueado.selector, bal));
        t.transfer(bal, a);
        address[] memory l = new address[](1);
        l[0] = bal;
        vm.prank(DONO); // guardião nos testes
        t.permitir(l);
        // CORRIGIDO: nem liberado pelo guardião o cofre recebe
        vm.prank(atacante);
        vm.expectRevert(abi.encodeWithSelector(AGL.CofreDeDexBloqueado.selector, bal));
        t.transfer(bal, a);
    }

    /// T5: custo das sondas por destinatário (gás medido em transferência).
    function test_T5_gas_das_sondas() public {
        uint256 a = _comprar(atacante, _unid(100));
        address eoa = makeAddr("eoa-gas");
        Pesado pesado = new Pesado();
        PoolQualquerV3 semFallback = new PoolQualquerV3();
        address safe = _criarSafe();
        address[5] memory alvos = [eoa, address(semFallback), safe, address(pesado), address(0)];
        string[5] memory nomes = ["EOA", "contrato sem fallback", "Safe 1.4.1", "contrato com fallback caro", ""];
        for (uint256 i; i < 4; i++) {
            if (alvos[i] == address(0)) continue;
            vm.prank(atacante);
            uint256 g = gasleft();
            t.transfer(alvos[i], a / 10);
            emit log_named_uint(string.concat("gas transfer -> ", nomes[i]), g - gasleft());
        }
        assertEq(t.balanceOf(address(pesado)), a / 10, "contrato pesado recebe (12 sondas x 10k)");
    }

    function _criarSafe() internal returns (address) {
        address fab = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
        address sing = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
        address handler = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
        if (fab.code.length == 0 || sing.code.length == 0) return address(0);
        address[] memory donos = new address[](1);
        donos[0] = vitima;
        bytes memory ini = abi.encodeWithSignature(
            "setup(address[],uint256,address,bytes,address,address,uint256,address)",
            donos, 1, address(0), "", handler, address(0), 0, address(0)
        );
        return ISafeFactory(fab).createProxyWithNonce(sing, ini, 7);
    }

    /// T6: contratos de infraestrutura comuns recebem (não são confundidos com pool).
    function test_T6_infra_comum_recebe() public {
        uint256 a = _comprar(atacante, _unid(100));
        address[8] memory infra = [
            0x000000000022D473030F116dDEE9F6B43aC78BA3, // Permit2
            0xcA11bde05977b3631167028862bE2a173976CA11, // Multicall3
            EP, // LayerZero EndpointV2
            0x111111125421cA6dc452d289314280a0f8842A65, // 1inch v6
            0x6131B5fae19EA4f9D964eAc0408E4408b66337b5, // Kyber MetaAggregationRouterV2
            0x6A000F20005980200259B80c5102003040001068, // ParaSwap Augustus v6.2
            0x0BA5ED0c6AA8c49038F819E587E2633c4A9F428a, // Coinbase Smart Wallet factory
            _criarSafe() // Safe 1.4.1 (proxy + fallback handler)
        ];
        uint256 n;
        for (uint256 i; i < infra.length; i++) {
            if (infra[i] == address(0) || infra[i].code.length == 0) continue;
            vm.prank(atacante);
            t.transfer(infra[i], 1e9);
            n++;
        }
        emit log_named_uint("contratos de infra testados", n);
        assertGt(n, 4);
        a;
    }

    // ===================================================================== P: ponte

    function _ligarBsc() internal {
        uint32[] memory e = new uint32[](1);
        e[0] = EID_BSC;
        vm.prank(DEPLOYER);
        t.ligarRedesEVM(e);
    }

    /// Simula a verificação dos DVNs: a biblioteca de recebimento grava o hash no endpoint REAL.
    function _verificar(Origin memory _o, bytes32 _guid, bytes memory _m) internal {
        (address lib,) = IEndpointV2(EP).getReceiveLibrary(address(t), _o.srcEid);
        vm.prank(lib);
        IEndpointV2(EP).verify(_o, address(t), keccak256(abi.encodePacked(_guid, _m)));
    }

    /// P1 (CORRIGIDO): criação de AGL direto no PoolManager é recusada sempre, então a
    /// mensagem para o endereço do PoolManager não pode ser capturada dentro de um unlock.
    function test_P1_mensagem_para_poolmanager_e_capturada() public {
        _ligarBsc();
        _comprar(comprador, _unid(5000));
        uint256 X = 1e9 * 1e9 * 1000;
        (bytes memory m,) = OFTMsgCodec.encode(bytes32(uint256(uint160(address(PM)))), uint64(X / 1e9), "");
        Origin memory o = Origin(EID_BSC, bytes32(uint256(uint160(address(t)))), 1);
        bytes32 guid = keccak256("guid-p1");
        _verificar(o, guid, m);
        vm.expectRevert();
        IEndpointV2(EP).lzReceive(o, address(t), guid, m, "");
        (origemP1, msgP1, vendaP1) = (o, m, X);
        vm.expectRevert();
        PM.unlock(abi.encode(guid));
        assertEq(IERC20(MOEDA).balanceOf(atacante), 0, "atacante nao lucra");
    }

    function unlockCallback(bytes calldata _d) external returns (bytes memory) {
        require(msg.sender == address(PM));
        bytes32 guid = abi.decode(_d, (bytes32));
        bool t0 = pool.tokenEhMoeda0();
        PM.swap(pool.chave(), SwapParams(t0, -int256(vendaP1), t0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), "");
        PM.sync(pool.token());
        IEndpointV2(EP).lzReceive(origemP1, address(t), guid, msgP1, ""); // cria o AGL NO PoolManager
        PM.settle();
        int256 d = PM.currencyDelta(address(this), pool.moeda());
        PM.take(pool.moeda(), atacante, uint256(d));
        return "";
    }

    /// P2: destinatário-contrato "pesado": as 4 sondas (4 x 30k) estouram os 150k fixados
    /// como gás de entrega. A entrega pelo executor falha; qualquer um reexecuta com mais gás.
    function test_P2_gas_de_entrega_fixado_nao_cobre_sondas() public {
        _ligarBsc();
        Pesado pesado = new Pesado();
        (bytes memory m,) = OFTMsgCodec.encode(bytes32(uint256(uint160(address(pesado)))), uint64(1000), "");
        Origin memory o = Origin(EID_BSC, bytes32(uint256(uint160(address(t)))), 1);
        bytes32 guid = keccak256("guid-p2");
        _verificar(o, guid, m);
        (bool ok,) = EP.call{ gas: 150_000 }(abi.encodeCall(IEndpointV2.lzReceive, (o, address(t), guid, m, bytes(""))));
        assertFalse(ok, "com 150k a entrega falha");
        uint256 g = gasleft();
        IEndpointV2(EP).lzReceive(o, address(t), guid, m, "");
        emit log_named_uint("gas da entrega ao contrato pesado", g - gasleft());
        assertEq(t.balanceOf(address(pesado)), 1000 * 1e9, "reexecucao com mais gas entrega");
    }

    /// P2b: entrega pela ponte a um Safe novo com o gás fixado (150k): cabe?
    function test_P2b_entrega_a_safe_com_150k() public {
        _ligarBsc();
        address safe = _criarSafe();
        vm.skip(safe == address(0));
        (bytes memory m,) = OFTMsgCodec.encode(bytes32(uint256(uint160(safe))), uint64(1000), "");
        Origin memory o = Origin(EID_BSC, bytes32(uint256(uint160(address(t)))), 1);
        bytes32 guid = keccak256("guid-p2b");
        _verificar(o, guid, m);
        uint256 g = gasleft();
        (bool ok,) = EP.call{ gas: 150_000 }(abi.encodeCall(IEndpointV2.lzReceive, (o, address(t), guid, m, bytes(""))));
        emit log_named_uint("gas usado (endpoint, 150k)", g - gasleft());
        emit log_named_uint("entregou com 150k (1=sim)", ok ? 1 : 0);
        assertEq(t.balanceOf(safe), ok ? 1000 * 1e9 : 0);
    }

    /// P3: mensagem para pool "com cara de pool" fica presa; o guardião (sozinho, sem
    /// timelock) destrava liberando o destino — e a pool falsa recebe o AGL.
    function test_P3_mensagem_presa_e_guardiao_destrava_para_pool() public {
        _ligarBsc();
        PoolDoAgl pf = new PoolDoAgl(address(t));
        (bytes memory m,) = OFTMsgCodec.encode(bytes32(uint256(uint160(address(pf)))), uint64(1000), "");
        Origin memory o = Origin(EID_BSC, bytes32(uint256(uint160(address(t)))), 1);
        bytes32 guid = keccak256("guid-p3");
        _verificar(o, guid, m);
        vm.expectRevert(abi.encodeWithSelector(AGL.PoolNaoAutorizada.selector, address(pf)));
        IEndpointV2(EP).lzReceive(o, address(t), guid, m, "");
        address[] memory l = new address[](1);
        l[0] = address(pf);
        vm.prank(DONO);
        t.permitir(l);
        IEndpointV2(EP).lzReceive(o, address(t), guid, m, "");
        assertEq(t.balanceOf(address(pf)), 1000 * 1e9);
    }

    /// P4: poeira e teto do envio (sharedDecimals 0).
    function test_P4_poeira_fica_e_teto_uint64_reverte() public {
        _ligarBsc();
        uint256 a = _comprar(viajanteP4, _unid(10));
        uint256 valor = 5e9 + 123; // 5 AGL + poeira
        SendParam memory sp = SendParam(EID_BSC, bytes32(uint256(uint160(viajanteP4))), valor, 0, "", "", "");
        _opcoesGas();
        MessagingFee memory taxa = t.quoteSend(sp, false);
        vm.deal(viajanteP4, taxa.nativeFee);
        vm.prank(viajanteP4);
        t.send{ value: taxa.nativeFee }(sp, taxa, viajanteP4);
        assertEq(t.balanceOf(viajanteP4), a - 5e9, "so 5 AGL queimados; a poeira ficou com o dono");
        // acima de uint64 em AGL inteiro: reverte (não trunca)
        deal(address(t), viajanteP4, uint256(type(uint64).max) * 1e9 + 2e9);
        sp.amountLD = uint256(type(uint64).max) * 1e9 + 1e9;
        vm.expectRevert();
        t.quoteSend(sp, false);
    }

    address viajanteP4 = makeAddr("viajanteP4");

    function _opcoesGas() internal {
        EnforcedOptionParam[] memory op = new EnforcedOptionParam[](1);
        op[0] = EnforcedOptionParam(EID_BSC, 1, abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), uint128(150_000)));
        vm.prank(DEPLOYER);
        t.setEnforcedOptions(op);
    }

    /// P6: a configuração "fixada" do script fica de fato explícita (bibliotecas, ULN com
    /// confirmações > 0 e opcionais NIL, executor) dos dois lados, e o envio ainda cota.
    function test_P6_config_da_ponte_fica_explicita() public {
        PublicarExposto px = new PublicarExposto();
        vm.startPrank(DEPLOYER);
        uint32[] memory e = new uint32[](1);
        e[0] = EID_BSC;
        t.ligarRedesEVM(e);
        t.setDelegate(address(px));
        t.transferOwnership(address(px));
        vm.stopPrank();
        px.fixar(t, e);
        IEpLib ep = IEpLib(EP);
        assertFalse(ep.isDefaultSendLibrary(address(t), EID_BSC), "envio fixado");
        (address rl, bool rDef) = ep.getReceiveLibrary(address(t), EID_BSC);
        assertFalse(rDef, "recebimento fixado");
        address sl = ep.getSendLibrary(address(t), EID_BSC);
        UlnConfig memory cs = IUlnApp(sl).getAppUlnConfig(address(t), EID_BSC);
        UlnConfig memory cr = IUlnApp(rl).getAppUlnConfig(address(t), EID_BSC);
        (, address exe) = IUlnApp(sl).executorConfigs(address(t), EID_BSC);
        emit log_named_uint("confirmacoes envio", cs.confirmations);
        emit log_named_uint("confirmacoes recebimento", cr.confirmations);
        emit log_named_uint("DVNs obrigatorios envio", cs.requiredDVNCount);
        emit log_named_uint("DVNs opcionais envio (255=NIL)", cs.optionalDVNCount);
        assertGt(cs.confirmations, 0);
        assertGt(cr.confirmations, 0);
        assertEq(cs.optionalDVNCount, 255);
        assertEq(cr.optionalDVNCount, 255);
        assertTrue(cs.requiredDVNCount > 0 && cs.requiredDVNCount < 255);
        assertTrue(exe != address(0), "executor explicito");
        uint256 a = _comprar(viajanteP4, _unid(10));
        SendParam memory sp = SendParam(EID_BSC, bytes32(uint256(uint160(viajanteP4))), (a / 1e9) * 1e9, 0, "", "", "");
        MessagingFee memory taxa = t.quoteSend(sp, false);
        assertGt(taxa.nativeFee, 0, "envio cota com a config fixada");
        // reexecutar o script (retomada) nao refaz nada nesta rede: pula pelo isDefaultSendLibrary
        px.fixar(t, e);
    }

    /// P5: pior caso do dono da ponte. Timelock montado EXATAMENTE como o script; após 7 dias
    /// o DONO troca o par de uma rede por um contrato dele e cria AGL sem limite, que vende
    /// na pool oficial levando o USDC de todos os compradores. Antes do prazo não executa.
    function test_P5_timelock_dono_cria_sem_limite_apos_7_dias() public {
        _comprar(comprador, _unid(50_000));
        address[] memory propoe = new address[](1);
        propoe[0] = DONO;
        address[] memory executa = new address[](1);
        TimelockController tl = new TimelockController(7 days, propoe, executa, address(0));
        vm.startPrank(DEPLOYER);
        t.setDelegate(address(tl));
        t.transferOwnership(address(tl));
        vm.stopPrank();
        // papéis
        assertTrue(tl.hasRole(tl.CANCELLER_ROLE(), DONO), "dono tambem cancela");
        assertTrue(tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "qualquer um executa");
        assertTrue(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), address(tl)), "timelock administra a si mesmo");
        assertFalse(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), DEPLOYER));
        assertFalse(tl.hasRole(tl.PROPOSER_ROLE(), DEPLOYER));
        // DONO propõe: par da BSC = contrato do atacante
        address falso = makeAddr("parFalso");
        bytes memory dados = abi.encodeWithSignature("setPeer(uint32,bytes32)", EID_BSC, bytes32(uint256(uint160(falso))));
        vm.prank(DONO);
        tl.schedule(address(t), 0, dados, bytes32(0), bytes32(0), 7 days);
        vm.expectRevert();
        tl.execute(address(t), 0, dados, bytes32(0), bytes32(0));
        vm.warp(block.timestamp + 7 days);
        tl.execute(address(t), 0, dados, bytes32(0), bytes32(0)); // qualquer um
        // o par falso manda uma mensagem legítima (verificada pelos DVNs) criando o máximo
        (bytes memory m,) = OFTMsgCodec.encode(bytes32(uint256(uint160(atacante))), type(uint64).max, "");
        Origin memory o = Origin(EID_BSC, bytes32(uint256(uint160(falso))), 1);
        _verificar(o, keccak256("g5"), m);
        IEndpointV2(EP).lzReceive(o, address(t), keccak256("g5"), m, "");
        assertEq(t.balanceOf(atacante), uint256(type(uint64).max) * 1e9, "criou 1,8e19 AGL fora da regra");
        uint256 usdcPool = IERC20(MOEDA).balanceOf(address(PM));
        uint256 levou = _vender(atacante, t.balanceOf(atacante));
        emit log_named_uint("USDC drenado da pool oficial (unid.)", levou);
        assertGt(levou, _unid(45_000), "levou ~todo o USDC dos compradores");
        usdcPool;
    }
}

contract PublicarExposto is Publicar {
    function fixar(AGL _t, uint32[] memory _e) external {
        _fixarPonte(_t, _e);
    }
}

interface IUlnApp {
    function getAppUlnConfig(address, uint32) external view returns (UlnConfig memory);
    function executorConfigs(address, uint32) external view returns (uint32, address);
}

interface IEpLib {
    function isDefaultSendLibrary(address, uint32) external view returns (bool);
    function getReceiveLibrary(address, uint32) external view returns (address, bool);
    function getSendLibrary(address, uint32) external view returns (address);
}

contract PoolDoAgl {
    address public token0;
    address public token1 = address(0xbeef);

    constructor(address _a) {
        token0 = _a;
    }
}

contract PoolQualquerV3 {
    function nada() external { }
}
