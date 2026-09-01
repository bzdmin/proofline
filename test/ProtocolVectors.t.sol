// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/write-ability/common/EvmV1Decoder.sol";

/// @title ProtocolVectors — the real EvmV1Decoder against real proofs captured in G0-A.
///
/// @notice This is the PROTOCOL EVIDENCE layer. No mocks, no synthesised bytes: every
///         vector is an `encodedTransaction` returned by the live Attestcoin prover for a
///         transaction that actually happened on Ethereum Sepolia on 2026-09-01.
///
///         These tests exist to lock in what G0-A discovered, so a later refactor cannot
///         quietly erase a finding. They assert protocol behaviour only — nothing here
///         touches a ProofLine contract.
contract ProtocolVectorsTest is Test {
    // keccak256("SpikePing(uint256,address,uint256)")
    bytes32 constant SPIKE_PING_SIG = keccak256("SpikePing(uint256,address,uint256)");

    address constant SPIKE_SOURCE   = 0x26b83c601609DDdBC78CEe99825b84f74741837A;
    address constant SPIKE_IMPOSTER = 0x3513B2da2b823f084610a2797a7Cc8052b87b093;

    function _vector(string memory name) internal view returns (bytes memory) {
        string memory json = vm.readFile(
            string.concat("evidence/G0-A/fixtures/", name, ".json")
        );
        return vm.parseJsonBytes(json, ".proof.txBytes");
    }

    // ------------------------------------------------------------------ Q7
    // The finding this whole gate exists for.

    /// A transaction that emitted and then reverted carries receiptStatus 0.
    function test_revertedTransactionHasStatusZero() public view {
        EvmV1Decoder.ReceiptFields memory r =
            EvmV1Decoder.decodeReceiptFields(_vector("revertAfterEmit"));
        assertEq(r.receiptStatus, 0, "reverted tx must report status 0");
    }

    /// CORRECTED 2026-09-01. An earlier claim in this repo said the reverted
    /// transaction's logs remained visible to the decoder. They do not.
    ///
    /// A reverted transaction is INCLUDED in the block and IS provable through
    /// Attestcoin — but its logs are discarded, per standard EVM semantics. So the
    /// receipt carries status 0 and an empty log array.
    ///
    /// Consequence: gate 4 (receiptStatus) and gate 5 (logsFound) BOTH reject it
    /// independently. Gate 4 is defence in depth and a documented protocol MUST — it
    /// is not the sole barrier, and this repo must not claim that it is.
    function test_revertedTransactionCarriesNoLogs() public view {
        EvmV1Decoder.ReceiptFields memory r =
            EvmV1Decoder.decodeReceiptFields(_vector("revertAfterEmit"));

        assertEq(r.receiptStatus, 0, "status 0");
        assertEq(r.receiptLogs.length, 0, "reverted execution discards its logs");

        EvmV1Decoder.LogEntry[] memory logs =
            EvmV1Decoder.getLogsByEventSignature(r, SPIKE_PING_SIG);
        assertEq(logs.length, 0, "nothing for an ASC to act on");
    }

    /// Why gate 4 stays despite gate 5 also catching this: the rejection reason must be
    /// unambiguous. NoMatchingLogs means "wrong event type, or nothing here, or it
    /// reverted" — three very different situations. TxDidNotSucceed means one thing.
    /// We also decline to rest credit-file integrity on an emergent property of EVM log
    /// semantics when the protocol documentation explicitly requires an explicit check.
    function test_gate4AndGate5AreIndependentDefences() public view {
        EvmV1Decoder.ReceiptFields memory r =
            EvmV1Decoder.decodeReceiptFields(_vector("revertAfterEmit"));
        assertTrue(r.receiptStatus != 1, "gate 4 would reject");
        assertTrue(EvmV1Decoder.getLogsByEventSignature(r, SPIKE_PING_SIG).length == 0,
                   "gate 5 would also reject");
    }

    /// The happy path for contrast.
    function test_successfulTransactionHasStatusOne() public view {
        EvmV1Decoder.ReceiptFields memory r =
            EvmV1Decoder.decodeReceiptFields(_vector("happy"));
        assertEq(r.receiptStatus, 1);
    }

    // ------------------------------------------------------------------ Q6
    // Fan-out: replay identity is per transaction, so one proof must yield N events.

    function test_oneTransactionCarriesThreeLogs() public view {
        EvmV1Decoder.ReceiptFields memory r =
            EvmV1Decoder.decodeReceiptFields(_vector("batch3"));

        EvmV1Decoder.LogEntry[] memory logs =
            EvmV1Decoder.getLogsByEventSignature(r, SPIKE_PING_SIG);

        assertEq(logs.length, 3, "one proof must fan out to three credit events");
        for (uint256 i = 0; i < logs.length; i++) {
            assertEq(logs[i].address_, SPIKE_SOURCE, "every log from the authorized source");
        }
    }

    // ------------------------------------------------------------------ Q5
    // A byte-identical event from an unauthorized contract.

    function test_imposterEmitsIdenticalEventFromDifferentAddress() public view {
        EvmV1Decoder.ReceiptFields memory r =
            EvmV1Decoder.decodeReceiptFields(_vector("imposter"));

        EvmV1Decoder.LogEntry[] memory logs =
            EvmV1Decoder.getLogsByEventSignature(r, SPIKE_PING_SIG);

        assertGt(logs.length, 0, "the fake event is found by signature");
        assertEq(logs[0].topics[0], SPIKE_PING_SIG, "signature is identical to the real one");
        assertEq(logs[0].address_, SPIKE_IMPOSTER, "only the emitter distinguishes it");
        assertTrue(logs[0].address_ != SPIKE_SOURCE, "emitter check is the ONLY defence here");
    }

    // ------------------------------------------------------------------ decoding

    /// Every field the underwriter needs must survive the round trip, because the ASC
    /// cannot read source-chain state afterwards.
    function test_decodedFieldsSurviveTheRoundTrip() public view {
        EvmV1Decoder.ReceiptFields memory r =
            EvmV1Decoder.decodeReceiptFields(_vector("happy"));

        EvmV1Decoder.LogEntry[] memory logs =
            EvmV1Decoder.getLogsByEventSignature(r, SPIKE_PING_SIG);

        assertEq(logs.length, 1);
        assertEq(logs[0].topics.length, 3, "sig + two indexed params");

        uint256 pingId = uint256(logs[0].topics[1]);
        address who    = address(uint160(uint256(logs[0].topics[2])));
        uint256 amount = abi.decode(logs[0].data, (uint256));

        assertGt(pingId, 0, "indexed uint256 decodes");
        assertTrue(who != address(0), "indexed address decodes");
        assertEq(amount, 1_000_000, "non-indexed uint256 decodes to the value we sent");
    }

    function test_transactionTypeIsValidForAllVectors() public view {
        string[5] memory names =
            ["happy", "batch3", "imposter", "revertAfterEmit", "relayTarget"];
        for (uint256 i = 0; i < names.length; i++) {
            uint8 t = EvmV1Decoder.getTransactionType(_vector(names[i]));
            assertTrue(EvmV1Decoder.isValidTransactionType(t), "valid tx type");
        }
    }

    /// Gas used is recoverable from the receipt — worth knowing we have it, since the
    /// borrowing-base logic never needs it but the evidence layer might.
    function test_receiptExposesGasUsed() public view {
        EvmV1Decoder.ReceiptFields memory r =
            EvmV1Decoder.decodeReceiptFields(_vector("happy"));
        assertGt(r.receiptGasUsed, 0);
    }
}
