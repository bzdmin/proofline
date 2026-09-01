// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {CreditFile} from "../src/CreditFile.sol";
import {UnderwritingLib as U} from "../src/UnderwritingLib.sol";
import {CreditEvent, CreditEventType, File, Terms, Tier} from "../src/Types.sol";

/// @title CreditFile - the stateful coordinator.
///
/// @notice Asserts what an external consumer can observe: recorded history, file state, and
///         terms. Nothing here reaches into internals, so the suite survives a refactor of
///         how CreditFile stores anything.
contract CreditFileTest is Test {
    uint256 constant M = 1e6;
    uint64  constant DUE = 1_000_000;
    uint64  constant CK = 1;

    CreditFile cf;
    address receiver = address(0xA5C);
    address bob = address(0xB0B);
    address buyerA = address(0xAAA1);
    address buyerB = address(0xBBB2);
    address buyerC = address(0xCCC3);

    function setUp() public { cf = new CreditFile(receiver); }

    function _ev(CreditEventType t, uint256 id, address cp, uint256 amount, uint64 ts)
        internal view returns (CreditEvent memory e)
    {
        e.chainKey = CK;
        e.blockHeight = 100;
        e.txIndex = 7;
        e.eventType = t;
        e.borrower = bob;
        e.counterparty = cp;
        e.obligationId = id;
        e.amount = amount;
        e.dueDate = DUE;
        e.timestamp = ts;
    }

    function _apply(CreditEvent memory e) internal {
        vm.prank(receiver);
        cf.applyVerifiedEvent(e);
    }

    function _settle(uint256 id, address cp, uint256 amount, uint64 ts) internal {
        _apply(_ev(CreditEventType.ObligationCreated, id, cp, amount, 1));
        _apply(_ev(CreditEventType.ObligationSettled, id, cp, amount, ts));
    }

    // ------------------------------------------------------------ access control

    function test_onlyReceiverMayWrite() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(CreditFile.NotReceiver.selector);
        cf.applyVerifiedEvent(_ev(CreditEventType.ObligationCreated, 1, buyerA, 10_000 * M, 1));
    }

    function test_anyoneMayRead() public {
        _settle(1, buyerA, 10_000 * M, DUE - 1);
        vm.prank(address(0xBAD));
        assertEq(cf.getCreditFile(bob).settled, 1, "reads are public by design");
    }

    // ------------------------------------------------------------ recorded vs counted

    /// The distinction that must never collapse. Both events are auditable; only the
    /// qualifying one has any financial effect.
    function test_dustIsRecordedButNotCounted() public {
        uint256 dust = U.MIN_QUALIFYING_AMOUNT - 1;
        _apply(_ev(CreditEventType.ObligationCreated, 1, buyerA, dust, 1));
        _apply(_ev(CreditEventType.ObligationSettled, 1, buyerA, dust, DUE - 1));

        assertEq(cf.eventCount(bob), 2, "both events are in the audit log");
        File memory f = cf.getCreditFile(bob);
        assertEq(f.settled, 0, "but nothing was counted");
        assertEq(f.outstandingReceivables, 0);
        assertEq(f.counterparties, 0);
        assertEq(f.maxSettledAmount, 0);
    }

    function test_everyEventIsRecordedRegardlessOfEffect() public {
        _apply(_ev(CreditEventType.ObligationCreated, 1, buyerA, 10_000 * M, 1));
        _apply(_ev(CreditEventType.ObligationOverdue, 1, buyerA, 10_000 * M, DUE + 1));
        _apply(_ev(CreditEventType.ObligationSettled, 1, buyerA, 10_000 * M, DUE + 5));
        assertEq(cf.eventCount(bob), 3);

        CreditEvent[] memory evs = cf.getCreditEvents(bob);
        assertTrue(evs[0].eventType == CreditEventType.ObligationCreated);
        assertTrue(evs[1].eventType == CreditEventType.ObligationOverdue);
        assertTrue(evs[2].eventType == CreditEventType.ObligationSettled);
        assertEq(evs[2].txIndex, 7, "proof provenance survives into the audit log");
    }

    // ------------------------------------------------------------ set membership

    function test_sameCounterpartyCountedOnce() public {
        _settle(1, buyerA, 8_000 * M, DUE - 1);
        _settle(2, buyerA, 8_000 * M, DUE - 1);
        File memory f = cf.getCreditFile(bob);
        assertEq(f.settled, 2);
        assertEq(f.counterparties, 1, "same buyer twice is one counterparty");
    }

    function test_distinctCounterpartiesAccumulate() public {
        _settle(1, buyerA, 8_000 * M, DUE - 1);
        _settle(2, buyerB, 8_000 * M, DUE - 1);
        _settle(3, buyerC, 8_000 * M, DUE - 1);
        assertEq(cf.getCreditFile(bob).counterparties, 3);
    }

    /// The same obligation reaching the file twice must not double-count.
    function test_obligationCountedOnlyOnce() public {
        _settle(1, buyerA, 8_000 * M, DUE - 1);
        _apply(_ev(CreditEventType.ObligationSettled, 1, buyerA, 8_000 * M, DUE - 1));

        File memory f = cf.getCreditFile(bob);
        assertEq(f.settled, 1, "counted once");
        assertEq(cf.eventCount(bob), 3, "but all three events remain auditable");
    }

    /// The same obligation id on a DIFFERENT chain is a different obligation.
    function test_obligationKeyIsChainScoped() public {
        _settle(1, buyerA, 8_000 * M, DUE - 1);

        CreditEvent memory e = _ev(CreditEventType.ObligationSettled, 1, buyerB, 8_000 * M, DUE - 1);
        e.chainKey = 3;                       // mainnet, same id
        _apply(e);

        assertEq(cf.getCreditFile(bob).settled, 2, "ids collide across chains; the key does not");
    }

    // ------------------------------------------------------------ fan-out

    /// One proof delivering three events: all three recorded, each counted exactly once.
    function test_threeEventsFromOneProofEachCountOnce() public {
        for (uint256 i = 1; i <= 3; i++) {
            _apply(_ev(CreditEventType.ObligationCreated, i, buyerA, 5_000 * M, 1));
        }
        assertEq(cf.eventCount(bob), 3);
        assertEq(cf.getCreditFile(bob).outstandingReceivables, 15_000 * M,
                 "three distinct obligations, three additions");
    }

    // ------------------------------------------------------------ terms

    function test_termsRecomputeInTheSameTransaction() public {
        _settle(1, buyerA, 10_000 * M, DUE - 1);
        Terms memory t = cf.getTerms(bob);
        assertTrue(t.tier == Tier.STANDARD);
        assertEq(t.advanceBps, 6_000);
        assertGt(t.limit, 0, "the limit moved when the proof landed, not later");
    }

    /// The climb, through the public read surface only.
    function test_theClimbToTrusted() public {
        _settle(1, buyerA, 10_000 * M, DUE - 1);
        assertTrue(cf.getTerms(bob).tier == Tier.STANDARD);
        _settle(2, buyerB,  8_000 * M, DUE - 1);
        assertTrue(cf.getTerms(bob).tier == Tier.STANDARD);
        _settle(3, buyerC, 12_000 * M, DUE - 1);
        assertTrue(cf.getTerms(bob).tier == Tier.GOOD);
        _settle(4, buyerA,  7_000 * M, DUE - 1);
        assertTrue(cf.getTerms(bob).tier == Tier.GOOD);
        _settle(5, buyerB,  9_000 * M, DUE - 1);

        Terms memory t = cf.getTerms(bob);
        assertTrue(t.tier == Tier.TRUSTED, "5 settlements, 3 counterparties");
        assertEq(t.advanceBps, 8_000);
        assertEq(t.aprBps, 1_200);
        assertEq(cf.getCreditFile(bob).maxSettledAmount, 12_000 * M);
    }

    /// Capacity must survive settlement - the bug that split capacity from drawable.
    function test_capacitySurvivesSettlementThroughThePublicApi() public {
        _settle(1, buyerA, 12_000 * M, DUE - 1);
        Terms memory t = cf.getTerms(bob);
        assertEq(cf.getCreditFile(bob).outstandingReceivables, 0, "everything paid");
        assertGt(t.capacity, 0, "capacity persists");
        assertEq(t.drawable, 0, "but nothing is drawable with no receivables");
    }

    function test_drawableRespectsReportedDebt() public {
        _settle(1, buyerA, 12_000 * M, DUE - 1);
        _apply(_ev(CreditEventType.ObligationCreated, 2, buyerB, 12_000 * M, 1));

        uint256 free = cf.getTermsWithDebt(bob, 0).drawable;
        uint256 owed = cf.getTermsWithDebt(bob, 1_000 * M).drawable;
        assertEq(owed, free - 1_000 * M, "debt is reported by the consumer, not tracked here");
    }

    // ------------------------------------------------------------ downside

    function test_overdueTightensTermsImmediately() public {
        _settle(1, buyerA, 10_000 * M, DUE - 1);
        _settle(2, buyerB, 10_000 * M, DUE - 1);
        _settle(3, buyerC, 10_000 * M, DUE - 1);
        assertTrue(cf.getTerms(bob).tier == Tier.GOOD);

        _apply(_ev(CreditEventType.ObligationCreated, 4, buyerA, 10_000 * M, 1));
        _apply(_ev(CreditEventType.ObligationOverdue, 4, buyerA, 10_000 * M, DUE + 1));

        Terms memory t = cf.getTerms(bob);
        assertTrue(t.tier == Tier.WATCH, "same block, no smoothing");
        assertEq(t.advanceBps, 4_000);
    }

    function test_defaultFreezesAndNeverTouchesSettled() public {
        _settle(1, buyerA, 10_000 * M, DUE - 1);
        _settle(2, buyerB, 10_000 * M, DUE - 1);
        _settle(3, buyerC, 10_000 * M, DUE - 1);

        _apply(_ev(CreditEventType.ObligationCreated, 4, buyerA, 10_000 * M, 1));
        _apply(_ev(CreditEventType.ObligationDefaulted, 4, buyerA, 10_000 * M, DUE + 900));

        File memory f = cf.getCreditFile(bob);
        assertEq(f.settled, 3, "a default is not a settlement");
        assertEq(f.onTime, 3);
        assertEq(f.defaults, 1);

        Terms memory t = cf.getTerms(bob);
        assertTrue(t.tier == Tier.FROZEN);
        assertEq(t.drawable, 0);
    }

    function test_termsChangedEventFiresOnTierMove() public {
        _settle(1, buyerA, 10_000 * M, DUE - 1);
        _settle(2, buyerB, 10_000 * M, DUE - 1);

        vm.recordLogs();
        _settle(3, buyerC, 10_000 * M, DUE - 1);   // STANDARD -> GOOD

        bool sawTermsChanged;
        bytes32 sig = keccak256("TermsChanged(address,uint8,uint8,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) sawTermsChanged = true;
        }
        assertTrue(sawTermsChanged, "a tier move is observable to consumers");
    }
}
