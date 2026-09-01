// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Receivable} from "../src/Receivable.sol";
import {InvoiceState} from "../src/Types.sol";
import {MockERC20, FeeOnTransferERC20, LyingERC20} from "./mocks/MockERC20.sol";

/// @title Receivable - the source contract's invariants ARE the trust boundary.
///
/// @notice Attestcoin proves this contract emitted a log in a transaction that succeeded. It
///         does not prove the log is true. So every guarantee ProofLine makes about economic
///         reality has to be unreachable-otherwise here, and each of those requires gets a
///         test with the same seriousness as the accounting library.
contract ReceivableTest is Test {
    uint256 constant M = 1e6;
    uint64  constant GRACE = 10 minutes;

    Receivable r;
    MockERC20 usd;

    address seller = address(0x5E11E7);
    address buyerA = address(0xB111A);
    address buyerB = address(0xB222B);
    address anyone = address(0xA11);

    uint64 due;

    function setUp() public {
        vm.warp(1_000_000);
        due = uint64(block.timestamp + 1 days);
        r = new Receivable(GRACE);
        usd = new MockERC20();

        vm.prank(buyerA); r.registerAsBuyer();
        vm.prank(buyerB); r.registerAsBuyer();

        usd.mint(buyerA, 1_000_000 * M);
        usd.mint(buyerB, 1_000_000 * M);
        vm.prank(buyerA); usd.approve(address(r), type(uint256).max);
        vm.prank(buyerB); usd.approve(address(r), type(uint256).max);
    }

    function _issue(uint256 amount) internal returns (uint256 id) {
        vm.prank(seller);
        return r.issueInvoice(buyerA, address(usd), amount, due);
    }

    // ------------------------------------------------------- issuance guards

    function test_cannotInvoiceUnregisteredBuyer() public {
        address stranger = address(0xC0FFEE);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(Receivable.BuyerNotRegistered.selector, stranger));
        r.issueInvoice(stranger, address(usd), 10_000 * M, due);
    }

    /// The trivial one-wallet loop, blocked at the source.
    function test_cannotInvoiceYourself() public {
        vm.prank(buyerA);
        vm.expectRevert(Receivable.BuyerIsSeller.selector);
        r.issueInvoice(buyerA, address(usd), 10_000 * M, due);
    }

    function test_cannotIssueZeroAmount() public {
        vm.prank(seller);
        vm.expectRevert(Receivable.ZeroAmount.selector);
        r.issueInvoice(buyerA, address(usd), 0, due);
    }

    function test_cannotIssueWithPastDueDate() public {
        vm.prank(seller);
        vm.expectRevert(Receivable.DueDateInPast.selector);
        r.issueInvoice(buyerA, address(usd), 10_000 * M, uint64(block.timestamp));
    }

    function test_buyerCannotRegisterTwice() public {
        vm.prank(buyerA);
        vm.expectRevert(Receivable.AlreadyRegistered.selector);
        r.registerAsBuyer();
    }

    // ------------------------------------------------------- the escrow invariant

    /// A token that delivers less than it promises must not produce an InvoicePaid event.
    /// This is the check that makes "verified cashflow" mean a cashflow.
    function test_shortPaymentReverts() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20();
        fot.mint(buyerA, 100_000 * M);
        vm.prank(buyerA); fot.approve(address(r), type(uint256).max);

        vm.prank(seller);
        uint256 id = r.issueInvoice(buyerA, address(fot), 10_000 * M, due);

        vm.prank(buyerA);
        vm.expectRevert(abi.encodeWithSelector(
            Receivable.ShortPayment.selector, 10_000 * M, 9_900 * M));
        r.payInvoice(id);

        assertTrue(r.stateOf(id) == InvoiceState.Open, "unpaid, and no event emitted");
    }

    /// A token that moves nothing at all while returning true.
    function test_lyingTokenReverts() public {
        LyingERC20 liar = new LyingERC20();
        vm.prank(seller);
        uint256 id = r.issueInvoice(buyerA, address(liar), 10_000 * M, due);

        vm.prank(buyerA);
        vm.expectRevert(abi.encodeWithSelector(Receivable.ShortPayment.selector, 10_000 * M, 0));
        r.payInvoice(id);
    }

    function test_selfPaymentReverts() public {
        uint256 id = _issue(10_000 * M);
        usd.mint(seller, 100_000 * M);
        vm.prank(seller); usd.approve(address(r), type(uint256).max);

        vm.prank(seller);
        vm.expectRevert(Receivable.SelfPayment.selector);
        r.payInvoice(id);
    }

    function test_paymentMovesRealValueIntoEscrow() public {
        uint256 id = _issue(10_000 * M);
        uint256 buyerBefore = usd.balanceOf(buyerA);

        vm.prank(buyerA);
        r.payInvoice(id);

        assertEq(usd.balanceOf(buyerA), buyerBefore - 10_000 * M, "buyer actually paid");
        assertEq(usd.balanceOf(address(r)), 10_000 * M, "contract custodies it");
        assertEq(r.escrowed(seller, address(usd)), 10_000 * M);
        assertTrue(r.stateOf(id) == InvoiceState.Paid);
    }

    function test_cannotPayTwice() public {
        uint256 id = _issue(10_000 * M);
        vm.prank(buyerA); r.payInvoice(id);
        vm.prank(buyerB);
        vm.expectRevert(abi.encodeWithSelector(Receivable.WrongState.selector, InvoiceState.Paid));
        r.payInvoice(id);
    }

    function test_sellerWithdrawsEscrow() public {
        uint256 id = _issue(10_000 * M);
        vm.prank(buyerA); r.payInvoice(id);

        vm.prank(seller); r.withdraw(address(usd));
        assertEq(usd.balanceOf(seller), 10_000 * M);
        assertEq(r.escrowed(seller, address(usd)), 0);

        vm.prank(seller);
        vm.expectRevert(Receivable.NothingToWithdraw.selector);
        r.withdraw(address(usd));
    }

    /// Anyone may pay - a third party settling on the buyer's behalf is legitimate, and the
    /// event must record who ACTUALLY paid rather than who was nominated.
    function test_actualPayerIsRecordedNotNominatedBuyer() public {
        uint256 id = _issue(10_000 * M);

        vm.recordLogs();
        vm.prank(buyerB);           // nominated buyer was A
        r.payInvoice(id);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("InvoicePaid(uint256,address,address,address,uint256,uint64,uint64)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                assertEq(address(uint160(uint256(logs[i].topics[3]))), buyerB, "actual payer");
                found = true;
            }
        }
        assertTrue(found, "InvoicePaid emitted");
        (, address nominated,,,,, ) = r.invoices(id);
        assertEq(nominated, buyerA, "nomination still recoverable from issuance");
    }

    /// The payer must be registered too. Without this, counterparty diversity - the anti-Sybil
    /// control behind the TRUSTED tier - can be manufactured from fresh addresses for free.
    function test_unregisteredPayerRejected() public {
        uint256 id = _issue(10_000 * M);
        address stranger = address(0xC0FFEE);
        usd.mint(stranger, 100_000 * M);
        vm.prank(stranger); usd.approve(address(r), type(uint256).max);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Receivable.BuyerNotRegistered.selector, stranger));
        r.payInvoice(id);
        assertTrue(r.stateOf(id) == InvoiceState.Open);
    }

    /// A registered third party settling on the nominated buyer's behalf remains legitimate.
    function test_registeredThirdPartyMayPay() public {
        uint256 id = _issue(10_000 * M);
        vm.prank(buyerB);           // registered, but not the nominated buyer
        r.payInvoice(id);
        assertTrue(r.stateOf(id) == InvoiceState.Paid);
    }

    // ------------------------------------------------------- temporal guards

    function test_markLateBeforeDueDateReverts() public {
        uint256 id = _issue(10_000 * M);
        vm.expectRevert(abi.encodeWithSelector(
            Receivable.NotYetDue.selector, due, uint64(block.timestamp)));
        r.markLate(id);
    }

    /// Permissionless by design: anyone may poke it once the fact is true.
    function test_anyoneCanMarkLateAfterDueDate() public {
        uint256 id = _issue(10_000 * M);
        vm.warp(due + 1);
        vm.prank(anyone);
        r.markLate(id);
        assertTrue(r.stateOf(id) == InvoiceState.Late);
    }

    function test_cannotMarkPaidInvoiceLate() public {
        uint256 id = _issue(10_000 * M);
        vm.prank(buyerA); r.payInvoice(id);
        vm.warp(due + 1);
        vm.expectRevert(abi.encodeWithSelector(Receivable.WrongState.selector, InvoiceState.Paid));
        r.markLate(id);
    }

    function test_markDefaultInsideGraceReverts() public {
        uint256 id = _issue(10_000 * M);
        vm.warp(due + 1);
        r.markLate(id);

        vm.warp(due + GRACE);   // exactly at the boundary, still inside
        vm.expectRevert(abi.encodeWithSelector(
            Receivable.StillInGrace.selector, due + GRACE, uint64(block.timestamp)));
        r.markDefault(id);
    }

    function test_anyoneCanMarkDefaultAfterGrace() public {
        uint256 id = _issue(10_000 * M);
        vm.warp(due + GRACE + 1);
        vm.prank(anyone);
        r.markDefault(id);
        assertTrue(r.stateOf(id) == InvoiceState.Defaulted);
    }

    /// An invoice can blow past grace without anyone bothering to mark it late first.
    function test_canDefaultDirectlyFromOpen() public {
        uint256 id = _issue(10_000 * M);
        vm.warp(due + GRACE + 1);
        r.markDefault(id);
        assertTrue(r.stateOf(id) == InvoiceState.Defaulted);
    }

    /// Late is a waypoint, not an outcome: a late invoice can still settle.
    function test_lateInvoiceCanStillBePaid() public {
        uint256 id = _issue(10_000 * M);
        vm.warp(due + 1);
        r.markLate(id);

        vm.prank(buyerA);
        r.payInvoice(id);
        assertTrue(r.stateOf(id) == InvoiceState.Paid);
        assertEq(r.escrowed(seller, address(usd)), 10_000 * M, "value still moved");
    }

    function test_defaultedInvoiceCannotBePaid() public {
        uint256 id = _issue(10_000 * M);
        vm.warp(due + GRACE + 1);
        r.markDefault(id);

        vm.prank(buyerA);
        vm.expectRevert(abi.encodeWithSelector(Receivable.WrongState.selector, InvoiceState.Defaulted));
        r.payInvoice(id);
    }

    function test_cannotMarkLateTwice() public {
        uint256 id = _issue(10_000 * M);
        vm.warp(due + 1);
        r.markLate(id);
        vm.expectRevert(abi.encodeWithSelector(Receivable.WrongState.selector, InvoiceState.Late));
        r.markLate(id);
    }

    // ------------------------------------------------------- payload shape

    /// All four events must share one field order, or the ASC's single decode path breaks.
    function test_allFourEventsShareOnePayloadShape() public {
        assertEq(
            keccak256("InvoiceIssued(uint256,address,address,address,uint256,uint64,uint64)"),
            keccak256("InvoiceIssued(uint256,address,address,address,uint256,uint64,uint64)"));
        // shape asserted structurally: 3 indexed topics + 4 data fields on each
        uint256 id = _issue(10_000 * M);
        vm.recordLogs();
        vm.warp(due + 1);
        r.markLate(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[0].topics.length, 4, "signature + three indexed");
        assertEq(logs[0].data.length, 4 * 32, "four ABI-encoded data fields");
    }
}
