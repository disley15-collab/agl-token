# AgroLastro (AGL)

Utility token and contracts of **AgroLastro**, a service by **Solidity Brasil** (https://soliditybrasil.com.br): a non-custodial stablecoin escrow for agricultural trade across Portuguese-speaking countries.

> Not affiliated with *Apex Gold Ledger*, which also uses the ticker AGL. Always check the name **AgroLastro** and the address below.

## Deployed contracts (same address on BNB Chain, Base, Arbitrum, Polygon, Optimism, Avalanche, Celo and Ethereum)

| Contract | Address |
|---|---|
| AGL token (LayerZero v2 OFT, 9 decimals) | `0x0000000000109de411eabC9f04906d79F06FDa0e` |
| PoolAGL (Uniswap v4 hook, official AGL/USDC pool) | `0x0000000456b76bc801253eF2366664750F602840` |
| RegistroAGL (KYC, profile, contact, on-chain contract signatures) | `0xcF429Bbbbc6498f50418a7A5996Ab35A76ba001a` |
| EscrowAGL (stablecoin escrow) | `0xA7f625C1a64893eB803c0a3b4316E4832809eC48` |
| cAGL confidential wrapper (Zama, Ethereum only) | `0xd02F76eA336552D8019f7596E47EbDB4685d0528` |

- 1,000,000,000,000,000,000,000 AGL per chain, 100% placed by the hook in a 20-step single-sided ladder (from US$0.000000001) in the same transaction that created the token. Liquidity can never be removed.
- Bridge ownership renounced on all 8 chains (owner and LayerZero delegate = 0x0): no mint outside the bridge, no pause, no blacklist, no transfer tax, no proxy.
- 2% LP fee on the official pool, withdrawable only to the fee recipient.
- Source verified on Sourcify on all 8 chains. Publication record: [`docs/publicacao-mainnet.json`](docs/publicacao-mainnet.json). Threat model: [`docs/AMEACAS.md`](docs/AMEACAS.md). Security: [`SECURITY.md`](SECURITY.md).

## Build and test

```sh
forge build
forge test
```

Site: https://agl-token.vercel.app · Token page: https://sdbr.soliditybrasil.com.br/agl/ · Telegram: https://t.me/agrolastro

License: MIT
