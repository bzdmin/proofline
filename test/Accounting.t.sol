// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AccountingLib as A} from "../src/AccountingLib.sol";
import {UnderwritingLib as U} from "../src/UnderwritingLib.sol";
import {File, CreditEvent, CreditEventType, Tier} from "../src/Types.sol";

/// @title Accounting - the credit file's state transitions as executable specification.
///
/// @notice Pure. Every assertion is on an externally meaningful counter, never on how the
///         library arrived at it.
contract AccountingTest is Test {
    uint256 constant M = 1e6;
    uint64  constant DUE = 1_000_000;

    function _ev(CreditEventType t, uint256 amount, uint64 ts)
        internal pure returns (CreditEvent memory e)
    {
        e.chainKey = 1;
        e.eventType = t;
        e.amount = amount;
        e.dueDate = DUE;
        e.timestamp = ts;
        e.borrower = address(0xB0B);
        e.counterparty = address(0xBEEF);
        e.obligationId = 1;
    }

    function _apply(File memory f, CreditEvent memory e, bool newCp, bool counted)
        internal pure returns (File memory)
    { return A.applyEvent(f, e, newCp, counted); }

    // ------------------------------------------------- borrowing base lifecycle

    function test_qualifyingIssueIncreasesOutstanding() public pure {
        File memory f;
        f = _apply(f, _ev(CreditEventType.ObligationCreated, 10_000 * M, 1), false, false);
        assertEq(f.outstandingReceivables, 10_000 * M);
        assertEq(f.settled, 0, "issuance moves no score counter");
        assertEq(f.onTime, 0);
        assertEq(f.counterparties, 0);
    }

    function test_settlementDecreasesOutstanding() public pure {
        File memory f;
        f = _apply(f, _ev(CreditEventType.ObligationCreated, 10_000 * M, 1), false, false);
        f = _apply(f, _ev(CreditEventType.ObligationSettled, 10_000 * M, DUE - 1), true, false);
        assertEq(f.outstandingReceivables, 0);
    }

    function test_defaultDecreasesOutstandingAndNeverTouchesSettled() public pure {
        File memory f;
        f = _apply(f, _ev(CreditEventType.ObligationCreated, 10_000 * M, 1), false, false);
        f = _apply(f, _ev(CreditEventType.ObligationDefaulted, 10_000 * M, DUE + 999), false, false);

        assertEq(f.defaults, 1);
        assertEq(f.outstandingReceivables, 0, "written off, out of the base");
        assertEq(f.settled, 0, "a default is not a settlement");
        assertEq(f.onTime, 0);
    }

    function test_overdueLeavesOutstandingUnchanged() public pure {
        File memory f;
        f = _apply(f, _ev(CreditEventType.ObligationCreated, 10_000 * M, 1), false, false);
        uint256 before = f.outstandingReceivables;
        f = _apply(f, _ev(CreditEventType.ObligationOverdue, 10_000 * M, DUE + 1), false, false);

        assertEq(f.outstandingReceivables, before, "Late is a waypoint, not an exit");
        assertEq(f.openDelinquencies, 1);
        assertEq(f.settled, 0, "nothing has settled");
    }

    function test_outstandingNeverUnderflows() public pure {
        File memory f;
        f = _apply(f, _ev(CreditEventType.ObligationSettled, 10_000 * M, DUE - 1), true, false);
        assertEq(f.outstandingReceivables, 0, "settling more than the base floors at zero");
    }

    // ------------------------------------------------- on-time determination

    /// Computed from paidAt vs dueDate carried in the event. The Overdue event is never
    /// consulted, which is why dueDate has to travel in the settlement payload.
    function test_onTimeUsesTimestampVersusDueDate() public pure {
        File memory a;
        a = _apply(a, _ev(CreditEventType.ObligationSettled, 5_000 * M, DUE), true, false);
        assertEq(a.onTime, 1, "paidAt == dueDate is on time");

        File memory b;
        b = _apply(b, _ev(CreditEventType.ObligationSettled, 5_000 * M, DUE + 1), true, false);
        assertEq(b.settled, 1);
        assertEq(b.onTime, 0, "one second late is late");
    }

    function test_settlementClearsOpenDelinquency() public pure {
        File memory f;
        f = _apply(f, _ev(CreditEventType.ObligationCreated, 10_000 * M, 1), false, false);
        f = _apply(f, _ev(CreditEventType.ObligationOverdue, 10_000 * M, DUE + 1), false, false);
        assertEq(f.openDelinquencies, 1);

        f = _apply(f, _ev(CreditEventType.ObligationSettled, 10_000 * M, DUE + 50), true, false);
        assertEq(f.openDelinquencies, 0, "resolved either way clears it");
        assertEq(f.settled, 1);
        assertEq(f.onTime, 0, "settled late, so it does not count as on time");
    }

    function test_defaultAlsoClearsOpenDelinquency() public pure {
        File memory f;
        f = _apply(f, _ev(CreditEventType.ObligationCreated, 10_000 * M, 1), false, false);
        f = _apply(f, _ev(CreditEventType.ObligationOverdue, 10_000 * M, DUE + 1), false, false);
        f = _apply(f, _ev(CreditEventType.ObligationDefaulted, 10_000 * M, DUE + 900), false, false);
        assertEq(f.openDelinquencies, 0);
        assertEq(f.defaults, 1);
    }

    // ------------------------------------------------- recorded vs counted

    /// The distinction that must never collapse: a dust event is fully auditable and
    /// completely inert. This library governs the second half only.
    function test_dustHasZeroFinancialEffectAcrossItsWholeLifecycle() public pure {
        uint256 dust = U.MIN_QUALIFYING_AMOUNT - 1;
        File memory f;

        f = _apply(f, _ev(CreditEventType.ObligationCreated, dust, 1), false, false);
        assertEq(f.outstandingReceivables, 0, "dust never enters the borrowing base");

        f = _apply(f, _ev(CreditEventType.ObligationSettled, dust, DUE - 1), true, false);
        assertEq(f.settled, 0);
        assertEq(f.onTime, 0);
        assertEq(f.counterparties, 0);
        assertEq(f.maxSettledAmount, 0);
        assertEq(f.verifiedVolume, 0);
        assertEq(f.outstandingReceivables, 0, "and never leaves it either - symmetric");
    }

    /// Ten thousand dust issuances must not create drawable capacity.
    function test_dustCannotInflateBorrowingBase() public pure {
        File memory f;
        f.settled = 5; f.onTime = 5; f.counterparties = 3; f.maxSettledAmount = 12_000 * M;

        for (uint256 i = 0; i < 200; i++) {
            f = _apply(f, _ev(CreditEventType.ObligationCreated, 1 * M, uint64(i)), false, false);
        }
        assertEq(f.outstandingReceivables, 0, "200 dust invoices add nothing");

        (uint16 advance,) = U.ratesFor(U.tierOf(f));
        uint256 lim = U.limitOf(f, U.capacityOf(f, advance));
        assertEq(U.drawableOf(f, lim, advance, 0), 0, "and therefore create no drawable");
    }

    function test_exactlyAtThresholdQualifies() public pure {
        File memory f;
        f = _apply(f, _ev(CreditEventType.ObligationCreated, U.MIN_QUALIFYING_AMOUNT, 1), false, false);
        assertEq(f.outstandingReceivables, U.MIN_QUALIFYING_AMOUNT, "the threshold is inclusive");
    }

    // ------------------------------------------------- counting rules

    function test_obligationCountedOnlyOnce() public pure {
        File memory f;
        f = _apply(f, _ev(CreditEventType.ObligationSettled, 8_000 * M, DUE - 1), true, false);
        assertEq(f.settled, 1);

        // same obligation reaching the library again
        f = _apply(f, _ev(CreditEventType.ObligationSettled, 8_000 * M, DUE - 1), true, true);
        assertEq(f.settled, 1, "settled counts each obligation at most once");
        assertEq(f.counterparties, 1, "and does not re-count the counterparty");
    }

    function test_counterpartyCountedOncePerAddress() public pure {
        File memory f;
        f = _apply(f, _ev(CreditEventType.ObligationSettled, 8_000 * M, DUE - 1), true, false);
        f = _apply(f, _ev(CreditEventType.ObligationSettled, 8_000 * M, DUE - 1), false, false);
        assertEq(f.settled, 2);
        assertEq(f.counterparties, 1, "the same buyer twice is still one counterparty");
    }

    function test_maxSettledAmountTracksTheLargest() public pure {
        File memory f;
        f = _apply(f, _ev(CreditEventType.ObligationSettled,  8_000 * M, DUE - 1), true, false);
        f = _apply(f, _ev(CreditEventType.ObligationSettled, 12_000 * M, DUE - 1), true, false);
        f = _apply(f, _ev(CreditEventType.ObligationSettled,  3_000 * M, DUE - 1), true, false);
        assertEq(f.maxSettledAmount, 12_000 * M, "the anchor is the largest ever proven");
    }

    // ------------------------------------------------- invariants

    function testFuzz_onTimeNeverExceedsSettled(uint64[8] calldata stamps, uint128[8] calldata amts)
        public pure
    {
        File memory f;
        for (uint256 i = 0; i < 8; i++) {
            uint256 amt = bound(uint256(amts[i]), 0, 1_000_000e6);
            f = A.applyEvent(f, _ev(CreditEventType.ObligationSettled, amt, stamps[i]), true, false);
            assertLe(f.onTime, f.settled, "onTime <= settled, always");
        }
    }

    /// applyEvent must not mutate its input. File memory is a reference type, so a
    /// mutating version silently corrupts any caller holding the prior state.
    function test_applyEventDoesNotMutateItsInput() public pure {
        File memory before;
        before.settled = 5; before.onTime = 5; before.outstandingReceivables = 9_000 * M;

        File memory after_ = _apply(before, _ev(CreditEventType.ObligationSettled, 9_000 * M, DUE - 1), true, false);

        assertEq(before.settled, 5, "input untouched");
        assertEq(before.outstandingReceivables, 9_000 * M, "input untouched");
        assertEq(after_.settled, 6, "output advanced");
        assertEq(after_.outstandingReceivables, 0);
    }

    /// The full downside fork from the demo, asserted end to end.
    function test_theDownsideFork() public pure {
        File memory base;
        base.settled = 5; base.onTime = 5; base.counterparties = 3;
        base.maxSettledAmount = 12_000 * M;
        base = _apply(base, _ev(CreditEventType.ObligationCreated, 9_000 * M, 1), false, false);
        assertTrue(U.tierOf(base) == Tier.TRUSTED);

        // goes past due
        File memory late = _apply(base, _ev(CreditEventType.ObligationOverdue, 9_000 * M, DUE + 1), false, false);
        assertTrue(U.tierOf(late) == Tier.WATCH, "terms tighten immediately");

        // branch A - paid late, recovers
        File memory rec = _apply(late, _ev(CreditEventType.ObligationSettled, 9_000 * M, DUE + 60), false, false);
        assertEq(rec.settled, 6);
        assertEq(rec.onTime, 5, "83% on time");
        assertTrue(U.tierOf(rec) == Tier.GOOD, "recovers, but not to TRUSTED");

        // branch B - grace expires, frozen
        File memory dead = _apply(late, _ev(CreditEventType.ObligationDefaulted, 9_000 * M, DUE + 900), false, false);
        assertEq(dead.settled, 5, "default never touched the settlement counters");
        assertEq(dead.onTime, 5);
        assertTrue(U.tierOf(dead) == Tier.FROZEN);
    }
}
