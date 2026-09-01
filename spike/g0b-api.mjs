// G0-B, part 1: does getBatchProof work on OUR path?
//
// Bounded experiment. The eight history events are already emitted, already attested and
// already proven individually, so there is no attestation wait and no new economic activity.
// This asks only what the batch API does with proofs we know are good.
//
// If this fails, we record the exact failure and stop. The product does not depend on it.
import 'dotenv/config';
import { proofProvider } from '@gluwa/usc-sdk';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';

const E = process.env;
const CK = Number(E.CHAINKEY_SEPOLIA ?? 1);
mkdirSync('evidence/G0-B', { recursive: true });

const emitted = JSON.parse(readFileSync('evidence/integration/history/emitted.json', 'utf8'));
const hashes = emitted.events.map(e => e.txHash);
const span = emitted.blockSpan;

const builder = new proofProvider.service.ProofBuilder(CK, E.PROVER_API_URL, 120_000);
const out = {
  ranAt: new Date().toISOString(),
  chainKey: CK,
  candidates: { count: hashes.length, blockSpan: span },
  documented: { maxBatchSize: 10, maxBatchRange: 1000 },
  probes: [],
};
const save = () => writeFileSync('evidence/G0-B/api.json', JSON.stringify(out, null, 2));

console.log(`${hashes.length} already-proven events, blocks ${span.from}..${span.to} (span ${span.span})`);
console.log('documented limits: 10 proofs / 1000 blocks\n');

async function probe(n, label) {
  const t = Date.now();
  try {
    const r = await builder.getBatchProof(hashes.slice(0, n));
    const ms = Date.now() - t;
    const arr = Array.isArray(r) ? r : [r];
    const ok = arr.every(x => x?.success !== false);
    const d = arr[0]?.data ?? r?.data ?? r;

    // count how many individual proofs actually came back
    let proofCount = 0, heights = [];
    if (d?.merkleProofs) {
      for (const h of Object.keys(d.merkleProofs)) {
        heights.push(Number(h));
        proofCount += Object.keys(d.merkleProofs[h]).length;
      }
    }
    const res = {
      label, requested: n, ok, ms,
      fromHeader: d?.fromHeader ?? null, toHeader: d?.toHeader ?? null,
      proofsReturned: proofCount,
      distinctHeights: heights.length,
      continuityRoots: d?.continuityProof?.roots?.length ?? null,
      error: ok ? null : JSON.stringify(arr).slice(0, 400),
    };
    console.log(`  ${label.padEnd(22)} ${ok ? 'OK ' : 'ERR'}  ${ms}ms  proofs ${proofCount}  headers ${res.fromHeader}..${res.toHeader}  roots ${res.continuityRoots}`);
    return res;
  } catch (err) {
    const res = { label, requested: n, ok: false, threw: (err.message ?? String(err)).slice(0, 400) };
    console.log(`  ${label.padEnd(22)} THREW  ${res.threw.slice(0, 100)}`);
    return res;
  }
}

// Q1/Q2: does the documented path work, and where does it actually break?
for (const [n, label] of [[2, 'getBatchProof(2)'], [8, 'getBatchProof(8) - ours'], [10, 'getBatchProof(10) - max']]) {
  out.probes.push(await probe(n, label));
  save();
}

// over the documented maximum, to see whether the limit is enforced or advisory
const eleven = [...hashes, hashes[0], hashes[1], hashes[2]].slice(0, 11);
try {
  const t = Date.now();
  const r = await builder.getBatchProof(eleven);
  const arr = Array.isArray(r) ? r : [r];
  const ok = arr.every(x => x?.success !== false);
  console.log(`  ${'getBatchProof(11)'.padEnd(22)} ${ok ? 'OK (limit advisory)' : 'rejected (limit enforced)'}  ${Date.now()-t}ms`);
  out.overLimit = { requested: 11, accepted: ok, raw: JSON.stringify(arr).slice(0, 300) };
} catch (err) {
  console.log(`  ${'getBatchProof(11)'.padEnd(22)} rejected: ${(err.message ?? err).slice(0, 80)}`);
  out.overLimit = { requested: 11, accepted: false, threw: (err.message ?? String(err)).slice(0, 300) };
}

// keep the successful batch payload so part 2 can submit it without re-fetching
const good = out.probes.find(p => p.ok && p.requested === 8);
if (good) {
  const r = await builder.getBatchProof(hashes);
  writeFileSync('evidence/G0-B/batch-payload.json', JSON.stringify(Array.isArray(r) ? r[0] : r, null, 1));
  console.log('\n  batch payload saved for on-chain verification');
}

out.verdict = good ? 'getBatchProof works on our path' : 'getBatchProof did not return a usable batch';
save();
console.log(`\n=== ${out.verdict} ===`);
