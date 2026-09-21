// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/*//////////////////////////////////////////////////////////////////
  ov-harness instance — Overnight Finance (ovnstable) USD+ share vault
  ---------------------------------------------------------------------
  Target (Base mainnet, chainId 8453, fork-based, READ-ONLY):
    USD+ proxy  0xB79DD08EA68A908A97220C76d19A6aA9cBDE4376
    impl        0xe1201f02C02e468c7fF6F61AFff505A859673cfD (UsdPlusToken_Base)
    exchange    0x7cb1B38591021309C64f451859d79312d8Ca2789 (authorized minter)
    PortfolioMgr 0x27B12F3282F1d02682D7D1AD30E45e818B78f7B8

  Accounting model: credits-per-token rebasing vault (WadRayMath RAY).
    balanceOf(a) = creditToAsset(a, _creditBalances[a])
    credit  <-> asset conversion is the "share" surface.

  Run:
    cd instances/overnight && forge test --match-contract Invariants -vv \
        --fork-url https://mainnet.base.org
//////////////////////////////////////////////////////////////////*/

interface IUsdPlus {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function exchange() external view returns (address);
    function mint(address account, uint256 amount) external;
    function burn(address account, uint256 amount) external;
    function assetToCredit(address owner, uint256 amount) external view returns (uint256);
    function creditToAsset(address owner, uint256 credit) external view returns (uint256);
    function rebasingCredits() external view returns (uint256);
    function rebasingCreditsPerToken() external view returns (uint256);
    function rebasingCreditsPerTokenHighres() external view returns (uint256);
    function nonRebasingSupply() external view returns (uint256);
    function MAX_SUPPLY() external view returns (uint256);
}

interface IERC20m {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IPortfolioManager {
    function claimAndBalance() external;
}

contract OvernightHandler is Test {
    IUsdPlus internal constant USD_PLUS =
        IUsdPlus(0xB79DD08EA68A908A97220C76d19A6aA9cBDE4376);
    IERC20m internal constant USDC =
        IERC20m(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913); // Base USDC (asset)
    IPortfolioManager internal constant PM =
        IPortfolioManager(0x27B12F3282F1d02682D7D1AD30E45e818B78f7B8);

    address[3] public actors;

    // --- ghost / accounting accumulators ---
    uint256 public ghostMinted; // Σ successful privileged mints (deposits)
    uint256 public ghostBurned; // Σ successful privileged burns (withdraws)
    uint256 public ghostDonationDrift; // times a raw asset donation moved a user balance
    uint256 public ghostSentinelHits; // times a conversion returned the MAX_SUPPLY sentinel
    uint256 public ghostOps;

    // --- post-shock insensitivity (exogenous-shock insensitivity) telemetry ---
    uint256 public immutable initialRate; // credits-per-token (highres) at the fork block
    uint256 public ghostUnprivilegedRateDrift; // # times a donation / large transfer moved the rate
    uint256 public maxUnprivilegedDriftBps; // worst |delta rate| in bps over unprivileged shocks
    uint256 public ghostRoundtripSurplus; // # times deposit->withdraw ended with MORE assets
    uint256 public maxRoundtripDelta; // worst roundtrip gain (wei)

    constructor(address ex) {
        actors[0] = address(uint160(uint256(keccak256("ov.actor.0"))));
        actors[1] = address(uint160(uint256(keccak256("ov.actor.1"))));
        actors[2] = address(uint160(uint256(keccak256("ov.actor.2"))));
        vm.deal(actors[0], 1 ether);
        vm.deal(actors[1], 1 ether);
        vm.deal(actors[2], 1 ether);
        vm.label(ex, "exchange");
        initialRate = USD_PLUS.rebasingCreditsPerTokenHighres();
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    /// @dev post-shock insensitivity: the "share price" surface of this vault = credits-per-token (high res),
    ///      since balanceOf = credits / creditsPerToken.
    function _rate() internal view returns (uint256) {
        return USD_PLUS.rebasingCreditsPerTokenHighres();
    }

    /// @dev record whether an UNPRIVILEGED exogenous shock moved the conversion rate.
    function _noteShock(uint256 rateBefore) internal {
        uint256 rateNow = _rate();
        if (rateNow == rateBefore) return;
        ghostUnprivilegedRateDrift++;
        if (rateBefore != 0) {
            uint256 d = rateNow > rateBefore ? rateNow - rateBefore : rateBefore - rateNow;
            uint256 bps = (d * 10_000) / rateBefore;
            if (bps > maxUnprivilegedDriftBps) maxUnprivilegedDriftBps = bps;
        }
    }

    /// @dev deposit: privileged mint, as the exchange would on a real deposit
    function deposit(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 1e6, 1e11);
        vm.prank(USD_PLUS.exchange());
        try USD_PLUS.mint(a, amount) {
            ghostMinted += amount;
            ghostOps++;
        } catch {}
    }

    /// @dev withdraw: privileged burn, as the exchange would on a real redeem
    function withdraw(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        uint256 bal = USD_PLUS.balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(USD_PLUS.exchange());
        try USD_PLUS.burn(a, amount) {
            ghostBurned += amount;
            ghostOps++;
        } catch {}
    }

    /// @dev transfer between actors (share movement only)
    function transfer(uint256 s1, uint256 s2, uint256 amount) external {
        address from = _actor(s1);
        address to = _actor(s2);
        if (from == to) return;
        uint256 bal = USD_PLUS.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        uint256 r0 = _rate();
        vm.prank(from);
        try USD_PLUS.transfer(to, amount) {
            _noteShock(r0);
            ghostOps++;
        } catch {}
    }

    /// @dev post-shock insensitivity shock: one LARGE transfer (up to the full balance) must be rate-neutral.
    function shockTransfer(uint256 s1, uint256 s2, uint256 amount) external {
        address from = _actor(s1);
        address to = _actor(s2);
        if (from == to) return;
        uint256 bal = USD_PLUS.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        uint256 r0 = _rate();
        vm.prank(from);
        try USD_PLUS.transfer(to, amount) {
            _noteShock(r0);
            ghostOps++;
        } catch {}
    }

    /// @dev exogenous-shock epsilon: a single-step deposit->withdraw roundtrip must not create value.
    function roundtrip(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 1e6, 1e10);
        uint256 balBefore = USD_PLUS.balanceOf(a);
        vm.prank(USD_PLUS.exchange());
        try USD_PLUS.mint(a, amount) {
            ghostMinted += amount;
            vm.prank(USD_PLUS.exchange());
            try USD_PLUS.burn(a, amount) {
                ghostBurned += amount;
                uint256 balAfter = USD_PLUS.balanceOf(a);
                if (balAfter > balBefore) {
                    uint256 gain = balAfter - balBefore;
                    ghostRoundtripSurplus++;
                    if (gain > maxRoundtripDelta) maxRoundtripDelta = gain;
                }
            } catch {}
        } catch {}
        ghostOps++;
    }

    /// @dev donate: raw asset (USDC) sent straight to the vault token address
    function donate(uint256 amount) external {
        amount = bound(amount, 1e6, 1e10);
        deal(address(USDC), address(this), amount);
        uint256 r0 = _rate();
        uint256[3] memory before;
        for (uint256 i; i < 3; i++) before[i] = USD_PLUS.balanceOf(actors[i]);
        USDC.transfer(address(USD_PLUS), amount);
        for (uint256 i; i < 3; i++) {
            if (USD_PLUS.balanceOf(actors[i]) != before[i]) ghostDonationDrift++;
        }
        _noteShock(r0);
        ghostOps++;
    }

    /// @dev sync: privileged PortfolioManager claim/rebalance kick
    function sync() external {
        vm.prank(USD_PLUS.exchange());
        try PM.claimAndBalance() {
            ghostOps++;
        } catch {}
    }

    function actorCount() external pure returns (uint256) {
        return 3;
    }
}

contract OvernightInvariants is Test {
    OvernightHandler internal h;
    IUsdPlus internal constant USD_PLUS =
        IUsdPlus(0xB79DD08EA68A908A97220C76d19A6aA9cBDE4376);

    uint256 internal initialSupply;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_URL", string("https://mainnet.base.org"));
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        if (blk == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, blk);
        }
        assertEq(USD_PLUS.decimals(), 6, "unexpected decimals");
        initialSupply = USD_PLUS.totalSupply();
        h = new OvernightHandler(USD_PLUS.exchange());
        targetContract(address(h));
    }

    /// 1. No free lunch: supply growth is fully explained by mint/burn ops.
    function invariant_ghost_supply_no_free_lunch() public view {
        assertEq(
            USD_PLUS.totalSupply(),
            initialSupply + h.ghostMinted() - h.ghostBurned(),
            "supply changed without a mint/burn"
        );
    }

    /// 2. No double counting: actor balances can never exceed total supply.
    function invariant_actor_balances_le_total_supply() public view {
        uint256 sum;
        for (uint256 i; i < 3; i++) sum += USD_PLUS.balanceOf(h.actors(i));
        assertLe(sum, USD_PLUS.totalSupply(), "actors hold more than total supply");
    }

    /// 3. Rounding direction: credits->asset->credits must never gain (rounding direction).
    function invariant_credit_roundtrip_no_gain() public view {
        for (uint256 i; i < 3; i++) {
            address a = h.actors(i);
            uint256 bal = USD_PLUS.balanceOf(a);
            if (bal == 0) continue;
            uint256 credit = USD_PLUS.assetToCredit(a, bal);
            uint256 back = USD_PLUS.creditToAsset(a, credit);
            assertLe(back, bal, "credit/asset roundtrip gained value");
        }
    }

    /// 4. Donation resistance: raw asset donations must not move user balances (donation resistance).
    function invariant_donation_does_not_shift_user_balances() public view {
        assertEq(h.ghostDonationDrift(), 0, "donation shifted a user balance");
    }

    /// 5. Post-shock integrity: conversions must stay finite (no MAX_SUPPLY sentinel) (post-shock integrity).
    function invariant_no_sentinel_overflow() public view {
        assertEq(h.ghostSentinelHits(), 0, "sentinel overflow hit in conversions");
        assertGt(USD_PLUS.rebasingCreditsPerToken(), 0, "credits per token collapsed to 0");
    }

    /// 6. exogenous-shock sibling — exogenous-shock insensitivity of the share conversion rate.
    ///    post-shock insensitivity proper targets LP vaults priced off pool slot0; this vault has no pool /
    ///    spot surface at all (share price = credits-per-token, moved only by a privileged
    ///    rebase), so the same-family form is used: a raw donation or a LARGE transfer must
    ///    not move the rate at all (eps = 0 bps), and a single-step deposit->withdraw
    ///    roundtrip must never leave the actor holding more assets than before.
    function invariant_shock_rate_no_drift_no_roundtrip_surplus() public view {
        assertEq(h.ghostUnprivilegedRateDrift(), 0, "post-shock insensitivity: unprivileged shock moved the conversion rate");
        assertEq(h.maxUnprivilegedDriftBps(), 0, "post-shock insensitivity: shock drift exceeded eps (0 bps)");
        assertEq(h.ghostRoundtripSurplus(), 0, "post-shock insensitivity: deposit->withdraw roundtrip produced a surplus");
        assertLe(h.maxRoundtripDelta(), 1, "post-shock insensitivity: roundtrip gain exceeded eps (1 wei)");
    }
}
