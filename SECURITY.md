# Segurança — AgroLastro (AGL)

## Contato
Relatos de vulnerabilidade: **t.me/agrolastro** (assunto: `[AGL] segurança`).
Não abra issue pública antes de uma correção. Resposta inicial em até 72 h.

## Escopo
| Contrato | Arquivo | Redes |
|---|---|---|
| AGL (ERC-20 + LayerZero OFT + trava de pools) | `src/AGL.sol` | BSC, Base, Arbitrum, Polygon, Optimism, Avalanche, Celo, Ethereum |
| PoolAGL (hook Uniswap v4, pool AGL/USDC travada) | `src/PoolAGL.sol` | as 8 |
| EscrowAGL (escrow em stablecoin) | `src/EscrowAGL.sol` | as 8 |
| RegistroAGL (KYC, serviços em AGL, contratos assinados) | `src/RegistroAGL.sol` | as 8 |
| cAGL (ERC-7984 confidencial, Zama) | `zama/src/AGLConfidencial.sol` | Ethereum |

Compilador fixo: **solc 0.8.38** (sem bugs conhecidos na lista oficial em 08/11/2026), `via_ir`, otimizador 200, `evm_version = cancun`, `bytecode_hash = none`, `cbor_metadata = false` (build reproduzível).

## Chaves e poderes depois do lançamento
| Papel | Quem | Pode | Não pode |
|---|---|---|---|
| Dono da ponte (OFT) | **ninguém** (renunciado na etapa 3) | — | mudar pares, bibliotecas, verificadores, criar AGL |
| Delegate LayerZero | **ninguém** (zerado na etapa 3) | — | mudar configuração da ponte |
| Guardião do AGL | carteira do emissor | **liberar** pools do próprio emissor (lista só cresce) | bloquear alguém, congelar, emitir, liberar cofres de DEX |
| Recebedor de taxas da pool | carteira do emissor | sacar taxas (2%) por moeda | tirar liquidez (não existe função) |
| Supervisor do escrow | carteira do emissor | decidir disputa até 30 dias, só entre comprador e vendedor | mandar dinheiro a terceiros ou a si; decidir depois do prazo |
| Supervisor do registro | carteira do emissor | definir preços dos serviços; trocar o atestador | mover AGL de ninguém (o pagador tem teto `_maxAgl`) |
| Atestador de KYC | servidor da plataforma | gravar/revogar selo de KYC | mover fundos |
| Carteira de publicação | descartada após o lançamento | nada depois da etapa 3 | — |

Não há proxy, upgrade, `selfdestruct`, `delegatecall`, pausa, blacklist de usuários, taxa na transferência nem mint fora da ponte.

## Ponte (LayerZero v2)
Configuração fixada explicitamente nas 56 rotas (bibliotecas de envio/recebimento, executor, ULN). Todas as rotas usam **4 verificadores (DVNs) obrigatórios** (conferido em 08/11/2026); a conferência de publicação recusa rota com menos de 2. Gás de entrega fixado em 300k.

## Limites conhecidos (aceitos e documentados)
1. **AMM feito sob medida para enganar a sonda** de "cara de pool" pode receber AGL. Nenhum agregador indexa esse tipo de contrato; só cai quem é levado por site golpista. Ninguém perde AGL que já tem e a pool oficial não é afetada.
2. **Compensação de saldos / claims ERC-6909 dentro do Uniswap v4**: a cota age na transferência física; quem compensa saldos no mesmo `unlock` leva AGL a outra pool v4 sem transferir. Sem perda para detentores nem para as taxas da pool oficial.
3. **Roteador que paga antes de trocar** não vende AGL (a cota abre depois da troca). Compra funciona.
4. **Ponte renunciada**: se um verificador da LayerZero parar, a rota afetada para; o AGL e as pools seguem em cada rede.
5. **Preço exibido abaixo do lançamento** pode ser empurrado de graça (sem liquidez abaixo); ninguém perde, e o Registro usa piso no preço de lançamento.

## Verificação
Ver `docs/AMEACAS.md` (modelo de ameaças e mapa invariante → teste) e o relatório de validação em `docs/VALIDACAO.md`.
