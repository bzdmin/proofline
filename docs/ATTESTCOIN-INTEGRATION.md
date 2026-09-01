# Attestcoin Protocol Integration Summary

**ProofLine** - verified Ethereum economic events become reusable Creditcoin credit state.

Every claim below is reproducible from this repository. Where we were wrong during
development, the correction is recorded rather than removed.

**Three categories, never blended.** Each claim in this document is tagged:

| Tag | Meaning |
|---|---|
| **[DOC]** | Attestcoin documented behaviour - quoted from the protocol docs |
| **[MEAS]** | ProofLine measured behaviour - observed on live chains, with transaction hashes |
| **[DESIGN]** | ProofLine design decision - our choice, and reversible by anyone building differently |

---

## 1. What Attestcoin does in ProofLine

Attestcoin is not a data feed here. It is the **only** thing that can change a borrower's
credit standing.

```
Ethereum Sepolia          Attestcoin              Creditcoin CC3
────────────────          ──────────              ──────────────
Receivable.sol      →     attestation       →     ASCReceiver.sol
  real mUSD moves         Merkle proof             six verification gates
  invariants enforced     continuity proof              ↓
                                                  CreditFile.sol   <- the primitive
                                                  append-only credit state
                                                       ↓
                                          ┌────────────┴────────────┐
                                     Treasury.sol            CreditAccess.sol
                                     working capital         deposit requirement
```

`CreditFile` has exactly one writer: `ASCReceiver`. `ASCReceiver` writes only after a proof
verifies on the precompile at `0x…0FD2`. **Remove Attestcoin and the credit file cannot
change at all** - not "the UI breaks", not "the worker stops fetching". The financial state
transition becomes impossible.

## 2. The six verification gates

Executed in this order in `ASCReceiver.submitProof`. The order is not arbitrary: some
information does not exist until after verification.

| # | Gate | Check | Category |
|---|---|---|---|
| 1 | Replay | `!processed[keccak256(chainKey, blockHeight, txIndex)]` | **[DESIGN]** following `ASCBase` |
| 2 | Proof | `VERIFIER.verifyAndEmit(...)` at `0x…0FD2` | **[DOC]** |
| 3 | Tx type | `EvmV1Decoder.isValidTransactionType(...)` | **[DOC]** official example |
| 4 | **Receipt status** | `receipt.receiptStatus == 1` | **[DOC] protocol MUST** |
| 5 | Logs present | `getLogsByEventSignature(...).length > 0` | **[DESIGN]** |
| 6 | Emitter | `log.address_ == authorizedSource[chainKey]` | **[DESIGN]** |

**Gate 1 uses a proof-derived identity.** `txIndex` comes from
`VERIFIER.calculateTxIndex(merkleProof)` - computed by the precompile from the proof itself.
An earlier revision of our design keyed replay on a caller-supplied `txHash` and `logIndex`.
That was exploitable: one valid proof submitted twice under two different claimed hashes
would pass both times, double-crediting the file from a single real settlement. Discovered
by reading `ASCBase.sol` in the official examples, not by testing.

**Gate 6 must come last.** The emitter address is only available after the receipt is
decoded, which requires the proof to have verified. There is no honest way to check the
source first.

**One proof, N credit events.** Replay identity is per *transaction*, and
`getLogsByEventSignature` returns every matching log in it, so a single submission fans out.
Measured: a three-log transaction produced three credit events for 12,096 gas more than one.

## 3. Measured protocol behaviour [MEAS]

None of the following is documented by Attestcoin. All of it was measured by us on
2026-09-01 against Sepolia (chainKey 1) and CC3 testnet (chain 102031).

| Measurement | Value | Consequence for ProofLine |
|---|---|---|
| End-to-end attestation | **7.96-8.7 min** | Demo cannot prove a fresh event live; the UI is genuinely asynchronous |
| Attestation cadence | ~10-block steps, not continuous | Pending states name the height being waited on |
| Proof construction, once attested | **244-669 ms** | All latency is attestation; fixtures make iteration instant |
| Protocol-only ingest (spike) | **126,854 gas** | Verification itself is cheap |
| **Production ingest (mean of 8)** | **321,498 gas** | The real figure - includes the credit file write |
| Marginal gas per extra event in one proof | **~6,000** | Fan-out is ~3× cheaper than per-log submission |
| Permissionless relay | **works** | Our worker is convenience, not a trust assumption |
| Continuity roots per proof | 1, 10, 9, 8, 6 across six consecutive blocks | Size tracks checkpoint distance - the expiry mechanism; gas is not constant |
| Prover reliability | one `ETIMEDOUT` at 281 s | Transport failure must not be classified as proof rejection |

Full three-layer write-up with transaction hashes: [`evidence/G0-A/README.md`](../evidence/G0-A/README.md).

## 3a. The complete economic lifecycle, live [MEAS]

Credit is not only earned here - it is used. Every row below is a live read from the
deployed contracts, captured in [`evidence/integration/borrow/borrow.json`](../evidence/integration/borrow/borrow.json).

| State | Tier | Capacity | Line | Available | Debt |
|---|---|---|---|---|---|
| Before receivable | TRUSTED | 9,600 | 9,600 | **0** | 0 |
| Receivable outstanding | TRUSTED | 9,600 | 9,600 | 9,600 | 0 |
| Borrowed 6,300 | TRUSTED | 9,600 | 9,600 | 3,300 | 6,300 |
| Repaid 3,150 | TRUSTED | 9,600 | 9,600 | **6,449.999** | **3,150.001** |

Three things this establishes.

**The first row is only representable because the three numbers are kept apart.** Earned
standing of 9,600 with nothing currently drawable. Collapse them into a single "credit
limit" and that state cannot be expressed - which is precisely the defect that once zeroed a
borrower's line at the moment they proved a perfect payment.

**Tier, capacity and line never moved.** Only `available` and `debt` responded to borrowing.
Standing is earned from proven history; liquidity tracks current receivables and debt.

**The fractional remainder is real interest.** Repaying exactly 3,150 left 3,150.001
outstanding, because interest accrued between the draw and the repayment. It is preserved
unrounded here deliberately: it is evidence that repayment interacts with live debt
accounting rather than a mocked balance.

Transactions: issue `0xbcd63bf4…` (proven in 7.8 min, 311,342 gas) · borrow `0xd3174e51…`
(171,528 gas) · repay `0x3cf490de…` (78,148 gas).

> **[DESIGN] Attestcoin is upstream of the credit decision, not downstream of the loan.**
> The borrowing contract consumes credit terms produced from verified economic history. It
> does not create or modify that history, and it cannot: `Treasury` has no write path to
> `CreditFile`. The same holds for `CreditAccess`, which sat at a 0% deposit requirement
> throughout the borrow and repayment because it reads `tier`, and borrowing does not touch
> tier.

## 4. A correction we are keeping in the record

During the spike we asserted that a reverted Ethereum transaction's logs **remain visible**
to the decoder, and described `receiptStatus` as the sole barrier against a manufactured
credit history.

**That was wrong.** It was an inference, not a measurement - gate 4 fires before gate 5, so
the live run stopped before ever looking for logs. Decoding the captured vector directly
shows the reverted receipt carries **zero** logs, per standard EVM semantics.

What is true: a reverted transaction **is** included and **is** provable through Attestcoin -
the proof builds and verifies normally - but it carries no logs, so gates 4 and 5 reject it
independently. Gate 4 is retained because it is a documented protocol MUST, because the
rejection reason must be unambiguous, and because credit-file integrity should not rest on
an emergent property of EVM log semantics.

Both halves are regression-locked in `test/ProtocolVectors.t.sol` against the real captured
vector. The correction is preserved in the evidence directory rather than edited away,
because the distinction between what we measured and what we inferred is the point.

## 5. Discrepancies between the official examples and the published packages

All three stop a team that follows the tutorial verbatim. Recorded in
[`evidence/G0-A/package-discrepancies.md`](../evidence/G0-A/package-discrepancies.md).

| Official example says | Published package contains | Result |
|---|---|---|
| `@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol` | `contracts/write-ability/common/EvmV1Decoder.sol` | source file not found |
| `pragma solidity ^0.8.23` | decoder requires `^0.8.28` | no matching solc |
| - | `verifyAndEmit` + locals overflow the stack | requires `via_ir` |

Also worth noting for other builders: `verifySingle` is the **JavaScript** SDK helper. The
Solidity surface is `verifyAndEmit` on the precompile, taking the encoded transaction plus
`MerkleProof` and `ContinuityProof` structs. Writing a contract against the SDK signature
produces an interface that does not exist on-chain.

## 6. The source contract is part of the trust boundary [DESIGN]

Attestcoin proves that an authorized contract emitted a log in a transaction that succeeded.
It does **not** prove the log's semantic claim is true. So every guarantee ProofLine makes
about economic reality is enforced by `Receivable.sol`'s own `require` statements:

- `InvoicePaid` is unreachable unless the contract's **measured balance delta** equals the
  invoice amount. A fee-on-transfer token that returns `true` while delivering less is
  rejected; so is a token that moves nothing at all.
- `InvoiceLate` is unreachable before `dueDate`.
- `InvoiceDefaulted` is unreachable before `dueDate + GRACE`.
- The **actual payer** must be a registered counterparty, not merely the nominated buyer -
  otherwise counterparty diversity could be manufactured from fresh addresses.

Attestcoin therefore proves that the source contract reached a state its own invariants made
impossible to reach falsely. That is a stronger claim than "an event happened."

## 7. Live deployment

| Network | Contract | Address |
|---|---|---|
| Sepolia (chainKey 1) | `Receivable` | `0x047F1cdAC2A9007188b2A8B9ffB5Ce171B88EF7c` |
| Sepolia | `mUSD` | `0x1Fd9658993573E73AE439c1BeDd902c2E5142153` |
| CC3 (102031) | `ASCReceiver` | `0x968E2BFEe40982EDB0595be7B9e0E73933d87170` |
| CC3 | `CreditFile` | `0xAEF3D1b97bB60eBA82cf0254f724f5a8b1B1b34a` |
| CC3 | `Treasury` | `0x0cb2A0162ed7D5eE8fEf48A9AcE12fAdcbd24e40` |
| CC3 | `CreditAccess` | `0x49DdB1b11a953BcD9894F2816878aa1a50DAb869` |

`CreditFile` and `ASCReceiver` reference each other **immutably**. The deployment script
predicts the receiver's address from the deployer nonce rather than introducing a mutable
setter, so the system retains exactly one privileged call: `setAuthorizedSource`.

## 8. Known limitations, stated plainly

- **Batch proving tested, not relied upon. [MEAS]** `getBatchProof` returned
  `success: true` for 2, 8, 10 and 11 of our already-attested history transactions, with a
  correct header range and a 58-root continuity proof - but an **empty `merkleProofs`
  object** every time, so no `txBytes` and no Merkle path for any transaction. `verifyBatch`
  was therefore not exercisable and no contract was deployed for it. A control in the same
  process shows `getProof` succeeding for the identical hash. We are not claiming the
  endpoint is broken; we are recording what it returned for us on 2026-09-02, with a control.
  Full detail and raw output: [`evidence/G0-B/`](../evidence/G0-B/). The verified history was
  established through the single-proof path, which is fully measured.
- **Sybil resistance is not solved.** Five controls raise the cost of self-dealing - payer
  registration, buyer ≠ seller, minimum qualifying amount, per-borrower exposure cap, and a
  three-counterparty requirement for the top tier - but a determined operator with three
  funded addresses can still manufacture history. Production needs counterparty attestations
  and stake-at-risk. We are not claiming otherwise.
- **Repayment is unsecured.** Writability is in audit, so proceeds on Ethereum cannot be
  routed to repayment on Creditcoin and the receivable cannot be seized. Enforcement is the
  credit file: a proven default freezes the borrower permanently. This is deliberate -
  ProofLine prices unsecured credit from verified behaviour rather than seizing collateral.
- **Mainnet (chainKey 3) is not integrated.** Supported by the protocol, out of scope here.

## 9. Reproducing this

```bash
npm install                    # Attestcoin SDK and contracts
forge test                     # 118 tests, incl. real captured Attestcoin proofs
node script/deploy.mjs         # both networks
node script/history-emit.mjs   # real economic facts on Sepolia
node script/history-prove.mjs  # prove them (resumable)
node ui/serve.mjs              # read the live credit file
```

`evidence/` contains the G0-A protocol study, the captured proof fixtures, the integration
round trip with its rejection paths, and the verified credit history - each with transaction
hashes, so no claim here has to be taken on trust.
