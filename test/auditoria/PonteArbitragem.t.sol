// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Auditoria v3 — ponte × pools independentes por rede.
//   ORIGEM=bsc DESTINO=base forge test --isolate --match-contract PonteArbitragemAuditoria --match-test test_X -vv

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PonteTest} from "../Ponte.t.sol";

contract PonteArbitragemAuditoria is PonteTest {
    /// X1 (OK): cada rede tem a SUA escada de 1e30 no mesmo preço inicial. Com o 1º degrau de
    /// ~US$62 bi, US$200 mil de compras não mexem o tick; comprar na rede "fria" e vender pela
    /// ponte na "quente" perde as duas taxas de 2% — a arbitragem entre redes não compensa
    /// em volume realista.
    function test_X1_arbitragem_entre_redes_nao_compensa() public {
        address baleia = makeAddr("baleia");
        address arb = makeAddr("arb");
        _usar(d);
        _comprar(baleia, _unid(200_000)); // rede destino "quente"
        int24 tickAntes = _tick();
        _usar(o);
        uint256 custo = _unid(20_000);
        uint256 comprado = _comprar(arb, custo); // rede origem "fria": preço de lançamento
        uint256 v = (comprado / 1e9) * 1e9;
        vm.prank(arb);
        IERC20(address(o.t)).transfer(viajante, v);
        (bytes memory m, uint256 taxa) = _enviar(viajante, v);
        _entregar(m, 1);
        _usar(d);
        uint256 recebido = _vender(viajante, v);
        emit log_named_uint("custo na origem (unid. moeda origem)", custo);
        emit log_named_uint("recebido no destino (unid. moeda destino)", recebido);
        emit log_named_uint("taxa LayerZero (wei nativo)", taxa);
        emit log_named_int("tick destino antes", tickAntes);
        emit log_named_int("tick destino depois", _tick());
        _usar(d);
        // normaliza casas da moeda (BSC USDC 18, Base USDC 6)
        uint256 custoN = custo * 1e6 / 10 ** o.casas;
        uint256 recebN = recebido * 1e6 / 10 ** d.casas;
        assertEq(_tick(), tickAntes, "tick do destino nem se mexeu com US$200 mil");
        assertLt(recebN, custoN, "arbitragem da prejuizo (duas taxas de 2%)");
    }
}
