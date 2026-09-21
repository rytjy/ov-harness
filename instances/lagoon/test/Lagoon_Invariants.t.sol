// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/*//////////////////////////////////////////////////////////////////
  ov-harness instance — Lagoon (ERC4626-flavoured async vault, v0.6.0)
  -----------------------------------------------------------------
  Target : Tulipa USDC vault (proxy) on Ethereum mainnet
  Proxy  : 0xcE0b790ae0d8cF91e01f3FB69025e14569b574f3
  Impl   : 0x6C77c47FB8168E22976C3B0338CB1769c952249f (shared "Vault" impl)
  Flow   : ERC-7540 async (requestDeposit -> settleDeposit -> claimShares)
  Run    : cd instances/lagoon && forge test --match-contract Invariants -vv \
                   --fork-url https://eth.drpc.org
//////////////////////////////////////////////////////////////////*/

interface IERC20m {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface ILagoonVault {
    // ERC20 share token
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
    // ERC4626 / ERC7540 accounting
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function maxDeposit(address) external view returns (uint256);
    // async (7540) actions
    function requestDeposit(uint256 assets, address controller, address owner) external payable returns (uint256);
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256);
    function claimSharesOnBehalf(address[] calldata controllers) external;
    function claimAssetsOnBehalf(address[] calldata controllers) external;
    function claimSharesAndRequestRedeem(uint256 shares) external;
    function settleDeposit(uint256) external;
    function settleRedeem(uint256) external;
    function pendingDepositRequest(uint256, address) external view returns (uint256);
    function claimableDepositRequest(uint256, address) external view returns (uint256);
    function updateNewTotalAssets(uint256) external;
    // sync ERC4626 path (may be disabled: ERC7540PreviewDepositDisabled)
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
}

/* ------------------------------- handler ------------------------------ */

contract LagoonHandler is Test {
    address public constant VAULT = 0xcE0b790ae0d8cF91e01f3FB69025e14569b574f3;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant OWNER = 0x70a784BC7EC9eB2E6b219C9e1A7cA8Ecb779FFac; // vault owner (role holder)
    address public constant SAFE = 0x4018327d5BFee6636509b2a4b5caC2D3E7B641DD; // vault custody Safe / operator

    address[3] public actors;

    // ghost accumulators — the "no free lunch" ledger
    uint256 public ghostAssetsIn; // assets sent into the vault (deposits + donations)
    uint256 public ghostAssetsOut; // assets pulled back out (claims + redeems)
    mapping(address => uint256) public ghostInOf;
    mapping(address => uint256) public ghostOutOf;

    uint256 public calls;
    uint256 public settleAttempts;
    uint256 public successOps; // actions that actually mutated vault state
    bool public everDeposited;

    constructor() {
        actors[0] = makeAddr("lp0");
        actors[1] = makeAddr("lp1");
        actors[2] = makeAddr("lp2");
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function _giveAndApprove(address who, uint256 amt) internal {
        deal(USDC, who, amt);
        vm.prank(who);
        IERC20m(USDC).approve(VAULT, amt);
    }

    /* ------------------------- core actions ------------------------- */

    /// deposit: deal USDC, request async deposit into the vault
    function requestDeposit(uint256 seed, uint256 amt) external {
        calls++;
        address a = _actor(seed);
        amt = bound(amt, 1e6, 500_000e6); // 1 .. 500k USDC
        _giveAndApprove(a, amt);
        vm.prank(a);
        try ILagoonVault(VAULT).requestDeposit(amt, a, a) {
            ghostAssetsIn += amt;
            ghostInOf[a] += amt;
            everDeposited = true;
            successOps++;
        } catch {}
    }

    /// sync ERC4626 deposit (expected to revert while 7540 path is active)
    function syncDeposit(uint256 seed, uint256 amt) external {
        calls++;
        address a = _actor(seed);
        amt = bound(amt, 1e6, 100_000e6);
        _giveAndApprove(a, amt);
        vm.prank(a);
        try ILagoonVault(VAULT).deposit(amt, a) {
            ghostAssetsIn += amt;
            ghostInOf[a] += amt;
            everDeposited = true;
            successOps++;
        } catch {}
    }

    /// settle: the "settle/sync" family, driven by a role holder
    function settle(uint256 amt) external {
        calls++;
        settleAttempts++;
        amt = bound(amt, 0, 1e30);
        vm.startPrank(SAFE);
        try ILagoonVault(VAULT).settleDeposit(amt) {} catch {}
        try ILagoonVault(VAULT).settleRedeem(amt) {} catch {}
        vm.stopPrank();
    }

    /// re-mark the vault valuation (settle/sync class; no exogenous value created)
    function syncValuation() external {
        calls++;
        uint256 ta = ILagoonVault(VAULT).totalAssets();
        vm.startPrank(OWNER);
        try ILagoonVault(VAULT).updateNewTotalAssets(ta) {} catch {}
        vm.stopPrank();
    }

    /// claim shares / assets owed to the actors
    function claim() external {
        calls++;
        uint256[3] memory before;
        for (uint256 i = 0; i < 3; i++) before[i] = IERC20m(USDC).balanceOf(actors[i]);

        address[] memory who = new address[](3);
        who[0] = actors[0];
        who[1] = actors[1];
        who[2] = actors[2];

        vm.startPrank(SAFE);
        try ILagoonVault(VAULT).claimSharesOnBehalf(who) {} catch {}
        try ILagoonVault(VAULT).claimAssetsOnBehalf(who) {} catch {}
        vm.stopPrank();

        for (uint256 i = 0; i < 3; i++) {
            uint256 after_ = IERC20m(USDC).balanceOf(actors[i]);
            if (after_ > before[i]) {
                uint256 out = after_ - before[i];
                ghostAssetsOut += out;
                ghostOutOf[actors[i]] += out;
                successOps++;
            }
        }
    }

    /// request an async redeem of the actor's shares
    function requestRedeem(uint256 seed, uint256 shareFrac) external {
        calls++;
        address a = _actor(seed);
        uint256 bal = ILagoonVault(VAULT).balanceOf(a);
        if (bal == 0) return;
        uint256 shares = bound(shareFrac, 1, bal);
        vm.prank(a);
        try ILagoonVault(VAULT).requestRedeem(shares, a, a) {
            successOps++;
        } catch {}
    }

    /// synchronous ERC4626 redeem (may be disabled by the 7540 mode)
    function redeemNow(uint256 seed, uint256 shareFrac) external {
        calls++;
        address a = _actor(seed);
        uint256 bal = ILagoonVault(VAULT).balanceOf(a);
        if (bal == 0) return;
        uint256 shares = bound(shareFrac, 1, bal);
        uint256 b0 = IERC20m(USDC).balanceOf(a);
        vm.prank(a);
        try ILagoonVault(VAULT).redeem(shares, a, a) {
            uint256 b1 = IERC20m(USDC).balanceOf(a);
            if (b1 > b0) {
                ghostAssetsOut += (b1 - b0);
                ghostOutOf[a] += (b1 - b0);
                successOps++;
            }
        } catch {}
    }

    /// direct donation of assets to the vault (no shares received)
    function donate(uint256 seed, uint256 amt) external {
        calls++;
        address a = _actor(seed);
        amt = bound(amt, 1e6, 50_000e6);
        deal(USDC, a, amt);
        vm.prank(a);
        IERC20m(USDC).transfer(VAULT, amt);
        ghostAssetsIn += amt;
        ghostInOf[a] += amt;
    }

    /// move shares between actors (internal transfer — must not create value)
    function transferShares(uint256 seed, uint256 shareFrac) external {
        calls++;
        address from = _actor(seed);
        address to = _actor(seed + 1);
        uint256 bal = ILagoonVault(VAULT).balanceOf(from);
        if (bal == 0) return;
        uint256 shares = bound(shareFrac, 1, bal);
        vm.prank(from);
        try ILagoonVault(VAULT).transfer(to, shares) {} catch {}
    }

    function actorCount() external pure returns (uint256) {
        return 3;
    }
}

/* ------------------------------ invariants ----------------------------- */

contract LagoonInvariants is Test {
    address constant VAULT = 0xcE0b790ae0d8cF91e01f3FB69025e14569b574f3;
    address constant OWNER = 0x70a784BC7EC9eB2E6b219C9e1A7cA8Ecb779FFac;
    address constant SAFE = 0x4018327d5BFee6636509b2a4b5caC2D3E7B641DD;
    uint256 constant FORK_BLOCK = 0; // 0 = latest

    LagoonHandler handler;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_URL", string("https://eth.drpc.org"));
        if (FORK_BLOCK != 0) vm.createSelectFork(rpc, FORK_BLOCK);
        else vm.createSelectFork(rpc);

        handler = new LagoonHandler();
        targetContract(address(handler));

        address[] memory selectors = new address[](1);
        selectors[0] = address(handler);
        bytes4[] memory sels = new bytes4[](9);
        sels[0] = LagoonHandler.requestDeposit.selector;
        sels[1] = LagoonHandler.syncDeposit.selector;
        sels[2] = LagoonHandler.settle.selector;
        sels[3] = LagoonHandler.syncValuation.selector;
        sels[4] = LagoonHandler.claim.selector;
        sels[5] = LagoonHandler.requestRedeem.selector;
        sels[6] = LagoonHandler.redeemNow.selector;
        sels[7] = LagoonHandler.donate.selector;
        sels[8] = LagoonHandler.transferShares.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    /// 1. No free lunch: aggregate value pulled out may never exceed value put in.
    function invariant_no_free_lunch() public view {
        assertLe(handler.ghostAssetsOut(), handler.ghostAssetsIn(), "withdrew more assets than deposited+donated");
    }

    /// 2. First-depositor / inflation guard (inflation guard): shares outstanding imply backing.
    function invariant_shares_are_backed() public view {
        uint256 ts = ILagoonVault(VAULT).totalSupply();
        if (ts > 0) assertGt(ILagoonVault(VAULT).totalAssets(), 0, "shares outstanding with zero assets");
    }

    /// 3. Rounding direction (assets->shares->assets) must never favour the user.
    function invariant_roundtrip_assets_le() public view {
        uint256 x = 1e6; // 1 USDC
        uint256 shares = ILagoonVault(VAULT).convertToShares(x);
        uint256 back = ILagoonVault(VAULT).convertToAssets(shares);
        assertLe(back, x, "assets round-trip inflated");
    }

    /// 4. Rounding direction (shares->assets->shares) must never favour the user.
    function invariant_roundtrip_shares_le() public view {
        uint256 s = 1e18;
        uint256 assets = ILagoonVault(VAULT).convertToAssets(s);
        uint256 back = ILagoonVault(VAULT).convertToShares(assets);
        assertLe(back, s, "shares round-trip inflated");
    }

    /// 5. Double-count guard: the whole share supply cannot claim more than reported assets.
    function invariant_supply_claim_le_totalAssets() public view {
        uint256 ts = ILagoonVault(VAULT).totalSupply();
        if (ts == 0) return;
        uint256 claim = ILagoonVault(VAULT).convertToAssets(ts);
        assertLe(claim, ILagoonVault(VAULT).totalAssets(), "supply claims more than totalAssets");
    }

    /* ------------------------- liveness (plain tests) -------------------------
       "the fuzzer really touched the vault" cannot be an invariant (a short
       sequence legitimately has zero successful ops), so prove it explicitly. */

    /// requestDeposit must actually pull real USDC into the vault on the fork
    function test_liveness_requestDeposit_movesAssets() public {
        handler.requestDeposit(0, 10_000e6);
        assertGt(handler.ghostAssetsIn(), 0, "requestDeposit never moved assets");
    }

    /// full async round-trip: request -> (valuation refresh) -> settle -> claim shares
    function test_liveness_asyncDeposit_roundTrip() public {
        address a = handler.actors(0);
        handler.requestDeposit(0, 10_000e6);
        uint256 moved = handler.ghostAssetsIn();
        vm.startPrank(SAFE);
        try ILagoonVault(VAULT).updateNewTotalAssets(ILagoonVault(VAULT).totalAssets()) {} catch {}
        try ILagoonVault(VAULT).settleDeposit(moved) {} catch {}
        vm.stopPrank();
        handler.claim();
        assertGt(ILagoonVault(VAULT).balanceOf(a), 0, "async deposit never minted shares");
    }

    /// diagnostic (log-only): surface where the async settle path stops
    function test_diag_settle() public {
        address a = handler.actors(0);
        handler.requestDeposit(0, 10_000e6);
        uint256 moved = handler.ghostAssetsIn();
        console2.log("ghostAssetsIn", moved);
        uint256 taBefore = ILagoonVault(VAULT).totalAssets();
        vm.startPrank(SAFE);
        try ILagoonVault(VAULT).updateNewTotalAssets(taBefore) {
            console2.log("updateNewTotalAssets OK, ta=", ILagoonVault(VAULT).totalAssets());
        } catch { console2.log("updateNewTotalAssets REVERTED"); }
        try ILagoonVault(VAULT).settleDeposit(moved) {
            console2.log("settleDeposit OK");
        } catch { console2.log("settleDeposit REVERTED"); }
        vm.stopPrank();
        console2.log("claimableDepositRequest(0,a)", ILagoonVault(VAULT).claimableDepositRequest(0, a));
        handler.claim();
        console2.log("sharesAfterClaim", ILagoonVault(VAULT).balanceOf(a));
    }
}
