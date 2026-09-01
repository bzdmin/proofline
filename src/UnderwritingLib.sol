// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {File, Tier} from "./Types.sol";

/// @title UnderwritingLib — ProofLine's credit policy.
///
/// @notice Deterministic and transparent. Every function is `internal pure`, so the library
///         inlines into CreditFile at compile time: four deployed contracts, no extra address
///         to wire, no cross-contract call — while the policy stays in its own readable,
///         independently testable file. It is the first thing a reviewer should open.
///
///         The policy reads a File and returns terms. It never reads storage, never reads
///         time, and never depends on who is calling. Given the same history it always
///         produces the same credit decision, which is the property that makes a proof-backed
///         credit file worth having.
///         ---------------------------------------------------------------------------
///         POLICY, NOT PROTOCOL.
///
///         Everything below is *ProofLine's initial underwriting policy*, not a Creditcoin
///         standard and not part of the primitive. "Five settlements across three
///         counterparties" is a threshold we chose for a testnet demonstration; a different
///         lender consuming the same CreditFile would reasonably choose differently.
///
///         The reusable part is the separation:
///             verified event history  ->  deterministic function  ->  terms
///
///         The primitive is CreditFile plus that shape. This library is one instantiation
///         of it. Any consumer may read the raw File and price it however it likes; nothing
///         in the architecture requires agreement with these numbers.
///         ---------------------------------------------------------------------------
library UnderwritingLib {
    uint256 internal constant MIN_QUALIFYING_AMOUNT      =  1_000e6;
    uint256 internal constant MAX_EXPOSURE_PER_BORROWER  = 25_000e6;
    uint256 internal constant MAX_INCREASE_PER_SETTLEMENT =  5_000e6;

    uint32 internal constant TRUSTED_MIN_SETTLED        = 5;
    uint32 internal constant TRUSTED_MIN_COUNTERPARTIES = 3;
    uint32 internal constant GOOD_MIN_SETTLED           = 3;
    uint256 internal constant TRUSTED_MIN_ONTIME_BPS    = 9_000;
    uint256 internal constant WATCH_ONTIME_BPS          = 8_000;

    /// Disqualifying states first, then the highest qualifying rung.
    ///
    /// Rungs below TRUSTED carry no on-time condition of their own: anything under 80% has
    /// already been caught by the WATCH check above them, so restating the floor would be
    /// redundant. `recentLate` deliberately does not exist — it would need "recent" defined
    /// and a rolling window stored, where openDelinquencies and the ratio give the same
    /// behaviour with no bookkeeping.
    function tierOf(File memory f) internal pure returns (Tier) {
        if (f.defaults > 0)                return Tier.FROZEN;
        if (f.openDelinquencies > 0)       return Tier.WATCH;
        if (f.settled == 0)                return Tier.NEW;

        uint256 onTimeBps = (uint256(f.onTime) * 10_000) / uint256(f.settled);
        if (onTimeBps < WATCH_ONTIME_BPS)  return Tier.WATCH;

        if (f.settled >= TRUSTED_MIN_SETTLED
            && onTimeBps >= TRUSTED_MIN_ONTIME_BPS
            && f.counterparties >= TRUSTED_MIN_COUNTERPARTIES) return Tier.TRUSTED;

        if (f.settled >= GOOD_MIN_SETTLED) return Tier.GOOD;
        return Tier.STANDARD;
    }

    function ratesFor(Tier t) internal pure returns (uint16 advanceBps, uint16 aprBps) {
        if (t == Tier.FROZEN)   return (0,     0);
        if (t == Tier.WATCH)    return (4_000, 2_200);
        if (t == Tier.TRUSTED)  return (8_000, 1_200);
        if (t == Tier.GOOD)     return (7_000, 1_400);
        if (t == Tier.STANDARD) return (6_000, 1_600);
        return (5_000, 1_800); // NEW
    }

    /// What verified history has earned, anchored on the largest single settlement the
    /// borrower has ever proven. Persists across settlement: being paid must not destroy
    /// the credit line at the moment it improves the borrower's standing.
    function capacityOf(File memory f, uint16 advanceBps) internal pure returns (uint256) {
        return (f.maxSettledAmount * advanceBps) / 10_000;
    }

    /// Capacity, then the exposure ceiling, then the per-settlement throttle.
    ///
    /// The throttle is gated on currentLimit rather than settled so it is independent of the
    /// order in which counters move: with no previous limit there is nothing to throttle
    /// against, and the first settlement must not be capped. `min` never blocks a decrease,
    /// so a tier drop lands on the same block — smoothing on the way down would be a bug.
    function limitOf(File memory f, uint256 capacity) internal pure returns (uint256 lim) {
        lim = capacity;
        if (lim > MAX_EXPOSURE_PER_BORROWER) lim = MAX_EXPOSURE_PER_BORROWER;

        if (f.currentLimit > 0) {
            uint256 ceiling = f.currentLimit + MAX_INCREASE_PER_SETTLEMENT;
            if (lim > ceiling) lim = ceiling;
        }
    }

    /// What can actually be taken today: the authorised line, bounded by what current
    /// receivables support, less what is already drawn.
    function drawableOf(File memory f, uint256 lim, uint16 advanceBps, uint256 debt)
        internal pure returns (uint256)
    {
        uint256 backed = (f.outstandingReceivables * advanceBps) / 10_000;
        uint256 cap = lim < backed ? lim : backed;
        return cap > debt ? cap - debt : 0;
    }

    /// Below this, an event is verified and recorded in history but has no financial effect.
    /// Applied per-event and uniformly across every event type, so an invoice that did not
    /// enter the borrowing base cannot later be subtracted from it.
    function qualifies(uint256 amount) internal pure returns (bool) {
        return amount >= MIN_QUALIFYING_AMOUNT;
    }
}
