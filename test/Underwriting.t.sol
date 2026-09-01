// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {UnderwritingLib as U} from "../src/UnderwritingLib.sol";
import {File, Terms, Tier} from "../src/Types.sol";

/// @title Underwriting — the credit policy as executable specification.
///
/// @notice Pure functions over a File. No Attestcoin, no storage, no mocks: every case here
///         is deterministic. Assertions are on externally meaningful outcomes — tier, rate,
///         capacity, limit, drawable — never on internal variables, so the suite survives a
///         refactor of how the library computes them.
contract UnderwritingTest is Test {
    uint256 constant M = 1e6; // mUSD has 6 decimals

    function _file() internal pure returns (File memory f) { return f; }

    // ---------------------------------------------------------- tier ordering
    // Worst-first, then best rung down. Rungs below TRUSTED carry no on-time
    // condition of their own because anything under 80% is caught above them.

    function test_newBorrowerIsNEW() public pure {
        assertTrue(U.tierOf(_file()) == Tier.NEW);
    }

    function test_defaultFreezesRegardlessOfEverythingElse() public pure {
        File memory f = _file();
        f.settled = 50; f.onTime = 50; f.counterparties = 20; f.defaults = 1;
        assertTrue(U.tierOf(f) == Tier.FROZEN, "a spotless file with one default is FROZEN");
    }

    function test_frozenIsTerminal() public pure {
        File memory f = _file();
        f.defaults = 1;
        for (uint32 i = 0; i < 20; i++) {
            f.settled += 1; f.onTime += 1; f.counterparties = 5;
            assertTrue(U.tierOf(f) == Tier.FROZEN, "no run of good events escapes FROZEN");
        }
    }

    function test_openDelinquencyForcesWATCH() public pure {
        File memory f = _file();
        f.settled = 9; f.onTime = 9; f.counterparties = 4; f.openDelinquencies = 1;
        assertTrue(U.tierOf(f) == Tier.WATCH, "something past due right now outranks history");
    }

    /// The precedence bug, pinned. One settlement paid late must NOT satisfy STANDARD.
    function test_singleLatePaidSettlementIsWatchNotStandard() public pure {
        File memory f = _file();
        f.settled = 1; f.onTime = 0;
        assertTrue(U.tierOf(f) == Tier.WATCH, "0% on-time is WATCH, not STANDARD");
    }

    function test_standardRequiresOnlyOneCleanSettlement() public pure {
        File memory f = _file();
        f.settled = 1; f.onTime = 1; f.counterparties = 1;
        assertTrue(U.tierOf(f) == Tier.STANDARD);
    }

    function test_goodRequiresThreeSettlements() public pure {
        File memory f = _file();
        f.settled = 2; f.onTime = 2; f.counterparties = 2;
        assertTrue(U.tierOf(f) == Tier.STANDARD, "two is not enough");
        f.settled = 3; f.onTime = 3; f.counterparties = 3;
        assertTrue(U.tierOf(f) == Tier.GOOD);
    }

    /// The anti-Sybil gate: volume alone must not reach the top tier.
    function test_trustedRequiresThreeDistinctCounterparties() public pure {
        File memory f = _file();
        f.settled = 5; f.onTime = 5; f.counterparties = 1;
        assertTrue(U.tierOf(f) == Tier.GOOD, "five settlements from one buyer stays GOOD");
        f.counterparties = 3;
        assertTrue(U.tierOf(f) == Tier.TRUSTED);
    }

    function test_trustedRequiresFiveSettlements() public pure {
        File memory f = _file();
        f.settled = 4; f.onTime = 4; f.counterparties = 3;
        assertTrue(U.tierOf(f) == Tier.GOOD);
        f.settled = 5; f.onTime = 5;
        assertTrue(U.tierOf(f) == Tier.TRUSTED);
    }

    function test_watchRecoversAsRatioHeals() public pure {
        File memory f = _file();
        f.settled = 4; f.onTime = 3; f.counterparties = 3;   // 75%
        assertTrue(U.tierOf(f) == Tier.WATCH);
        f.settled = 5; f.onTime = 4;                          // 80%
        assertTrue(U.tierOf(f) == Tier.GOOD, "the ratio heals; the state clears");
    }

    // ---------------------------------------------------------- invariants

    /// onTime can never exceed settled, so the ratio is always well-formed.
    function testFuzz_tierNeverRevertsOnWellFormedFile(
        uint16 settled, uint16 onTime, uint16 cps, uint8 delinq, uint8 defaults
    ) public pure {
        File memory f = _file();
        f.settled = settled;
        f.onTime = onTime > settled ? settled : onTime;
        f.counterparties = cps > settled ? settled : cps;
        f.openDelinquencies = delinq;
        f.defaults = defaults;
        U.tierOf(f); // must not revert or divide by zero
    }

    function test_ratesAreMonotonicAcrossTheLadder() public pure {
        (uint16 aNew, uint16 rNew)   = U.ratesFor(Tier.NEW);
        (uint16 aStd, uint16 rStd)   = U.ratesFor(Tier.STANDARD);
        (uint16 aGood, uint16 rGood) = U.ratesFor(Tier.GOOD);
        (uint16 aTr, uint16 rTr)     = U.ratesFor(Tier.TRUSTED);
        assertTrue(aNew < aStd && aStd < aGood && aGood < aTr, "advance rises with standing");
        assertTrue(rNew > rStd && rStd > rGood && rGood > rTr, "APR falls with standing");
        (uint16 aFrozen,) = U.ratesFor(Tier.FROZEN);
        assertEq(aFrozen, 0, "frozen advances nothing");
    }

    // ---------------------------------------------------------- capacity

    /// The bug that motivated splitting capacity from drawable: a settlement must not
    /// destroy the credit line at the moment it improves the borrower's standing.
    function test_capacitySurvivesSettlement() public pure {
        File memory f = _file();
        f.settled = 5; f.onTime = 5; f.counterparties = 3;
        f.maxSettledAmount = 12_000 * M;
        f.outstandingReceivables = 0;             // everything has been paid

        (uint16 advance,) = U.ratesFor(U.tierOf(f));
        uint256 capacity = U.capacityOf(f, advance);

        assertEq(capacity, 9_600 * M, "80% of the largest settlement ever proven");
        assertGt(capacity, 0, "being paid must not zero the line");
    }

    function test_capacityIsZeroBeforeAnySettlement() public pure {
        File memory f = _file();
        (uint16 advance,) = U.ratesFor(U.tierOf(f));
        assertEq(U.capacityOf(f, advance), 0, "history earns capacity; issuance does not");
    }

    // ---------------------------------------------------------- limit

    function test_firstLimitIsNotThrottled() public pure {
        File memory f = _file();
        f.settled = 1; f.onTime = 1; f.counterparties = 1;
        f.maxSettledAmount = 10_000 * M;
        f.currentLimit = 0;                        // nothing to throttle against

        (uint16 advance,) = U.ratesFor(U.tierOf(f));
        uint256 cap = U.capacityOf(f, advance);
        assertEq(U.limitOf(f, cap), cap, "the first settlement is not capped by the increment");
    }

    function test_laterIncreasesAreThrottled() public pure {
        File memory f = _file();
        f.settled = 5; f.onTime = 5; f.counterparties = 3;
        f.maxSettledAmount = 12_000 * M;
        f.currentLimit = 1_000 * M;

        (uint16 advance,) = U.ratesFor(U.tierOf(f));
        uint256 cap = U.capacityOf(f, advance);        // 9,600
        uint256 lim = U.limitOf(f, cap);

        assertEq(lim, 1_000 * M + U.MAX_INCREASE_PER_SETTLEMENT, "one step per settlement");
        assertLt(lim, cap, "history must be built, not bought in one transaction");
    }

    /// A tier drop must land immediately. Throttling a decrease would be a real bug.
    function test_decreasesAreNeverThrottled() public pure {
        File memory f = _file();
        f.settled = 5; f.onTime = 5; f.counterparties = 3; f.openDelinquencies = 1; // WATCH
        f.maxSettledAmount = 12_000 * M;
        f.currentLimit = 9_600 * M;

        (uint16 advance,) = U.ratesFor(U.tierOf(f));
        uint256 lim = U.limitOf(f, U.capacityOf(f, advance));

        assertEq(lim, 4_800 * M, "WATCH advance applies on the same block");
        assertLt(lim, f.currentLimit, "no smoothing on the way down");
    }

    function test_limitNeverExceedsExposureCap() public pure {
        File memory f = _file();
        f.settled = 9; f.onTime = 9; f.counterparties = 5;
        f.maxSettledAmount = 1_000_000 * M;         // enormous history
        f.currentLimit = U.MAX_EXPOSURE_PER_BORROWER;

        (uint16 advance,) = U.ratesFor(U.tierOf(f));
        assertEq(U.limitOf(f, U.capacityOf(f, advance)), U.MAX_EXPOSURE_PER_BORROWER);
    }

    // ---------------------------------------------------------- drawable

    function test_drawableIsBoundedByCurrentReceivables() public pure {
        File memory f = _file();
        f.settled = 5; f.onTime = 5; f.counterparties = 3;
        f.maxSettledAmount = 12_000 * M;
        f.currentLimit = 9_600 * M;
        f.outstandingReceivables = 4_000 * M;

        (uint16 advance,) = U.ratesFor(U.tierOf(f));
        uint256 lim = U.limitOf(f, U.capacityOf(f, advance));

        // 80% of 4,000 = 3,200, which is less than the 9,600 line
        assertEq(U.drawableOf(f, lim, advance, 0), 3_200 * M);
    }

    function test_drawableSubtractsExistingDebt() public pure {
        File memory f = _file();
        f.settled = 5; f.onTime = 5; f.counterparties = 3;
        f.maxSettledAmount = 12_000 * M;
        f.currentLimit = 9_600 * M;
        f.outstandingReceivables = 12_000 * M;

        (uint16 advance,) = U.ratesFor(U.tierOf(f));
        uint256 lim = U.limitOf(f, U.capacityOf(f, advance));
        assertEq(U.drawableOf(f, lim, advance, 2_000 * M), lim - 2_000 * M);
    }

    function test_drawableNeverUnderflows() public pure {
        File memory f = _file();
        f.settled = 5; f.onTime = 5; f.counterparties = 3;
        f.maxSettledAmount = 12_000 * M;
        f.outstandingReceivables = 1_000 * M;
        (uint16 advance,) = U.ratesFor(U.tierOf(f));
        assertEq(U.drawableOf(f, 9_600 * M, advance, 999_999 * M), 0, "debt beyond the line floors at zero");
    }

    /// A frozen borrower can draw nothing, whatever their receivables look like.
    function test_frozenBorrowerCannotDraw() public pure {
        File memory f = _file();
        f.settled = 9; f.onTime = 9; f.counterparties = 5; f.defaults = 1;
        f.maxSettledAmount = 50_000 * M;
        f.outstandingReceivables = 50_000 * M;

        (uint16 advance,) = U.ratesFor(U.tierOf(f));
        uint256 lim = U.limitOf(f, U.capacityOf(f, advance));
        assertEq(U.drawableOf(f, lim, advance, 0), 0);
    }
}
