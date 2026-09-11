// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CreditFile} from "../src/CreditFile.sol";
import {CreditEvent, CreditEventType} from "../src/Types.sol";
import {NetTermsDesk, ICreditFileReader} from "../src/examples/NetTermsDesk.sol";

/// @title NetTermsDesk - a third consumer that imports nothing from ProofLine.
///
/// @notice Runs the desk against the real CreditFile, so the struct it declared from the ABI
///         is decoded from the real return value, not from a mock shaped to match it.
contract NetTermsDeskTest is Test {
    uint256 constant M = 1e6;
    uint64  constant DUE = 2_000_000;

    CreditFile cf;
    NetTermsDesk desk;

    address receiver = address(0xA5C);
    address seller   = address(0x5E11);
    address buyerA = address(0xAAA1);
    address buyerB = address(0xBBB2);
    address buyerC = address(0xCCC3);

    event TermsDecided(address indexed business, uint16 netDays, uint32 settled,
                       uint32 counterparties, uint256 verifiedVolume, string basis);

    function setUp() public {
        vm.warp(1_000_000);
        cf   = new CreditFile(receiver);
        desk = new NetTermsDesk(ICreditFileReader(address(cf)));
    }

    function _ev(CreditEventType t, uint256 id, address cp, uint256 amount, uint64 ts)
        internal view returns (CreditEvent memory e)
    {
        e.chainKey = 1; e.blockHeight = 100; e.txIndex = 7;
        e.eventType = t; e.borrower = seller; e.counterparty = cp;
        e.obligationId = id; e.amount = amount; e.dueDate = DUE; e.timestamp = ts;
    }
    function _apply(CreditEvent memory e) internal { vm.prank(receiver); cf.applyVerifiedEvent(e); }
    function _cycle(uint256 id, address cp, uint256 a) internal {
        _apply(_ev(CreditEventType.ObligationCreated, id, cp, a, 1));
        _apply(_ev(CreditEventType.ObligationSettled, id, cp, a, DUE - 1));
    }

    function test_thinFile_cashInAdvance() public view {
        (uint16 d, string memory basis) = desk.quote(seller);
        assertEq(d, 0);
        assertEq(basis, "thin file: cash in advance");
    }

    function test_threeSettlementsTwoCounterparties_net30() public {
        _cycle(1, buyerA, 5_000 * M);
        _cycle(2, buyerB, 5_000 * M);
        _cycle(3, buyerA, 5_000 * M);
        (uint16 d,) = desk.quote(seller);
        assertEq(d, 30);
    }

    /// Five settlements and three counterparties, but only 25,000 of volume: ProofLine would
    /// rate this file TRUSTED, and this desk still says net 30. Its policy is its own.
    function test_ownPolicy_volumeGateHoldsBackNet60() public {
        _cycle(1, buyerA, 5_000 * M);
        _cycle(2, buyerB, 5_000 * M);
        _cycle(3, buyerC, 5_000 * M);
        _cycle(4, buyerA, 5_000 * M);
        _cycle(5, buyerB, 5_000 * M);
        (uint16 d,) = desk.quote(seller);
        assertEq(d, 30);
    }

    function test_fiveSettlementsThreeCounterpartiesEnoughVolume_net60() public {
        _cycle(1, buyerA, 10_000 * M);
        _cycle(2, buyerB, 10_000 * M);
        _cycle(3, buyerC, 10_000 * M);
        _cycle(4, buyerA, 10_000 * M);
        _cycle(5, buyerB, 10_000 * M);
        (uint16 d, string memory basis) = desk.quote(seller);
        assertEq(d, 60);
        assertEq(basis, "net 60");
    }

    function test_verifiedDefault_overridesHistory() public {
        _cycle(1, buyerA, 10_000 * M);
        _cycle(2, buyerB, 10_000 * M);
        _cycle(3, buyerC, 10_000 * M);
        _apply(_ev(CreditEventType.ObligationCreated, 4, buyerA, 10_000 * M, 1));
        _apply(_ev(CreditEventType.ObligationDefaulted, 4, buyerA, 10_000 * M, DUE + 1));
        (uint16 d, string memory basis) = desk.quote(seller);
        assertEq(d, 0);
        assertEq(basis, "verified default: cash in advance");
    }

    function test_decide_recordsAndEmits_andLeavesCreditFileUnchanged() public {
        _cycle(1, buyerA, 5_000 * M);
        _cycle(2, buyerB, 5_000 * M);
        _cycle(3, buyerA, 5_000 * M);
        uint256 before = cf.eventCount(seller);

        vm.expectEmit(true, false, false, true);
        emit TermsDecided(seller, 30, 3, 2, 15_000 * M, "net 30");
        vm.prank(address(0xD00D));   // anyone may ask
        uint16 d = desk.decide(seller);

        assertEq(d, 30);
        (uint16 stored, uint64 at) = desk.lastDecision(seller);
        assertEq(stored, 30);
        assertEq(at, uint64(block.timestamp));
        assertEq(cf.eventCount(seller), before);
    }
}
