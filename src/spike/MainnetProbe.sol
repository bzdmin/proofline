// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/write-ability/common/EvmV1Decoder.sol";
import {INativeQueryVerifier, ProofLineConstants} from "../Types.sol";

/// @title MainnetProbe - throwaway. Measures whether ProofLine's six-gate pipeline can
///        consume Ethereum mainnet (chainKey 3), using an event that already exists in the
///        wild rather than one we emitted.
///
/// @notice NOT part of ProofLine. It writes to no credit file, holds no capital and is
///         referenced by no production contract. It exists to answer one question and be
///         deleted, exactly like SpikeASC did for chainKey 1.
///
///         The gates are identical to ASCReceiver's. The only differences are that the event
///         signature is a parameter rather than the Receivable ABI, and that nothing is
///         decoded into a CreditEvent - we record what the gates saw, not what it means.
contract MainnetProbe {
    INativeQueryVerifier public constant VERIFIER =
        INativeQueryVerifier(ProofLineConstants.VERIFY_PRECOMPILE);

    address public owner;
    mapping(uint64 => address) public authorizedSource;
    mapping(bytes32 => bool) public processedQueries;

    event GateReached(uint8 gate, string name);
    event MainnetLogVerified(
        uint64 chainKey, uint64 blockHeight, uint64 txIndex,
        address emitter, uint256 logCount, uint256 topicCount, uint256 dataBytes
    );

    error NotOwner();
    error AlreadyProcessed(bytes32 q);
    error VerificationFailed();
    error BadTxType(uint8 t);
    error TxDidNotSucceed(uint8 s);
    error NoMatchingLogs();
    error UnauthorizedSource(address got, address want);

    constructor() { owner = msg.sender; }

    function setAuthorizedSource(uint64 chainKey, address source) external {
        if (msg.sender != owner) revert NotOwner();
        authorizedSource[chainKey] = source;
    }

    function submitProof(
        uint64 chainKey,
        uint64 blockHeight,
        bytes calldata encodedTransaction,
        bytes32 merkleRoot,
        INativeQueryVerifier.MerkleProofEntry[] calldata siblings,
        bytes32 lowerEndpointDigest,
        bytes32[] calldata continuityRoots,
        bytes32 eventSignature
    ) external returns (uint256 logsFound) {
        address expected = authorizedSource[chainKey];

        INativeQueryVerifier.MerkleProof memory mp =
            INativeQueryVerifier.MerkleProof({root: merkleRoot, siblings: siblings});
        uint64 txIndex = VERIFIER.calculateTxIndex(mp);
        bytes32 q = keccak256(abi.encodePacked(chainKey, blockHeight, txIndex));

        if (processedQueries[q]) revert AlreadyProcessed(q);
        emit GateReached(1, "replay");

        {
            INativeQueryVerifier.ContinuityProof memory cp =
                INativeQueryVerifier.ContinuityProof({
                    lowerEndpointDigest: lowerEndpointDigest, roots: continuityRoots });
            if (!VERIFIER.verifyAndEmit(chainKey, blockHeight, encodedTransaction, mp, cp)) {
                revert VerificationFailed();
            }
        }
        processedQueries[q] = true;
        emit GateReached(2, "verifyAndEmit");

        uint8 txType = EvmV1Decoder.getTransactionType(encodedTransaction);
        if (!EvmV1Decoder.isValidTransactionType(txType)) revert BadTxType(txType);
        emit GateReached(3, "txType");

        EvmV1Decoder.ReceiptFields memory receipt =
            EvmV1Decoder.decodeReceiptFields(encodedTransaction);
        if (receipt.receiptStatus != 1) revert TxDidNotSucceed(receipt.receiptStatus);
        emit GateReached(4, "receiptStatus");

        EvmV1Decoder.LogEntry[] memory logs =
            EvmV1Decoder.getLogsByEventSignature(receipt, eventSignature);
        if (logs.length == 0) revert NoMatchingLogs();
        emit GateReached(5, "logsFound");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].address_ != expected) {
                revert UnauthorizedSource(logs[i].address_, expected);
            }
        }
        emit GateReached(6, "sourceAuthorized");

        emit MainnetLogVerified(chainKey, blockHeight, txIndex, logs[0].address_,
                                logs.length, logs[0].topics.length, logs[0].data.length);
        return logs.length;
    }
}
