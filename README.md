<img src="docs/assets/proofline-logo.png" alt="ProofLine" width="180">

# ProofLine

**ProofLine turns verified economic events on Ethereum into reusable credit state on
Creditcoin.**

`CreditFile` is the primitive: a proof-backed credit-state layer that any Creditcoin
application can read. ProofLine is the reference application built around it.

## The chain

```
Ethereum economic event  ->  Attestcoin proof  ->  persistent CreditFile state
                         ->  underwriting terms  ->  independent application consumption
```

Live, on deployed contracts:

```
5 proven settlements  ->  TRUSTED  ->  80% advance  ->  $9,600 earned capacity
                      ->  $12,000 receivable  ->  $6,300 borrowed
                      ->  $3,150 repaid  ->  available credit recovers
```

## Judge the live system

The DApp is a **read-only inspection surface over the deployed system**. No wallet, test
tokens, deployment, API key or environment variables are required.

```bash
git clone https://github.com/bzdmin/proofline.git
cd proofline
npm install
node ui/serve.mjs
```

The server prints the URL to open:

```
ProofLine ui on http://localhost:4173
  read-only. no wallet, no test tokens, no deployment, no API key.
  reads the deployed Sepolia and Creditcoin CC3 contracts live.
```

`forge-std` is vendored, so a plain clone is enough. No `--recursive`, no submodule init.

### What to inspect

1. **Live credit state.** TRUSTED, 80% advance, 12% APR.
2. **Click "Why these terms?"** Five settlements, three counterparties, 100% on-time, zero
   delinquencies, zero defaults, $12,000 largest proven settlement.
3. **The derivation.** 80% of $12,000 = $9,600 earned capacity. Being paid earns capacity;
   issuing an invoice does not.
4. **Verified history.** Open a settlement and follow it back to its Ethereum transaction.
5. **The proof chain.** Attested block, proof-derived `txIndex`, six verification gates,
   authorised source, and the resulting `CreditFile` write.
6. **Independent consumers.** Compare `CreditFile`'s earned state against Treasury's own debt
   and availability, then open `CreditAccess` reading the same file through `tier` alone.

The lifecycle has already happened on-chain: five settlements, a $6,300 draw and a $3,150
repayment. The DApp does not ask you to recreate that evidence.

## What happened on-chain

Five settlements on Ethereum Sepolia, each moving mUSD between distinct registered
counterparties, then proven through Attestcoin and verified on Creditcoin. No credit state
was seeded: every tier change came from the proven settlement history.

```
#1  buyerA  $12,000   ->  STANDARD   60% advance / 16% APR
#2  buyerB   $8,000   ->  STANDARD   60% / 16%
#3  buyerC  $10,000   ->  GOOD       70% / 14%      <- third counterparty
#4  buyerA   $7,000   ->  GOOD       70% / 14%
#5  buyerB   $9,000   ->  TRUSTED    80% / 12%      <- five settlements, three counterparties
```

Then the earned line was used:

| State | Tier | Capacity | Approved line | Available | Debt |
|---|---|---|---|---|---|
| Before receivable | TRUSTED | 9,600 | 9,600 | **0** | 0 |
| Receivable outstanding | TRUSTED | 9,600 | 9,600 | 9,600 | 0 |
| Borrowed 6,300 | TRUSTED | 9,600 | 9,600 | 3,300 | 6,300 |
| Repaid 3,150 | TRUSTED | 9,600 | 9,600 | 6,449.999 | 3,150.001 |

**The first row is the architecture in one line.** Earned standing of 9,600 with nothing
currently drawable, a state that cannot be expressed if capacity, the approved line and
available-to-draw are collapsed into a single number.

Tier, capacity and line never moved during borrowing. Only availability and debt did.
`CreditFile` determines earned credit terms from verified history; consumers apply their own
debt and utilisation when calculating available credit. The `.001` is real accrued interest,
left unrounded.

## Why CreditFile is reusable infrastructure

`Treasury` and `CreditAccess` are two unrelated applications reading the same credit file.
Neither imports the other. Neither computes a tier. Neither can write to it.

One proven settlement moved both: Treasury's advance rate 70% to 80% and its APR 14% to 12%,
while CreditAccess waived a 40% security deposit entirely. `CreditAccess` reads `tier` and
nothing else, with no debt, no drawable and no invoice knowledge.

That is what `test_oneSettlementMovesBothConsumers` executes and the deployed contracts
demonstrate.

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

`CreditFile` has exactly one writer, and it writes only after a proof verifies.
**Remove Attestcoin and the credit file cannot change at all.**

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

## Evidence

`evidence/` separates what the protocol **documents**, what we **measured**, and what we
**decided**, with transaction hashes throughout.

| Path | Contents |
|---|---|
| [`evidence/G0-A/`](evidence/G0-A/) | Protocol study: seven questions answered against live chains, plus captured proof fixtures |
| [`evidence/G0-A/package-discrepancies.md`](evidence/G0-A/package-discrepancies.md) | Three ways the official examples do not work against the published packages |
| [`evidence/integration/run-001/`](evidence/integration/run-001/) | First end-to-end round trip, with both rejection paths asserting zero downstream mutation |
| [`evidence/integration/history/`](evidence/integration/history/) | The five settlements and the tier progression |
| [`evidence/integration/borrow/`](evidence/integration/borrow/) | Borrow and repayment, ten assertions |
| [`evidence/mainnet/`](evidence/mainnet/) | Six gates run against a real Ethereum mainnet transaction |
| [`evidence/G0-B/`](evidence/G0-B/) | Batch proving tested on our path, with a control |
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
node script/history-emit.mjs    # real economic facts on Sepolia
node script/history-prove.mjs   # prove them (resumable)
node script/borrow-demo.mjs     # draw against the earned line
```

Requires Foundry `v1.2.3`, the version the Attestcoin examples pin, and Node 20+.

## Limitations

- **Counterparty independence is not established.** The protocol verifies settlement events
  and requires registered counterparties, but provides no external attestation that those
  counterparties are economically independent. A determined operator could therefore
  manufacture self-dealing history. Production needs counterparty attestations, identity, or
  stake-at-risk.
- **Repayment is unsecured.** Attestcoin writability is in audit, so proceeds on Ethereum
  cannot be routed to repayment and the receivable cannot be seized. Enforcement is the
  credit file: a proven default freezes the borrower permanently. That is deliberate, and it
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
