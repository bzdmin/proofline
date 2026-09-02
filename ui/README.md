# ProofLine interface

Static. No build step, no server-side code, no indexer, no cache.

    node ui/serve.mjs   # no dependencies; falls through to a free port
    open http://localhost:4173

Everything on screen is a live contract read against Creditcoin CC3. `ethers` is vendored
in `vendor/` so it works offline, and `data/config.json` holds only addresses and a map from
each credit event to the Ethereum transaction that caused it.

Every number can be reproduced independently:

    cast call <CreditFile> "getTerms(address)" <borrower> \
      --rpc-url https://rpc.cc3-testnet.creditcoin.network

## What it is built to show

1. **Who is this borrower** - address, tier, rates.
2. **What has been proven** - every credit event, each traceable to Sepolia.
3. **Why the terms are what they are** - settlements, counterparties, on-time rate,
   largest settlement. The tier is a deterministic consequence of those four numbers.
4. **What they can do now** - capacity, approved line, available to draw, kept separate.

Clicking any credit event follows the evidence chain backwards:
Ethereum transaction -> attested block and derived txIndex -> the six verification gates
-> the authorized source contract -> the credit file write.

## Deliberate choices

- **The numbers are grouped by which contract owns them.** Capacity and approved line sit
  under *Earned from verified history - CreditFile*; available and debt sit under *This
  consumer - Treasury*, in a dashed border. Four equal tiles read as four versions of
  "credit limit"; grouped, the architectural boundary is visible without reading a caption.
  Merging them is also the bug that once zeroed a borrower's line at the moment they proved
  a perfect payment.
- **The pipeline shows the real 7.96 minute attestation delay** rather than a spinner.
- **Failure states are visible**: prover retry, proof expired, rejected. A credit product
  that only ever displays successful proofs looks fake.
- **CreditAccess gets its own panel** stating that it reads `tier` alone - no Treasury
  import, no debt, no invoice knowledge.
