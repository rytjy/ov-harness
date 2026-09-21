# ov-harness instance — Overnight Finance (ovnstable) USD+ share vault

Fork-based, **read-only** (no broadcast, no keys, no testnet).

## Target

| field | value |
|---|---|
| Chain | **Base mainnet (chainId 8453)** |
| Vault (proxy) | `0xB79DD08EA68A908A97220C76d19A6aA9cBDE4376` |
| Implementation | `0xe1201f02C02e468c7fF6F61AFff505A859673cfD` (`UsdPlusToken_Base`) |
| Authorized exchange/minter | `0x7cb1B38591021309C64f451859d79312d8Ca2789` |
| PortfolioManager | `0x27B12F3282F1d02682D7D1AD30E45e818B78f7B8` |
| Underlying (donation asset) | Base USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| On-chain state | `symbol=USD+`, `decimals=6`, `totalSupply=412,918.366605`, not paused |

**Source provenance.** Sourcify: proxy = `exact_match`; impl = `match`
(both `creationMatch`+`runtimeMatch`, verified 2025-10-17). Repo
`ovnstable/ovnstable-core-contracts` (`pkg/core/contracts/UsdPlusToken_Base.sol`, 892 lines);
in-scope impl SLOC ≈ **892** (≤2500). Accounting = **credits-per-token rebasing**
(WadRayMath RAY): `balanceOf(a) = creditToAsset(a, _creditBalances[a])`.

> **Why Base.** Overnight's USD+ has no Ethereum-mainnet deployment: the published address list
> (`docs.overnight.fi/advanced/contract-addresses`) defaults to Base, and the repo's deployments
> cover arbitrum/base/bsc/linea/optimism/polygon/zksync/blast only. Casting the documented
> addresses on Ethereum mainnet returns "does not have any code". This instance therefore pins
> the real, TVL-holding Base USD+ vault (still a share/accounting vault with a fee-taking share
> token).

## Invariants (6)

1. `invariant_ghost_supply_no_free_lunch` — `totalSupply == initialSupply + Σmint − Σburn` (no free lunch / no double count).
2. `invariant_actor_balances_le_total_supply` — Σ actor balances ≤ `totalSupply`.
3. `invariant_credit_roundtrip_no_gain` — `creditToAsset(a, assetToCredit(a, b)) ≤ b` (rounding direction).
4. `invariant_donation_does_not_shift_user_balances` — raw USDC donation to the vault moves no user balance (donation resistance).
5. `invariant_no_sentinel_overflow` — conversions never return the `MAX_SUPPLY` sentinel; `rebasingCreditsPerToken > 0` (post-shock insensitivity post-shock integrity).
6. `invariant_shock_rate_no_drift_no_roundtrip_surplus` — **exogenous-shock sibling** (exogenous-shock
   insensitivity of the share conversion rate). A raw USDC donation or a LARGE transfer between actors
   must not move the rate at all (`rebasingCreditsPerTokenHighres`, ε = 0 bps), and a single-step
   `mint → burn` roundtrip must never leave the actor holding more assets than before (gain ≤ 1 wei).
   > **适配性说明（如实）**：post-shock insensitivity 原形针对 **LP-vault 按 Uniswap `slot0` 瞬时价估值**；本靶**不是**
   > LP/现货定价型金库——没有池、没有 `slot0`/sqrtPriceX96/tick，份额价 = credits-per-token，只被
   > 特权 rebase 推动。因此**原形不适用**，采用**同族形式**： exogenous shock（donation / 大额 transfer）
   > 对换算率零影响 + deposit→withdraw 单步往返无正盈余。特权 rebase（`sync`）不纳入 ε 断言，
   > 它本来就有权改率；但它无法被用来做往返套利 —— 这正是第 6 条第二条断言覆盖的。

Handler: **3 actors**, actions `deposit` (prank exchange → `mint`), `withdraw` (prank exchange → `burn`),
`transfer` / `shockTransfer` (rate-neutral large transfer), `donate` (USDC → vault),
`roundtrip` (mint→burn single step), `sync` (prank exchange → `PortfolioManager.claimAndBalance`).
Ghost accumulators: `ghostMinted`, `ghostBurned`, `ghostDonationDrift`, `ghostSentinelHits`,
`ghostUnprivilegedRateDrift`, `maxUnprivilegedDriftBps`, `ghostRoundtripSurplus`, `maxRoundtripDelta`.

## How to run (开箱可复现)

- **RPC 走环境变量** `RPC_URL`（默认 `https://mainnet.base.org`），**fork 区块**走 `FORK_BLOCK`（未设 = 取最新）。
- **钉死区块**：`FORK_BLOCK=51544475`（2026-09-20 12:2x 抓到的高度，本实例记录的那次运行就用它）。
- **一条命令**：

```bash
cd instances/overnight && \
  RPC_URL=${RPC_URL:-https://base.drpc.org} FORK_BLOCK=51544475 \
  forge test --match-contract OvernightInvariants -vv
```

⚠️ **公共 RPC 是这条流水线的真瓶颈**（实测 2026-09-20）：`mainnet.base.org` 本机超时；
`base-rpc.publicnode.com` 请求历史区块 → `403 Archive requests require a personal token`；
`base.meowrpc.com` → `429 Too Many Requests`；`base.drpc.org` 能读状态但高请求量下会**静默挂死**
（anvil/forge CPU ≈ 0）。**稳跑姿势 = 本地 fork**（只有首次拉状态走网络）：

```bash
anvil --fork-url https://base-rpc.publicnode.com --fork-block-number 51544475 --port 8545 --silent &
cd instances/overnight && RPC_URL=http://127.0.0.1:8545 FOUNDRY_INVARIANT_RUNS=2 FOUNDRY_INVARIANT_DEPTH=8 \
  forge test --match-contract OvernightInvariants -vv
# 按 PID 收尾（不要 pkill -f 长串 —— 会杀掉你自己那条 shell）：
for p in $(pgrep -f "^.*/anvil$"); do kill $p; done
```

> 提示：`--invariant-runs/--invariant-depth` 在 forge v1.5.1 **不是合法 CLI flag**；调小规模用
> `FOUNDRY_INVARIANT_RUNS` / `FOUNDRY_INVARIANT_DEPTH` 环境变量覆盖 `foundry.toml`（本实例默认 10/40）。

## Result

```
Ran 6 tests for test/Overnight_Invariants.t.sol:OvernightInvariants
[PASS] invariant_actor_balances_le_total_supply() (runs: 10, calls: 400, reverts: 0)
[PASS] invariant_credit_roundtrip_no_gain() (runs: 10, calls: 400, reverts: 0)
[PASS] invariant_donation_does_not_shift_user_balances() (runs: 10, calls: 400, reverts: 0)
[PASS] invariant_ghost_supply_no_free_lunch() (runs: 10, calls: 400, reverts: 0)
[PASS] invariant_no_sentinel_overflow() (runs: 10, calls: 400, reverts: 0)
[PASS] invariant_shock_rate_no_drift_no_roundtrip_surplus() (runs: 10, calls: 400, reverts: 0)
Suite result: ok. 6 passed; 0 failed; 0 skipped; finished in 118.52s (689.31s CPU time)
```

**No counterexample found** —— 6 条不变量在 **runs=10 / depth=40（每条 400 calls）** 的 campaign 全部成立；
`reverts: 0` 说明 handler 每个动作都真实执行过（不是靠 revert 混过去）。

> 复现路径（实测 2026-09-20）：先 `RPC_URL=http://127.0.0.1:8545 FOUNDRY_INVARIANT_RUNS=2 FOUNDRY_INVARIANT_DEPTH=8`
> 跑一遍小规模把 fork 状态预热进本地 anvil，再跑满配置 —— 全程公共 RPC 只在预热阶段被少量命中。
> 新不变量 `invariant_shock_rate_no_drift_no_roundtrip_surplus` 已同时出现在小规模与满配置两次运行结果里。
