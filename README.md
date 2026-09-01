# ProofLine

**ProofLine turns verified economic events on Ethereum into reusable credit state on
Creditcoin.**

**ProofLine is the reference application. `CreditFile` is the primitive.**

`CreditFile` is a proof-backed credit-state layer any Creditcoin application can read. The
invoice contract is one source of economic evidence. `Treasury` is the first capital
consumer. `CreditAccess` is a second, independent one. Everything else exists to prove those
three things belong together.

```
Ethereum Sepolia
  Receivable.sol
      │  successful transaction + events, invariants enforced on-chain
      ▼
  Attestcoin
      │  Merkle inclusion + continuity proof, verified on a Creditcoin precompile
      ▼
  CreditFile.sol            ← the primitive
      │  append-only, proof-backed credit state
      │
      ├── UnderwritingLib → Treasury.sol       working capital
      │
      └── tier            → CreditAccess.sol   security-deposit requirement
```

`CreditFile` has exactly one writer, and it writes only after a proof verifies.
**Remove Attestcoin and the credit file cannot change at all.**

---

## What is actually live

Five real settlements on Ethereum Sepolia, each moving real value between independently
registered counterparties, each proven through Attestcoin and verified on Creditcoin.

```
#1  buyerA  $12,000   →  STANDARD   60% advance / 16% APR
#2  buyerB   $8,000   →  STANDARD   60% / 16%
#3  buyerC  $10,000   →  GOOD       70% / 14%      ← third counterparty
#4  buyerA   $7,000   →  GOOD       70% / 14%
#5  buyerB   $9,000   →  TRUSTED    80% / 12%      ← five settlements, three counterparties
```

Then the earned line was actually used:

| State | Tier | Capacity | Line | Available | Debt |
|---|---|---|---|---|---|
| Before receivable | TRUSTED | 9,600 | 9,600 | **0** | 0 |
| Receivable outstanding | TRUSTED | 9,600 | 9,600 | 9,600 | 0 |
| Borrowed 6,300 | TRUSTED | 9,600 | 9,600 | 3,300 | 6,300 |
| Repaid 3,150 | TRUSTED | 9,600 | 9,600 | 6,449.999 | 3,150.001 |

**The first row is the whole architecture in one line.** Earned standing of 9,600 with
nothing currently drawable - a state that cannot even be expressed if capacity, the approved
line and available-to-draw are collapsed into a single number.

Tier, capacity and line never moved during borrowing. Only availability and debt did.
Standing is earned from proven history; liquidity tracks current receivables. And the
`.001` is real accrued interest, left unrounded on purpose.

## Why this is not an invoice lending app

`Treasury` and `CreditAccess` are two unrelated applications reading the same credit file.
Neither imports the other. Neither computes a tier. Neither can write to `CreditFile`.

One proven Ethereum settlement moved both: Treasury's advance rate went 70% → 80% and its
APR 14% → 12%, while CreditAccess waived a 40% security deposit entirely. `CreditAccess`
reads `tier` and nothing else - no debt, no drawable, no invoice knowledge.

That is the claim `test_oneSettlementMovesBothConsumers` executes, and the deployed
contracts demonstrate.

## Deployed

| Network | Contract | Address |
|---|---|---|
| Sepolia | `Receivable` | [`0x047F1cdA…`](https://sepolia.etherscan.io/address/0x047F1cdAC2A9007188b2A8B9ffB5Ce171B88EF7c) |
| Sepolia | `mUSD` | `0x1Fd9658993573E73AE439c1BeDd902c2E5142153` |
| CC3 | `ASCReceiver` | [`0x968E2BFE…`](https://creditcoin-testnet.blockscout.com/address/0x968E2BFEe40982EDB0595be7B9e0E73933d87170) |
| CC3 | `CreditFile` | [`0xAEF3D1b9…`](https://creditcoin-testnet.blockscout.com/address/0xAEF3D1b97bB60eBA82cf0254f724f5a8b1B1b34a) |
| CC3 | `Treasury` | `0x0cb2A0162ed7D5eE8fEf48A9AcE12fAdcbd24e40` |
| CC3 | `CreditAccess` | `0x49DdB1b11a953BcD9894F2816878aa1a50DAb869` |

Verify any claim in this README without trusting us:

```bash
cast call 0xAEF3D1b97bB60eBA82cf0254f724f5a8b1B1b34a \
  "getTerms(address)" 0xE5d69e9A09dA71c4B68e2e14f96c93FC50da8FDA \
  --rpc-url https://rpc.cc3-testnet.creditcoin.network
```

## Evidence

`evidence/` is the part we would want a protocol engineer to read first. It separates
**documented** protocol behaviour, **measured** behaviour, and **our design decisions** -
and records where we were wrong.

| Path | Contents |
|---|---|
| [`evidence/G0-A/`](evidence/G0-A/) | Protocol study. Seven questions answered against live chains, each with transaction hashes, plus captured proof fixtures |
| [`evidence/G0-A/package-discrepancies.md`](evidence/G0-A/package-discrepancies.md) | Three ways the official examples do not work against the published packages |
| [`evidence/integration/run-001/`](evidence/integration/run-001/) | First end-to-end round trip, with both rejection paths asserting zero downstream mutation |
| [`evidence/integration/history/`](evidence/integration/history/) | The five settlements and the tier progression |
| [`evidence/integration/borrow/`](evidence/integration/borrow/) | Borrow and repayment, ten assertions |
| [`docs/ATTESTCOIN-INTEGRATION.md`](docs/ATTESTCOIN-INTEGRATION.md) | **Attestcoin Protocol Integration Summary** |

**Measured, not assumed:** attestation takes 7.96-8.7 minutes; production ingest averages
321,498 gas over 8 ingests; proof construction after attestation is 244-669 ms; permissionless
relay works. None of these figures is documented by the protocol.

**Found during development, fixed, and recorded:** our original replay key was spoofable by
the caller; a `File memory` accounting function silently aliased its input; a gate-ordering
test passed while proving nothing; the actual payer was unchecked, allowing counterparty
diversity to be manufactured; and one claim in this repo about reverted-transaction logs was
an inference we later disproved and corrected in place.

## Run it

```bash
forge test                      # 118 tests, incl. real captured Attestcoin proofs
node ui/serve.mjs               # read the live credit file in a browser
```

Full pipeline against your own testnet keys:

```bash
cp .env.example .env            # fill PRIVATE_KEY and RELAYER_PRIVATE_KEY
node script/deploy.mjs          # both networks
node script/history-emit.mjs    # real economic facts on Sepolia
node script/history-prove.mjs   # prove them (resumable - expect ~8 min attestation)
node script/borrow-demo.mjs     # draw against the earned line
```

Requires Foundry `v1.2.3` (the version the Attestcoin examples pin) and Node 20+.

## Limitations, stated plainly

- **Batch proving tested, not relied upon.** `getBatchProof` returned success with an empty
  proof set for our already-attested transactions, so `verifyBatch` was not exercisable. The
  single-proof path works for the same hashes. Recorded with a control in
  [`evidence/G0-B/`](evidence/G0-B/); the history was established sequentially.
- **Sybil resistance is not solved.** Five controls raise the cost of self-dealing; a
  determined operator with three funded addresses can still manufacture history. Production
  needs counterparty attestations and stake-at-risk.
- **Repayment is unsecured.** Writability is in audit, so proceeds on Ethereum cannot be
  routed to repayment and the receivable cannot be seized. Enforcement is the credit file: a
  proven default freezes the borrower permanently. This is deliberate - ProofLine prices
  unsecured credit from verified behaviour rather than seizing collateral.
- **Tier thresholds are ProofLine's policy, not a Creditcoin standard.** "Five settlements
  across three counterparties" is one lender's opinion. The reusable part is the shape:
  verified history → deterministic function → terms. Any consumer may read the raw file and
  price it differently.
