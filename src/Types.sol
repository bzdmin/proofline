// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ProofLine shared types - Interface Specification v2.
/// @notice Imported by every contract on both networks so the Sepolia emitter and the
///         Creditcoin decoder cannot drift. Nothing here is invoice-specific except the
///         source contract's own event names: the credit layer speaks in obligations.

// ---------------------------------------------------------------- enums

/// Generic credit vocabulary. The ASC adapter translates source-specific events
/// (InvoiceIssued, InvoicePaid, ...) into these before CreditFile ever sees them.
enum CreditEventType {
    ObligationCreated,
    ObligationSettled,
    ObligationOverdue,
    ObligationDefaulted
}

/// Source-chain lifecycle. Late is a waypoint, not an outcome.
enum InvoiceState { None, Open, Late, Paid, Defaulted }

/// Evaluated worst-first, then best rung down. See UnderwritingLib.tierOf.
enum Tier { NEW, STANDARD, GOOD, TRUSTED, WATCH, FROZEN }

// ---------------------------------------------------------------- records

/// One accepted proof-backed fact. The same object is the audit trail, the underwriting
/// input, and the row the interface renders - so those three cannot drift apart.
struct CreditEvent {
    uint64          chainKey;      // uint64: matches the precompile, not uint32
    uint64          blockHeight;
    uint64          txIndex;       // derived by the precompile from the merkle proof
    uint32          logIndex;      // position in the receipt. Audit data ONLY - never replay identity
    CreditEventType eventType;
    address         sourceContract;
    address         borrower;      // the seller; same address on both chains
    address         counterparty;  // the ACTUAL payer (msg.sender on the source), not the nominated buyer
    uint256         obligationId;
    uint256         amount;        // mUSD base units, 6 decimals
    uint64          dueDate;
    uint64          timestamp;     // paidAt on a settlement; block time otherwise
}

/// Aggregates derived from the event log. Every counter moves in exactly one place.
struct File {
    uint32  settled;
    uint32  onTime;
    uint32  defaults;
    uint32  openDelinquencies;
    uint32  counterparties;
    uint256 verifiedVolume;
    uint256 outstandingReceivables;  // the borrowing base
    uint256 maxSettledAmount;        // capacity anchor
    uint256 currentLimit;            // previous limit, for the incremental throttle
    uint64  lastUpdated;
}

/// The three numbers, never collapsed into one.
struct Terms {
    Tier    tier;
    uint16  advanceBps;
    uint16  aprBps;
    uint256 capacity;   // what history earned
    uint256 limit;      // what underwriting authorises
    uint256 drawable;   // what current receivables support, less debt
}

// ---------------------------------------------------------------- interfaces

/// The public credit primitive. Any Creditcoin contract may read these; only the
/// registered ASCReceiver may write. Treasury and CreditAccess are two independent
/// consumers, and neither knows the other exists.
interface ICreditFile {
    function applyVerifiedEvent(CreditEvent calldata e) external;

    function getCreditFile(address borrower)   external view returns (File memory);
    function getCreditEvents(address borrower) external view returns (CreditEvent[] memory);
    function getTerms(address borrower)        external view returns (Terms memory);
}

/// The Attestcoin block-prover precompile at 0x...0FD2.
/// Shape taken verbatim from contracts/sol/VerifierInterface.sol in the official examples.
interface INativeQueryVerifier {
    struct MerkleProofEntry { bytes32 hash; bool isLeft; }
    struct MerkleProof { bytes32 root; MerkleProofEntry[] siblings; }
    struct ContinuityProof { bytes32 lowerEndpointDigest; bytes32[] roots; }

    function verifyAndEmit(
        uint64 chainKey,
        uint64 height,
        bytes calldata encodedTransaction,
        MerkleProof calldata merkleProof,
        ContinuityProof calldata continuityProof
    ) external returns (bool);

    function calculateTxIndex(MerkleProof calldata merkleProof) external view returns (uint64);
}

library ProofLineConstants {
    address internal constant VERIFY_PRECOMPILE =
        0x0000000000000000000000000000000000000FD2;

    uint64 internal constant CHAINKEY_SEPOLIA = 1;
    uint64 internal constant CHAINKEY_MAINNET = 3;
}
