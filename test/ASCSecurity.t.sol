// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/write-ability/common/EvmV1Decoder.sol";
import {ASCReceiver} from "../src/ASCReceiver.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";
import {
    INativeQueryVerifier, ICreditFile, CreditEvent, CreditEventType, File, Terms,
    ProofLineConstants
} from "../src/Types.sol";

/// Records what the receiver forwarded. Deliberately dumb - accepts everything, so any
/// rejection observed in these tests came from a gate and not from downstream validation.
contract RecordingCreditFile is ICreditFile {
    CreditEvent[] public received;
    function applyVerifiedEvent(CreditEvent calldata e) external { received.push(e); }
    function count() external view returns (uint256) { return received.length; }
    function getCreditFile(address) external pure returns (File memory f) { return f; }
    function getCreditEvents(address) external pure returns (CreditEvent[] memory c) { return c; }
    function getTerms(address) external pure returns (Terms memory t) { return t; }
}

/// Harness: swaps the production Receivable-ABI decoder for a trivial one, so the gate
/// tests can run against the real SpikePing vectors captured in G0-A.
contract HarnessASC is ASCReceiver {
    constructor(ICreditFile c) ASCReceiver(c) {}

    function _toCreditEvent(
        uint64 chainKey, uint64 blockHeight, uint64 txIndex, uint32 logIndex,
        address sourceContract, EvmV1Decoder.LogEntry memory lg, bytes32 sig
    ) internal view override returns (CreditEvent memory e) {
        e.chainKey = chainKey;
        e.blockHeight = blockHeight;
        e.txIndex = txIndex;
        e.logIndex = logIndex;
        e.sourceContract = sourceContract;
        e.eventType = eventTypeOf[sig];
        e.obligationId = uint256(lg.topics[1]);
        e.borrower = address(uint160(uint256(lg.topics[2])));
        e.amount = abi.decode(lg.data, (uint256));
    }
}

/// @title ASC security - the six-gate state machine, deterministically.
///
/// @notice HYBRID by design. The encoded transactions are REAL - captured from the live
///         Attestcoin prover in G0-A - and the decoder is the REAL EvmV1Decoder. Only the
///         precompile is mocked, because it is native and does not exist in a Foundry EVM.
///
///         The mock is deliberately stupid: it returns controlled values and reproduces no
///         cryptography. It proves nothing about Attestcoin. Real protocol behaviour is
///         evidenced in ProtocolVectors.t.sol and evidence/G0-A. Neither substitutes for
///         the other, and the repo should never present them as if they did.
contract ASCSecurityTest is Test {
    bytes32 constant SPIKE_PING_SIG = keccak256("SpikePing(uint256,address,uint256)");
    address constant SPIKE_SOURCE   = 0x26b83c601609DDdBC78CEe99825b84f74741837A;
    address constant SPIKE_IMPOSTER = 0x3513B2da2b823f084610a2797a7Cc8052b87b093;
    uint64  constant CK = 1;

    MockVerifier v;
    RecordingCreditFile cf;
    HarnessASC asc;

    struct Vec {
        bytes txBytes;
        bytes32 root;
        INativeQueryVerifier.MerkleProofEntry[] siblings;
        bytes32 lower;
        bytes32[] roots;
        uint64 header;
    }

    function setUp() public {
        v = new MockVerifier();
        vm.etch(ProofLineConstants.VERIFY_PRECOMPILE, address(v).code);
        v = MockVerifier(ProofLineConstants.VERIFY_PRECOMPILE);
        v.setVerifyResult(true);
        v.setTxIndex(131);

        cf = new RecordingCreditFile();
        asc = new HarnessASC(ICreditFile(address(cf)));
        asc.setAuthorizedSource(CK, SPIKE_SOURCE);
        asc.registerEventType(SPIKE_PING_SIG, CreditEventType.ObligationSettled);
    }

    function _vec(string memory name) internal view returns (Vec memory x) {
        string memory j = vm.readFile(string.concat("evidence/G0-A/fixtures/flat/", name, ".json"));
        x.txBytes = vm.parseJsonBytes(j, ".txBytes");
        x.root    = vm.parseJsonBytes32(j, ".root");
        x.lower   = vm.parseJsonBytes32(j, ".lower");
        x.roots   = vm.parseJsonBytes32Array(j, ".roots");
        x.header  = uint64(vm.parseJsonUint(j, ".header"));
        bytes32[] memory hashes = vm.parseJsonBytes32Array(j, ".siblingHashes");
        bool[] memory lefts     = vm.parseJsonBoolArray(j, ".siblingIsLeft");
        x.siblings = new INativeQueryVerifier.MerkleProofEntry[](hashes.length);
        for (uint256 i = 0; i < hashes.length; i++) {
            x.siblings[i] = INativeQueryVerifier.MerkleProofEntry({hash: hashes[i], isLeft: lefts[i]});
        }
    }

    function _submit(Vec memory x) internal returns (uint256) {
        return asc.submitProof(CK, x.header, x.txBytes, x.root, x.siblings, x.lower, x.roots, SPIKE_PING_SIG);
    }

    // ------------------------------------------------------------ happy path

    function test_validProofCreatesOneCreditEvent() public {
        assertEq(_submit(_vec("happy")), 1);
        assertEq(cf.count(), 1);
    }

    /// One proof, three logs, three credit events. The fan-out model.
    function test_oneProofYieldsThreeCreditEvents() public {
        v.setTxIndex(81);
        assertEq(_submit(_vec("batch3")), 3);
        assertEq(cf.count(), 3, "one submission, three events");
    }

    // ------------------------------------------------------------ THE replay attack
    //
    // Not merely "same proof twice reverts". The actual vulnerability in our earlier
    // design: the attacker varies every caller-supplied field, and the identity refuses
    // to move because it is derived by the precompile from the proof itself.

    function test_replayCannotBeSpoofedByVaryingCallerSuppliedFields() public {
        Vec memory x = _vec("happy");
        assertEq(_submit(x), 1);
        assertEq(cf.count(), 1);

        (bytes32 qid,) = asc.computeQueryId(CK, x.header, x.root, x.siblings);

        // 1. identical resubmission
        vm.expectRevert(abi.encodeWithSelector(ASCReceiver.AlreadyProcessed.selector, qid));
        _submit(x);

        // 2. attacker claims a different event signature - no new identity
        vm.expectRevert(abi.encodeWithSelector(ASCReceiver.AlreadyProcessed.selector, qid));
        asc.submitProof(CK, x.header, x.txBytes, x.root, x.siblings, x.lower, x.roots, keccak256("Other(uint256)"));

        // 3. attacker mangles the continuity proof - still the same identity
        bytes32[] memory fakeRoots = new bytes32[](1);
        fakeRoots[0] = bytes32(uint256(0xdead));
        vm.expectRevert(abi.encodeWithSelector(ASCReceiver.AlreadyProcessed.selector, qid));
        asc.submitProof(CK, x.header, x.txBytes, x.root, x.siblings, bytes32(uint256(1)), fakeRoots, SPIKE_PING_SIG);

        // 4. a DIFFERENT sender cannot launder it either
        vm.prank(address(0xA77ACC));
        vm.expectRevert(abi.encodeWithSelector(ASCReceiver.AlreadyProcessed.selector, qid));
        _submit(x);

        assertEq(cf.count(), 1, "exactly one credit event survives every variation");
    }

    /// The identity depends ONLY on chainKey, blockHeight and the precompile-derived index.
    function test_queryIdIgnoresEverythingTheCallerControls() public view {
        Vec memory a = _vec("happy");
        Vec memory b = _vec("relayTarget");   // different tx, different bytes
        (bytes32 qa,) = asc.computeQueryId(CK, 999, a.root, a.siblings);
        (bytes32 qb,) = asc.computeQueryId(CK, 999, b.root, b.siblings);
        assertEq(qa, qb, "same chainKey+height+derived txIndex, so same identity");
    }

    /// Changing blockHeight DOES create a new identity - that is correct, because a
    /// different height is a genuinely different transaction position.
    function test_differentHeightIsADifferentIdentity() public view {
        Vec memory x = _vec("happy");
        (bytes32 q1,) = asc.computeQueryId(CK, x.header, x.root, x.siblings);
        (bytes32 q2,) = asc.computeQueryId(CK, x.header + 1, x.root, x.siblings);
        assertTrue(q1 != q2);
    }

    // ------------------------------------------------------------ gates

    function test_gate2_failedVerificationReverts() public {
        Vec memory x = _vec("happy");
        v.setVerifyResult(false);
        vm.expectRevert(ASCReceiver.VerificationFailed.selector);
        _submit(x);
        assertEq(cf.count(), 0);
    }

    /// A rejected proof must NOT burn its query id.
    function test_failedVerificationDoesNotConsumeTheQueryId() public {
        Vec memory x = _vec("happy");
        v.setVerifyResult(false);
        vm.expectRevert(ASCReceiver.VerificationFailed.selector);
        _submit(x);

        v.setVerifyResult(true);
        assertEq(_submit(x), 1, "the legitimate proof still lands afterwards");
    }

    function test_gate4_revertedSourceTransactionRejected() public {
        Vec memory x = _vec("revertAfterEmit");
        v.setTxIndex(62);
        vm.expectRevert(abi.encodeWithSelector(ASCReceiver.TxDidNotSucceed.selector, 0));
        _submit(x);
        assertEq(cf.count(), 0, "no credit from a transaction that failed");
    }

    function test_gate5_noMatchingLogsRejected() public {
        Vec memory x = _vec("happy");
        vm.expectRevert(ASCReceiver.NoMatchingLogs.selector);
        asc.submitProof(CK, x.header, x.txBytes, x.root, x.siblings, x.lower, x.roots, keccak256("Nope(uint256)"));
    }

    function test_gate6_unauthorizedEmitterRejected() public {
        Vec memory x = _vec("imposter");
        v.setTxIndex(79);
        vm.expectRevert(abi.encodeWithSelector(
            ASCReceiver.UnauthorizedSource.selector, SPIKE_IMPOSTER, SPIKE_SOURCE));
        _submit(x);
        assertEq(cf.count(), 0);
    }

    function test_unconfiguredChainKeyRejected() public {
        Vec memory x = _vec("happy");
        vm.expectRevert(abi.encodeWithSelector(ASCReceiver.SourceNotConfigured.selector, uint64(99)));
        asc.submitProof(99, x.header, x.txBytes, x.root, x.siblings, x.lower, x.roots, SPIKE_PING_SIG);
    }

    // ------------------------------------------------------------ gate ORDERING
    //
    // The order is not arbitrary: some information does not exist until after
    // verification. Proven by showing an earlier gate fires while a later one would
    // also have rejected.

    /// Ordering is proven by WHICH error returns, not by counting calls on the mock.
    /// A revert rolls back the mock's own counters, so any call-count assertion across a
    /// failing submission is vacuous - it would hold whether or not the order were correct.
    /// The error identity does discriminate, because only one gate can be the first to fail.

    /// Gate 1 before gate 2: with verification forced to FAIL, an already-consumed proof
    /// still returns AlreadyProcessed. If gate 2 ran first it would return VerificationFailed.
    function test_gate1PrecedesGate2() public {
        Vec memory x = _vec("happy");
        _submit(x);
        (bytes32 qid,) = asc.computeQueryId(CK, x.header, x.root, x.siblings);

        v.setVerifyResult(false);
        vm.expectRevert(abi.encodeWithSelector(ASCReceiver.AlreadyProcessed.selector, qid));
        _submit(x);
    }

    /// Gate 2 before gate 6: with verification forced to FAIL, the imposter vector returns
    /// VerificationFailed rather than UnauthorizedSource - so the emitter was never read.
    function test_gate2PrecedesGate6() public {
        Vec memory x = _vec("imposter");
        v.setTxIndex(79);
        v.setVerifyResult(false);
        vm.expectRevert(ASCReceiver.VerificationFailed.selector);
        _submit(x);
    }

    /// And with verification succeeding, the SAME vector reaches gate 6. The pair together
    /// prove the emitter check happens strictly after verification and decoding - which is
    /// forced, because the emitter address does not exist until the receipt is decoded.
    function test_gate6IsReachedOnlyAfterVerificationSucceeds() public {
        Vec memory x = _vec("imposter");
        v.setTxIndex(79);
        v.setVerifyResult(true);
        vm.expectRevert(abi.encodeWithSelector(
            ASCReceiver.UnauthorizedSource.selector, SPIKE_IMPOSTER, SPIKE_SOURCE));
        _submit(x);
        assertEq(cf.count(), 0);
    }

    /// Gate 4 before gate 5: the reverted vector has status 0 AND zero logs, so both gates
    /// would reject. TxDidNotSucceed proves gate 4 is the one that fires.
    function test_gate4PrecedesGate5() public {
        Vec memory x = _vec("revertAfterEmit");
        v.setTxIndex(62);
        vm.expectRevert(abi.encodeWithSelector(ASCReceiver.TxDidNotSucceed.selector, 0));
        _submit(x);
    }

    // ------------------------------------------------------------ permissionless

    function test_anyRelayerCanSubmit() public {
        vm.prank(address(0xDEADBEEF));   // not owner, not deployer, unrelated
        assertEq(_submit(_vec("happy")), 1);
        assertEq(cf.count(), 1);
    }

    function test_onlyOwnerCanAuthorizeSources() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(ASCReceiver.NotOwner.selector);
        asc.setAuthorizedSource(CK, address(0xBAD));
    }
}
