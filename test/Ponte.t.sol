// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {SendParam, MessagingFee} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {OFTMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import {EnforcedOptionParam} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import {AGL} from "../src/AGL.sol";
import {PoolAGL} from "../src/PoolAGL.sol";
import {BaseAGL} from "./BaseAGL.sol";

interface ILzEndpointConfig {
    function setSendLibrary(address oapp, uint32 eid, address lib) external;
}

/// Pool falsa no destino (token0/token1 = AGL).
contract PoolFalsaDestino {
    address public token0;
    address public token1;

    constructor(address _agl) {
        (token0, token1) = (_agl, address(0xdead));
    }
}

/// Ponte LayerZero entre duas redes REAIS (dois forks). ORIGEM e DESTINO por env
/// (padrão bsc → base). Na origem: cotação e envio reais pelo endpoint da LayerZero
/// (queima). No destino: a entrega é feita como o endpoint faria (lzReceive).
contract PonteTest is BaseAGL {
    address constant EP = 0x1a44076050125825900e736c501f859c50fE728c;
    uint128 constant GAS_ENTREGA = 300_000;

    struct Rede {
        uint256 fork;
        uint32 eid;
        AGL t;
        PoolAGL pool;
        PoolSwapTest router;
        address moeda;
        uint8 casas;
    }

    Rede o;
    Rede d;
    address viajante = makeAddr("viajante");

    function setUp() public override {
        string memory origem = vm.envOr("ORIGEM", string("bsc"));
        string memory destino = vm.envOr("DESTINO", string("base"));
        o = _subir(origem);
        d = _subir(destino);
        // liga as duas redes nos dois sentidos e fixa o gás de entrega (como o script)
        _ligar(o, d.eid);
        _ligar(d, o.eid);
    }

    function _eid(uint256 _chainid) internal pure returns (uint32) {
        if (_chainid == 56) return 30102;
        if (_chainid == 8453) return 30184;
        if (_chainid == 42161) return 30110;
        if (_chainid == 137) return 30109;
        if (_chainid == 10) return 30111;
        if (_chainid == 43114) return 30106;
        if (_chainid == 42220) return 30125;
        return 30101;
    }

    function _subir(string memory _rede) internal returns (Rede memory r) {
        vm.setEnv("REDE", _rede);
        if (keccak256(bytes(_rede)) == keccak256("optimism")) {
            vm.setEnv("RPC", "https://mainnet.optimism.io");
        } else if (keccak256(bytes(_rede)) == keccak256("avalanche")) {
            vm.setEnv("RPC", "https://api.avax.network/ext/bc/C/rpc");
        } else {
            vm.setEnv("RPC", "");
        }
        super.setUp();
        _lancar();
        r = Rede(vm.activeFork(), _eid(block.chainid), t, pool, router, MOEDA, casasMoeda);
    }

    function _ligar(Rede memory _r, uint32 _outro) internal {
        vm.selectFork(_r.fork);
        uint32[] memory e = new uint32[](1);
        e[0] = _outro;
        vm.startPrank(DEPLOYER);
        _r.t.ligarRedesEVM(e);
        EnforcedOptionParam[] memory op = new EnforcedOptionParam[](1);
        op[0] = EnforcedOptionParam(_outro, 1, abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), GAS_ENTREGA));
        _r.t.setEnforcedOptions(op);
        vm.stopPrank();
    }

    function _usar(Rede memory _r) internal {
        vm.selectFork(_r.fork);
        (t, pool, router, MOEDA, casasMoeda) = (_r.t, _r.pool, _r.router, _r.moeda, _r.casas);
        PM = IPoolManager(pool.poolManager());
    }

    /// Envia `_valor` de AGL da origem para `_para` no destino; devolve a mensagem.
    function _enviar(address _para, uint256 _valor) internal returns (bytes memory m, uint256 taxaNativa) {
        _usar(o);
        SendParam memory sp = SendParam(d.eid, bytes32(uint256(uint160(_para))), _valor, 0, "", "", "");
        MessagingFee memory taxa = t.quoteSend(sp, false);
        vm.deal(viajante, taxa.nativeFee);
        vm.prank(viajante);
        t.send{value: taxa.nativeFee}(sp, taxa, viajante);
        (m,) = OFTMsgCodec.encode(bytes32(uint256(uint160(_para))), uint64(_valor / 1e9), "");
        taxaNativa = taxa.nativeFee;
    }

    function _entregar(bytes memory _m, uint64 _nonce) internal {
        _usar(d);
        vm.prank(EP);
        d.t
            .lzReceive(
                Origin(o.eid, bytes32(uint256(uint160(address(o.t)))), _nonce),
                bytes32(uint256(_nonce)),
                _m,
                address(0),
                ""
            );
    }

    // ---------------------------------------------------------------------------- testes

    function test_ponte_queima_na_origem_e_cria_no_destino() public {
        _usar(o);
        uint256 comprado = _comprar(viajante, _unid(1000));
        uint256 valor = (comprado / 1e9) * 1e9; // só AGL inteiro viaja
        assertEq(address(o.t), address(d.t), "mesmo endereco nas duas redes");
        (bytes memory m, uint256 taxa) = _enviar(viajante, valor);
        emit log_named_uint("taxa LayerZero (nativo, wei)", taxa);
        assertEq(o.t.totalSupply(), 1e30 - valor, "queimou na origem");
        assertEq(o.t.balanceOf(viajante), comprado - valor, "so a fracao ficou");
        uint256 g = gasleft();
        _entregar(m, 1);
        assertLt(g - gasleft(), GAS_ENTREGA, "cabe no gas de entrega fixado");
        assertEq(d.t.balanceOf(viajante), valor, "criou no destino");
        assertEq(d.t.totalSupply(), 1e30 + valor, "soma das redes constante");
        // no destino, sem compradores lá ainda, a pool não tem USDC: a venda não paga
        // nada, mas também NÃO toma o AGL (nada se perde)
        _usar(d);
        uint256 antes = d.t.balanceOf(viajante);
        _vender(viajante, valor);
        assertEq(d.t.balanceOf(viajante), antes, "sem USDC no destino: AGL nao e tomado");
        // depois que alguém compra no destino, a venda paga
        _comprar(makeAddr("compradorDestino"), _unid(2000));
        uint256 recebido = _vender(viajante, valor);
        assertGt(recebido, _unid(900), "vende no destino depois que ha USDC la");
    }

    /// Ida e volta: o total de cada rede volta ao original.
    function test_ida_e_volta() public {
        _usar(o);
        uint256 v = (_comprar(viajante, _unid(100)) / 1e9) * 1e9;
        (bytes memory m,) = _enviar(viajante, v);
        _entregar(m, 1);
        // volta: destino -> origem
        _usar(d);
        SendParam memory sp = SendParam(o.eid, bytes32(uint256(uint160(viajante))), v, 0, "", "", "");
        MessagingFee memory taxa = d.t.quoteSend(sp, false);
        vm.deal(viajante, taxa.nativeFee);
        vm.prank(viajante);
        d.t.send{value: taxa.nativeFee}(sp, taxa, viajante);
        assertEq(d.t.totalSupply(), 1e30, "destino voltou ao original");
        _usar(o);
        (bytes memory m2,) = OFTMsgCodec.encode(bytes32(uint256(uint160(viajante))), uint64(v / 1e9), "");
        vm.prank(EP);
        o.t
            .lzReceive(
                Origin(d.eid, bytes32(uint256(uint160(address(d.t)))), 1), bytes32(uint256(9)), m2, address(0), ""
            );
        assertEq(o.t.totalSupply(), 1e30, "origem voltou ao original");
    }

    /// Mensagem que não vem do AGL da outra rede é recusada.
    function test_mensagem_de_estranho_recusada() public {
        _usar(d);
        (bytes memory m,) = OFTMsgCodec.encode(bytes32(uint256(uint160(viajante))), uint64(1e12), "");
        vm.prank(EP);
        vm.expectRevert();
        d.t.lzReceive(Origin(o.eid, bytes32(uint256(uint160(atacante))), 1), bytes32(uint256(1)), m, address(0), "");
        vm.prank(atacante);
        vm.expectRevert();
        d.t.lzReceive(Origin(o.eid, bytes32(uint256(uint160(address(o.t)))), 1), bytes32(uint256(1)), m, address(0), "");
        assertEq(d.t.balanceOf(viajante), 0);
    }

    /// A trava vale também na chegada: AGL enviado para uma pool falsa no destino não é
    /// criado lá (a entrega reverte e fica pendente na LayerZero).
    function test_trava_vale_na_chegada() public {
        _usar(d);
        PoolFalsaDestino pf = new PoolFalsaDestino(address(d.t));
        _usar(o);
        uint256 v = (_comprar(viajante, _unid(100)) / 1e9) * 1e9;
        (bytes memory m,) = _enviar(address(pf), v);
        _usar(d);
        vm.prank(EP);
        vm.expectRevert(abi.encodeWithSelector(AGL.PoolNaoAutorizada.selector, address(pf)));
        d.t.lzReceive(Origin(o.eid, bytes32(uint256(uint160(address(o.t)))), 1), bytes32(uint256(1)), m, address(0), "");
    }

    /// Etapa 3: depois da renúncia ninguém muda a ponte (nem a carteira de publicação), e a
    /// ponte continua funcionando.
    function test_renuncia_trava_a_ponte_e_ela_segue_funcionando() public {
        _usar(o);
        vm.startPrank(DEPLOYER);
        o.t.setDelegate(address(0));
        o.t.renounceOwnership();
        vm.stopPrank();
        assertEq(o.t.owner(), address(0));
        uint32[] memory e = new uint32[](1);
        e[0] = 30999;
        vm.prank(DEPLOYER);
        vm.expectRevert();
        o.t.ligarRedesEVM(e);
        // configuração do endpoint também não muda mais
        vm.prank(DEPLOYER);
        vm.expectRevert();
        ILzEndpointConfig(EP).setSendLibrary(address(o.t), d.eid, address(0x1234));
        // e a ponte segue: envia e entrega
        uint256 v = (_comprar(viajante, _unid(100)) / 1e9) * 1e9;
        (bytes memory m,) = _enviar(viajante, v);
        _entregar(m, 1);
        assertEq(d.t.balanceOf(viajante), v);
    }

    /// Só o dono da ponte liga redes e muda opções.
    function test_so_dono_configura_ponte() public {
        _usar(o);
        uint32[] memory e = new uint32[](1);
        e[0] = 30999;
        vm.prank(atacante);
        vm.expectRevert();
        o.t.ligarRedesEVM(e);
        assertEq(o.t.owner(), DEPLOYER, "antes do timelock: carteira de publicacao");
    }
}
