# Stakingverse — ov-harness (LST share-accounting invariants)

## Target
| | |
|---|---|
| Chain | **LUKSO mainnet, chainId 42** (⚠️ NOT Ethereum mainnet; docs section "LUKSO SERVICES") |
| Vault (proxy) | `0x9F49a95b0c3c9e2A6c77a16C177928294c0F6F04` (StakingverseVault) |
| Impl (EIP-1967) | `0x1711b2e1b64f38ca33e51b717cfd27acd1bd2e2d` |
| Share token | sLYX LSP7 `0x8A3982f0A7d154D11a5f43EEc7F50E52eBBc8F7D` |
| Fork block | 8409876 |
| Provenance | `github.com/Stakingverse/pool-contracts` `src/StakingverseVault.sol` (BUSL-1.1, pragma `=0.8.22`) |
| Sourcify | ❌ chain 42 unsupported (`{"customCode":"unsupported_chain"}`) → used Blockscout LUKSO `/api/v2/smart-contracts/<impl>`: `is_verified: true`, name `StakingverseVault` |

## ⚠️ Deployed ≠ repo HEAD
Deployed impl has `receive() external payable { deposit(msg.sender); }`;
repo HEAD has an **empty** `receive()`. Raw native transfer therefore **mints shares** on mainnet.

## Invariants (5)
1. `invariant_solvency_nativeBacksUnstaked` — vault native balance ≥ `totalUnstaked()`
2. `invariant_solvency_assetsCoverActorClaims` — Σ actor `balanceOf` ≤ `totalAssets()`
3. `invariant_noFreeLunch_ghostConservation` — ghost Σwithdrawn + ΣbalanceOf + Σpending ≤ Σdeposited
4. `invariant_rounding_favorsPool` — `balanceOf·totalShares ≤ sharesOf·totalAssets` (floor-only, per actor)
5. `invariant_donation_doesNotReprice` — raw transfer must not move `totalAssets()`

Handler: 3 actors, actions `deposit / withdraw / claim / donate / sync`, ghosts Σdeposited, Σwithdrawn, ΣpendingCreated, Σdonated, reprice counter.

## Run
```bash
anvil --fork-url https://rpc.mainnet.lukso.network --fork-block-number 8409876 --port 8545 --silent &
cd instances/stakingverse && forge test --match-contract Invariants -vv --fork-url http://127.0.0.1:8545
kill <anvil-pid>
```

## Result — 4 passed / 1 FAILED
`[FAIL: donation repriced the pool: 1 != 0]` — counterexample sequence: `donate(58496246095623)` (single call).
Measured on fork: `totalAssets()` 3666392750937598139895781 → 3666392750996094385991404 (**+58 496 246 095 623**, exactly the transferred wei).
Cause: `receive() → deposit(msg.sender)` mints sLYX shares. A 1-wei transfer reverts (`shares == 0 → InvalidAmount`).
Reading of the output (engineering, not a security assessment): the deployed implementation
diverges from the repository HEAD, where `receive()` is empty. On chain a raw native transfer
goes through `deposit(msg.sender)`, so the sender receives shares for the value it sent — the
sender pays for them, so this is not a value-extraction path, but it does mean the invariant
"a raw transfer does not move `totalAssets()`" does not hold for this deployment. Kept as a
worked example of a FAIL outcome, and as a reminder that repository HEAD must not be assumed to
be what is live. No severity is claimed and nothing here is a disclosure; if you are the
protocol owner, verify against your own deployment and decide what, if anything, to change.
