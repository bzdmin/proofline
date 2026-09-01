// G0-B - batching. Measures OUR path rather than trusting the documented limits.
//
// Asks: how many proofs does getBatchProof actually accept? what block range? what does
// verifyBatch cost? does a multi-tx batch fan out correctly? what happens when one proof
// in a batch is bad? and does replay protection survive batch ingestion?
import 'dotenv/config';
import { ethers } from 'ethers';
import { proofProvider } from '@gluwa/usc-sdk';
import { readFileSync, writeFileSync } from 'node:fs';

const E = process.env;
const CHAINKEY = Number(E.CHAINKEY_SEPOLIA ?? 1);
const abiOf = (f, c) => JSON.parse(readFileSync(`out/${f}/${c}.json`, 'utf8')).abi;

const sepProvider = new ethers.JsonRpcProvider(E.SEPOLIA_RPC_URL);
const main = new ethers.Wallet(E.PRIVATE_KEY, sepProvider);
const source = new ethers.Contract(E.SPIKE_SOURCE_ADDRESS, abiOf('SpikeSource.sol','SpikeSource'), main);

const out = { startedAt: new Date().toISOString(), chainKey: CHAINKEY, findings: {} };
const log = (...a) => console.log(...a);
const save = () => writeFileSync('evidence/G0-B/results.json', JSON.stringify(out, null, 2));

// ------------------------------------------------------------------ phase 1
// 12 transactions: deliberately MORE than the documented max batch of 10.
const N = 12;
log(`=== PHASE 1 - fire ${N} Sepolia transactions (documented max batch is 10) ===`);
const txs = [];
for (let i = 0; i < N; i++) {
  const tx = await source.ping(BigInt(100_000 + i));
  const r = await tx.wait();
  txs.push({ i, txHash: tx.hash, block: r.blockNumber });
  log(`  ${String(i).padStart(2)}  ${tx.hash}  block ${r.blockNumber}`);
}
const blocks = txs.map(t => t.block);
const span = Math.max(...blocks) - Math.min(...blocks);
log(`\n  block span ${Math.min(...blocks)}..${Math.max(...blocks)} = ${span} blocks`);
out.findings.sourceTxs = { count: N, blockSpan: span, txs };
save();

// ------------------------------------------------------------------ phase 2
log('\n=== PHASE 2 - wait for attestation ===');
const builder = new proofProvider.service.ProofBuilder(CHAINKEY, E.PROVER_API_URL, 120_000);
const target = Math.max(...blocks);
const t0 = Date.now();
let waitErr = null;
while (Date.now() - t0 < 25 * 60 * 1000) {
  try { await builder.waitUntilHeightAttested(CHAINKEY, target); waitErr = null; break; }
  catch (e) { waitErr = e.message ?? String(e);
    log(`  retry at ${((Date.now()-t0)/1000).toFixed(0)}s: ${waitErr.slice(0,90)}`);
    await new Promise(r => setTimeout(r, 15_000)); }
}
const waitMin = +((Date.now()-t0)/60000).toFixed(2);
log(`  ${waitErr ? 'GAVE UP after' : 'attested after'} ${waitMin} min`);
out.findings.attestationWaitMinutes = waitMin;
save();
if (waitErr) { log('cannot continue without attestation'); process.exit(1); }

// ------------------------------------------------------------------ phase 3
log('\n=== PHASE 3 - probe the real batch limit ===');
const hashes = txs.map(t => t.txHash);
const probe = async (n, label) => {
  const t = Date.now();
  try {
    const r = await builder.getBatchProof(hashes.slice(0, n));
    const ok = Array.isArray(r) ? r.every(x => x.success !== false) : r.success !== false;
    const data = Array.isArray(r) ? r[0]?.data : r.data;
    log(`  ${label.padEnd(22)} ${ok ? 'OK ' : 'ERR'}  ${Date.now()-t}ms` +
        (data ? `  headers ${data.fromHeader}..${data.toHeader}` : ''));
    return { n, ok, ms: Date.now()-t, fromHeader: data?.fromHeader, toHeader: data?.toHeader,
             error: ok ? null : JSON.stringify(r).slice(0, 300) };
  } catch (e) {
    log(`  ${label.padEnd(22)} THREW  ${(e.message ?? String(e)).slice(0,110)}`);
    return { n, ok: false, threw: (e.message ?? String(e)).slice(0, 300) };
  }
};

out.findings.batchProbes = [];
for (const n of [2, 10, 11, 12]) {
  out.findings.batchProbes.push(await probe(n, `getBatchProof(${n})`));
  save();
}

// one deliberately bogus hash mixed into an otherwise valid batch
log('\n--- one invalid hash inside a valid batch ---');
try {
  const bogus = '0x' + 'de'.repeat(32);
  const t = Date.now();
  const r = await builder.getBatchProof([hashes[0], bogus, hashes[1]]);
  const ok = Array.isArray(r) ? r.every(x => x.success !== false) : r.success !== false;
  log(`  mixed batch            ${ok ? 'OK (!)' : 'rejected'}  ${Date.now()-t}ms`);
  out.findings.batchWithInvalidHash = { rejected: !ok, raw: JSON.stringify(r).slice(0, 400) };
} catch (e) {
  log(`  mixed batch            THREW  ${(e.message ?? String(e)).slice(0,110)}`);
  out.findings.batchWithInvalidHash = { rejected: true, threw: (e.message ?? String(e)).slice(0,300) };
}

out.finishedAt = new Date().toISOString();
save();
log('\n=== done - evidence/G0-B/results.json ===');
