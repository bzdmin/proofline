// Step 2: prove the emitted history. Resumable - anything already VERIFIED is skipped, and
// an AlreadyProcessed rejection is treated as "already done" rather than a failure, so this
// can be re-run safely after an interruption.
//
// Order matters: ObligationCreated adds to the borrowing base, ObligationSettled removes it.
// Events are proven strictly in the sequence they occurred on Sepolia.
import 'dotenv/config';
import { ethers } from 'ethers';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { proveAndSubmit, waitForAttestation } from '../worker/worker.mjs';
import { retry } from './net.mjs';

const E = process.env;
const DIR = 'evidence/integration/history';
const PROGRESS = `${DIR}/progress.json`;
const abiOf = (f, c) => JSON.parse(readFileSync(`out/${f}/${c}.json`, 'utf8')).abi;

const cc3P = new ethers.JsonRpcProvider(E.CC3_RPC_URL, undefined, { staticNetwork: true });
const seller = new ethers.Wallet(E.PRIVATE_KEY).address;
const cf  = new ethers.Contract(E.CREDITFILE_ADDRESS, abiOf('CreditFile.sol','CreditFile'), cc3P);
const acc = new ethers.Contract(E.CREDITACCESS_ADDRESS, abiOf('CreditAccess.sol','CreditAccess'), cc3P);

const TIER = ['NEW','STANDARD','GOOD','TRUSTED','WATCH','FROZEN'];
const u = (x) => Number(x) / 1e6;

async function snapshot(label) {
  const f = await retry('getCreditFile', () => cf.getCreditFile(seller));
  const t = await retry('getTerms', () => cf.getTerms(seller));
  const dep = await retry('deposit', () => acc.requiredDepositBps(seller));
  const s = {
    label,
    settled: Number(f.settled), onTime: Number(f.onTime), counterparties: Number(f.counterparties),
    outstanding: u(f.outstandingReceivables), maxSettled: u(f.maxSettledAmount),
    verifiedVolume: u(f.verifiedVolume),
    tier: TIER[Number(t.tier)], advanceBps: Number(t.advanceBps), aprBps: Number(t.aprBps),
    capacity: u(t.capacity), limit: u(t.limit), drawable: u(t.drawable),
    depositBps: Number(dep),
  };
  console.log(`  -> ${s.tier.padEnd(8)} ${s.advanceBps/100}%/${s.aprBps/100}%  settled ${s.settled} CPs ${s.counterparties}  cap ${s.capacity.toLocaleString()} limit ${s.limit.toLocaleString()}  deposit ${s.depositBps/100}%`);
  return s;
}

const emitted = JSON.parse(readFileSync(`${DIR}/emitted.json`, 'utf8'));
const progress = existsSync(PROGRESS) ? JSON.parse(readFileSync(PROGRESS, 'utf8')) : { done: {}, snapshots: [] };
const save = () => writeFileSync(PROGRESS, JSON.stringify(progress, null, 2));

const pending = emitted.events.filter(e => !progress.done[e.txHash + e.event]);
console.log(`${emitted.events.length} events, ${pending.length} still to prove\n`);

if (pending.length) {
  // One attestation wait covers the whole set: the emissions span 10 blocks.
  const att = await waitForAttestation(emitted.blockSpan.to);
  if (!att.ok) { console.log('attestation deadline exceeded; re-run to resume'); process.exit(1); }
  progress.attestation = att;
  save();
}

for (const e of emitted.events) {
  const key = e.txHash + e.event;
  if (progress.done[key]) { console.log(`#${e.seq} ${e.event} (already proven, skipped)`); continue; }

  console.log(`#${e.seq} invoice #${e.invoiceId} ${e.event} buyer${e.buyer} ${e.amount.toLocaleString()}`);
  const r = await proveAndSubmit(e.txHash, e.event);

  // AlreadyProcessed means a previous run landed it. Not a failure.
  const done = r.state === 'VERIFIED' || (r.reason ?? '').startsWith('AlreadyProcessed');
  if (!done) { console.log(`  FAILED: ${r.reason ?? r.msg}. Re-run to resume.`); save(); process.exit(1); }

  progress.done[key] = { state: r.state, cc3Tx: r.cc3Tx ?? null, gasUsed: r.gasUsed ?? null,
                         creditEvents: r.creditEventsCreated ?? 0, reason: r.reason ?? null };
  if (e.event === 'InvoicePaid') {
    const s = await snapshot(`after settlement of invoice #${e.invoiceId}`);
    progress.snapshots.push(s);
  }
  save();
}

const final = await snapshot('FINAL');
const gas = Object.values(progress.done).filter(d => d.gasUsed).map(d => Number(d.gasUsed));
writeFileSync(`${DIR}/history.json`, JSON.stringify({
  completedAt: new Date().toISOString(),
  borrower: seller,
  buyers: emitted.buyers,
  note: 'Settlement #1 is evidence/integration/run-001. Settlements #2-#5 are here.',
  attestation: progress.attestation,
  ingestGas: gas.length ? { count: gas.length, total: gas.reduce((a,b)=>a+b,0), mean: Math.round(gas.reduce((a,b)=>a+b,0)/gas.length) } : null,
  progression: progress.snapshots,
  final,
}, null, 2));

console.log(`\n=== verified credit history complete ===`);
console.log(`${DIR}/history.json`);
