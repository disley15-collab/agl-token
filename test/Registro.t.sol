// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SwapParams } from "v4-core/types/PoolOperation.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { AGL } from "../src/AGL.sol";
import { RegistroAGL, IPoolAGLLeitura } from "../src/RegistroAGL.sol";
import { BaseAGL } from "./BaseAGL.sol";

contract RegistroTest is BaseAGL {
    RegistroAGL reg;
    address sup = makeAddr("supervisor");
    address atest = makeAddr("atestador");
    address receb = makeAddr("recebedor");
    address a = makeAddr("empresaA");
    address b = makeAddr("empresaB");

    function setUp() public override {
        super.setUp();
        _lancar();
        reg = new RegistroAGL(
            IPoolAGLLeitura(address(pool)), receb, sup, atest,
            TickMath.getSqrtPriceAtTick(int24(vm.parseJsonInt(json, ".tickInicial")))
        );
        // o registro guarda AGL dos pedidos: o guardião (dono) libera o contrato no token
        address[] memory p = new address[](1);
        p[0] = address(reg);
        vm.prank(DONO);
        t.permitir(p);
        vm.startPrank(sup);
        reg.definirPreco(RegistroAGL.Servico.KycPessoa, _unid(25));
        reg.definirPreco(RegistroAGL.Servico.KybEmpresa, _unid(75));
        reg.definirPreco(RegistroAGL.Servico.Contato, _unid(15));
        reg.definirPreco(RegistroAGL.Servico.InfoExtra, _unid(10));
        vm.stopPrank();
        address[] memory c = new address[](2);
        (c[0], c[1]) = (a, b);
        vm.prank(atest);
        reg.atestar(c, uint64(block.timestamp + 365 days));
        _comprar(a, _unid(1000));
        _comprar(b, _unid(1000));
        vm.prank(a);
        t.approve(address(reg), type(uint256).max);
        vm.prank(b);
        t.approve(address(reg), type(uint256).max);
    }

    function test_kyc_de_25_dolares_em_agl() public {
        uint256 v = reg.precoEmAgl(RegistroAGL.Servico.KycPessoa);
        // US$25 a ~US$1e-9 = ~2,5e10 AGL = 2,5e19 unidades
        assertApproxEqRel(v, 25e9 * 1e9, 0.01e18);
        vm.prank(a);
        reg.pagarServico(RegistroAGL.Servico.KycPessoa, keccak256("protocolo-1"), v);
        assertEq(t.balanceOf(receb), v, "AGL vai para a carteira do dono");
    }

    function test_teto_do_pagador() public {
        uint256 v = reg.precoEmAgl(RegistroAGL.Servico.KybEmpresa);
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(RegistroAGL.AcimaDoTeto.selector, v, v - 1));
        reg.pagarServico(RegistroAGL.Servico.KybEmpresa, keccak256("x"), v - 1);
    }

    /// Preço empurrado para baixo do lançamento (de graça, sem liquidez) não encarece
    /// o serviço: vale o piso.
    function test_piso_de_preco_contra_manipulacao() public {
        uint256 antes = reg.precoEmAgl(RegistroAGL.Servico.Contato);
        bool t0 = pool.tokenEhMoeda0();
        // um vendedor com AGL de sobra (deal) vende abaixo do lançamento: sem liquidez lá,
        // o preço vai ao extremo
        uint256 extra = 1e28;
        deal(address(t), a, t.balanceOf(a) + extra);
        PoolKey memory k = pool.chave();
        vm.startPrank(a);
        t.approve(address(router), type(uint256).max);
        router.swap(k, SwapParams(t0, -int256(t.balanceOf(a)), t0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
        int24 ti = int24(vm.parseJsonInt(json, ".tickInicial"));
        int24 d = _tick() > ti ? _tick() - ti : ti - _tick();
        assertGt(d, 100_000, "preco foi empurrado para longe do lancamento");
        // sem o piso, o preço no extremo pediria ~infinitos AGL; com o piso fica no preço do lançamento
        assertApproxEqRel(reg.precoEmAgl(RegistroAGL.Servico.Contato), antes, 1e12, "piso segura o preco (1e-6)");
    }

    function test_contato_aceito_paga_o_dono() public {
        vm.prank(a);
        uint256 id = reg.pedir(b, RegistroAGL.Servico.Contato, type(uint256).max);
        (,,,, uint256 v,) = reg.pedidos(id);
        assertEq(t.balanceOf(address(reg)), v, "reservado");
        vm.prank(a);
        vm.expectRevert(RegistroAGL.SoAlvo.selector);
        reg.responder(id, true);
        vm.prank(b);
        reg.responder(id, true);
        assertEq(t.balanceOf(receb), v);
        vm.prank(b);
        vm.expectRevert(RegistroAGL.PedidoFechado.selector);
        reg.responder(id, true);
    }

    function test_contato_recusado_devolve() public {
        uint256 saldo = t.balanceOf(a);
        vm.prank(a);
        uint256 id = reg.pedir(b, RegistroAGL.Servico.InfoExtra, type(uint256).max);
        vm.prank(b);
        reg.responder(id, false);
        assertEq(t.balanceOf(a), saldo, "devolvido");
        assertEq(t.balanceOf(receb), 0);
    }

    function test_sem_resposta_devolve_em_7_dias() public {
        uint256 saldo = t.balanceOf(a);
        vm.prank(a);
        uint256 id = reg.pedir(b, RegistroAGL.Servico.Contato, type(uint256).max);
        vm.expectRevert(RegistroAGL.PrazoNaoVenceu.selector);
        reg.devolver(id);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(b);
        vm.expectRevert(RegistroAGL.PrazoVencido.selector);
        reg.responder(id, true);
        reg.devolver(id);
        assertEq(t.balanceOf(a), saldo);
    }

    function test_pedido_exige_kyc_das_duas_partes() public {
        address c = makeAddr("semKyc");
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(RegistroAGL.SemKYC.selector, c));
        reg.pedir(c, RegistroAGL.Servico.Contato, type(uint256).max);
    }

    function test_servico_sem_preco() public {
        vm.prank(a);
        vm.expectRevert(RegistroAGL.PrecoNaoDefinido.selector);
        reg.pagarServico(RegistroAGL.Servico.Cadastro, keccak256("x"), type(uint256).max);
    }

    function test_so_supervisor_define_preco() public {
        vm.prank(a);
        vm.expectRevert(RegistroAGL.SoSupervisor.selector);
        reg.definirPreco(RegistroAGL.Servico.Contato, 1);
    }

    function test_vendedor_assina_primeiro_comprador_ainda_nao_abre() public {
        bytes32 h = keccak256("contrato-cafe");
        vm.prank(b);
        reg.assinar(h, a, b);
        assertTrue(reg.podeAbrir(h, a, b, b));
        assertFalse(reg.podeAbrir(h, a, b, a), "comprador ainda nao assinou");
    }

    function test_contrato_assinatura_e_acesso() public {
        bytes32 h = keccak256("contrato-soja");
        address est = makeAddr("estranho");
        vm.prank(est);
        vm.expectRevert(RegistroAGL.SoParte.selector);
        reg.assinar(h, a, b);
        vm.prank(a);
        reg.assinar(h, a, b);
        assertFalse(reg.contratoAssinado(h, a, b), "falta o vendedor");
        assertTrue(reg.podeAbrir(h, a, b, a), "quem assinou abre");
        assertFalse(reg.podeAbrir(h, a, b, b), "vendedor ainda nao assinou");
        assertFalse(reg.podeAbrir(h, a, b, sup), "supervisor so com as duas assinaturas");
        vm.prank(b);
        reg.assinar(h, a, b);
        assertTrue(reg.contratoAssinado(h, a, b));
        assertFalse(reg.contratoAssinado(h, b, a), "papeis trocados nao valem");
        assertTrue(reg.podeAbrir(h, a, b, b));
        assertTrue(reg.podeAbrir(h, a, b, sup));
        assertFalse(reg.podeAbrir(h, a, b, est));
    }

    /// R1 (auditoria): um estranho registra o mesmo hash com ELE como comprador; isso não
    /// atrapalha o contrato verdadeiro e não lhe dá acesso ao arquivo.
    function test_R1_hash_nao_e_sequestrado() public {
        bytes32 h = keccak256("contrato-milho");
        address est = makeAddr("estranho");
        address[] memory c = new address[](1);
        c[0] = est;
        vm.prank(atest);
        reg.atestar(c, uint64(block.timestamp + 1 days));
        vm.prank(est);
        reg.assinar(h, est, b);
        vm.prank(a);
        reg.assinar(h, a, b);
        vm.prank(b);
        reg.assinar(h, a, b);
        assertTrue(reg.contratoAssinado(h, a, b));
        assertFalse(reg.podeAbrir(h, a, b, est));
        assertFalse(reg.contratoAssinado(h, est, b), "o do estranho nao tem a assinatura do vendedor");
    }

    function test_assinar_exige_kyc() public {
        address semKyc = makeAddr("semKyc");
        vm.prank(semKyc);
        vm.expectRevert(abi.encodeWithSelector(RegistroAGL.SemKYC.selector, semKyc));
        reg.assinar(keccak256("x"), semKyc, b);
    }

    /// Sem o registro liberado no token, ele não consegue reservar AGL.
    /// O registro recebe AGL sem liberação (lógica inversa).
    function test_registro_funciona_sem_liberacao() public {
        RegistroAGL r2 = new RegistroAGL(IPoolAGLLeitura(address(pool)), receb, sup, atest, 1);
        vm.prank(sup);
        r2.definirPreco(RegistroAGL.Servico.Contato, _unid(15));
        address[] memory c = new address[](2);
        (c[0], c[1]) = (a, b);
        vm.prank(atest);
        r2.atestar(c, uint64(block.timestamp + 1 days));
        vm.startPrank(a);
        t.approve(address(r2), type(uint256).max);
        uint256 id = r2.pedir(b, RegistroAGL.Servico.Contato, type(uint256).max);
        assertEq(id, 1);
        vm.stopPrank();
    }
}
