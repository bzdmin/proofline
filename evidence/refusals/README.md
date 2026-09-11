# Two rejections, mined on the production receiver

Both were sent to the production `ASCReceiver`
([`0x968E2BFE...`](https://creditcoin-testnet.blockscout.com/address/0x968E2BFEe40982EDB0595be7B9e0E73933d87170?tab=contract))
by the relayer, an ordinary address with no role in the contracts. Both reverted before any
`CreditFile` state change: `CreditFile` held 11 events before and 11 after. The only cost was the
relayer's gas.

Each case was dry-run first. The script (`script/refusals.mjs`) broadcast a transaction only when
the dry run returned the expected error, then sent it with a fixed gas limit so that the
rejection would be mined instead of stopping at gas estimation. The contract source is verified
on Blockscout, so each transaction's input is decoded there.

| Case | Gate | Creditcoin transaction | Result | Gas |
|---|---|---|---|---|
| Replay-protected event substitution | 1, replay | [`0xf36fdb0b...`](https://creditcoin-testnet.blockscout.com/tx/0xf36fdb0bc22f64c69cc509f0a40eab9ac2534fe2ef01363df62662a6324b8cf1) | `AlreadyProcessed` | 140,658 |
| Unauthorized source | 6, emitter authorized | [`0x209317f6...`](https://creditcoin-testnet.blockscout.com/tx/0x209317f636d38d45a205b4dde4685d1628d14f340028651ff968fbd289efd94e) | `UnauthorizedSource` | 159,600 |

## Replay-protected event substitution

Source: [`0x6d909c47...`](https://sepolia.etherscan.io/tx/0x6d909c470c9be3fc0226ce05e00d770b6eaa62ba6b35ee78bf2e71c30b0b64e3),
the InvoicePaid transaction already verified for invoice #1 in `evidence/integration/run-001/`.

It was resubmitted with the `InvoiceDefaulted` event signature. The receiver rejected it at gate 1
with `AlreadyProcessed(0x86693c19...)`, before any event decoding, because the replay key is
derived from the proof itself (chainKey, block height, transaction index) and not from the event
the caller names. A processed proof cannot be reused to reinterpret its source transaction as a
different event.

## Unauthorized source

Source: [`0x606d7a6d...`](https://sepolia.etherscan.io/tx/0x606d7a6d17ee168fcec7134aff26e8d97f7f0372c92b315064df3458af17d99f),
a Circle USDC transfer on Ethereum Sepolia, from a contract ProofLine did not deploy.

It was proven and submitted with the `Transfer` event signature. The proof verified: gates 1
through 5 passed, including `verifyAndEmit`. Gate 6 rejected it with
`UnauthorizedSource(0x1c7D4B19... USDC, 0x047F1cdA... Receivable)`: a valid proof of a real event,
refused because the emitter is not the one source this receiver trusts.

The same gate also refused a real Ethereum mainnet swap during the mainnet probe
([`evidence/mainnet/`](../mainnet/)).

## Raw record

[`refusals.json`](refusals.json): both source transactions, their proof-derived block and index,
both Creditcoin transactions, status, gas, and the decoded reason.
