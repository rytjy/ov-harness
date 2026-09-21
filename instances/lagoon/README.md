# ov-harness instance — Lagoon

Fork-based, read-only invariant harness against a **real mainnet** Lagoon vault.
No broadcast, no private keys, no testnet.

## Target

| Field | Value |
|---|---|
| Chain | Ethereum mainnet (1) |
| Vault (proxy) | `0xcE0b790ae0d8cF91e01f3FB69025e14569b574f3` |
| Share token | `tulipaUSDC` / "Tulipa USDC", 18 dec |
| Asset | USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| TVL (API) | ≈ 9,371,912.64 USDC (≈$9.37M) |
| Impl (EIP-1967) | `0x6C77c47FB8168E22976C3B0338CB1769c952249f` |
| Custody Safe | `0x4018327d5BFee6636509b2a4b5caC2D3E7B641DD` |
| Owner | `0x70a784BC7EC9eB2E6b219C9e1A7cA8Ecb779FFac` |
| Version | `v0.6.0` |

Addresses from Lagoon docs `resources/networks-and-addresses`, cross-checked against the
public Lagoon GraphQL API (`api.lagoon.finance/query`) and verified on-chain.

**Source / Sourcify**: proxy is unverified (`match: null`); impl
`0x6C77c47F…` = Sourcify `runtimeMatch: match` (partial — settings differ, not `exact_match`).
Extracted from Sourcify: **in-scope SLOC 4,063** (`src/**`, deps excluded); Vault core
`src/v0.6.0/vault/Vault-v0.6.0.sol` = 673 SLOC.

## Invariants (5)

1. `invariant_no_free_lunch` — Σ withdrawn assets ≤ Σ deposited + donated (ghost ledger).
2. `invariant_shares_are_backed` — `totalSupply() > 0 ⇒ totalAssets() > 0` (inflation guard).
3. `invariant_roundtrip_assets_le` — `convertToAssets(convertToShares(x)) ≤ x` (rounding dir).
4. `invariant_roundtrip_shares_le` — `convertToShares(convertToAssets(s)) ≤ s` (rounding dir).
5. `invariant_supply_claim_le_totalAssets` — supply cannot claim more than `totalAssets()` (double-count).

Handler: **3 actors**, 9 actions — `requestDeposit`, `syncDeposit`, `settle`, `syncValuation`,
`claim`, `requestRedeem`, `redeemNow`, `donate` (direct USDC→vault), `transferShares`.

## How to run

```bash
cd instances/lagoon && forge test --match-contract Invariants -vv --fork-url https://eth.drpc.org
```

## Result

**5/5 invariants PASS** (runs:10, calls:400, reverts:0) — **no counterexample found**.
Liveness: `test_liveness_requestDeposit_movesAssets` PASS (real USDC pulled by `requestDeposit`).

⚠️ **Known blocker (expected FAIL)** — `test_liveness_asyncDeposit_roundTrip`: the async
settle→claim leg cannot be driven read-only. `settleDeposit` is `OnlySafe`
(`0xfde82f1f`, arg = Safe address) and then `NewTotalAssetsMissing()` (`0x87d895da`);
impersonating the Safe passes `OnlySafe` but `updateNewTotalAssets` reverts (valuation
manager is a different role). Reverted to red on purpose — evidence, not a vault bug.
