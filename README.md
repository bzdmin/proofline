<img src="docs/assets/proofline-logo.png" alt="ProofLine" width="180">

# ProofLine

## Verified economic history becomes reusable credit.

**[Open the live DApp](https://bzdmin.github.io/proofline/)** &middot; read-only, no wallet,
reads Creditcoin as the page draws it.

ProofLine turns verified economic events on Ethereum into persistent credit state on
Creditcoin.

Attestcoin verifies the source evidence. `CreditFile` persists the resulting credit history.
Independent applications consume that state without owning or rewriting the underlying
history.

The reference application demonstrates the complete lifecycle:

```
five verified settlement events  ->  TRUSTED  ->  $9,600 earned capacity
                                 ->  $6,300 Treasury draw  ->  $3,150 repayment
```

## The chain

```
Ethereum source event
  -> Attestcoin verification
  -> CreditFile state
  -> deterministic underwriting
  -> independent consumer
```

`CreditFile` has exactly one writer, and it writes only after a proof verifies.
**Remove Attestcoin and the credit file cannot change at all.**

## What is verified, and what is not

| Verified | Not established |
|---|---|
| Ethereum source transaction inclusion | Counterparties are economically independent |
| Source receipt succeeded | The demonstration history represents external commercial activity |
| Expected event was emitted | CreditFile guarantees repayment |
| Event came from the authorized source | Tier thresholds are Creditcoin protocol standards |
| Replay identity was unused | |
| Credit event was persisted to `CreditFile` | |
| Credit terms derived deterministically from that state | |

**ProofLine verifies evidence. It does not manufacture trust outside that evidence.**

## Judge the live system

**https://bzdmin.github.io/proofline/**

The DApp is a read-only inspection surface over the deployed contracts. No wallet, test
tokens, deployment, API key or environment variables. If Creditcoin does not answer, the page
says so and shows the last recorded state, labelled as recorded. It never shows figures it did
not read.

To run it locally instead:

```bash
git clone https://github.com/bzdmin/proofline.git
cd proofline
node ui/serve.mjs
```

### What to inspect

1. **What it is, then the state.** One sentence on what ProofLine does, then the borrower's
   tier: TRUSTED, 80% advance, 12% APR.
2. **"Why these terms?"** Each condition the tier depends on, read from the credit file.
3. **Verified history, with its limits beside it.** Five settlements, three registered
   counterparties, and what that does and does not prove.
4. **CreditFile history.** All 13 changes to the credit file. Selecting one re-reads Creditcoin
   at that change's own block and reports whether every figure still matches.
5. **Receipts.** Any event, as three things you can open independently: the Ethereum source
   transaction, the Creditcoin verification transaction, and the CreditFile state change.
6. **Verification boundary.** Two recorded rejections, each at a different gate.
7. **CreditAccess.** A second consumer deriving its own terms from the same file.

## What happened on-chain

Five settlement events on Ethereum Sepolia across three registered counterparties, verified
through Attestcoin and persisted in `CreditFile`. No credit state was written directly: every
tier change came from a verified settlement event.

**The history is deliberately seeded demonstration data.** The builder issued the invoices,
controls all three counterparty addresses, and minted the test mUSD that moved and that funds
Treasury. Attestcoin verified that each event happened as the source contract recorded it.
Nothing here shows that the counterparties are economically independent.

```
#1  counterparty A  $12,000   ->  STANDARD   60% advance / 16% APR
#2  counterparty B   $8,000   ->  STANDARD   60% / 16%
#3  counterparty C  $10,000   ->  GOOD       70% / 14%      <- third counterparty
#4  counterparty A   $7,000   ->  GOOD       70% / 14%
#5  counterparty B   $9,000   ->  TRUSTED    80% / 12%      <- five settlements, three counterparties
```

Then the earned line was used:

| State | Tier | Capacity | Approved line | Available | Debt |
|---|---|---|---|---|---|
| Before receivable | TRUSTED | 9,600 | 9,600 | **0** | 0 |
| Receivable outstanding | TRUSTED | 9,600 | 9,600 | 9,600 | 0 |
| Borrowed 6,300 | TRUSTED | 9,600 | 9,600 | 3,300 | 6,300 |
| Repaid 3,150 | TRUSTED | 9,600 | 9,600 | 6,449.999281 | 3,150.000719 |

**Verified history changes earned capacity. Receivables and debt change availability.**

The first row is only representable because the three numbers are kept apart: earned standing
of 9,600 with nothing currently drawable. Collapse capacity, approved line and available into a
single number and that state cannot be expressed. The remainder after repaying exactly 3,150
is interest accrued between the draw and the repayment, in mUSD's six-decimal units.

Every row can be re-read from Creditcoin at its own block. The DApp does this for each change.

## Two rejections, two different gates

**Replay-protected event substitution.** The same Ethereum transaction was resubmitted with a
different event type. The receiver rejected it with `AlreadyProcessed` before event decoding,
because the proof-derived transaction identity had already been processed. A processed proof
cannot be reused to reinterpret its source transaction as a different event.
[Record](evidence/integration/run-001/04-rejection-fake-event.json.note)

**Unauthorized source.** A real Ethereum mainnet transaction contained an event from an
unauthorized emitter, WETH where USDC was authorized. Gates 1 through 5 passed, including
`verifyAndEmit`, and the source authorization gate rejected it with `UnauthorizedSource`.
[Record](evidence/mainnet/README.md)

These are recorded rejection cases, caught at gas estimation and never mined. Neither changes
`CreditFile`.

## Why CreditFile is reusable infrastructure

`Treasury` and `CreditAccess` are two unrelated applications reading the same credit file.
Neither imports the other. Neither computes a tier. Neither can write to it.

One verified settlement moved Treasury's advance rate from 70% to 80% and its APR from 14% to
12%, and moved CreditAccess's deposit requirement from 40% to 0%.

`CreditAccess` is a second read-only consumer in the demonstration. It reads `CreditFile`
state and derives its own deposit requirement from `tier` alone, with no debt, no drawable and
no invoice knowledge. No `CreditAccess` agreement was opened.

The same `CreditFile` state can be consumed independently without giving the consumer
ownership of the underlying credit history. `test_oneSettlementMovesBothConsumers` executes
this.

## Architecture

```
Ethereum Sepolia
  Receivable.sol
      |  successful transaction + events, invariants enforced on-chain
      v
  Attestcoin
      |  Merkle inclusion + continuity proof, verified on a Creditcoin precompile
      v
  CreditFile.sol            <- the primitive
      |  append-only, proof-backed credit state
      |
      +-- UnderwritingLib -> Treasury.sol       working capital
      |
      +-- tier            -> CreditAccess.sol   security-deposit requirement
```

## Deployed

| Network | Contract | Address |
|---|---|---|
| Sepolia | `Receivable` | [`0x047F1cdA...`](https://sepolia.etherscan.io/address/0x047F1cdAC2A9007188b2A8B9ffB5Ce171B88EF7c) |
| Sepolia | `mUSD` | `0x1Fd9658993573E73AE439c1BeDd902c2E5142153` |
| CC3 | `ASCReceiver` | [`0x968E2BFE...`](https://creditcoin-testnet.blockscout.com/address/0x968E2BFEe40982EDB0595be7B9e0E73933d87170) |
| CC3 | `CreditFile` | [`0xAEF3D1b9...`](https://creditcoin-testnet.blockscout.com/address/0xAEF3D1b97bB60eBA82cf0254f724f5a8b1B1b34a) |
| CC3 | `Treasury` | `0x0cb2A0162ed7D5eE8fEf48A9AcE12fAdcbd24e40` |
| CC3 | `CreditAccess` | `0x49DdB1b11a953BcD9894F2816878aa1a50DAb869` |

## Verify it yourself

```bash
npm install
forge test
```

118 tests, including the real `EvmV1Decoder` run against Attestcoin proofs captured from the
live prover.

Check any number in this README directly against the chain:

```bash
cast call 0xAEF3D1b97bB60eBA82cf0254f724f5a8b1B1b34a \
  "getTerms(address)" \
  0xE5d69e9A09dA71c4B68e2e14f96c93FC50da8FDA \
  --rpc-url https://rpc.cc3-testnet.creditcoin.network
```

Rebuild the DApp's receipts and history from the evidence, checked against both chains:

```bash
node script/ui-data.mjs
```

Each Ethereum source transaction is accepted only if its block and transaction index equal the
ones the precompile derived and `CreditFile` stored.

## Evidence

`evidence/` separates what the protocol **documents**, what we **measured**, and what we
**decided**, with transaction hashes throughout.

| Path | Contents |
|---|---|
| [`evidence/G0-A/`](evidence/G0-A/) | Protocol study: seven questions answered against live chains, plus captured proof fixtures |
| [`evidence/G0-A/package-discrepancies.md`](evidence/G0-A/package-discrepancies.md) | Three ways the official examples do not work against the published packages |
| [`evidence/integration/run-001/`](evidence/integration/run-001/) | First end-to-end round trip and a replay-protected event substitution, with zero downstream mutation |
| [`evidence/integration/history/`](evidence/integration/history/) | The five settlements and the tier progression |
| [`evidence/integration/borrow/`](evidence/integration/borrow/) | Borrow and repayment, ten assertions |
| [`evidence/mainnet/`](evidence/mainnet/) | Six gates run against a real Ethereum mainnet transaction, and the unauthorized-source rejection |
| [`evidence/G0-B/`](evidence/G0-B/) | Batch proving tested on our path, with a control |
| [`ui/data/receipts.json`](ui/data/receipts.json) | Every CreditFile event mapped to its Ethereum and Creditcoin transactions |
| [`docs/ATTESTCOIN-INTEGRATION.md`](docs/ATTESTCOIN-INTEGRATION.md) | **Attestcoin Protocol Integration Summary** |

Measured, not assumed: attestation takes 7.96 to 8.7 minutes; production ingest averages
321,498 gas over 8 ingests; proof construction after attestation is 244 to 669 ms;
permissionless relay works. None of these figures is documented by the protocol.

## Reproduce the full pipeline

**Optional.** This deploys new contracts and creates new evidence. It is not required to
judge the submitted system, and expects an attestation wait of roughly eight minutes.

```bash
cp .env.example .env            # fill PRIVATE_KEY and RELAYER_PRIVATE_KEY
node script/deploy.mjs          # both networks
node script/history-emit.mjs    # demonstration settlement events on Sepolia
node script/history-prove.mjs   # verify them through Attestcoin (resumable)
node script/borrow-demo.mjs     # draw against the earned line
```

Requires Foundry `v1.2.3`, the version the Attestcoin examples pin, and Node 20+.

## Limitations

- **The demonstration history was seeded by the builder, and counterparty independence is
  not established.** The three counterparties are registered addresses the builder controls
  (`script/history-emit.mjs` derives two of them from the relayer key). ProofLine verifies that
  the recorded events happened as the source contract claims. It does not establish that the
  counterparties are economically independent. Registration, buyer ≠ seller, a minimum
  qualifying amount, an exposure cap and a three-counterparty requirement raise the cost of
  self-dealing; they do not establish independence. Production needs counterparty
  attestations, identity, or stake-at-risk.
- **Repayment is unsecured.** Attestcoin writability is in audit, so proceeds on Ethereum
  cannot be routed to repayment and the receivable cannot be seized. Enforcement is the
  credit file: a verified default freezes the borrower permanently. That is deliberate, and it
  is Creditcoin's own thesis.
- **Ethereum mainnet: the verification boundary has been exercised, the credit file has not.**
  The six gates were run against a real mainnet transaction emitted by a contract we do not
  control, and all six passed ([`evidence/mainnet/`](evidence/mainnet/)). The production
  `CreditFile` ingests the configured Sepolia source only, and has exactly one authoritative
  writer fixed at construction.
- **Batch proving tested, not relied upon.** `getBatchProof` returned success with an empty
  proof set for our already-attested transactions, so `verifyBatch` was not exercisable. The
  single-proof path works for the same hashes ([`evidence/G0-B/`](evidence/G0-B/)).
- **Tier thresholds are ProofLine's policy**, not a Creditcoin standard. The reusable part is
  the shape: verified history, deterministic function, terms. Any consumer may read the raw
  file and price it differently.

## License

MIT.
