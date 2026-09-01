# G0-A - single proof, end to end

**Status:** ✅ **GATE PASSED**
**Date:** 2026-09-01
**Networks:** Ethereum Sepolia (chainKey 1) → Creditcoin CC3 testnet (chain 102031)

One real Ethereum event became one verified Creditcoin state transition. All seven questions
answered against live networks on the first complete run.

Every entry below separates three things that must never be blended:

- **OFFICIAL** - what the protocol documentation promises.
- **MEASURED** - what the networks actually did, with transaction hashes.
- **DECISION** - what ProofLine does in response.

---

## Contracts deployed for this test

Throwaway. They share no code with the ProofLine contracts and exist only to be measured.

| Chain | Contract | Address | Deploy gas |
|---|---|---|---|
| Sepolia | `SpikeSource` | `0x26b83c601609DDdBC78CEe99825b84f74741837A` | 190,920 |
| Sepolia | `SpikeImposter` | `0x3513B2da2b823f084610a2797a7Cc8052b87b093` | 87,359 |
| CC3 | `SpikeASC` | `0x26b83c601609DDdBC78CEe99825b84f74741837A` | 1,203,400 |

`authorizedSource[1] = 0x26b8…837A`, set in a separate transaction, 86,324 gas.

## Source transactions

| Label | Tx hash | Block | Status |
|---|---|---|---|
| happy | `0x47fea6037392015b99b578008ba3737ddf699aacd2d61e3c50c758172f5e5644` | 11613020 | 1 |
| batch3 | `0xb230a019efedebd2543efdcbd475c285e7febfd2a31534355265dc5de023f79a` | 11613021 | 1 |
| imposter | `0x7fafc76ac6f0fe7cbfcaf34e3d2cdced2bbb686c4cea238256cb12314b9f4d24` | 11613022 | 1 |
| revertAfterEmit | `0x2ff03bda82c18a72b42358a47707cf5dc772c96c8b0d63a116c5bf0932e73cff` | 11613023 | **0** |
| relayTarget | `0xe60e2683c699f9f48ba62c951a7c25fcc87a495d9b74726cd1e8ad90e19885cd` | 11613025 | 1 |

---

## Q1 - Does a fresh Sepolia event produce a valid proof CC3 accepts?

**OFFICIAL:** An ASC verifies proofs synchronously by calling the Block Prover precompile at
`0x…0FD2` via `verifyAndEmit`.

**MEASURED:** Yes. CC3 tx `0x9b7b9fc894a9dfae…`, all six gates passed in order:
`replay → verifyAndEmit → txType → receiptStatus → logsFound → sourceAuthorized`.
One `SpikeAccepted` event emitted, carrying the decoded id, sender and amount.

**DECISION:** The architecture is viable. Proceed to the real build.

---

## Q2 - What is the real end-to-end attestation latency?

**OFFICIAL:** Not documented. No figure appears anywhere in the Attestcoin docs.

**MEASURED:** **8.7 minutes** (522.1s) from the highest source transaction being mined to that
height being attested. 22 poll cycles at 15s.

Attested height advanced in **~10-block steps**, not continuously:

```
11613000 → 11613010 → 11613020 → 11613025 (target reached)
```

An earlier run measured attested height 37 blocks behind Sepolia head at the moment of polling.

Proof *construction*, once a height is attested, is fast: **244-669 ms**. The 8.7 minutes is
entirely attestation lag, not proving cost.

**DECISION:** Three consequences.

1. The demo cannot prove a fresh event live inside four minutes. The verified-credit-history
   approach is confirmed, not merely convenient.
2. The UI pipeline must be genuinely asynchronous, with real pending states naming the height
   being waited on - attestation visibly lags, so pretending otherwise would be a lie the
   protocol itself contradicts.
3. Fixtures are captured on first success so development iterates in milliseconds, not minutes.

---

## Q3 - What does verification cost on CC3?

**OFFICIAL:** A gas-costs page exists but gives no figure for this path.

**MEASURED:**

| Ingest | Gas | Per event |
|---|---|---|
| 1 log | 126,854 | 126,854 |
| 3 logs (one tx) | 138,950 | 46,317 |

Two additional events cost **12,096 gas** - about 6,000 each, against ~127,000 for the first.
Essentially all the cost is proof verification; decoding extra logs is nearly free.

**DECISION:** Same-transaction underwriting has ample block budget; the risk that verification
would crowd out the credit calculation does not materialise. It also makes the fan-out model
(below) strongly preferable on cost, not only on safety.

---

## Q4 - Is proof relay permissionless?

**OFFICIAL:** Not stated explicitly.

**MEASURED:** Yes. `0x8468d2eB6cB8CE29D756EFD2B733a9d002F3FbE1` - an address that is not the
deployer, not the ASC owner, and unrelated to the source contract - submitted a fresh, unconsumed
proof and it fully succeeded. CC3 tx `0x43d1101a650e75cc…`, 129,094 gas, all six gates passed.

**DECISION:** The ProofLine worker is convenience infrastructure, not a trust assumption. If it
stops, anyone can keep the credit file advancing. Stated in the README as a decentralisation
property we get from the protocol rather than one we built.

---

## Q5 - Is an unauthorized source rejected?

**OFFICIAL:** The loan-flow tutorial warns that without an emitter check, anyone can deploy a
contract emitting the same event and prove it fraudulently.

**MEASURED:** Rejected. `SpikeImposter` emitted a byte-identical `SpikePing` from a different
address. The proof was valid, verification passed, the receipt decoded, and the log was found -
then gate 6 rejected it:

```
UnauthorizedSource(0x3513B2da2b823f084610a2797a7Cc8052b87b093,
                   0x26b83c601609DDdBC78CEe99825b84f74741837A)
```

**DECISION:** Emitter authorisation is the last gate, not the first - the emitter address only
exists after the receipt is decoded, which requires verification first. Our original spec had
this backwards.

---

## Q6 - What is the replay behaviour?

**OFFICIAL:** `ASCBase` computes a query id as
`keccak256(chainKey, blockHeight, txIndex)` where `txIndex` comes from
`VERIFIER.calculateTxIndex(merkleProof)` - derived from the proof, never supplied by the caller.

**MEASURED (a):** Resubmitting the identical proof was rejected with
`AlreadyProcessed(0xa6949cfad87897b1…)`.

**MEASURED (b):** `pingBatch(3)` - one transaction, three logs - produced **one** submission and
**three** accepted events. CC3 tx `0x121b675451103c22…`, 138,950 gas.

**DECISION - architecture change.** ProofLine's frozen spec keyed replay on
`(chainKey, txHash, logIndex)` with both supplied by the caller and neither verified against the
proof. That is **exploitable**: submit one valid proof twice under two different claimed
`txHash` values and both pass, double-crediting the credit file from a single real settlement.

Replaced with the proof-derived identity, and the ingestion model becomes:

```
one Ethereum transaction → one proof → one verified receipt → N matching logs → N CreditEvents
```

`logIndex` disappears as a caller-controlled input entirely.

---

## Q7 - Does the proof establish that the transaction succeeded?

**OFFICIAL:** "A dApp's ASC **MUST** check the 'status' field of the transaction to ensure
security." - Attestcoin Smart Contracts documentation.

**MEASURED (live):** `pingThenRevert` emitted `SpikePing` and then reverted. Sepolia tx
`0x2ff03bda82c18a72…`, block 11613023, **receiptStatus 0**.

The proof built normally. Verification passed. Transaction-type validation passed. The
pipeline reached gate 4 and stopped there with `TxDidNotSucceed(0)`.

**MEASURED (decoder, against the captured vector):**

| Vector | receiptStatus | logs in receipt |
|---|---|---|
| revertAfterEmit | 0 | **0** |
| happy | 1 | 1 |
| batch3 | 1 | 3 |

> ### Correction - 2026-09-01
>
> An earlier version of this document claimed the reverted transaction's log **remained
> visible** to the decoder, and called `receiptStatus` the only barrier against a
> manufactured credit history. **That was wrong.**
>
> It was an inference, not a measurement. Gate 4 fires before gate 5, so the live run
> stopped before ever looking for logs; the presence of logs was assumed, not observed.
> Decoding the captured vector directly shows the receipt carries **zero** logs - standard
> EVM semantics, where reverted execution discards its logs.
>
> Recorded rather than quietly edited, because the distinction between what we measured and
> what we inferred is the whole point of this directory.

**What is actually true:** a reverted transaction is included in the block and **is provable
through Attestcoin** - the proof builds and verifies normally. What it cannot carry is logs.
So gates 4 and 5 reject it **independently**.

**DECISION:** Gate 4 stays, for reasons that survive the correction.

1. It is a documented protocol **MUST**, not our judgement call.
2. The rejection reason must be unambiguous. `NoMatchingLogs` means "wrong event type, or
   nothing here, or it reverted" - three very different situations. `TxDidNotSucceed` means
   one thing, which matters when a judge is reading a failed submission on screen.
3. We decline to rest credit-file integrity on an emergent property of EVM log semantics
   when the protocol asks for an explicit check. Defence in depth is cheap; the check costs
   one comparison.

Both halves are now regression-locked in `test/ProtocolVectors.t.sol` against the real
captured vector.

## Additional measured behaviour

### Transient prover failure is not proof failure

**OBSERVED:** `connect ETIMEDOUT 48.206.104.94:443` against the prover API at the 281-second
mark, mid-wait. An earlier run died outright on a 30-second HTTP timeout and reported it as an
attestation failure.

**RESPONSE:** Resilient polling - 120s request timeout, retry on transport errors, 25-minute
overall deadline. The retry absorbed the timeout and the wait completed normally.

**IMPLICATION:** The worker must distinguish three states that all look like "it didn't work":
network or prover unavailability, an attestation that has not happened yet, and a proof that is
genuinely invalid. Only the third is a rejection. Conflating them would have had us report a
working protocol as broken - which is exactly what the first run did.

### Continuity proof size varies with checkpoint distance

**OBSERVED:** Continuity roots across five transactions in six consecutive blocks:

| Tx | Header | txIndex | Merkle siblings | Continuity roots |
|---|---|---|---|---|
| happy | 11613020 | 131 | 8 | **1** |
| batch3 | 11613021 | 81 | 7 | **10** |
| imposter | 11613022 | 79 | 8 | **9** |
| revertAfterEmit | 11613023 | 62 | 7 | **8** |
| relayTarget | 11613025 | 129 | 8 | **6** |

Root count is not a function of block height alone - it reflects distance from the attestation
checkpoint the proof chains back to.

**IMPLICATION:** This is the mechanism behind proof expiry. As checkpoints advance, the
continuity chain a given proof needs changes, which is why a proof does not stay valid forever.
It also means proof calldata size varies between transactions, so gas is not perfectly constant.
Not yet measured: how long a proof remains acceptable. **Open for G0-B.**

---

## Fixtures

All five proofs captured in `fixtures/`. Decoder and payload iteration no longer costs 8.7
minutes per cycle.

**Boundary:** a fixture proves the decode path indefinitely. It does **not** prove CC3 would
accept that proof today - continuity checkpoints advance. Fixture tests and live verification
are labelled separately, and an expired fixture is never presented as evidence of on-chain
acceptance.

---

## Outcome

- [x] **GATE PASSED** - proof verified on CC3. Proceed.
- [ ] GATE FAILED - skip CTC.

**Four corrections the protocol requires**, each now backed by a transaction rather than a
reading of the docs:

1. `chainKey` and `blockHeight` are `uint64`, not `uint32`.
2. Replay identity is `keccak256(chainKey, blockHeight, txIndex)`, derived from the proof.
3. One verified transaction fans out to N credit events; `logIndex` is not a caller input.
4. Transaction type and `receiptStatus == 1` are validated before any log is trusted.
