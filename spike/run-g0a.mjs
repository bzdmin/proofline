// G0-A runner. Answers the seven questions and captures fixtures.
//
// Strategy: fire EVERY Sepolia transaction first, then wait once for attestation,
// then prove them all. Attestation latency is paid once instead of N times.
import 'dotenv/config';
import { ethers } from 'ethers';
import { proofProvider } from '@gluwa/usc-sdk';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';

const E = process.env;
const CHAINKEY = Number(E.CHAINKEY_SEPOLIA ?? 1);
const abiOf = (f, c) => JSON.parse(readFileSync(`out/${f}/${c}.json`, 'utf8')).abi;

const sepProvider = new ethers.JsonRpcProvider(E.SEPOLIA_RPC_URL);
const cc3Provider = new ethers.JsonRpcProvider(E.CC3_RPC_URL);
const main    = new ethers.Wallet(E.PRIVATE_KEY, sepProvider);
const cc3Main = new ethers.Wallet(E.PRIVATE_KEY, cc3Provider);
const cc3Relay = E.RELAYER_PRIVATE_KEY && E.RELAYER_PRIVATE_KEY !== '0x'
  ? new ethers.Wallet(E.RELAYER_PRIVATE_KEY, cc3Provider) : null;

const source   = new ethers.Contract(E.SPIKE_SOURCE_ADDRESS,   abiOf('SpikeSource.sol','SpikeSource'),   main);
const imposter = new ethers.Contract(E.SPIKE_IMPOSTER_ADDRESS, abiOf('SpikeSource.sol','SpikeImposter'), main);
const ascAbi   = abiOf('SpikeASC.sol','SpikeASC');
const asc      = new ethers.Contract(E.SPIKE_ASC_ADDRESS, ascAbi, cc3Main);

const results = { startedAt: new Date().toISOString(), chainKey: CHAINKEY, phases: {}, answers: {} };
const log = (...a) => console.log(...a);
const save = () => writeFileSync('evidence/G0-A/results.json', JSON.stringify(results, null, 2));

// ---------------------------------------------------------------- phase 1
log('=== PHASE 1 — fire all Sepolia transactions ===');
const sent = {};
async function fire(label, promise, expectRevert = false) {
  try {
    const tx = await promise;
    const r = await tx.wait();
    sent[label] = { txHash: tx.hash, block: r.blockNumber, status: r.status, gasUsed: r.gasUsed.toString() };
    log(`  ${label.padEnd(16)} ${tx.hash}  block ${r.blockNumber}  status ${r.status}`);
  } catch (err) {
    // pingThenRevert reverts; ethers throws but the tx IS mined with status 0
    const h = err?.receipt?.hash ?? err?.transaction?.hash ?? err?.transactionHash;
    if (expectRevert && h) {
      const r = await sepProvider.getTransactionReceipt(h);
      sent[label] = { txHash: h, block: r.blockNumber, status: r.status, gasUsed: r.gasUsed.toString(), reverted: true };
      log(`  ${label.padEnd(16)} ${h}  block ${r.blockNumber}  status ${r.status}  (reverted, as intended)`);
    } else { log(`  ${label.padEnd(16)} FAILED: ${err.shortMessage ?? err.message}`); }
  }
}

await fire('happy',      source.ping(1_000_000n));
await fire('batch3',     source.pingBatch(3n));
await fire('imposter',   imposter.ping(999n, 500_000n));
await fire('revertAfterEmit', source.pingThenRevert(42n, { gasLimit: 200_000n }), true);
await fire('relayTarget',  source.ping(7_777n));   // reserved for Q4: must be unconsumed

results.phases.sepolia = sent;
const maxBlock = Math.max(...Object.values(sent).map(s => s.block));
log(`\n  highest block to attest: ${maxBlock}`);
save();

// ---------------------------------------------------------------- phase 2
log('\n=== PHASE 2 — wait for attestation (Q2: latency) ===');
const builder = new proofProvider.service.ProofBuilder(CHAINKEY, E.PROVER_API_URL, 120_000);
const t0 = Date.now();
const DEADLINE_MS = 25 * 60 * 1000;
let waitErr = null, attempts = 0, transient = 0;
while (Date.now() - t0 < DEADLINE_MS) {
  attempts++;
  try {
    await builder.waitUntilHeightAttested(CHAINKEY, maxBlock);
    waitErr = null; break;
  } catch (e) {
    waitErr = e.message ?? String(e);
    transient++;
    log(`  attempt ${attempts} at ${((Date.now()-t0)/1000).toFixed(0)}s: ${waitErr.slice(0,110)}`);
    await new Promise(r => setTimeout(r, 15_000));
  }
}
const waitMs = Date.now() - t0;
log(`  ${waitErr ? 'GAVE UP after' : 'attested after'} ${(waitMs/60000).toFixed(1)} min for height ${maxBlock}`);
results.answers.Q2_attestationLatency = {
  targetHeight: maxBlock,
  waitedSeconds: +(waitMs/1000).toFixed(1),
  waitedMinutes: +(waitMs/60000).toFixed(2),
  pollAttempts: attempts, transientErrors: transient,
  note: 'wall clock from highest tx mined to that height attested; single sample',
  error: waitErr,
};
save();

// ---------------------------------------------------------------- phase 3
log('\n=== PHASE 3 — build proofs and submit ===');
mkdirSync('evidence/G0-A/fixtures', { recursive: true });
const proofs = {};

for (const [label, s] of Object.entries(sent)) {
  const p0 = Date.now();
  const res = await builder.getProof(s.txHash);
  const pMs = Date.now() - p0;
  if (!res.success) { log(`  ${label.padEnd(16)} getProof FAILED: ${res.error}`); proofs[label] = { error: res.error }; continue; }
  const d = res.data;
  proofs[label] = { ms: pMs, headerNumber: d.headerNumber, txIndex: d.txIndex, siblings: d.merkleProof.siblings.length, roots: d.continuityProof.roots.length };
  log(`  ${label.padEnd(16)} proof in ${pMs}ms  header ${d.headerNumber}  txIndex ${d.txIndex}  siblings ${d.merkleProof.siblings.length}`);
  writeFileSync(`evidence/G0-A/fixtures/${label}.json`, JSON.stringify({ label, capturedAt: new Date().toISOString(), sepolia: s, proof: d }, null, 2));
}
results.phases.proofs = proofs;
save();

// ---------------------------------------------------------------- submissions
async function submit(label, signer, fixtureLabel) {
  let fx;
  try { fx = JSON.parse(readFileSync(`evidence/G0-A/fixtures/${fixtureLabel}.json`, 'utf8')).proof; }
  catch { log(`  ${label.padEnd(22)} SKIPPED — no fixture (${fixtureLabel})`); return { ok:false, reason:'no fixture captured' }; }
  const c = new ethers.Contract(E.SPIKE_ASC_ADDRESS, ascAbi, signer);
  const args = [ BigInt(CHAINKEY), BigInt(fx.headerNumber), fx.txBytes,
                 fx.merkleProof.root, fx.merkleProof.siblings,
                 fx.continuityProof.lowerEndpointDigest, fx.continuityProof.roots ];
  try {
    const est = await c.submit.estimateGas(...args);
    const tx = await c.submit(...args, { gasLimit: est * 12n / 10n });
    const r = await tx.wait();
    const accepted = r.logs.filter(l => { try { return c.interface.parseLog(l)?.name === 'SpikeAccepted'; } catch { return false; } }).length;
    const gates = r.logs.map(l => { try { return c.interface.parseLog(l); } catch { return null; } })
                        .filter(p => p?.name === 'GatePassed').map(p => `${p.args[1]}:${p.args[2]}`);
    log(`  ${label.padEnd(22)} OK   gas ${r.gasUsed}  accepted ${accepted}  gates [${gates.join(' ')}]`);
    return { ok: true, gasUsed: r.gasUsed.toString(), accepted, gates, txHash: tx.hash };
  } catch (err) {
    let reason = err.shortMessage ?? err.message;
    try { const d = c.interface.parseError(err.data ?? err.info?.error?.data); if (d) reason = `${d.name}(${d.args.join(', ')})`; } catch {}
    log(`  ${label.padEnd(22)} REJECTED  ${reason}`);
    return { ok: false, reason };
  }
}

log('\n--- Q1/Q3: happy path ---');
results.answers.Q1_Q3_happyPath = await submit('happy', cc3Main, 'happy');

log('\n--- Q6a: replay the same proof ---');
results.answers.Q6_replay = await submit('replay same proof', cc3Main, 'happy');

log('\n--- Q6b: one tx, three logs ---');
results.answers.Q6_batchLogs = await submit('pingBatch(3)', cc3Main, 'batch3');

log('\n--- Q5: unauthorized source ---');
results.answers.Q5_unauthorizedSource = await submit('imposter event', cc3Main, 'imposter');

log('\n--- Q7: reverted source transaction ---');
results.answers.Q7_receiptStatus = await submit('reverted tx', cc3Main, 'revertAfterEmit');

if (cc3Relay) {
  log('\n--- Q4: permissionless relay (unrelated address) ---');
  results.answers.Q4_permissionlessRelay = await submit('relayer submits', cc3Relay, 'relayTarget');
  results.answers.Q4_permissionlessRelay.note =
    'fresh unconsumed proof, submitted by an address unrelated to deployer/owner/source. Success proves relay is genuinely permissionless.';
}

results.finishedAt = new Date().toISOString();
save();
log('\n=== done — evidence/G0-A/results.json ===');
