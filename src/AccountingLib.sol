// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {File, CreditEvent, CreditEventType} from "./Types.sol";
import {UnderwritingLib} from "./UnderwritingLib.sol";

/// @title AccountingLib — the credit file as a pure state transition.
///
/// @notice `applyEvent` takes a File and a verified event and returns the next File. It reads
///         no storage, so the whole accounting model is deterministic and fuzzable.
///
///         Two questions genuinely need set membership — is this counterparty new, and has
///         this obligation already been counted — so CreditFile resolves them against its
///         mappings and passes the answers in. The arithmetic stays pure; the sets stay
///         where sets belong.
///
///         **Recorded is not counted.** CreditFile appends every verified event to the audit
///         log unconditionally. This library decides whether it has any *financial* effect.
///         A dust event is fully auditable and completely inert.
library AccountingLib {
    /// Saturating subtraction. A qualifying-amount check that is applied at issuance but not
    /// at settlement would underflow here; this makes that failure visible as a stuck balance
    /// rather than a revert that blocks the whole proof path.
    function _sub(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    /// Returns a NEW File. Does not mutate the input.
    ///
    /// `File memory` is a reference type in Solidity, so a version that mutated in place
    /// would silently alias for any caller holding the prior state — branching two outcomes
    /// from one file would corrupt both. Caught by test_theDownsideFork. The copy costs a
    /// little gas and buys a function that behaves the way its signature reads.
    function applyEvent(
        File memory prev,
        CreditEvent memory e,
        bool firstTimeCounterparty,
        bool obligationAlreadyCounted
    ) internal pure returns (File memory) {
        File memory f = File({
            settled:                prev.settled,
            onTime:                 prev.onTime,
            defaults:               prev.defaults,
            openDelinquencies:      prev.openDelinquencies,
            counterparties:         prev.counterparties,
            verifiedVolume:         prev.verifiedVolume,
            outstandingReceivables: prev.outstandingReceivables,
            maxSettledAmount:       prev.maxSettledAmount,
            currentLimit:           prev.currentLimit,
            lastUpdated:            prev.lastUpdated
        });

        // Every financial effect is gated identically, for every event type. Because the
        // amount is identical across an obligation's lifecycle, this is automatically
        // symmetric: what issuance skipped, settlement also skips.
        if (!UnderwritingLib.qualifies(e.amount)) {
            f.lastUpdated = e.timestamp;
            return f;
        }

        if (e.eventType == CreditEventType.ObligationCreated) {
            f.outstandingReceivables += e.amount;

        } else if (e.eventType == CreditEventType.ObligationSettled) {
            f.outstandingReceivables = _sub(f.outstandingReceivables, e.amount);
            if (f.openDelinquencies > 0) f.openDelinquencies -= 1;

            if (!obligationAlreadyCounted) {
                f.settled += 1;
                // On-time is COMPUTED here, from the event's own fields. The presence or
                // absence of an Overdue event is never consulted.
                if (e.timestamp <= e.dueDate) f.onTime += 1;

                f.verifiedVolume += e.amount;
                if (e.amount > f.maxSettledAmount) f.maxSettledAmount = e.amount;
                if (firstTimeCounterparty) f.counterparties += 1;
            }

        } else if (e.eventType == CreditEventType.ObligationOverdue) {
            // Not a settlement outcome — live delinquency. The receivable is still
            // outstanding and can still settle either way.
            f.openDelinquencies += 1;

        } else if (e.eventType == CreditEventType.ObligationDefaulted) {
            f.defaults += 1;
            f.outstandingReceivables = _sub(f.outstandingReceivables, e.amount);
            if (f.openDelinquencies > 0) f.openDelinquencies -= 1;
            // Deliberately does NOT touch settled or onTime. A default is not a settlement.
        }

        f.lastUpdated = e.timestamp;
        return f;
    }
}
