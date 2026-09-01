// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICreditFile, CreditEvent, CreditEventType, File, Terms, Tier} from "./Types.sol";
import {AccountingLib} from "./AccountingLib.sol";
import {UnderwritingLib} from "./UnderwritingLib.sol";

/// @title CreditFile - the credit primitive. Proof-backed credit state, publicly readable.
///
/// @notice A stateful coordinator, and almost nothing else. It stores events, maintains the
///         File, answers the two questions that genuinely need set membership, and delegates
///         every decision:
///
///           AccountingLib   pure state transition
///           UnderwritingLib pure policy
///
///         It deliberately does NOT understand Attestcoin proofs, decode Ethereum receipts,
///         contain invoice logic, implement any underwriting formula of its own, or know that
///         Treasury or CreditAccess exist. An external engineer should be able to read this
///         file and conclude it has no policy of its own - that is the point.
///
///         Any Creditcoin contract may read it. Only the registered ASCReceiver may write.
contract CreditFile is ICreditFile {
    address public immutable receiver;

    mapping(address => File) private _files;
    mapping(address => CreditEvent[]) private _events;

    /// Set membership question 1: have we seen this counterparty for this borrower before?
    mapping(address => mapping(address => bool)) private _seenCounterparty;

    /// Set membership question 2: has this obligation already been counted as settled?
    /// Keyed on (chainKey, obligationId) - Sepolia and mainnet both start ids at 1.
    mapping(bytes32 => bool) private _countedObligation;

    /// Debt is reported by whichever consumer holds it. CreditFile does not track lending;
    /// it accepts a debt figure when asked for terms, so a consumer that lends nothing can
    /// ask for terms without CreditFile knowing lending exists.
    event CreditEventRecorded(
        address indexed borrower,
        CreditEventType indexed eventType,
        uint256 amount,
        bool qualifying,
        uint64 chainKey,
        uint64 blockHeight,
        uint64 txIndex,
        uint32 logIndex
    );
    event TermsChanged(address indexed borrower, Tier from, Tier to, uint256 limitFrom, uint256 limitTo);

    error NotReceiver();

    modifier onlyReceiver() { if (msg.sender != receiver) revert NotReceiver(); _; }

    constructor(address _receiver) { receiver = _receiver; }

    /// One verified proof may deliver several events; the receiver calls this once per log.
    /// Replay protection lives at the proof level in ASCReceiver, so this function is
    /// deliberately not idempotent on its own - it trusts that its only caller has already
    /// established the transaction was never processed before.
    function applyVerifiedEvent(CreditEvent calldata e) external onlyReceiver {
        // Audit history is unconditional. Recorded is not the same as counted: a dust event
        // is fully auditable here and completely inert below.
        _events[e.borrower].push(e);

        File memory before = _files[e.borrower];
        Tier tierBefore = UnderwritingLib.tierOf(before);
        uint256 limitBefore = before.currentLimit;

        bytes32 obKey = keccak256(abi.encodePacked(e.chainKey, e.obligationId));
        bool alreadyCounted = _countedObligation[obKey];
        bool firstTimeCp = !_seenCounterparty[e.borrower][e.counterparty];

        File memory next = AccountingLib.applyEvent(before, e, firstTimeCp, alreadyCounted);

        bool qualifying = UnderwritingLib.qualifies(e.amount);
        if (qualifying && e.eventType == CreditEventType.ObligationSettled && !alreadyCounted) {
            _countedObligation[obKey] = true;
            if (firstTimeCp) _seenCounterparty[e.borrower][e.counterparty] = true;
        }

        // Terms are recomputed and stored in the SAME transaction as verification. Nothing
        // can move a borrower's terms except a proof arriving through the receiver.
        Tier tierAfter = UnderwritingLib.tierOf(next);
        (uint16 advanceBps,) = UnderwritingLib.ratesFor(tierAfter);
        next.currentLimit = UnderwritingLib.limitOf(next, UnderwritingLib.capacityOf(next, advanceBps));

        _files[e.borrower] = next;

        emit CreditEventRecorded(
            e.borrower, e.eventType, e.amount, qualifying,
            e.chainKey, e.blockHeight, e.txIndex, e.logIndex
        );
        if (tierAfter != tierBefore || next.currentLimit != limitBefore) {
            emit TermsChanged(e.borrower, tierBefore, tierAfter, limitBefore, next.currentLimit);
        }
    }

    // ------------------------------------------------------------------ public reads
    // The whole infrastructure story. Any Creditcoin application may consume these, and
    // none of them needs to know what an invoice is.

    function getCreditFile(address borrower) external view returns (File memory) {
        return _files[borrower];
    }

    function getCreditEvents(address borrower) external view returns (CreditEvent[] memory) {
        return _events[borrower];
    }

    /// Terms with no debt assumed. A consumer that lends reports its own debt via
    /// getTermsWithDebt; a consumer that does not lend - CreditAccess, say - uses this and
    /// only ever reads `tier`.
    function getTerms(address borrower) external view returns (Terms memory) {
        return _terms(borrower, 0);
    }

    function getTermsWithDebt(address borrower, uint256 debt) external view returns (Terms memory) {
        return _terms(borrower, debt);
    }

    function eventCount(address borrower) external view returns (uint256) {
        return _events[borrower].length;
    }

    function _terms(address borrower, uint256 debt) internal view returns (Terms memory t) {
        File memory f = _files[borrower];
        t.tier = UnderwritingLib.tierOf(f);
        (t.advanceBps, t.aprBps) = UnderwritingLib.ratesFor(t.tier);
        t.capacity = UnderwritingLib.capacityOf(f, t.advanceBps);
        t.limit = f.currentLimit;
        t.drawable = UnderwritingLib.drawableOf(f, t.limit, t.advanceBps, debt);
    }
}
