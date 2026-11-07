// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Auditoria independente — Escrow e Registro.
//   REDE=base forge test --match-contract EscrowRegistroAuditoria --isolate -vv

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { EscrowAGL } from "../../src/EscrowAGL.sol";
import { RegistroAGL } from "../../src/RegistroAGL.sol";
import { EscrowBase, IFiatToken } from "../Escrow.t.sol";

contract EscrowRegistroAuditoria is EscrowBase {
    function _contestar(address quem, uint256 id) internal {
        uint256 c = V / 100;
        deal(MOEDA, quem, c);
        vm.startPrank(quem);
        IERC20(MOEDA).approve(address(esc), c);
        esc.contestar(id);
        vm.stopPrank();
    }

    // E1, E2, E3, E5 e R1 foram corrigidos em 07/11 (testes em test/Escrow.t.sol e
    // test/Registro.t.sol). Fica aqui o E4, que é limite conhecido (documentado).

    /// E4: comprador na blacklist da stablecoin não consegue contestar (a caução sai da
    /// carteira dele por transferFrom): a etapa informada passa sem contestação.
    function test_E4_comprador_bloqueado_nao_contesta() public {
        if (block.chainid == 56) return;
        uint256 id = _criar(0);
        _ate(id, 2);
        deal(MOEDA, comp, V / 100);
        vm.prank(comp);
        IERC20(MOEDA).approve(address(esc), V / 100);
        vm.prank(IFiatToken(MOEDA).blacklister());
        IFiatToken(MOEDA).blacklist(comp);
        vm.prank(comp);
        vm.expectRevert();
        esc.contestar(id);
    }
}
