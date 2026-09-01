// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/write-ability/common/EvmV1Decoder.sol";
import {INativeQueryVerifier, ICreditFile, CreditEvent, CreditEventType, ProofLineConstants} from "./Types.sol";

/// @title ASCReceiver - the only contract permitted to write to CreditFile.
///
/// @notice Six gates, in an order that G0-A established is not arbitrary. Some information
///         does not exist until after verification: the emitter address comes out of the
///         decoded receipt, so source authorization cannot precede proof verification.
///
///         Submission is permissionless. The gates validate the proof, never the sender.
///         Confirmed live in G0-A Q4: an unrelated address relayed a proof in full.
contract ASCReceiver {
    INativeQueryVerifier public constant VERIFIER =
        INativeQueryVerifier(ProofLineConstants.VERIFY_PRECOMPILE);

    ICreditFile public immutable creditFile;
    address public owner;

    /// chainKey => the ONE source contract whose logs we act on.
    mapping(uint64 => address) public authorizedSource;

    /// Proof-derived replay identity. Never a caller-supplied value.
    mapping(bytes32 => bool) public processedQueries;

    /// Source event signature => the generic credit meaning it carries.
    /// This mapping is the adapter boundary: Ethereum speaks invoices, the credit layer
    /// speaks obligations, and nothing downstream of here knows what an invoice is.
    mapping(bytes32 => CreditEventType) public eventTypeOf;
    mapping(bytes32 => bool) public isRegisteredEvent;

    event ProofAccepted(bytes32 indexed queryId, uint64 chainKey, uint64 blockHeight, uint64 txIndex, uint256 eventsCreated);
    event SourceAuthorized(uint64 indexed chainKey, address source);
    event EventTypeRegistered(bytes32 indexed signature, CreditEventType eventType);

    error NotOwner();
    error AlreadyProcessed(bytes32 queryId);
    error VerificationFailed();
    error BadTxType(uint8 txType);
    error TxDidNotSucceed(uint8 status);
    error NoMatchingLogs();
    error UnauthorizedSource(address emitter, address expected);
    error SourceNotConfigured(uint64 chainKey);

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    constructor(ICreditFile _creditFile) {
        creditFile = _creditFile;
        owner = msg.sender;
    }

    /// The single privileged call in the entire system. Named as such in the demo rather
    /// than left for a reviewer to discover.
    function setAuthorizedSource(uint64 chainKey, address source) external onlyOwner {
        authorizedSource[chainKey] = source;
        emit SourceAuthorized(chainKey, source);
    }

    function registerEventType(bytes32 signature, CreditEventType t) external onlyOwner {
        eventTypeOf[signature] = t;
        isRegisteredEvent[signature] = true;
        emit EventTypeRegistered(signature, t);
    }

    /// Replay identity, derived entirely from the proof. `txIndex` is computed by the
    /// precompile from the merkle proof, so no caller-supplied field can mint a fresh
    /// identity for a proof that has already been consumed.
    function computeQueryId(
        uint64 chainKey,
        uint64 blockHeight,
        bytes32 merkleRoot,
        INativeQueryVerifier.MerkleProofEntry[] calldata siblings
    ) public view returns (bytes32 queryId, uint64 txIndex) {
        INativeQueryVerifier.MerkleProof memory mp =
            INativeQueryVerifier.MerkleProof({root: merkleRoot, siblings: siblings});
        txIndex = VERIFIER.calculateTxIndex(mp);
        queryId = keccak256(abi.encodePacked(chainKey, blockHeight, txIndex));
    }

    /// Permissionless. Anyone may relay any valid proof.
    function submitProof(
        uint64 chainKey,
        uint64 blockHeight,
        bytes calldata encodedTransaction,
        bytes32 merkleRoot,
        INativeQueryVerifier.MerkleProofEntry[] calldata siblings,
        bytes32 lowerEndpointDigest,
        bytes32[] calldata continuityRoots,
        bytes32 eventSignature
    ) external returns (uint256 eventsCreated) {
        address expected = authorizedSource[chainKey];
        if (expected == address(0)) revert SourceNotConfigured(chainKey);

        (bytes32 queryId, uint64 txIndex) =
            computeQueryId(chainKey, blockHeight, merkleRoot, siblings);

        // GATE 1 - replay. Free, needs no proof, so it goes first.
        if (processedQueries[queryId]) revert AlreadyProcessed(queryId);

        // GATE 2 - proof verification.
        {
            INativeQueryVerifier.MerkleProof memory mp =
                INativeQueryVerifier.MerkleProof({root: merkleRoot, siblings: siblings});
            INativeQueryVerifier.ContinuityProof memory cp =
                INativeQueryVerifier.ContinuityProof({
                    lowerEndpointDigest: lowerEndpointDigest, roots: continuityRoots
                });
            if (!VERIFIER.verifyAndEmit(chainKey, blockHeight, encodedTransaction, mp, cp)) {
                revert VerificationFailed();
            }
        }

        // Marked only after verification: a malformed proof must not burn a legitimate id.
        processedQueries[queryId] = true;

        // GATE 3 - transaction type.
        uint8 txType = EvmV1Decoder.getTransactionType(encodedTransaction);
        if (!EvmV1Decoder.isValidTransactionType(txType)) revert BadTxType(txType);

        // GATE 4 - receipt status. Required by Attestcoin ASC security guidance.
        // Defence in depth: a reverted transaction also carries no logs, so gate 5 would
        // catch it too - but the rejection reason must be unambiguous, and integrity should
        // not rest on an incidental property of EVM log semantics.
        EvmV1Decoder.ReceiptFields memory receipt =
            EvmV1Decoder.decodeReceiptFields(encodedTransaction);
        if (receipt.receiptStatus != 1) revert TxDidNotSucceed(receipt.receiptStatus);

        // GATE 5 - locate the logs. One transaction may carry many.
        EvmV1Decoder.LogEntry[] memory logs =
            EvmV1Decoder.getLogsByEventSignature(receipt, eventSignature);
        if (logs.length == 0) revert NoMatchingLogs();

        // GATE 6 - every emitter must be the authorized source.
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].address_ != expected) {
                revert UnauthorizedSource(logs[i].address_, expected);
            }
        }

        // Fan out: one proof, N credit events.
        for (uint256 i = 0; i < logs.length; i++) {
            creditFile.applyVerifiedEvent(
                _toCreditEvent(chainKey, blockHeight, txIndex, uint32(i), expected, logs[i], eventSignature)
            );
        }

        eventsCreated = logs.length;
        emit ProofAccepted(queryId, chainKey, blockHeight, txIndex, eventsCreated);
    }

    /// Translates one source-chain log into the generic credit vocabulary.
    /// Virtual so a test harness can substitute a trivial decoder while exercising the
    /// gates; production decoding of the Receivable ABI lives in the override.
    function _toCreditEvent(
        uint64 chainKey,
        uint64 blockHeight,
        uint64 txIndex,
        uint32 logIndex,
        address sourceContract,
        EvmV1Decoder.LogEntry memory lg,
        bytes32 eventSignature
    ) internal view virtual returns (CreditEvent memory e) {
        e.chainKey = chainKey;
        e.blockHeight = blockHeight;
        e.txIndex = txIndex;
        e.logIndex = logIndex;
        e.sourceContract = sourceContract;
        e.eventType = eventTypeOf[eventSignature];

        // Receivable's four events share one payload shape:
        //   topics: [sig, id, seller, buyer]
        //   data:   (token, amount, dueDate, ts)
        e.obligationId = uint256(lg.topics[1]);
        e.borrower     = address(uint160(uint256(lg.topics[2])));
        e.counterparty = address(uint160(uint256(lg.topics[3])));
        (, uint256 amount, uint64 dueDate, uint64 ts) =
            abi.decode(lg.data, (address, uint256, uint64, uint64));
        e.amount = amount;
        e.dueDate = dueDate;
        e.timestamp = ts;
    }
}
