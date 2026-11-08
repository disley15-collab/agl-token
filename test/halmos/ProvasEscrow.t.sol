// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EscrowAGL, IRegistro} from "../../src/EscrowAGL.sol";

contract MoedaProva is ERC20("USD", "USD") {
    function mint(address a, uint256 v) external {
        _mint(a, v);
    }
}

contract RegistroProva is IRegistro {
    function verificado(address) external pure returns (bool) {
        return true;
    }

    function contratoAssinado(bytes32, address, address) external pure returns (bool) {
        return true;
    }
}

/// Provas simbólicas (Halmos): valem para QUALQUER valor/parcela/decisão dentro dos limites.
/// Rodar: halmos --contract ProvasEscrow
contract ProvasEscrow is Test {
    EscrowAGL esc;
    MoedaProva m;
    address comp = address(0xC0);
    address vend = address(0xBE);
    address sup = address(0x5A);
    address taxas = address(0x7A);

    function setUp() public {
        m = new MoedaProva();
        address[] memory ms = new address[](1);
        ms[0] = address(m);
        esc = new EscrowAGL(IRegistro(address(new RegistroProva())), taxas, sup, 100, 200, ms);
    }

    function _prazos() internal view returns (EscrowAGL.Prazos memory p) {
        p.aceite = uint64(block.timestamp + 3 days);
        p.embarque = uint64(block.timestamp + 30 days);
        p.chegada = uint64(block.timestamp + 90 days);
        p.janela = 3 days;
        p.intervaloMax = 5 days;
    }

    function _criar(uint256 valor, uint16 bps) internal returns (uint256 id, uint256 total) {
        total = esc.totalADepositar(valor);
        m.mint(comp, total);
        vm.startPrank(comp);
        m.approve(address(esc), total);
        id = esc.criar(vend, address(m), valor, EscrowAGL.Modo.Rastreado, bps, keccak256("c"), _prazos());
        vm.stopPrank();
    }

    function _embarcar(uint256 id) internal {
        vm.startPrank(vend);
        esc.aceitar(id);
        esc.atualizar(id, EscrowAGL.Tipo.Imagem, keccak256("i"), "");
        esc.atualizar(id, EscrowAGL.Tipo.DocumentoCarga, keccak256("d"), "");
        esc.atualizar(id, EscrowAGL.Tipo.TramiteLegal, keccak256("t"), "");
        esc.informarEmbarque(id, keccak256("bl"));
        vm.stopPrank();
    }

    /// Reembolso por cancelamento devolve TUDO (valor + taxa do comprador); ninguém mais recebe.
    function check_reembolso_integral(uint256 valor, uint16 bps) public {
        vm.assume(valor >= esc.VALOR_MIN() && valor <= 1e36 && bps <= 10_000);
        (uint256 id, uint256 total) = _criar(valor, bps);
        vm.prank(comp);
        esc.cancelar(id);
        assert(esc.saldo(address(m), comp) == total);
        assert(esc.saldo(address(m), vend) == 0 && esc.saldo(address(m), taxas) == 0);
        assert(esc.travado(address(m)) == 0);
    }

    /// Liberação completa (parcela no embarque + resto na chegada): vendedor + taxas = depósito,
    /// taxas <= 3% do valor e o vendedor recebe pelo menos 98%. Valor simbólico (qualquer um);
    /// parcela fixada em casos representativos (o solucionador não fecha valor x parcela).
    function _liberacao(uint256 valor, uint16 bps) internal {
        vm.assume(valor >= esc.VALOR_MIN() && valor <= 1e36);
        (uint256 id, uint256 total) = _criar(valor, bps);
        _embarcar(id);
        vm.prank(comp);
        esc.confirmar(id);
        if (bps < 10_000) {
            vm.prank(vend);
            esc.informarChegada(id, keccak256("ch"));
            vm.prank(comp);
            esc.confirmar(id);
        }
        uint256 v = esc.saldo(address(m), vend);
        uint256 tx_ = esc.saldo(address(m), taxas);
        assert(v + tx_ == total);
        assert(tx_ <= valor * 3 / 100 + 2);
        assert(v >= valor * 98 / 100);
        assert(esc.travado(address(m)) == 0);
    }

    function check_liberacao_0(uint256 valor) public {
        _liberacao(valor, 0);
    }

    function check_liberacao_30(uint256 valor) public {
        _liberacao(valor, 3000);
    }

    function check_liberacao_100(uint256 valor) public {
        _liberacao(valor, 10_000);
    }

    /// Disputa: comprador + vendedor + taxas = depósito + caução; supervisor não recebe nada.
    function _disputa(uint256 valor, uint256 bpsAoVendedor) internal {
        vm.assume(valor >= esc.VALOR_MIN() && valor <= 1e36);
        (uint256 id, uint256 total) = _criar(valor, 3000);
        _embarcar(id);
        uint256 caucao = valor / 100;
        m.mint(comp, caucao);
        vm.startPrank(comp);
        m.approve(address(esc), caucao);
        esc.contestar(id);
        vm.stopPrank();
        vm.prank(sup);
        esc.decidir(id, bpsAoVendedor);
        uint256 soma = esc.saldo(address(m), comp) + esc.saldo(address(m), vend) + esc.saldo(address(m), taxas);
        assert(soma == total + caucao);
        assert(esc.saldo(address(m), sup) == 0);
        assert(esc.travado(address(m)) == 0);
    }

    function check_disputa_comprador_ganha(uint256 valor) public {
        _disputa(valor, 0);
    }

    function check_disputa_meio_a_meio(uint256 valor) public {
        _disputa(valor, 5000);
    }

    function check_disputa_vendedor_ganha(uint256 valor) public {
        _disputa(valor, 10_000);
    }

    function check_disputa_quase_tudo(uint256 valor) public {
        _disputa(valor, 9999);
    }
}
