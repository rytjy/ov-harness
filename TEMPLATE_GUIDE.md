# Add an instance in ~10 minutes

Goal: turn one deployed target into a **read-only fork + reproducible** stateful invariant instance.

Blueprint to copy: `instances/overnight/` (a rebasing share vault, 6 invariants, all PASS).

## Steps

1. `cp -r instances/overnight instances/<name> && rm -rf instances/<name>/{out,cache}` (keep its
   `foundry.toml`, including `libs = ["lib", "../../lib"]`).
2. Change **only three things**:
   - **Target addresses** — the `internal constant` block at the top of
     `test/<Name>_Invariants.t.sol` (vault/proxy, implementation, assets, interoperating
     contracts), plus the address block in the file header. Use a minimal interface
     (`interface I<Vault>`) — you do not need the target's source.
   - **Chain + pinned block** — the `RPC_URL` default (`vm.envOr`) in `setUp()` and `FORK_BLOCK`
     in the instance README.
   - **Handler action set + invariant functions** — actions are the protocol's *external entry
     points* (deposit/withdraw/sync/burn/transfer/…). Each action: `bound()` its arguments, wrap
     in `try/catch`, advance a ghost counter on success. For invariants, start with the three
     dumbest possible ones: a global total equals the sum of the local components; assets equal
     the accounting; nobody gets value from nothing.
3. `forge build` — fail fast on syntax before a 5-minute fuzz campaign.
4. `forge test --match-contract <Name>Invariants -vv` (see the instance README's "How to run").
5. Backfill the instance README: chain / vault(proxy) / implementation / verification level /
   number of invariants / the **verbatim** result output.
6. Add a row to the table in the top-level `README.md` — only for instances that actually run
   clean end to end. If it does not run, say so in its README instead of hiding it.

## Gotchas (all of these were hit in practice)

- **Dependency:** run `forge install foundry-rs/forge-std` once at the repo root; each instance
  finds it through `libs = ["lib", "../../lib"]` in its own `foundry.toml`. A remapping pointing
  outside the project root (`forge-std/=../lib/forge-std/src/`) does *not* resolve in `forge` 1.5.x.
- **RPC limits:** many public endpoints reject historical-block requests (`403 Archive requests
  require a personal token`) or rate-limit (`429`); some stall silently with CPU ≈ 0. Prefer a
  local fork: `anvil --fork-url <node> --fork-block-number <N> --port 8545 --silent &` then
  `RPC_URL=http://127.0.0.1:8545 forge test …`.
- **Pinning a block is not free:** most public nodes charge archive access once the block is not
  the chain head. Either use an archive-capable endpoint, or omit `FORK_BLOCK` and let
  `createSelectFork(rpc)` take the latest block (less reproducible).
- **Verified source is a semantic reference only:** indentation/formatting may differ from what was
  deployed. Use it to understand rebasing / rounding / precision logic; proving "deployed code ==
  reviewed code" is the job of `scripts/byte_diff.md` — do not conflate the two.
- **Read-only fork means no fake value:** `deal()` an asset only to simulate "the attacker brings
  its own funds" (the donation action in `instances/overnight`). **Never** `deal()` a
  protocol-derived asset (aToken / shares / debt receipt) — it creates value that does not exist
  and produces false positives. Protocol-internal assets must come through the protocol's own
  entry points (mint/deposit/borrow).
- **`fail_on_revert = false`** with `try/catch` on every external call, otherwise a pile of
  expected reverts drowns the real signal.
- **Stop anvil by PID**, not with a long `pkill -f` pattern (the pattern can match the shell
  running your own command): `for p in $(pgrep -f "^.*/anvil$"); do kill $p; done`.
- **Invariants must hold always:** identities, monotonicity, bounds. Do not assert "expected"
  states that can legitimately fail (e.g. `totalAssets > 0` on a legitimately empty vault).

## Acceptance checklist

- [ ] Targets are public, verified deployments; addresses + chain id + fork block are in the README.
- [ ] `forge build` clean; `forge test --match-contract <Name>Invariants -vv` — every invariant
      either PASSes or is documented as a known violation with its shrunk sequence.
      (When one fails: distinguish a real break / a badly written invariant / a missing
      precondition in the handler.)
- [ ] README lists every invariant with a one-line explanation and the verbatim result output.
- [ ] The command in the README is a single line that a stranger can paste and run.
- [ ] At least one invariant covers the **shock / rounding / roundtrip** family — that is where
      the interesting states live.
