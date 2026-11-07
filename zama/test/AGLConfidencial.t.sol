// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { euint64 } from "@fhevm/solidity/lib/FHE.sol";
import { AGL } from "../../src/AGL.sol";
import { BaseAGL } from "../../test/BaseAGL.sol";
import { AGLConfidencial } from "../src/AGLConfidencial.sol";

/// Fork do Ethereum MAINNET com o coprocessador real da Zama (ACL/Executor/KMS).
contract AGLConfidencialTest is BaseAGL {
    AGLConfidencial c;
    address ana = makeAddr("ana");
    address beto = makeAddr("beto");

    function setUp() public override {
        vm.setEnv("REDE", "ethereum");
        super.setUp();
        _lancar();
        c = new AGLConfidencial(t);
        address[] memory p = new address[](1);
        p[0] = address(c);
        vm.prank(DONO);
        t.permitir(p);
    }

    function test_embrulha_inteiros_e_devolve_fracao() public {
        uint256 r = _comprar(ana, _unid(1000)); // ~9,8e11 AGL
        assertEq(c.decimals(), 0);
        assertEq(c.rate(), 1e9, "1 cAGL = 1 AGL inteiro");
        vm.startPrank(ana);
        t.approve(address(c), r);
        c.wrap(ana, r);
        vm.stopPrank();
        uint256 inteiros = r / 1e9;
        assertEq(t.balanceOf(address(c)), inteiros * 1e9, "AGL inteiro fica no cofre");
        assertEq(t.balanceOf(ana), r % 1e9, "fracao volta");
        assertEq(c.inferredTotalSupply(), inteiros);
        // o saldo é um "handle" cifrado, não o número
        bytes32 h = euint64.unwrap(c.confidentialBalanceOf(ana));
        assertTrue(h != bytes32(0), "saldo cifrado existe");
        assertTrue(uint256(h) != inteiros, "valor nao aparece em claro");
    }

    /// Transferência confidencial do saldo inteiro (handle que a Ana já pode usar):
    /// os números não aparecem em lugar nenhum da transação.
    function test_transferencia_confidencial() public {
        uint256 r = _comprar(ana, _unid(100));
        vm.startPrank(ana);
        t.approve(address(c), r);
        c.wrap(ana, r);
        euint64 saldo = c.confidentialBalanceOf(ana);
        c.confidentialTransfer(beto, saldo);
        vm.stopPrank();
        assertTrue(euint64.unwrap(c.confidentialBalanceOf(beto)) != bytes32(0), "beto recebeu (cifrado)");
        assertEq(t.balanceOf(address(c)), (r / 1e9) * 1e9, "AGL publico continua no cofre");
    }

    /// O cofre cAGL recebe AGL sem liberação (lógica inversa).
    function test_cofre_funciona_sem_liberacao() public {
        AGLConfidencial c2 = new AGLConfidencial(t);
        uint256 r = _comprar(ana, _unid(10));
        vm.startPrank(ana);
        t.approve(address(c2), r);
        c2.wrap(ana, r);
        assertEq(t.balanceOf(address(c2)), (r / 1e9) * 1e9);
        vm.stopPrank();
    }

    /// Ninguém além do dono do saldo consegue usar o handle da Ana.
    function test_terceiro_nao_usa_handle_alheio() public {
        uint256 r = _comprar(ana, _unid(100));
        vm.startPrank(ana);
        t.approve(address(c), r);
        c.wrap(ana, r);
        vm.stopPrank();
        euint64 saldoAna = c.confidentialBalanceOf(ana);
        vm.prank(beto);
        vm.expectRevert();
        c.confidentialTransfer(beto, saldoAna);
    }
}
