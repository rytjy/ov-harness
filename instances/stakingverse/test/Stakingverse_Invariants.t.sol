// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IStakingverseVault} from "../src/IStakingverseVault.sol";

/// @title StakingverseVault share-accounting invariant harness (fork-based, read-only).
/// Target (LUKSO mainnet, chain 42):
///   vault proxy  0x9F49a95b0c3c9e2A6c77a16C177928294c0F6F04
///   impl         0x1711b2e1b64f38ca33e51b717cfd27acd1bd2e2d
///   sLYX (LSP7)  0x8A3982f0A7d154D11a5f43EEc7F50E52eBBc8F7D
contract StakingverseHandler is Test {
    IStakingverseVault public vault;
    address[] public actorList;

    // --- ghosts ---
    uint256 public ghostDeposited;          // Σ msg.value accepted by deposit()
    uint256 public ghostWithdrawn;          // Σ LYX actually received by actors (withdraw + claim)
    uint256 public ghostPendingCreated;     // Σ delayed (queued) withdrawal amount
    uint256 public ghostDonated;            // Σ raw native transfers pushed at the vault
    uint256 public ghostDonationMovedAssets; // # donations that changed totalAssets() (should be 0)
    uint256 public ghostReverts;            // expected-path reverts (deposit cap, dust, nothing claimable)

    constructor(IStakingverseVault vault_, address[] memory actors_) {
        vault = vault_;
        actorList = actors_;
    }

    function actorCount() external view returns (uint256) {
        return actorList.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actorList[seed % actorList.length];
    }

    receive() external payable {}

    /// @notice actor deposits native LYX; shares go to the actor itself.
    function deposit(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 1e17, 100e18);
        // fund both the pranked actor and this handler: value is debited from the effective caller
        vm.deal(a, a.balance + amount);
        vm.deal(address(this), address(this).balance + amount);
        vm.prank(a);
        try vault.deposit{value: amount}(a) {
            ghostDeposited += amount;
        } catch {
            ghostReverts++;
        }
    }

    /// @notice actor redeems `amount` of balance (may be split into immediate + queued part).
    function withdraw(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        uint256 before = a.balance;
        vm.prank(a);
        try vault.withdraw(amount, a) {} catch {
            ghostReverts++;
            return;
        }
        uint256 got = a.balance - before;
        ghostWithdrawn += got;
        ghostPendingCreated += amount - got;
    }

    /// @notice claim whatever the vault marks as claimable for the actor.
    function claim(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        uint256 avail = vault.claimableBalanceOf(a);
        if (avail == 0) return;
        amount = bound(amount, 1, avail);
        uint256 before = a.balance;
        vm.prank(a);
        try vault.claim(amount, a) {} catch {
            ghostReverts++;
            return;
        }
        ghostWithdrawn += a.balance - before;
    }

    /// @notice donation: raw native transfer straight at the vault, must not reprice shares.
    function donate(uint256 amount) external {
        amount = bound(amount, 1e15, 50e18);
        uint256 assetsBefore = vault.totalAssets();
        vm.deal(address(this), address(this).balance + amount);
        (bool ok,) = address(vault).call{value: amount}("");
        if (!ok) {
            ghostReverts++;
            return;
        }
        ghostDonated += amount;
        if (vault.totalAssets() != assetsBefore) ghostDonationMovedAssets++;
    }

    /// @notice read-only "sync" probe: touch every accounting counter so state is observed each run.
    function sync() external view returns (uint256) {
        return vault.totalAssets() + vault.totalShares() + vault.totalUnstaked()
            + vault.totalPendingWithdrawal();
    }
}

contract Stakingverse_Invariants is Test {
    IStakingverseVault constant VAULT =
        IStakingverseVault(0x9F49a95b0c3c9e2A6c77a16C177928294c0F6F04);

    StakingverseHandler handler;

    function setUp() public {
        address[] memory actors = new address[](3);
        actors[0] = address(0xA11CE);
        actors[1] = address(0xB0B);
        actors[2] = address(0xC0FFEE);

        handler = new StakingverseHandler(VAULT, actors);
        targetContract(address(handler));
    }

    function _sumActorValue() internal view returns (uint256 bal, uint256 pend) {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address a = handler.actorList(i);
            bal += VAULT.balanceOf(a);
            pend += VAULT.pendingBalanceOf(a);
        }
    }

    /// I1 - the vault's raw native balance always covers the instantly-unstaked liability.
    function invariant_solvency_nativeBacksUnstaked() public view {
        assertGe(address(VAULT).balance, VAULT.totalUnstaked());
    }

    /// I2 - aggregate actor redemption claims never exceed total pool assets.
    function invariant_solvency_assetsCoverActorClaims() public view {
        (uint256 bal,) = _sumActorValue();
        assertLe(bal, VAULT.totalAssets());
    }

    /// I3 - no free lunch: actors cannot take out more LYX value than they put in.
    function invariant_noFreeLunch_ghostConservation() public view {
        (uint256 bal, uint256 pend) = _sumActorValue();
        assertLe(
            handler.ghostWithdrawn() + bal + pend,
            handler.ghostDeposited() + 1e3, // 1e3 wei dust tolerance for floor-rounding
            "actors extracted more value than deposited"
        );
    }

    /// I4 - rounding always favours the pool: balanceOf() floors, never rounds up.
    function invariant_rounding_favorsPool() public view {
        uint256 ts = VAULT.totalShares();
        if (ts == 0) return;
        uint256 ta = VAULT.totalAssets();
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address a = handler.actorList(i);
            assertLe(VAULT.balanceOf(a) * ts, VAULT.sharesOf(a) * ta);
        }
    }

    /// I5 - donation immunity (donation-reprice family): a raw native transfer into the vault
    ///      must not move totalAssets(), so share price cannot be inflated by donation.
    function invariant_donation_doesNotReprice() public view {
        assertEq(handler.ghostDonationMovedAssets(), 0, "donation repriced the pool");
    }
}
