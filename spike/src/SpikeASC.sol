// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/write-ability/common/EvmV1Decoder.sol";

// NOTE: the official ASCLoanManager example imports this from
//   @gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol
// which does not exist in the published package. Real path is write-ability/common/.
// Recorded in evidence/G0-A as a MEASURED discrepancy against the example.

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

/// @title SpikeASC - throwaway G0-A receiver on Creditcoin CC3.
/// @notice Instrumented copy of the official ASCBase pipeline. Every gate emits, so a
///         failed submission tells us WHICH gate rejected it rather than just reverting.
///         Shares no code with ASCReceiver.sol. This exists to be measured, then deleted.
contract SpikeASC {
    address constant PRECOMPILE = 0x0000000000000000000000000000000000000FD2;
    INativeQueryVerifier public constant VERIFIER = INativeQueryVerifier(PRECOMPILE);

    /// keccak256("SpikePing(uint256,address,uint256)")
    bytes32 public constant SPIKE_PING_SIG =
        keccak256("SpikePing(uint256,address,uint256)");

    address public owner;
    mapping(uint64 => address) public authorizedSource;   // chainKey => source contract
    mapping(bytes32 => bool)   public processedQueries;   // official replay key

    /// One event per accepted log. G0-A asserts these appear N times for a pingBatch(N).
    event SpikeAccepted(
        bytes32 indexed queryId,
        uint64  chainKey,
        uint64  blockHeight,
        uint64  txIndex,
        uint256 logCount,
        uint256 pingId,
        address who,
        uint256 amount
    );

    /// Emitted before the state write so a trace shows how far a rejected proof got.
    event GatePassed(bytes32 indexed queryId, uint8 gate, string name);

    error NotOwner();
    error AlreadyProcessed(bytes32 queryId);
    error VerificationFailed();
    error BadTxType(uint8 txType);
    error TxDidNotSucceed(uint8 status);
    error NoMatchingLogs();
    error UnauthorizedSource(address emitter, address expected);

    constructor() { owner = msg.sender; }

    function setAuthorizedSource(uint64 chainKey, address source) external {
        if (msg.sender != owner) revert NotOwner();
        authorizedSource[chainKey] = source;
    }

    /// Official replay key: derived from the proof, never from caller-supplied values.
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

    /// Permissionless. Q4 submits this from an address unrelated to everything else.
    function submit(
        uint64 chainKey,
        uint64 blockHeight,
        bytes calldata encodedTransaction,
        bytes32 merkleRoot,
        INativeQueryVerifier.MerkleProofEntry[] calldata siblings,
        bytes32 lowerEndpointDigest,
        bytes32[] calldata continuityRoots
    ) external returns (uint256 accepted) {
        (bytes32 queryId, uint64 txIndex) =
            computeQueryId(chainKey, blockHeight, merkleRoot, siblings);

        // GATE 1 - replay. Derived key, so a spoofed txHash cannot bypass it.
        if (processedQueries[queryId]) revert AlreadyProcessed(queryId);
        emit GatePassed(queryId, 1, "replay");

        // GATE 2 - proof verification via the precompile.
        {
            INativeQueryVerifier.MerkleProof memory mp =
                INativeQueryVerifier.MerkleProof({root: merkleRoot, siblings: siblings});
            INativeQueryVerifier.ContinuityProof memory cp =
                INativeQueryVerifier.ContinuityProof({
                    lowerEndpointDigest: lowerEndpointDigest,
                    roots: continuityRoots
                });
            if (!VERIFIER.verifyAndEmit(chainKey, blockHeight, encodedTransaction, mp, cp)) {
                revert VerificationFailed();
            }
        }
        emit GatePassed(queryId, 2, "verifyAndEmit");

        // Mark AFTER verification, matching ASCBase: a bad proof must not burn the key.
        processedQueries[queryId] = true;

        // GATE 3 - transaction type.
        uint8 txType = EvmV1Decoder.getTransactionType(encodedTransaction);
        if (!EvmV1Decoder.isValidTransactionType(txType)) revert BadTxType(txType);
        emit GatePassed(queryId, 3, "txType");

        // GATE 4 - receipt status. Required by Attestcoin ASC security guidance.
        EvmV1Decoder.ReceiptFields memory receipt =
            EvmV1Decoder.decodeReceiptFields(encodedTransaction);
        if (receipt.receiptStatus != 1) revert TxDidNotSucceed(receipt.receiptStatus);
        emit GatePassed(queryId, 4, "receiptStatus");

        // GATE 5 - locate our logs. One transaction can carry many.
        EvmV1Decoder.LogEntry[] memory logs =
            EvmV1Decoder.getLogsByEventSignature(receipt, SPIKE_PING_SIG);
        if (logs.length == 0) revert NoMatchingLogs();
        emit GatePassed(queryId, 5, "logsFound");

        // GATE 6 - every log must come from the authorized emitter.
        address expected = authorizedSource[chainKey];
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].address_ != expected) {
                revert UnauthorizedSource(logs[i].address_, expected);
            }
        }
        emit GatePassed(queryId, 6, "sourceAuthorized");

        // Fan out: one submission, N accepted events.
        for (uint256 i = 0; i < logs.length; i++) {
            EvmV1Decoder.LogEntry memory lg = logs[i];
            emit SpikeAccepted(
                queryId,
                chainKey,
                blockHeight,
                txIndex,
                logs.length,
                uint256(lg.topics[1]),                        // indexed id
                address(uint160(uint256(lg.topics[2]))),      // indexed who
                abi.decode(lg.data, (uint256))                // non-indexed amount
            );
        }
        return logs.length;
    }
}
