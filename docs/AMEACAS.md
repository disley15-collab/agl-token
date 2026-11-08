# Modelo de ameaças e invariantes — AGL

## Atores
- **Comprador/vendedor de AGL** (qualquer carteira, carteira inteligente, agregador).
- **Golpista de pool**: cria pool falsa com taxa abusiva e tenta atrair rotas (caso real: SDBR, 06/11/2026, US$ 48 perdidos de US$ 52 numa pool de 94%).
- **Atacante de pré-inicialização**: tenta criar a pool oficial antes, com preço falso.
- **JIT/LP oportunista**: põe liquidez estreita para capturar a taxa.
- **Atacante de ponte**: mensagem forjada, par falso, captura de mensagem presa.
- **Partes do escrow** (comprador, vendedor) e **supervisor** — inclusive mal-intencionados entre si.
- **Chaves da plataforma** (guardião, supervisor, atestador, recebedor) — comprometidas.

## Invariantes e onde são provadas
| # | Invariante | Testes |
|---|---|---|
| T1 | Cada rede cria 1e30 unidades uma vez, todas para a pool; supply só muda pela ponte (queima aqui = cria lá) | `AGL.t.sol::test_lancamento_100pct…`, `Ponte.t.sol::test_ida_e_volta`, `Invariantes::invariant_supply_fixo` |
| T2 | Pool oficial só criada pela PoolAGL (pré-inicialização impossível) | `AGL.t.sol::test_pre_inicializacao_recusada`, `test_hook_recusa_outras_pools` |
| T3 | Ninguém põe liquidez na pool oficial (sem JIT) | `test_liquidez_de_terceiro_recusada`, `auditoria/Trava.t.sol` |
| T4 | Liquidez de cada degrau nunca diminui | `Invariantes::invariant_liquidez_nunca_diminui`, `test_liquidez_travada` |
| T5 | AGL só entra/sai do PoolManager dentro da cota da pool oficial; ida e volta não fabrica cota | `test_cota_so_pelo_token`, `test_A2_ida_e_volta_nao_deixa_cota`, `test_pool_v4_de_terceiro_nao_recebe_agl` |
| T6 | Cofres de DEX com taxa livre nunca recebem AGL (nem liberados) | `test_cofres_de_dex_bloqueados`, `auditoria/TravaPonteV3::test_T4` |
| T7 | Contrato com cara de pool do AGL não recebe (salvo liberado); contratos comuns e carteiras recebem | `test_pool_de_terceiro_nao_recebe`, `test_contratos_comuns_recebem_sem_liberacao`, `test_7702_delegada_a_pool_e_bloqueada`, `TravaPonteV3::T1,T3,T6` |
| T8 | Nenhuma criação de AGL direto no PoolManager | `TravaPonteV3::test_P1` |
| T9 | Ponte: só o par configurado entrega; trava vale na chegada; renúncia impede mudanças | `Ponte.t.sol::*` (8 rotas) |
| T10 | Taxas da pool só saem para o recebedor, por moeda | `test_taxa_2pct_para_o_dono`, `test_C1_saque_por_moeda_nao_trava`, `test_saque_de_taxas_nao_repete` |
| E1 | Caixa do escrow = travado + saldos a sacar | `Escrow.t.sol::invariant_caixa` |
| E2 | Todo reembolso devolve 100% ao comprador (inclusive a taxa dele) | `test_reembolso_*`, `test_cancelamentos` |
| E3 | Taxas só sobre o que vai ao vendedor; nunca acima de 3% | `invariant_taxa_e_supervisor`, `test_feliz_30_70…` |
| E4 | Supervisor nunca recebe nada e só decide até 30 dias; omissão = reembolso | `test_supervisor_nao_recebe_nada`, `test_E2_…`, `test_supervisor_omisso…` |
| E5 | Sem pagamento duplo; sem liberar e reembolsar a mesma parcela | `test_nao_libera_duas_vezes`, `invariant_ordens_coerentes` |
| E6 | Ordem só com KYC das duas partes e contrato assinado pelas duas | `test_sem_kyc_nao_cria`, `test_sem_contrato_assinado_nao_cria` |
| R1 | Contrato não é "sequestrado" (chave = hash + partes); só quem assinou abre | `Registro.t.sol::test_R1_…`, `test_contrato_assinatura_e_acesso` |
| R2 | Preço em AGL com piso no lançamento e teto do pagador | `test_piso_de_preco_contra_manipulacao`, `test_teto_do_pagador` |
| R3 | Pedido de contato: aceite paga o emissor; recusa/prazo devolve | `test_contato_*`, `test_sem_resposta_devolve_em_7_dias` |
| Z1 | cAGL: saldo cifrado; terceiro não usa handle alheio | `zama/test/AGLConfidencial.t.sol` |
