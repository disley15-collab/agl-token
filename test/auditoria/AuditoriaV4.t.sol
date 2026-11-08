// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Auditoria v4 (polimento 0.8.38 + economia de gás).
//   Local (sem fork):  forge test --match-contract AuditoriaV4Escrow -vv
//   Fork:              REDE=base forge test --isolate --threads 1 --match-contract AuditoriaV4Pool -vv

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {EscrowAGL, IRegistro} from "../../src/EscrowAGL.sol";
import {RegistroAGL, IPoolAGLLeitura} from "../../src/RegistroAGL.sol";
import {AGL} from "../../src/AGL.sol";
import {PoolAGL} from "../../src/PoolAGL.sol";
import {ICreateX} from "../../src/ICreateX.sol";
import {BaseAGL} from "../BaseAGL.sol";

// ------------------------------------------------------------------ mocks

contract MoedaV4 is ERC20("M", "M") {
    function mint(address a, uint256 v) external {
        _mint(a, v);
    }
}

contract RegistroLivre is IRegistro {
    function verificado(address) external pure returns (bool) {
        return true;
    }

    function contratoAssinado(bytes32, address, address) external pure returns (bool) {
        return true;
    }
}

/// token0() devolve 40 KB (cabe nos 10k de gás da sonda) (antes: o AGL copiava tudo para a memória).
contract BombaDeRetorno {
    fallback() external {
        assembly {
            return(0, 40000)
        }
    }
}

/// token0() devolve 64 bytes cujo 1º word é o AGL (não é 32 exatos: a sonda não reconhece).
contract Retorno64 {
    address immutable agl;

    constructor(address a) {
        agl = a;
    }

    fallback() external {
        address a = agl;
        assembly {
            mstore(0, a)
            mstore(32, 0)
            return(0, 64)
        }
    }
}

/// Só coins(1) = AGL (cobre o último ramo do ||).
contract SoCoins1 {
    address immutable agl;

    constructor(address a) {
        agl = a;
    }

    function coins(uint256 i) external view returns (address) {
        return i == 1 ? agl : address(0xbeef);
    }
}

/// Responde 20 bytes com o AGL (não é um word ABI): não reconhece.
contract Retorno20 {
    address immutable agl;

    constructor(address a) {
        agl = a;
    }

    fallback() external {
        bytes20 b = bytes20(agl);
        assembly {
            mstore(0, b)
            return(0, 20)
        }
    }
}

/// Ecoa a calldata: token0() vira 4 bytes; coins(n) vira 36 bytes.
contract Eco {
    fallback() external {
        assembly {
            calldatacopy(0, 0, calldatasize())
            return(0, calldatasize())
        }
    }
}

/// Responde `msg.sender` em qualquer seletor: o AGL o vê como "pool do AGL".
contract EcoRemetente {
    fallback() external {
        assembly {
            mstore(0, caller())
            return(0, 32)
        }
    }
}

// ------------------------------------------------------------------ escrow (local)

contract AuditoriaV4Escrow is Test {
    EscrowAGL esc;
    MoedaV4 m;
    address comp = makeAddr("comp");
    address vend = makeAddr("vend");
    address sup = makeAddr("sup");
    address taxas = makeAddr("taxas");

    function setUp() public {
        m = new MoedaV4();
        _novo(500, 500);
    }

    function _novo(uint256 tc, uint256 tv) internal {
        address[] memory ms = new address[](1);
        ms[0] = address(m);
        esc = new EscrowAGL(new RegistroLivre(), taxas, sup, tc, tv, ms);
    }

    function _prazos() internal view returns (EscrowAGL.Prazos memory p) {
        p.aceite = uint64(block.timestamp + 1 days);
        p.embarque = uint64(block.timestamp + 10 days);
        p.chegada = uint64(block.timestamp + 40 days);
        p.janela = 3 days;
        p.intervaloMax = 2 days;
    }

    function _criar(uint256 valor, EscrowAGL.Modo modo, uint16 bps) internal returns (uint256 id) {
        uint256 total = esc.totalADepositar(valor);
        m.mint(comp, total);
        vm.startPrank(comp);
        m.approve(address(esc), total);
        id = esc.criar(vend, address(m), valor, modo, bps, keccak256("c"), _prazos());
        vm.stopPrank();
    }

    function _caixa() internal view {
        uint256 s = esc.saldo(address(m), comp) + esc.saldo(address(m), vend) + esc.saldo(address(m), taxas);
        assertEq(m.balanceOf(address(esc)), esc.travado(address(m)) + s, "caixa = travado + saldos");
    }

    function _contestar(uint256 id, address quem) internal {
        uint256 c = uint256(esc.ordem(id).valor) / 100;
        m.mint(quem, c);
        vm.startPrank(quem);
        m.approve(address(esc), c);
        esc.contestar(id);
        vm.stopPrank();
    }

    /// Valor acima do VALOR_MAX é recusado (o uint128 nunca trunca).
    function test_V4_E_valor_acima_do_maximo() public {
        _novo(500, 500);
        uint256 v = esc.VALOR_MAX() + 1;
        m.mint(comp, esc.totalADepositar(v));
        vm.startPrank(comp);
        m.approve(address(esc), type(uint256).max);
        vm.expectRevert(EscrowAGL.ParametroInvalido.selector);
        esc.criar(vend, address(m), v, EscrowAGL.Modo.Simples, 0, keccak256("c"), _prazos());
        vm.stopPrank();
    }

    /// bpsEmbarque acima de 10000 recusado (uint16 aceitaria até 65535).
    function test_V4_E_bps_embarque_acima_de_100pct() public {
        _novo(500, 500);
        m.mint(comp, 1e30);
        vm.startPrank(comp);
        m.approve(address(esc), type(uint256).max);
        vm.expectRevert(EscrowAGL.ParametroInvalido.selector);
        esc.criar(vend, address(m), 1e18, EscrowAGL.Modo.Rastreado, 10_001, keccak256("c"), _prazos());
        vm.stopPrank();
    }

    /// Ciclo completo no VALOR_MAX, com taxas máximas, embarque de 100% e disputa: nada
    /// trunca, a caixa fecha, nada fica travado.
    function test_V4_E_valor_maximo_ciclo_completo() public {
        _novo(500, 500);
        uint256 v = esc.VALOR_MAX();
        uint256 id = _criar(v, EscrowAGL.Modo.Rastreado, 3333);
        vm.startPrank(vend);
        esc.aceitar(id);
        esc.atualizar(id, EscrowAGL.Tipo.Imagem, keccak256("i"), "");
        esc.atualizar(id, EscrowAGL.Tipo.DocumentoCarga, keccak256("d"), "");
        esc.atualizar(id, EscrowAGL.Tipo.TramiteLegal, keccak256("t"), "");
        esc.informarEmbarque(id, keccak256("e"));
        vm.stopPrank();
        vm.prank(comp);
        esc.confirmar(id);
        vm.warp(block.timestamp + 3 days);
        _contestar(id, comp); // silêncio
        vm.prank(sup);
        esc.decidir(id, 7777);
        _caixa();
        assertEq(esc.travado(address(m)), 0, "nada travado");
        EscrowAGL.Ordem memory o = esc.ordem(id);
        assertEq(o.taxaCompradorUsada, o.taxaComprador, "taxa do comprador toda usada");
    }

    /// Fuzz: qualquer valor válido, qualquer taxa, qualquer parcela e decisão: caixa fecha e
    /// travado volta a 0 (conversões uint128/uint16 sem perda).
    function testFuzz_V4_E_caixa_fecha(uint256 valor, uint16 bps, uint256 dec, uint16 tc, uint16 tv, uint8 rota)
        public
    {
        tc = uint16(bound(tc, 0, 500));
        tv = uint16(bound(tv, 0, 500));
        _novo(tc, tv);
        valor = bound(valor, esc.VALOR_MIN(), esc.VALOR_MAX());
        bps = uint16(bound(bps, 0, 10_000));
        dec = bound(dec, 0, 10_000);
        uint256 id = _criar(valor, EscrowAGL.Modo.Rastreado, bps);
        vm.startPrank(vend);
        esc.aceitar(id);
        esc.atualizar(id, EscrowAGL.Tipo.Imagem, keccak256("i"), "");
        esc.atualizar(id, EscrowAGL.Tipo.DocumentoCarga, keccak256("d"), "");
        esc.atualizar(id, EscrowAGL.Tipo.TramiteLegal, keccak256("t"), "");
        esc.informarEmbarque(id, keccak256("e"));
        vm.stopPrank();
        rota = rota % 4;
        if (rota == 0) {
            // disputa no embarque, decisão
            _contestar(id, vend);
            vm.prank(sup);
            esc.decidir(id, dec);
        } else {
            vm.prank(comp);
            esc.confirmar(id);
            if (esc.ordem(id).etapa == EscrowAGL.Etapa.Embarcada) {
                if (rota == 1) {
                    vm.prank(vend);
                    esc.informarChegada(id, keccak256("c"));
                    vm.prank(comp);
                    esc.confirmar(id);
                } else if (rota == 2) {
                    vm.warp(block.timestamp + 41 days);
                    esc.reembolsarPorPrazo(id);
                } else {
                    vm.warp(block.timestamp + 3 days);
                    _contestar(id, comp);
                    vm.warp(block.timestamp + 31 days);
                    esc.reembolsarPorOmissao(id);
                }
            }
        }
        _caixa();
        assertEq(esc.travado(address(m)), 0, "nada travado no fim");
        EscrowAGL.Ordem memory o = esc.ordem(id);
        assertLe(o.liberado, o.valor);
        assertEq(o.taxaCompradorUsada, o.taxaComprador);
    }

    /// Janela/intervalo: uint32 mais uint64 não estoura (limites máximos).
    function test_V4_E_prazos_no_limite() public {
        _novo(500, 500);
        EscrowAGL.Prazos memory p = _prazos();
        p.janela = uint32(esc.JANELA_MAX());
        p.intervaloMax = uint32(esc.INTERVALO_MAX());
        p.chegada = type(uint64).max - 1;
        m.mint(comp, 1e30);
        vm.startPrank(comp);
        m.approve(address(esc), type(uint256).max);
        uint256 id = esc.criar(vend, address(m), 1e18, EscrowAGL.Modo.Rastreado, 0, keccak256("c"), p);
        vm.stopPrank();
        assertEq(esc.ordem(id).prazos.janela, 30 days);
    }
}

// ------------------------------------------------------------------ pool, token, registro (fork)

contract AuditoriaV4Pool is BaseAGL {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function _initCom(bytes32 saltTk) internal returns (bool ok, bytes memory err) {
        bytes memory init = abi.encodePacked(
            type(PoolAGL).creationCode,
            abi.encode(PM, DEPLOYER, MOEDA, DONO, DONO, keccak256(_initToken(_poolPrevista())), saltTk)
        );
        vm.prank(DEPLOYER);
        (ok, err) = CREATEX.call(abi.encodeWithSelector(ICreateX.deployCreate3.selector, SALT_POOL, init));
    }

    /// Salt do token conferido no CONSTRUTOR: prefixo errado ou byte 21 != 0 → não publica.
    function test_V4_P_salt_errado_no_construtor() public {
        bytes32 bom = _saltPara(_poolPrevista());
        (bool ok,) = _initCom(bytes32(uint256(bom) ^ (uint256(1) << 255)));
        assertFalse(ok, "prefixo errado");
        (ok,) = _initCom(bytes32(uint256(bom) | (uint256(1) << 88)));
        assertFalse(ok, "byte 21 != 0");
        (ok,) = _initCom(bom);
        assertTrue(ok, "salt certo");
    }

    /// token()/tokenEhMoeda0() antes do lancar já dão o endereço final (antes era 0).
    function test_V4_P_token_antes_do_lancar() public {
        pool = _publicarPool();
        assertEq(Currency.unwrap(pool.token()), _enderecoToken(), "endereco previsto");
        assertEq(pool.tokenEhMoeda0(), _enderecoToken() < MOEDA, "ordem");
        assertEq(Currency.unwrap(pool.token()).code.length, 0, "sem codigo ainda");
        assertFalse(pool.lancado());
        // coletar antes do lancamento: não quebra, não cria saldo
        pool.coletarTaxas();
        vm.expectRevert(PoolAGL.IntervaloInvalido.selector);
        pool.coletarTaxasFaixas(0, 1);
        // ninguém consome cota fingindo ser o token (sem código no endereço)
        vm.prank(atacante);
        vm.expectRevert(PoolAGL.SoToken.selector);
        pool.consumirSaida(1);
    }

    /// Registro publicado ANTES do lançamento (agora possível) lê a pool certa e cota certo.
    function test_V4_R_registro_antes_do_lancar() public {
        pool = _publicarPool();
        json = _escada(_enderecoToken());
        int24 tk = int24(vm.parseJsonInt(json, ".tickInicial"));
        RegistroAGL reg =
            new RegistroAGL(IPoolAGLLeitura(address(pool)), DONO, DONO, DONO, TickMath.getSqrtPriceAtTick(tk));
        assertEq(address(reg.agl()), _enderecoToken());
        vm.prank(DONO);
        reg.definirPreco(RegistroAGL.Servico.Cadastro, _unid(25));
        // pool não inicializada: sp = 0
        uint256 antesDoLancar = reg.precoEmAgl(RegistroAGL.Servico.Cadastro);
        emit log_named_uint("preco em AGL antes do lancamento", antesDoLancar);
        PoolAGL.Faixa[] memory fx = _faixas();
        vm.prank(DEPLOYER);
        pool.lancar(_initToken(), tk, fx);
        t = AGL(Currency.unwrap(pool.token()));
        uint256 depois = reg.precoEmAgl(RegistroAGL.Servico.Cadastro);
        assertGt(depois, 0);
        // mesmo cálculo da versão anterior (3 chamadas externas)
        (uint160 sp,,,) = PM.getSlot0(pool.chave().toId());
        uint256 q96 = 1 << 96;
        uint256 esperado = pool.tokenEhMoeda0()
            ? FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(_unid(25), q96, sp), q96, sp)
            : FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(_unid(25), sp, q96), sp, q96);
        assertEq(depois, esperado, "cotacao igual a da versao anterior");
    }

    /// coletarTaxasFaixas em pedaços == coletarTaxas de uma vez (nas duas moedas), e o
    /// saldo físico da pool cobre exatamente o aSacar.
    function test_V4_P_coleta_parcial_igual_total() public {
        _lancar();
        uint256 n = pool.todasAsFaixas().length;
        // volume que atravessa vários degraus, ida e volta
        uint256 r = _comprar(atacante, _unid(5_000_000));
        _vender(atacante, r / 2);
        _comprar(comprador, _unid(100_000));

        address tk = Currency.unwrap(pool.token());
        uint256 snap = vm.snapshotState();
        pool.coletarTaxas();
        uint256 aT = pool.aSacar(tk);
        uint256 aM = pool.aSacar(MOEDA);
        assertGt(aT, 0);
        assertGt(aM, 0);
        assertEq(pool.cota(), 0, "cota zerada");
        vm.revertToState(snap);

        uint256 balT = IERC20(tk).balanceOf(address(pool));
        uint256 balM = IERC20(MOEDA).balanceOf(address(pool));
        uint256 meio = n / 2;
        pool.coletarTaxasFaixas(0, 1);
        pool.coletarTaxasFaixas(1, meio);
        pool.coletarTaxasFaixas(meio, n);
        assertEq(pool.aSacar(tk), aT, "AGL igual");
        assertEq(pool.aSacar(MOEDA), aM, "moeda igual");
        assertEq(IERC20(tk).balanceOf(address(pool)) - balT, aT, "AGL fisico = aSacar");
        assertEq(IERC20(MOEDA).balanceOf(address(pool)) - balM, aM, "moeda fisica = aSacar");
        // repetir não paga de novo
        pool.coletarTaxasFaixas(0, n);
        assertEq(pool.aSacar(tk), aT);
        assertEq(pool.aSacar(MOEDA), aM);
        // intervalos inválidos
        vm.expectRevert(PoolAGL.IntervaloInvalido.selector);
        pool.coletarTaxasFaixas(1, 1);
        vm.expectRevert(PoolAGL.IntervaloInvalido.selector);
        pool.coletarTaxasFaixas(0, n + 1);
        vm.expectRevert(PoolAGL.IntervaloInvalido.selector);
        pool.coletarTaxasFaixas(3, 2);
        // recebedor saca tudo, nas duas moedas
        vm.startPrank(DONO);
        pool.sacarTaxas(pool.token(), DONO);
        pool.sacarTaxas(Currency.wrap(MOEDA), DONO);
        vm.stopPrank();
        assertEq(pool.aSacar(tk), 0);
    }

    /// Sonda em assembly: bomba de retorno não encarece; respostas que não são um word ABI
    /// exato não contam; eco não conta; coins(1) sozinho conta.
    function test_V4_A_sonda_assembly() public {
        _lancar();
        uint256 r = _comprar(atacante, _unid(1000));
        uint256 parte = r / 8;

        address bomba = address(new BombaDeRetorno());
        vm.prank(atacante);
        uint256 g = gasleft();
        t.transfer(bomba, parte);
        uint256 gasto = g - gasleft();
        emit log_named_uint("gas transfer p/ bomba de retorno", gasto);
        assertLt(gasto, 400_000, "sem custo de copia de 40KB por sonda");

        address r64 = address(new Retorno64(address(t)));
        vm.prank(atacante);
        t.transfer(r64, parte);

        address r20 = address(new Retorno20(address(t)));
        vm.prank(atacante);
        t.transfer(r20, parte);

        address eco = address(new Eco());
        vm.prank(atacante);
        t.transfer(eco, parte);

        address c1 = address(new SoCoins1(address(t)));
        vm.prank(atacante);
        vm.expectRevert(abi.encodeWithSelector(AGL.PoolNaoAutorizada.selector, c1));
        t.transfer(c1, parte);

        // contrato que responde msg.sender a tudo: vira "pool do AGL" (falso positivo)
        address er = address(new EcoRemetente());
        vm.prank(atacante);
        vm.expectRevert(abi.encodeWithSelector(AGL.PoolNaoAutorizada.selector, er));
        t.transfer(er, parte);
    }

    /// Memória: a sonda escreve 36 bytes além do ponteiro livre ("memory-safe"); conferir
    /// que um array alocado depois não é corrompido (transferFrom com allowance etc.).
    function test_V4_A_sonda_nao_corrompe_memoria() public {
        _lancar();
        uint256 r = _comprar(atacante, _unid(1000));
        address eco = address(new Eco());
        vm.prank(atacante);
        t.approve(comprador, r);
        vm.prank(comprador);
        assertTrue(t.transferFrom(atacante, eco, r));
        assertEq(t.balanceOf(eco), r);
        assertEq(t.allowance(atacante, comprador), 0);
    }
}
