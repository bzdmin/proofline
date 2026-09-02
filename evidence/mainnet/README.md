# Ethereum mainnet - chainKey 3

**Status:** verified. **This is a measurement, not an integration.**
**Date:** 2026-09-02

## What this is not

ProofLine does **not** ingest Ethereum mainnet into its credit file, and cannot without
redeploying the primitive. `CreditFile.receiver` is `immutable`, so exactly one contract may
ever write to it, and the deployed `ASCReceiver` decodes the `Receivable` payload shape
specifically. Adding a mainnet source would mean redeploying both contracts - they hold
immutable references to each other - which would invalidate every transaction hash in the
deck, the README, the evidence directory and the interface.

That trade was not worth making eleven days from submission, and the primitive is frozen.

## What this is

A bounded measurement answering one question: **can ProofLine's six-gate verification
pipeline consume Ethereum mainnet at all?**

Reading mainnet costs no mainnet ETH. We deployed nothing there. We took a transaction that
had already happened, emitted by a contract we do not control, and ran it through the
identical gate sequence on Creditcoin.

## Result [MEAS]

```
mainnet head        25885942
attested height     25885902        (40 blocks behind, ~8 min at 12s/block)
transaction         0xb7f01725a99b599a47f62a53bb82f20ad46aa17f441e301ed7f0ea6c4aa50f32
emitter             0xdAC17F958D2ee523a2206206994597C13D831ec7   (USDT, not ours)
proof construction  656 ms
CC3 verification    0xe97997b3653cdd4c4cbd59d009e9b3ce0dbe300ed5d9ee2fda25f81e175eb0f3
gas                 125,398
gates               1:replay  2:verifyAndEmit  3:txType  4:receiptStatus
                    5:logsFound  6:sourceAuthorized
```

**All six gates passed.** The pipeline is chain-agnostic in fact, not only in principle.

Mainnet ingest cost **125,398 gas** against Sepolia's **126,854** for the equivalent
protocol-only path - effectively identical. The chain being read does not change the cost of
reading it.

## The first attempt is better evidence than the second

The initial run authorised USDC and picked a transaction containing a `Transfer`. It was
rejected:

```
UnauthorizedSource(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
                   0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)
```

The transaction was a DEX swap. Its first `Transfer` came from **WETH**, not the USDC we had
authorised. Gates 1 through 5 passed - including `verifyAndEmit`, so the mainnet proof itself
verified - and gate 6 refused it.

This is source authorisation doing exactly its job against real-world data we did not
construct: a valid proof of a real event, rejected because the emitter was not the one we
trust. The second run required every matching log to share a single emitter, which a plain
token payment satisfies and a swap does not.

## Why it matters

The strongest available criticism of ProofLine's evidence is that the verified credit history
was produced by our own Sepolia contracts. That criticism stands for the **credit history** -
and is disclosed.

It does not stand for the **verification pipeline**. The gates that admit a fact into the
credit file have now been exercised against a transaction nobody on this project created, on
a chain nobody on this project deployed to, emitted by a contract nobody on this project
controls.

## Reproducing

```bash
node spike/mainnet-probe.mjs
```

Finds the attested mainnet frontier, selects a single-emitter ERC-20 transfer inside it,
proves it, deploys a throwaway probe on CC3 and runs the six gates. `MainnetProbe.sol` writes
to no credit file, holds no capital, and is referenced by no production contract - the same
role `SpikeASC` played for chainKey 1 in G0-A.

Raw output: [`probe.json`](probe.json)
