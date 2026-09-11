# ProofLine interface

Static. No build step, no server-side code, no indexer. Published at
https://bzdmin.github.io/proofline/ and runnable locally:

    node ui/serve.mjs   # no dependencies; falls through to a free port

Every figure on screen is a contract read against Creditcoin CC3, made by the browser as the
page draws it. `ethers` is vendored in `vendor/`.

| File | Holds |
|---|---|
| `data/config.json` | Addresses and explorer URLs |
| `data/receipts.json` | Every CreditFile event mapped to its Ethereum source transaction and its Creditcoin verification transaction |
| `data/timeline.json` | The credit file at the Creditcoin block of each of its 13 changes |
| `data/snapshot.json` | The current state, shown only when Creditcoin does not answer |

All three data files are written by `node script/ui-data.mjs`, which accepts a source
transaction only if its Ethereum block and transaction index equal the ones the precompile
derived and CreditFile stored.

Every number can be reproduced independently:

    cast call <CreditFile> "getTerms(address)" <borrower> \
      --rpc-url https://rpc.cc3-testnet.creditcoin.network

## What it is built to show

1. **What ProofLine is**, in one sentence, before any number.
2. **The borrower's terms and why**: tier, rates, and each condition the tier depends on.
3. **Verified history beside its limits**: what the settlements prove, and that the
   counterparties' independence is not established.
4. **Who owns each number**: capacity and approved line under CreditFile, available and debt
   under Treasury.
5. **How the file changed**: all 13 changes, each re-read from Creditcoin at its own block
   when selected. Verified history moves earned capacity; receivables and debt move
   availability.
6. **Receipts**: any event as its Ethereum source transaction, its Creditcoin verification
   transaction, and the CreditFile state change.
7. **The verification boundary**: two rejections mined on the production receiver, at two
   different gates.

## Deliberate choices

- **Never a figure it did not read.** If Creditcoin does not answer, the page says so and
  shows `data/snapshot.json` labelled as recorded, with its block and time. A file of zeros
  would be indistinguishable from a borrower with no history.
- **Replayed frames are checked, not trusted.** Each change in the history is re-read at its
  block and the page reports whether every figure matches the recording.
- **The numbers are grouped by which contract owns them.** Four equal tiles read as four
  versions of "credit limit". Merging them is also the bug that once zeroed a borrower's line
  at the moment they proved a perfect payment.
- **CreditAccess is labelled read-only.** It derives a deposit requirement from `tier` alone;
  no agreement was opened in the demonstration.
