// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { AGL } from "../src/AGL.sol";
import { PoolAGL } from "../src/PoolAGL.sol";
import { ICreateX } from "../src/ICreateX.sol";
import { BaseAGL } from "./BaseAGL.sol";

contract AGLTest is BaseAGL {
    uint256 constant TOTAL = 1e30;

    // ------------------------------------------------------------ lançamento

    function test_lancamento_supply_dono_e_pool_numa_transacao() public {
        _lancar();
        uint256 parte = t.supplyDaRede(chainid);
        assertEq(t.totalSupply(), parte, "supply da rede");
        assertEq(parte, chainid == 56 ? TOTAL / 7 + TOTAL % 7 : TOTAL / 7);
        assertEq(t.balanceOf(DONO), parte * 5 / 100, "5% do dono");
        uint256 naPool = t.balanceOf(address(PM)) ;
        uint256 poeira = t.balanceOf(address(pool));
        // o PoolManager guarda o token de TODAS as pools: aqui só existe a nossa
        assertEq(naPool + poeira, parte - parte * 5 / 100, "o resto e da pool");
        assertLt(poeira, naPool / 1e9, "poeira de arredondamento < 1 bilionesimo da pool");
        assertEq(t.decimals(), 9);
        assertEq(t.symbol(), "AGL");
        assertEq(t.name(), "AgroLastro");
        // todos os degraus com liquidez
        PoolAGL.Faixa[] memory fx = pool.todasAsFaixas();
        assertEq(fx.length, 19);
        for (uint256 i; i < fx.length; i++) assertGt(_liquidez(fx[i]), 0);
        assertEq(_tick(), int24(vm.parseJsonInt(json, ".tickInicial")));
    }

    function test_token_soma_7_redes_um_sextilhao() public {
        t = new AGL(address(this));
        uint256[7] memory ids = [uint256(56), 8453, 42161, 137, 10, 43114, 42220];
        uint256 soma;
        for (uint256 i; i < 7; i++) soma += t.supplyDaRede(ids[i]);
        assertEq(soma, TOTAL);
        vm.expectRevert(abi.encodeWithSelector(AGL.RedeForaDaLista.selector, uint256(1)));
        t.supplyDaRede(1);
    }

    function test_token_recusa_rede_fora_da_lista() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(AGL.RedeForaDaLista.selector, uint256(1)));
        new AGL(address(this));
    }

    function test_so_lancador_e_uma_vez() public {
        pool = _publicarPool();
        json = _escada(_enderecoToken());
        PoolAGL.Faixa[] memory fx = _faixas();
        int24 ti = int24(vm.parseJsonInt(json, ".tickInicial"));
        vm.prank(atacante);
        vm.expectRevert(PoolAGL.SoLancador.selector);
        pool.lancar(_saltToken(), ti, fx);
        vm.prank(DEPLOYER);
        pool.lancar(_saltToken(), ti, fx);
        vm.prank(DEPLOYER);
        vm.expectRevert(PoolAGL.JaLancado.selector);
        pool.lancar(_saltToken(), ti, fx);
    }

    function test_degrau_abaixo_do_preco_recusado() public {
        pool = _publicarPool();
        json = _escada(_enderecoToken());
        PoolAGL.Faixa[] memory fx = _faixas();
        int24 ti = int24(vm.parseJsonInt(json, ".tickInicial"));
        // começar a pool 10 ticks acima: o 1º degrau ficaria com parte do lado da moeda
        bool t0 = _enderecoToken() < MOEDA;
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(PoolAGL.FaixaFora.selector, uint256(0)));
        pool.lancar(_saltToken(), t0 ? ti + 10 : ti - 10, fx);
    }

    function test_escada_maior_que_o_saldo_recusada() public {
        pool = _publicarPool();
        json = _escada(_enderecoToken());
        PoolAGL.Faixa[] memory fx = _faixas();
        fx[0].quantidade = TOTAL;
        vm.prank(DEPLOYER);
        vm.expectRevert(PoolAGL.SobraNegativa.selector);
        pool.lancar(_saltToken(), int24(vm.parseJsonInt(json, ".tickInicial")), fx);
    }

    /// Salt do token protegido: com o mesmo salt, outra conta cai em OUTRO endereço
    /// (a CreateX só aplica a proteção a quem está nos 20 primeiros bytes), e o
    /// lançamento oficial continua funcionando no endereço previsto.
    function test_ninguem_publica_no_endereco_do_token() public {
        pool = _publicarPool();
        address previsto = _enderecoToken();
        bytes memory init = abi.encodePacked(type(AGL).creationCode, abi.encode(atacante));
        vm.prank(atacante);
        address dele = ICreateX(CREATEX).deployCreate3(_saltToken(), init);
        assertTrue(dele != previsto, "atacante nao toma o endereco");
        assertEq(previsto.code.length, 0);
        json = _escada(previsto);
        PoolAGL.Faixa[] memory fx = _faixas();
        vm.prank(DEPLOYER);
        pool.lancar(_saltToken(), int24(vm.parseJsonInt(json, ".tickInicial")), fx);
        assertEq(Currency.unwrap(pool.token()), previsto);
    }

    function test_endereco_de_hook_errado_recusado() public {
        vm.expectRevert(PoolAGL.EnderecoDeHookErrado.selector);
        new PoolAGL(PM, DEPLOYER, MOEDA, DONO);
    }

    // ------------------------------------------- pré-inicialização (achado crítico SDBR)

    /// Antes do lançamento o endereço do token já é previsível (está no calldata da tx).
    /// Mesmo assim ninguém cria a pool oficial antes: o hook recusa.
    function test_pre_inicializacao_da_pool_oficial_recusada() public {
        pool = _publicarPool();
        address tk = _enderecoToken();
        (Currency c0, Currency c1) =
            tk < MOEDA ? (Currency.wrap(tk), Currency.wrap(MOEDA)) : (Currency.wrap(MOEDA), Currency.wrap(tk));
        PoolKey memory k = PoolKey(c0, c1, 20_000, 10, IHooks(address(pool)));
        vm.prank(atacante);
        vm.expectRevert();
        PM.initialize(k, TickMath.getSqrtPriceAtTick(0));
        // e depois do lançamento a pool oficial é a do lançamento, no preço certo
        json = _escada(tk);
        PoolAGL.Faixa[] memory fx = _faixas();
        vm.prank(DEPLOYER);
        pool.lancar(_saltToken(), int24(vm.parseJsonInt(json, ".tickInicial")), fx);
        t = AGL(tk);
        assertEq(_tick(), int24(vm.parseJsonInt(json, ".tickInicial")));
    }

    /// Ninguém usa o nosso hook em outra pool (outra taxa, outro par).
    function test_hook_recusa_outras_pools() public {
        _lancar();
        PoolKey memory k = pool.chave();
        k.fee = 3000;
        vm.prank(atacante);
        vm.expectRevert();
        PM.initialize(k, TickMath.getSqrtPriceAtTick(0));
    }

    // ------------------------------------------------------------ comprar e vender

    function test_compra_de_1_dolar_e_venda() public {
        _lancar();
        uint256 r = _comprar(comprador, _unid(1));
        assertGt(r, 0, "US$1 compra token");
        uint256 v = _vender(comprador, r);
        assertGt(v, _unid(1) * 95 / 100, "vende de volta perdendo ~4% (2 taxas)");
        assertLe(v, _unid(1));
    }

    /// O primeiro degrau custa o que a escada calculou.
    function test_primeiro_degrau_custa_o_previsto() public {
        _lancar();
        PoolAGL.Faixa[] memory fx = pool.todasAsFaixas();
        uint256 pago = _comprarTokens(comprador, fx[0].quantidade - 1e9);
        uint256 previsto = vm.parseUint(_semPonto(vm.parseJsonString(json, ".usd.primeiroDegrau"))) * 10 ** casasMoeda / 100;
        emit log_named_decimal_uint("1o degrau custou", pago, casasMoeda);
        assertApproxEqRel(pago, previsto, 0.01e18);
    }

    // ------------------------------------------------------------ taxas

    function test_taxas_so_para_o_recebedor() public {
        _lancar();
        _comprar(comprador, _unid(10_000));
        uint256 antes = IERC20(MOEDA).balanceOf(DONO);
        vm.prank(atacante);
        pool.coletarTaxas(); // qualquer um chama, o dinheiro vai ao recebedor
        uint256 taxa = IERC20(MOEDA).balanceOf(DONO) - antes;
        assertApproxEqRel(taxa, _unid(200), 0.001e18, "2% de US$10 mil");
        assertEq(IERC20(MOEDA).balanceOf(atacante), 0);
    }

    function test_transferir_recebedor_so_pelo_recebedor() public {
        _lancar();
        vm.prank(atacante);
        vm.expectRevert(PoolAGL.SoRecebedor.selector);
        pool.transferirRecebedor(atacante);
        vm.prank(DONO);
        pool.transferirRecebedor(comprador);
        assertEq(pool.recebedorTaxas(), comprador);
    }

    // ------------------------------------------------------------ escada inteira e a meta

    /// Compra a escada inteira, coleta as taxas e vende os 5% do dono: o dono ganha a meta
    /// da rede (US$ 20 mi / 7), medido no fork.
    function test_meta_do_dono_com_a_escada_inteira() public {
        _lancar();
        PoolAGL.Faixa[] memory fx = pool.todasAsFaixas();
        uint256 naPool;
        for (uint256 i; i < fx.length; i++) naPool += fx[i].quantidade;
        // compra quase tudo (deixa 1 token por arredondamento)
        uint256 gasto = _comprarTokens(comprador, naPool - 1e9);
        uint256 antes = IERC20(MOEDA).balanceOf(DONO);
        pool.coletarTaxas();
        uint256 taxas = IERC20(MOEDA).balanceOf(DONO) - antes;
        uint256 venda = _vender(DONO, t.balanceOf(DONO));
        uint256 ganho = taxas + venda;
        uint256 meta = _unid(20_000_000) / 7;
        emit log_named_decimal_uint("compradores gastaram", gasto, casasMoeda);
        emit log_named_decimal_uint("taxas", taxas, casasMoeda);
        emit log_named_decimal_uint("venda dos 5%", venda, casasMoeda);
        emit log_named_decimal_uint("dono ganhou", ganho, casasMoeda);
        assertApproxEqRel(ganho, meta, 0.01e18, "meta da rede +-1%");
        assertApproxEqRel(
            gasto, vm.parseUint(_semPonto(vm.parseJsonString(json, ".usd.compradoresGastamEscadaInteira"))) * 10 ** casasMoeda / 100,
            0.01e18, "custo da escada bate com escada.py"
        );
    }

    function _semPonto(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory o = new bytes(b.length - 1);
        uint256 j;
        for (uint256 i; i < b.length; i++) if (b[i] != ".") o[j++] = b[i];
        return string(o);
    }

    /// A liquidez nunca sai: depois de comprar e vender tudo, cada degrau tem a mesma
    /// liquidez do lançamento.
    function test_liquidez_travada() public {
        _lancar();
        PoolAGL.Faixa[] memory fx = pool.todasAsFaixas();
        uint128[] memory l0 = new uint128[](fx.length);
        for (uint256 i; i < fx.length; i++) l0[i] = _liquidez(fx[i]);
        uint256 r = _comprar(comprador, _unid(5_000_000));
        pool.coletarTaxas();
        _vender(comprador, r);
        pool.coletarTaxas();
        for (uint256 i; i < fx.length; i++) assertEq(_liquidez(fx[i]), l0[i]);
    }
}
