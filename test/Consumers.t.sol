// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CreditFile} from "../src/CreditFile.sol";
import {Treasury, IERC20, ITermsSource} from "../src/Treasury.sol";
import {CreditAccess, ITierSource} from "../src/CreditAccess.sol";
import {UnderwritingLib as U} from "../src/UnderwritingLib.sol";
import {CreditEvent, CreditEventType, Terms, Tier, File} from "../src/Types.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title Consumers - two independent applications over one credit file.
///
/// @notice The architectural claim, made checkable. Treasury lends; CreditAccess sets deposit
///         requirements. Neither imports the other. Neither computes a tier. The same proven
///         Ethereum settlement moves both, through CreditFile alone.
contract ConsumersTest is Test {
    uint256 constant M = 1e6;
    uint64  constant DUE = 2_000_000;

    CreditFile cf;
    Treasury tre;
    CreditAccess acc;
    MockERC20 usd;

    address receiver = address(0xA5C);
    address funder   = address(0xF00D);
    address bob      = address(0xB0B);
    address provider = address(0x9309);
    address buyerA = address(0xAAA1);
    address buyerB = address(0xBBB2);
    address buyerC = address(0xCCC3);

    function setUp() public {
        vm.warp(1_000_000);
        cf  = new CreditFile(receiver);
        usd = new MockERC20();
        tre = new Treasury(IERC20(address(usd)), ITermsSource(address(cf)), funder);
        acc = new CreditAccess(ITierSource(address(cf)));

        usd.mint(funder, 1_000_000 * M);
        vm.prank(funder); usd.approve(address(tre), type(uint256).max);
        vm.prank(funder); tre.fund(500_000 * M);
    }

    function _ev(CreditEventType t, uint256 id, address cp, uint256 amount, uint64 ts)
        internal view returns (CreditEvent memory e)
    {
        e.chainKey = 1; e.blockHeight = 100; e.txIndex = 7;
        e.eventType = t; e.borrower = bob; e.counterparty = cp;
        e.obligationId = id; e.amount = amount; e.dueDate = DUE; e.timestamp = ts;
    }
    function _apply(CreditEvent memory e) internal { vm.prank(receiver); cf.applyVerifiedEvent(e); }
    function _issue(uint256 id, address cp, uint256 a) internal { _apply(_ev(CreditEventType.ObligationCreated, id, cp, a, 1)); }
    function _settle(uint256 id, address cp, uint256 a) internal { _apply(_ev(CreditEventType.ObligationSettled, id, cp, a, DUE - 1)); }
    function _cycle(uint256 id, address cp, uint256 a) internal { _issue(id, cp, a); _settle(id, cp, a); }

    /// Five settlements across three counterparties, anchored at 12,000 -> TRUSTED.
    function _reachTrusted() internal {
        _cycle(1, buyerA, 10_000 * M);
        _cycle(2, buyerB,  8_000 * M);
        _cycle(3, buyerC, 12_000 * M);
        _cycle(4, buyerA,  7_000 * M);
        _cycle(5, buyerB,  9_000 * M);
    }

    // ------------------------------------------------------------ Treasury

    function test_newBorrowerCannotDrawWithoutReceivables() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Treasury.ExceedsDrawable.selector, 1 * M, 0));
        tre.borrow(1 * M);
    }

    /// The full transition that guards the zero-limit bug.
    function test_borrowDrawAndSettleKeepsCapacityIntact() public {
        _reachTrusted();
        _issue(6, buyerC, 12_000 * M);          // a live receivable to draw against

        Terms memory t0 = cf.getTermsWithDebt(bob, 0);
        assertTrue(t0.tier == Tier.TRUSTED);
        assertEq(t0.capacity, 9_600 * M, "80% of the 12,000 anchor");

        uint256 draw = 6_300 * M;
        vm.prank(bob); tre.borrow(draw);

        assertEq(usd.balanceOf(bob), draw, "capital actually moved");
        assertEq(tre.debtOf(bob), draw);
        Terms memory t1 = cf.getTermsWithDebt(bob, tre.debtOf(bob));
        assertEq(t1.drawable, t0.drawable - draw, "drawable falls by exactly what was drawn");

        // the Ethereum settlement proof arrives
        _settle(6, buyerC, 12_000 * M);

        Terms memory t2 = cf.getTermsWithDebt(bob, tre.debtOf(bob));
        assertEq(cf.getCreditFile(bob).outstandingReceivables, 0, "receivable is gone");
        assertTrue(t2.tier == Tier.TRUSTED, "standing is unchanged");
        assertEq(t2.capacity, 9_600 * M, "CAPACITY SURVIVES - the bug that split these apart");
        assertGt(t2.limit, 0, "and the authorised line is still real");
        assertEq(t2.drawable, 0, "only today's drawable reflects having no receivables");
    }

    function test_cannotExceedDrawable() public {
        _reachTrusted();
        _issue(6, buyerC, 12_000 * M);
        Terms memory t = cf.getTermsWithDebt(bob, 0);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(
            Treasury.ExceedsDrawable.selector, t.drawable + 1, t.drawable));
        tre.borrow(t.drawable + 1);
    }

    function test_interestAccruesAndRepaymentClears() public {
        _reachTrusted();
        _issue(6, buyerC, 12_000 * M);
        vm.prank(bob); tre.borrow(5_000 * M);

        uint256 d0 = tre.debtOf(bob);
        vm.warp(block.timestamp + 365 days);
        uint256 d1 = tre.debtOf(bob);
        assertGt(d1, d0, "simple interest accrues");
        assertApproxEqAbs(d1, 5_600 * M, 1 * M, "12% APR on 5,000 for a year");

        usd.mint(bob, 10_000 * M);
        vm.prank(bob); usd.approve(address(tre), type(uint256).max);
        vm.prank(bob); tre.repay(d1);
        assertEq(tre.debtOf(bob), 0, "cleared");
    }

    function test_repaymentOverpaymentIsClamped() public {
        _reachTrusted();
        _issue(6, buyerC, 12_000 * M);
        vm.prank(bob); tre.borrow(5_000 * M);

        usd.mint(bob, 100_000 * M);
        vm.prank(bob); usd.approve(address(tre), type(uint256).max);
        uint256 before = usd.balanceOf(bob);
        vm.prank(bob); tre.repay(50_000 * M);

        assertEq(tre.debtOf(bob), 0);
        assertEq(before - usd.balanceOf(bob), 5_000 * M, "only the debt was taken");
    }

    /// A default freezes the line, and Treasury enforces it without knowing why.
    function test_frozenBorrowerCannotDraw() public {
        _reachTrusted();
        _issue(6, buyerC, 12_000 * M);
        _apply(_ev(CreditEventType.ObligationDefaulted, 6, buyerC, 12_000 * M, DUE + 900));

        assertTrue(cf.getTerms(bob).tier == Tier.FROZEN);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Treasury.ExceedsDrawable.selector, 1 * M, 0));
        tre.borrow(1 * M);
    }

    function test_onlyFunderMayFund() public {
        usd.mint(address(0xBAD), 1_000 * M);
        vm.prank(address(0xBAD));
        vm.expectRevert(Treasury.NotFunder.selector);
        tre.fund(1_000 * M);
    }

    // ------------------------------------------------------------ CreditAccess

    function test_depositFallsAsCreditImproves() public {
        assertEq(acc.requiredDepositBps(bob), 10_000, "NEW pays everything up front");

        _cycle(1, buyerA, 10_000 * M);
        assertEq(acc.requiredDepositBps(bob), 7_500, "STANDARD");

        _cycle(2, buyerB, 8_000 * M);
        _cycle(3, buyerC, 12_000 * M);
        assertEq(acc.requiredDepositBps(bob), 4_000, "GOOD");

        _cycle(4, buyerA, 7_000 * M);
        _cycle(5, buyerB, 9_000 * M);
        assertEq(acc.requiredDepositBps(bob), 0, "TRUSTED contracts with no deposit");
    }

    function test_trustedClientOpensAgreementWithNoDeposit() public {
        _reachTrusted();
        assertEq(acc.requiredDeposit(bob, 50 ether), 0);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        uint256 id = acc.openAgreement{value: 0}(provider, 50 ether);
        (,, uint256 value,, bool open) = acc.agreements(id);
        assertEq(value, 50 ether);
        assertTrue(open);
    }

    function test_newClientMustPayFullDeposit() public {
        vm.deal(bob, 100 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CreditAccess.WrongDeposit.selector, 50 ether, 0));
        acc.openAgreement{value: 0}(provider, 50 ether);

        vm.prank(bob);
        acc.openAgreement{value: 50 ether}(provider, 50 ether);
    }

    function test_frozenClientCannotContractAtAll() public {
        _reachTrusted();
        _issue(6, buyerC, 12_000 * M);
        _apply(_ev(CreditEventType.ObligationDefaulted, 6, buyerC, 12_000 * M, DUE + 900));

        vm.deal(bob, 100 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CreditAccess.FrozenCreditCannotContract.selector, bob));
        acc.openAgreement{value: 0}(provider, 50 ether);
    }

    // ------------------------------------------------------------ the architectural claim

    /// ONE proven Ethereum settlement moves TWO unrelated applications, through a credit
    /// file that knows about neither. This is the evidence behind "reusable primitive".
    function test_oneSettlementMovesBothConsumers() public {
        _cycle(1, buyerA, 10_000 * M);
        _cycle(2, buyerB,  8_000 * M);
        _cycle(3, buyerC, 12_000 * M);
        _cycle(4, buyerA,  7_000 * M);
        _issue(5, buyerB, 9_000 * M);

        uint16 depositBefore = acc.requiredDepositBps(bob);
        Terms memory before = cf.getTermsWithDebt(bob, 0);
        assertTrue(before.tier == Tier.GOOD);
        assertEq(depositBefore, 4_000);

        // the fifth settlement proof lands - the demo's live moment
        _settle(5, buyerB, 9_000 * M);

        Terms memory afterT = cf.getTermsWithDebt(bob, 0);
        assertTrue(afterT.tier == Tier.TRUSTED, "Treasury sees better terms");
        assertGt(afterT.advanceBps, before.advanceBps);
        assertLt(afterT.aprBps, before.aprBps);
        assertEq(acc.requiredDepositBps(bob), 0, "CreditAccess sees a waived deposit");
    }

    /// Neither consumer can influence the credit file. They are readers, full stop.
    function test_consumersCannotWriteToTheCreditFile() public {
        vm.prank(address(tre));
        vm.expectRevert(CreditFile.NotReceiver.selector);
        cf.applyVerifiedEvent(_ev(CreditEventType.ObligationSettled, 99, buyerA, 99_000 * M, DUE - 1));

        vm.prank(address(acc));
        vm.expectRevert(CreditFile.NotReceiver.selector);
        cf.applyVerifiedEvent(_ev(CreditEventType.ObligationSettled, 98, buyerA, 99_000 * M, DUE - 1));
    }
}
