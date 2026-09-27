# ov-harness — stateful fork invariant harness

A small, reusable Foundry pattern for **stateful invariant testing against live DeFi deployments**.
Point it at a deployed protocol, drive it through a handler, and let the fuzzer search for a state
where a protocol-level accounting rule breaks.

- **Read-only.** Fork only. No broadcasts, no private keys, no testnets.
- **No source needed.** Instances talk to the deployed contracts through minimal interfaces.
- **Reproducible.** Every instance pins a chain, a block number and a single command.

It is an engineering tool: it answers "can I reach a state that violates this rule, and how?",
and gives you a minimal call sequence when the answer is yes.

## What it is good for

| Problem | What the harness gives you |
|---|---|
| "Does this vault's accounting ever break under weird usage?" | Handler here drives deposit / withdraw / transfer / donate / sync; invariants assert the accounting identity |
| "Is this deployment the code I read?" | `scripts/byte_diff.md` — pinned-block comparison of deployed code vs. verified source |
| "Can an exogenous shock (price, time, donation, whale transfer) move a rate in a user's favour?" | Shock actions inside the handler + epsilon assertions on the conversion rate |
| "I found a break — what is the minimal repro?" | Foundry shrinks the failing sequence for you; the instance prints the calls |

## Install

```bash
git clone <this repo> && cd ov-harness
forge install foundry-rs/forge-std     # one dependency, installed once, at the repo root
# (add --no-git if you downloaded a tarball instead of cloning)
```

Requires [Foundry](https://book.getfoundry.sh/) (built and tested on `forge 1.5.x`, solc `0.8.28`).
Instances resolve `forge-std` from the repo-root `lib/` (each instance's `foundry.toml` declares
`libs = ["lib", "../../lib"]`), so installing it once is enough.

## Run an instance (one command)

```bash
cd instances/overnight && RPC_URL=https://base.drpc.org FORK_BLOCK=51544475 \
  forge test --match-contract OvernightInvariants -vv
```

Each instance directory is its own Foundry project with its own pinned chain and block; see its
README for the exact command, addresses and the verbatim result.

> **RPC note.** Public RPCs are the bottleneck: many reject *archive* (historical-block) requests,
> and some silently stall under bursts. The reliable pattern is a local fork:
> `anvil --fork-url <archive-capable-node> --fork-block-number <N> --port 8545 --silent &`
> then `RPC_URL=http://127.0.0.1:8545 forge test --match-contract <X>Invariants -vv`
> (only the first state pull touches the network).

## Instances

| Instance | Chain | Subject | Invariants | Result |
|---|---|---|---|---|
| [`instances/overnight`](instances/overnight) | Base (8453) | USD+ rebasing share vault | 6 | all PASS (no counterexample) |
| [`instances/lagoon`](instances/lagoon) | Ethereum (1) | async ERC-4626 vault | 5 | 5/5 PASS; one liveness test left red on purpose |
| [`instances/stakingverse`](instances/stakingverse) | LUKSO (42) | LST share vault | 5 | 4 PASS / 1 invariant violation recorded |

The third one doubles as an example of a **FAIL** outcome: the campaign reached a state that
violates a stated invariant and Foundry shrank it to a single call. That output is raw engineering
data — see the instance README. This repository publishes no security assessments, severity
ratings or disclosures; an invariant violation is a lead for the owner of the code to investigate,
not a verdict about it.

## Add your own instance (≈10 minutes)

Copy `instances/overnight`, change three things (target addresses + chain/pinned block + handler
actions & invariants), fill in the README template. Full walkthrough, gotchas and the acceptance
checklist: **[`TEMPLATE_GUIDE.md`](TEMPLATE_GUIDE.md)**.

## Layout

```
test/Template_Invariants.t.sol   handler + invariant skeleton to copy
scripts/byte_diff.md             prove "deployed code != the code you read"
TEMPLATE_GUIDE.md                step-by-step recipe for a new instance
instances/<name>/                one self-contained pinned project per target
```

## Invariant families worth encoding

1. **Share / price accounting** — donation attacks, first-depositor inflation, rounding direction.
2. **Access control / proxy upgrade hijack** — role holders, initializer reachability, impl slot.
3. **Oracle manipulation** — spot vs. TWAP, staleness, decimal scaling.
4. **Bridge / peg** — circulating ≤ reserves, no unbacked mint, message/domain binding.
5. **Arithmetic / precision** — overflow, rounding, unit mismatch.
6. **Exogenous-shock insensitivity** — a price move, a whale transfer or a raw donation must not
   move a conversion rate in a user's favour.

> Donation recipe: send the asset to the vault/pool *directly* (no `deposit()`), then assert that
> share price / withdrawal / liquidation outcomes did not move in the donor's favour.

## Gotchas (learned the hard way)

- **Never `deal()` derived assets** (aTokens, vault shares, debt receipts). Fund through the
  protocol's own entry path, or you will "discover" artifacts that do not exist on chain.
- Creating a position often needs `vm.prank(actor)` — factories take ownership via `_msgSender()`.
- Protocols pulling funds through **Permit2** need `token.approve(PERMIT2, max)` **and**
  `permit2.approve(token, spender, max, max)`.
- A protocol's own `maxBorrow()` can be *wider* than what the external market allows → wrap calls
  in `try/catch` and treat expected reverts as non-failures (`fail_on_revert = false`).
- Local `anvil` forks only; public RPCs rate-limit fuzz campaigns.
- Long runs: launch in the background — some shells kill the process group when the parent exits,
  taking `anvil` with it. Stop forks by PID (`for p in $(pgrep -f "^.*/anvil$"); do kill $p; done`),
  never with a long `pkill -f` pattern, which can match your own shell.
- `--invariant-runs` / `--invariant-depth` are not CLI flags in `forge` 1.5.x; use the
  `FOUNDRY_INVARIANT_RUNS` / `FOUNDRY_INVARIANT_DEPTH` environment variables instead.

## Docs

- [`docs/MR_FIX_COMMIT_CHECK.md`](docs/MR_FIX_COMMIT_CHECK.md) — *Is the claimed fix actually in
  the reviewed revision?* A repeatable check for remediation reports (English;
  [中文版](docs/MR_FIX_COMMIT_CHECK.zh.md)).
- [`scripts/check_fix_commits.sh`](scripts/check_fix_commits.sh) — the check as one command.

## Disclaimer

This project is a testing utility. It is **not** an audit, does not perform vulnerability
assessment or severity classification, and makes no claim about the security of any protocol it is
pointed at. Forked state is a snapshot: a passing campaign means "this rule held under the
sequences that were explored at this block", nothing more. You are responsible for complying with
the terms of service of any RPC endpoint, explorer or protocol you use with it.

MIT licensed — see [`LICENSE`](LICENSE).
