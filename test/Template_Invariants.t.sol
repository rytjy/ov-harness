// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/*//////////////////////////////////////////////////////////////////
  ov-harness template — stateful fork invariant harness
  ---------------------------------------------------------------
  Fill in the FINANCE constants for your target, then run:
    RPC_URL=http://127.0.0.1:8545 forge test --match-contract TemplateInvariants -vv
  See ../README.md + ../scripts/byte_diff.md for the full workflow.
//////////////////////////////////////////////////////////////////*/

/* ------------------------- minimal interfaces ------------------------- */

interface IERC20m {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @dev The "subject": a position-managing contract driven by one actor (borrower/owner).
interface ISubject {
    function deposit(uint256 assets) external;
    function withdraw(uint256 assets, address receiver) external;
    function borrow(uint256 amount, address receiver) external;
    function repay(uint256 amount) external;
    function liquidate() external;
    function canLiquidate() external view returns (bool);
    function totalAssetsDepositedOrReserved() external view returns (uint256);
    function maxRelease() external view returns (uint256);
    function maxRepay() external view returns (uint256);
    function maxBorrow() external view returns (uint256);
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/* ------------------------------- handler ------------------------------ */

contract TemplateHandler is Test {
    address public immutable subject; // the position contract under test
    address public immutable actor; // borrower / owner of the subject
    address public immutable liquidator;
    uint256 public immutable BASE_PRICE; // oracle price at fork block (1e8 or protocol scale)
    address public immutable ORACLE; // price oracle the protocol reads

    uint256 public calls;
    bool public broken;
    string public brokenReason;
    bool public exogenous; // did a price/time shock happen?

    constructor(address _subject, address _actor, address _liquidator, address _oracle, uint256 _basePrice) {
        subject = _subject;
        actor = _actor;
        liquidator = _liquidator;
        ORACLE = _oracle;
        BASE_PRICE = _basePrice;
        vm.startPrank(_actor);
        // permit2 approvals if the protocol pulls funds that way
        IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3).approve(
            address(0), _subject, type(uint160).max, type(uint48).max
        );
        vm.stopPrank();
    }

    /* ------------- invariant helpers (mirror the protocol's own guard) ------------- */

    function _excessAndCollateral() internal view returns (uint256 E, uint256 C) {
        uint256 repay = ISubject(subject).maxRepay();
        uint256 borrowCap = ISubject(subject).maxBorrow();
        E = repay > borrowCap ? repay - borrowCap : 0;
        uint256 ta = ISubject(subject).totalAssetsDepositedOrReserved();
        uint256 rel = ISubject(subject).maxRelease();
        C = ta > rel ? ta - rel : 0;
    }

    /// @dev "the guard must never be bypassed": E/C may not worsen across a successful op
    function _checkNonWorsening(uint256 E0, uint256 C0) internal {
        (uint256 E1, uint256 C1) = _excessAndCollateral();
        bool ok = (E0 == 0) ? (E1 == 0) : (E1 * C0 <= E0 * C1);
        if (!ok) {
            broken = true;
            brokenReason = "E/C worsened";
        }
    }

    /* ------------------------------- actions ------------------------------- */

    function deposit(uint256 amt) external {
        calls++;
        amt = bound(amt, 1e15, 20e18);
        (uint256 E0, uint256 C0) = _excessAndCollateral();
        vm.prank(actor);
        try ISubject(subject).deposit(amt) {
            _checkNonWorsening(E0, C0);
        } catch {} // expected reverts (caps, guards) are not failures
    }

    function withdraw(uint256 amt) external {
        calls++;
        uint256 ta = ISubject(subject).totalAssetsDepositedOrReserved();
        uint256 rel = ISubject(subject).maxRelease();
        if (ta <= rel) return;
        amt = bound(amt, 1, ta - rel);
        (uint256 E0, uint256 C0) = _excessAndCollateral();
        vm.prank(actor);
        try ISubject(subject).withdraw(amt, actor) {
            _checkNonWorsening(E0, C0);
        } catch {}
    }

    function borrow(uint256 amt) external {
        calls++;
        uint256 cap = ISubject(subject).maxBorrow();
        if (cap == 0) return;
        amt = bound(amt, 1, cap > 1e21 ? 1e21 : cap);
        (uint256 E0, uint256 C0) = _excessAndCollateral();
        vm.prank(actor);
        try ISubject(subject).borrow(amt, actor) {
            _checkNonWorsening(E0, C0);
        } catch {}
    }

    function repay(uint256 amt) external {
        calls++;
        uint256 max = ISubject(subject).maxRepay();
        if (max == 0) return;
        amt = bound(amt, 1, max);
        (uint256 E0, uint256 C0) = _excessAndCollateral();
        vm.prank(actor);
        try ISubject(subject).repay(amt) {
            _checkNonWorsening(E0, C0);
        } catch {}
    }

    function liquidate() external {
        calls++;
        vm.prank(liquidator);
        try ISubject(subject).liquidate() {} catch {}
    }

    /* ------------------------- exogenous shocks ------------------------- */

    /// @dev move the oracle the protocol reads; drives both external-protocol HF and internal valuation
    function movePrice(uint256 bps) external {
        calls++;
        bps = bound(bps, 3000, 20000);
        vm.mockCall(
            ORACLE,
            abi.encodeWithSignature("getAssetPrice(address)", address(0)), // <- set the asset
            abi.encode(BASE_PRICE * bps / 10000)
        );
        exogenous = true;
    }

    function warpTime(uint256 secs) external {
        calls++;
        vm.warp(block.timestamp + bound(secs, 1, 30 days));
        exogenous = true;
    }
}

/* ------------------------------ invariants ----------------------------- */

contract TemplateInvariants is Test {
    // ---- fill these ----
    address constant SUBJECT = address(0); // deployed position contract
    address constant ORACLE = address(0); // oracle
    uint256 constant BASE_PRICE = 0; // price at fork block
    uint256 constant FORK_BLOCK = 0;

    address actor = makeAddr("actor");
    address liquidator = makeAddr("liquidator");

    TemplateHandler handler;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_URL", string("http://127.0.0.1:8545"));
        if (FORK_BLOCK != 0) vm.createSelectFork(rpc, FORK_BLOCK);
        else vm.createSelectFork(rpc);

        // open a position here (deposit + borrow) so the fuzzer starts from a live state
        handler = new TemplateHandler(SUBJECT, actor, liquidator, ORACLE, BASE_PRICE);
        targetContract(address(handler));
    }

    /// accounting identity: user collateral can never be negative
    function invariant_accounting_sane() public view {
        assertLe(ISubject(SUBJECT).maxRelease(), ISubject(SUBJECT).totalAssetsDepositedOrReserved());
    }

    /// liveness/safety: without exogenous shocks, a user's own actions can never make the position liquidatable
    function invariant_no_self_inflicted_liquidation() public view {
        if (!handler.exogenous()) {
            assertFalse(ISubject(SUBJECT).canLiquidate(), "liquidatable without price/time shock");
        }
    }

    /// the protocol's own guard must never be bypassed by any successful operation
    function invariant_guard_not_bypassed() public view {
        assertFalse(handler.broken(), handler.brokenReason());
    }

    /// fuzzer must actually be exploring
    function invariant_liveness() public view {
        assertGt(handler.calls(), 0, "handler never called");
    }
}
