// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SendParam, MessagingFee} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {EnforcedOptionParam} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import {EscrowAGL} from "../src/EscrowAGL.sol";
import {RegistroAGL} from "../src/RegistroAGL.sol";
import {EscrowBase} from "./Escrow.t.sol";

contract ContratoComum {
    function nada() external {}
}

/// Medição de gás das operações do usuário (fork). Cada medida é uma linha "gas <operação>".
contract GasTest is EscrowBase {
    function _medir(string memory _nome, uint256 _antes) internal {
        emit log_named_uint(string.concat("gas ", _nome), _antes - gasleft());
    }

    function test_gas_operacoes() public {
        // ---- token
        uint256 r = _comprar(comprador, _unid(1000));
        address eoa = makeAddr("eoa-gas");
        ContratoComum cc = new ContratoComum();
        vm.prank(comprador);
        uint256 g = gasleft();
        t.transfer(eoa, r / 10);
        _medir("AGL transfer para carteira", g);
        vm.prank(comprador);
        g = gasleft();
        t.transfer(address(cc), r / 10);
        _medir("AGL transfer para contrato (sondas)", g);

        // ---- pool (roteador de teste: swap + settle + take)
        deal(MOEDA, comprador, _unid(100));
        g = gasleft();
        _comprar(comprador, _unid(100));
        _medir("comprar na pool oficial", g);
        uint256 q = t.balanceOf(comprador) / 2;
        g = gasleft();
        _vender(comprador, q);
        _medir("vender na pool oficial", g);
        g = gasleft();
        pool.coletarTaxasFaixas(0, 1);
        _medir("coletarTaxas so do 1o degrau", g);
        g = gasleft();
        pool.coletarTaxas();
        _medir("coletarTaxas", g);

        // ---- ponte (envio, sem a entrega)
        uint32[] memory e = new uint32[](1);
        e[0] = 30184;
        vm.startPrank(DEPLOYER);
        t.ligarRedesEVM(e);
        EnforcedOptionParam[] memory op = new EnforcedOptionParam[](1);
        op[0] = EnforcedOptionParam(
            30184, 1, abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), uint128(300_000))
        );
        t.setEnforcedOptions(op);
        vm.stopPrank();
        uint256 v = (t.balanceOf(comprador) / 1e9) * 1e9;
        SendParam memory sp = SendParam(30184, bytes32(uint256(uint160(comprador))), v, 0, "", "", "");
        MessagingFee memory taxa = t.quoteSend(sp, false);
        vm.deal(comprador, taxa.nativeFee);
        vm.prank(comprador);
        g = gasleft();
        t.send{value: taxa.nativeFee}(sp, taxa, comprador);
        _medir("enviar pela ponte (origem)", g);

        // ---- registro
        address[] memory p = new address[](1);
        p[0] = address(reg);
        vm.prank(DONO);
        t.permitir(p);
        vm.startPrank(sup);
        reg.definirPreco(RegistroAGL.Servico.KycPessoa, _unid(25));
        reg.definirPreco(RegistroAGL.Servico.Contato, _unid(15));
        vm.stopPrank();
        _comprar(comp, _unid(500));
        vm.prank(comp);
        t.approve(address(reg), type(uint256).max);
        vm.prank(comp);
        g = gasleft();
        reg.pagarServico(RegistroAGL.Servico.KycPessoa, keccak256("p1"), type(uint256).max);
        _medir("pagar KYC em AGL", g);
        vm.prank(comp);
        g = gasleft();
        uint256 id = reg.pedir(vend, RegistroAGL.Servico.Contato, type(uint256).max);
        _medir("pedir contato", g);
        vm.prank(vend);
        g = gasleft();
        reg.responder(id, true);
        _medir("responder pedido", g);
        bytes32 h = keccak256("contrato-gas");
        vm.prank(comp);
        g = gasleft();
        reg.assinar(h, comp, vend);
        _medir("assinar contrato (1a parte)", g);
        vm.prank(vend);
        reg.assinar(h, comp, vend);

        // ---- escrow (modo rastreado, 30% no embarque)
        uint256 total = esc.totalADepositar(V);
        deal(MOEDA, comp, total);
        vm.prank(comp);
        IERC20(MOEDA).approve(address(esc), total);
        EscrowAGL.Prazos memory pz = _prazos();
        vm.prank(comp);
        g = gasleft();
        uint256 oid = esc.criar(vend, MOEDA, V, EscrowAGL.Modo.Rastreado, 3000, h, pz);
        _medir("escrow criar (deposito)", g);
        vm.prank(vend);
        g = gasleft();
        esc.aceitar(oid);
        _medir("escrow aceitar", g);
        vm.prank(vend);
        g = gasleft();
        esc.atualizar(oid, EscrowAGL.Tipo.Imagem, keccak256("f"), "foto da carga no porto");
        _medir("escrow atualizar (rastreio)", g);
        vm.startPrank(vend);
        esc.atualizar(oid, EscrowAGL.Tipo.DocumentoCarga, keccak256("d"), "romaneio");
        esc.atualizar(oid, EscrowAGL.Tipo.TramiteLegal, keccak256("t"), "DU-E");
        g = gasleft();
        esc.informarEmbarque(oid, keccak256("BL"));
        _medir("escrow informar embarque", g);
        vm.stopPrank();
        vm.prank(comp);
        g = gasleft();
        esc.confirmar(oid);
        _medir("escrow confirmar embarque (libera 30%)", g);
        vm.prank(vend);
        esc.informarChegada(oid, keccak256("ch"));
        vm.prank(comp);
        g = gasleft();
        esc.confirmar(oid);
        _medir("escrow confirmar chegada (libera 70%)", g);
        vm.prank(vend);
        g = gasleft();
        esc.sacar(MOEDA);
        _medir("escrow sacar", g);
    }
}
