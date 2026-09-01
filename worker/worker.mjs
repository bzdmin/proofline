// ProofLine worker. Deliberately small: watch, wait, prove, submit, record.
//
// It is convenience infrastructure, not a trust assumption - G0-A Q4 confirmed any address
// can relay a valid proof. If this process dies, anyone can keep the credit file advancing.
//
// The state machine reflects what G0-A measured. Network and prover failures are NOT proof
// failures, and collapsing them is exactly how the first spike run reported a working
// protocol as broken.
import 'dotenv/config';
import { ethers } from 'ethers';
import { proofProvider } from '@gluwa/usc-sdk';
import { readFileSync, writeFileSync, appendFileSync, mkdirSync } from 'node:fs';

export const State = {
  NOT_YET_ATTESTED: 'NOT_YET_ATTESTED',
  PROVER_RETRY:     'PROVER_RETRY',
  PROOF_READY:      'PROOF_READY',
  SUBMITTED:        'SUBMITTED',
  VERIFIED:         'VERIFIED',
  REJECTED:         'REJECTED',
};

const E = process.env;
const CK = Number(E.CHAINKEY_SEPOLIA ?? 1);
const abiOf = (f, c) => JSON.parse(readFileSync(`out/${f}/${c}.json`, 'utf8')).abi;

// staticNetwork skips the chainId detection round trip, which is where a flaky endpoint
// most often fails to start up at all.
const sepProvider = new ethers.JsonRpcProvider(E.SEPOLIA_RPC_URL, undefined, { staticNetwork: true });
const cc3Wallet = new ethers.Wallet(
  E.PRIVATE_KEY,
  new ethers.JsonRpcProvider(E.CC3_RPC_URL, undefined, { staticNetwork: true })
);

/// Retry any network call. A transport failure is NOT a proof failure - the worker must
/// never let an RPC timeout look like a rejected proof, or report a working protocol as
/// broken. Classified as PROVER_RETRY, never REJECTED.
async function withRetry(what, fn, attempts = 5, waitMs = 5_000) {
  for (let i = 1; i <= attempts; i++) {
    try { return await fn(); }
    catch (err) {
      // A contract revert is DETERMINISTIC. Retrying it is pointless, and logging it as
      // PROVER_RETRY corrupts the very distinction this state machine exists to preserve:
      // a rejected proof is not a flaky network. Rethrow immediately so the caller
      // classifies it as REJECTED.
      const isRevert = err.code === 'CALL_EXCEPTION'
        || err.data !== undefined
        || /execution reverted/i.test(err.message ?? '');
      if (isRevert) throw err;

      const m = (err.message ?? String(err)).slice(0, 80);
      if (i === attempts) throw err;
      log(State.PROVER_RETRY, `${what} transport failure (${i}/${attempts}): ${m}`);
      await new Promise(r => setTimeout(r, waitMs));
    }
  }
}
const ascAbi = abiOf('ASCReceiver.sol', 'ASCReceiver');
const asc = new ethers.Contract(E.ASCRECEIVER_ADDRESS, ascAbi, cc3Wallet);
const builder = new proofProvider.service.ProofBuilder(CK, E.PROVER_API_URL, 120_000);

mkdirSync('evidence/integration', { recursive: true });
const LOG = 'evidence/integration/worker-runs.jsonl';

const now = () => new Date().toISOString();
export const log = (s, msg, extra = {}) => {
  const line = { at: now(), state: s, msg, ...extra };
  console.log(`[${s.padEnd(16)}] ${msg}`);
  appendFileSync(LOG, JSON.stringify(line) + '\n');
  return line;
};

/// Wait for a height to be attested, retrying transport failures without ever reporting
/// them as attestation failures.
export async function waitForAttestation(height, deadlineMs = 25 * 60 * 1000) {
  const t0 = Date.now();
  let attempts = 0, transient = 0;
  log(State.NOT_YET_ATTESTED, `waiting for height ${height}`);
  while (Date.now() - t0 < deadlineMs) {
    attempts++;
    try {
      await builder.waitUntilHeightAttested(CK, height);
      const mins = ((Date.now() - t0) / 60000).toFixed(2);
      log(State.PROOF_READY, `height ${height} attested after ${mins} min`,
          { minutes: +mins, attempts, transientErrors: transient });
      return { ok: true, minutes: +mins, attempts, transientErrors: transient };
    } catch (err) {
      transient++;
      log(State.PROVER_RETRY, `transport failure, retrying: ${(err.message ?? err).slice(0, 90)}`,
          { attempt: attempts });
      await new Promise(r => setTimeout(r, 15_000));
    }
  }
  return { ok: false, reason: 'attestation deadline exceeded', attempts, transientErrors: transient };
}

/// Prove one Sepolia transaction and submit every matching log to the ASC.
export async function proveAndSubmit(txHash, eventName) {
  const rcpt = await withRetry('getTransactionReceipt',
    () => sepProvider.getTransactionReceipt(txHash));
  if (!rcpt) return log(State.REJECTED, `no receipt for ${txHash}`, { txHash });

  const att = await waitForAttestation(rcpt.blockNumber);
  if (!att.ok) return log(State.REJECTED, att.reason, { txHash, ...att });

  const t0 = Date.now();
  const res = await withRetry('getProof', () => builder.getProof(txHash));
  const buildMs = Date.now() - t0;
  if (!res.success) return log(State.REJECTED, `proof construction failed: ${res.error}`, { txHash });
  const p = res.data;

  const sig = ethers.id(`${eventName}(uint256,address,address,address,uint256,uint64,uint64)`);
  const args = [
    BigInt(CK), BigInt(p.headerNumber), p.txBytes,
    p.merkleProof.root, p.merkleProof.siblings,
    p.continuityProof.lowerEndpointDigest, p.continuityProof.roots,
    sig,
  ];

  try {
    const est = await withRetry('estimateGas', () => asc.submitProof.estimateGas(...args), 3);
    const tx = await asc.submitProof(...args, { gasLimit: (est * 12n) / 10n });
    log(State.SUBMITTED, `${eventName} -> CC3 ${tx.hash}`, { txHash, cc3Tx: tx.hash });
    const r = await tx.wait();

    const created = r.logs
      .map(l => { try { return asc.interface.parseLog(l); } catch { return null; } })
      .filter(x => x?.name === 'ProofAccepted')
      .map(x => Number(x.args.eventsCreated))
      .reduce((a, b) => a + b, 0);

    return log(State.VERIFIED, `${eventName}: ${created} credit event(s), gas ${r.gasUsed}`, {
      txHash, eventName,
      chainKey: CK, blockHeight: Number(p.headerNumber), txIndex: Number(p.txIndex),
      proofBuildMs: buildMs, attestationMinutes: att.minutes,
      transientErrors: att.transientErrors,
      cc3Tx: tx.hash, gasUsed: r.gasUsed.toString(), creditEventsCreated: created,
    });
  } catch (err) {
    let reason = err.shortMessage ?? err.message;
    try {
      const d = asc.interface.parseError(err.data ?? err.info?.error?.data);
      if (d) reason = `${d.name}(${d.args.join(', ')})`;
    } catch {}
    // A contract rejection is a REJECTED proof. A transport failure is not, and would have
    // been caught above - the distinction is the point of this state machine.
    return log(State.REJECTED, `${eventName}: ${reason}`, { txHash, eventName, reason });
  }
}

// CLI: node worker/worker.mjs <txHash> <EventName>
if (process.argv[2]) {
  const r = await proveAndSubmit(process.argv[2], process.argv[3] ?? 'InvoicePaid');
  writeFileSync('evidence/integration/last-run.json', JSON.stringify(r, null, 2));
}
