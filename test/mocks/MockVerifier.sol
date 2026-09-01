// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {INativeQueryVerifier} from "../../src/Types.sol";

/// @title MockVerifier - stand-in for the Attestcoin precompile at 0x...0FD2.
/// @notice The precompile is native and does not exist in a Foundry EVM, so gate-level
///         unit tests etch this at that address instead.
///
///         IMPORTANT - this mock proves NOTHING about the protocol. It exists to make our
///         six gates deterministically testable. The real-network evidence lives in
///         evidence/G0-A/, and the two must never be conflated:
///
///           REAL NETWORK   G0-A tx -> actual precompile -> actual receipt -> actual rejection
///           UNIT TEST      mock    -> forced conditions  -> our ASC rejects
///
///         Neither substitutes for the other.
contract MockVerifier is INativeQueryVerifier {
    /// What verifyAndEmit returns. Default true; set false to simulate a bad proof.
    bool public verifyResult = true;

    /// Whether verifyAndEmit should revert outright, as the precompile may on malformed input.
    bool public shouldRevert;

    /// txIndex returned by calculateTxIndex. This is the value the ASC derives its replay
    /// identity from, so tests drive it here to prove the caller cannot influence it.
    uint64 public txIndexToReturn;

    /// Recorded so tests can assert the ASC forwarded exactly what it was given.
    uint64 public lastChainKey;
    uint64 public lastHeight;
    bytes  public lastEncodedTransaction;
    uint256 public verifyCallCount;

    function setVerifyResult(bool v) external { verifyResult = v; }
    function setShouldRevert(bool v) external { shouldRevert = v; }
    function setTxIndex(uint64 v)    external { txIndexToReturn = v; }

    function verifyAndEmit(
        uint64 chainKey,
        uint64 height,
        bytes calldata encodedTransaction,
        MerkleProof calldata,
        ContinuityProof calldata
    ) external returns (bool) {
        if (shouldRevert) revert("MockVerifier: forced revert");
        verifyCallCount++;
        lastChainKey = chainKey;
        lastHeight = height;
        lastEncodedTransaction = encodedTransaction;
        return verifyResult;
    }

    /// Deliberately ignores the merkle proof. The point of the replay tests is that the
    /// ASC takes txIndex from HERE and not from anything the caller passed, so the tests
    /// hold this constant while varying every caller-supplied field.
    function calculateTxIndex(MerkleProof calldata) external view returns (uint64) {
        return txIndexToReturn;
    }
}
