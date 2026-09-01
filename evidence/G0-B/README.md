# G0-B - batch proving, tested on our path

**Status:** tested, not usable. **Not relied upon by the product.**
**Date:** 2026-09-02
**Time spent:** ~10 minutes, deliberately bounded.

Batch proving was never a dependency. It was run because this repository claims
"measured, not assumed" throughout, and leaving one documented protocol capability
untested was an inconsistency worth removing.

## Candidates

The eight events of the verified credit history, already emitted, already attested, and
already proven **individually** through `getProof`. No new economic activity, no attestation
wait.

```
8 transactions, Sepolia blocks 11614243..11614252, span 9 blocks
documented limits: MAX_BATCH_SIZE 10, MAX_BATCH_RANGE 1000 blocks
```

Well inside both documented limits.

## Q1 - Does `getBatchProof` accept our transactions? [MEAS]

Yes. Every call returned `success: true`.

| Request | Result | Time | fromHeader..toHeader | Continuity roots | Merkle proofs returned |
|---|---|---|---|---|---|
| 2 hashes | success | 7,696 ms | 11614243..11614245 | 58 | **0** |
| 8 hashes (ours) | success | 823 ms | 11614243..11614252 | 58 | **0** |
| 10 hashes (documented max) | success | 1,027 ms | 11614243..11614252 | 58 | **0** |
| 11 hashes (over the max) | success | 772 ms | - | - | **0** |

## Q2 - What actually came back? [MEAS]

A well-formed envelope containing **no per-transaction proofs**.

```json
{
  "chainKey": 1,
  "fromHeader": 11614243,
  "toHeader": 11614245,
  "continuityProof": { "lowerEndpointDigest": "0x...", "roots": [ 58 entries ] },
  "merkleProofs": {},          <-- empty
  "cached": false
}
```

The header range is correct and the continuity proof is substantial - 58 roots, against
1 to 10 for a single proof over the same blocks. But `merkleProofs` is an empty object, so
there is no `txBytes` and no Merkle path for any transaction in the batch.

**Control, run in the same process against the same hash:**

```
getProof(0x1266945c...)       OK       txIndex 106, 8 siblings
getBatchProof([0x1266945c..., 0x396e50e5...])
                              success  merkleProofs: {}
```

The single-proof path works for exactly the transactions the batch path returns nothing for.
So this is not a problem with our transactions, our block range, or our batch size.

## Q3 - Does `verifyBatch` succeed?

**Not answerable.** `verifyBatch` requires `txBytesArr` and `merkleProofs`, and the API
returned neither. There was nothing to submit on-chain, so no contract was written or
deployed for this experiment.

## Q4 - What does batching save?

**Not measurable on our path**, for the same reason.

Worth stating regardless, since it is easy to overclaim: batching would **not** reduce
latency. Attestation is paid once per block range whether one proof or eight are requested,
and our eight events span nine blocks. The saving would have been CC3 transaction count and
gas per verified event, not wall-clock time.

## Note on the documented maximum [MEAS]

`MAX_BATCH_SIZE` is documented as 10. A request for **11** was accepted rather than
rejected. Since no proofs were returned in any case, this says nothing about whether the
limit is enforced when the endpoint is working - only that the request itself was not
refused.

## Conclusion

**Batch proving was tested on our path and is not relied upon by the product.**

The verified credit history was established sequentially through the single-proof path,
which is fully measured: 7.96 minutes of attestation covering all eight events, 321,498 gas
mean production ingest, every transaction hash recorded.

We are not claiming the batch endpoint is broken. We are recording exactly what it returned
for us, on this date, for these transactions, alongside a control showing the single-proof
path working for the same inputs. Anyone can re-run `spike/g0b-api.mjs` and compare.

Raw output: [`api.json`](api.json) · [`batch-payload.json`](batch-payload.json)
