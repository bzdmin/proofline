// Resume run-001. The Sepolia facts already exist and are permanent; this proves them,
// then attempts the two rejection paths against the resulting state.
// Every step writes machine-readable JSON into evidence/integration/run-001/.
import 'dotenv/config';
import { ethers } from 'ethers';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { proveAndSubmit } from '../worker/worker.mjs';

const E = process.env;
const DIR = 'evidence/integration/run-001';
mkdirSync(DIR, { recursive: true });

const abiOf = (f, c) => JSON.parse(readFileSync(`out/${f}/${c}.json`, 'utf8')).abi;
const cc3P = new ethers.JsonRpcProvider(E.CC3_RPC_URL, undefined, { staticNetwork: true });
const seller = new ethers.Wallet(E.PRIVATE_KEY).address;

const cf  = new ethers.Contract(E.CREDITFILE_ADDRESS, abiOf('CreditFile.sol','CreditFile'), cc3P);
const acc = new ethers.Contract(E.CREDITACCESS_ADDRESS, abiOf('CreditAccess.sol','CreditAccess'), cc3P);

const TIER = ['NEW','STANDARD','GOOD','TRUSTED','WATCH','FROZEN'];
const u = (x) => Number(x) / 1e6;

async function snapshot(label) {
  const f = await cf.getCreditFile(seller);
  const t = await cf.getTerms(seller);
  const dep = await acc.requiredDepositBps(seller);
  const n = await cf.eventCount(seller);
  const s = {
    label, at: new Date().toISOString(), borrower: seller,
    creditFile: {
      settled: Number(f.settled), onTime: Number(f.onTime), defaults: Number(f.defaults),
      openDelinquencies: Number(f.openDelinquencies), counterparties: Number(f.counterparties),
      verifiedVolume: u(f.verifiedVolume), outstandingReceivables: u(f.outstandingReceivables),
      maxSettledAmount: u(f.maxSettledAmount), currentLimit: u(f.currentLimit),
      recordedEvents: Number(n),
    },
    treasuryTerms: {
      tier: TIER[Number(t.tier)], advanceBps: Number(t.advanceBps), aprBps: Number(t.aprBps),
      capacity: u(t.capacity), limit: u(t.limit), drawable: u(t.drawable),
    },
    creditAccess: { requiredDepositBps: Number(dep) },
  };
  const c = s.creditFile, tt = s.treasuryTerms;
  console.log(`\n=== ${label} ===`);
  console.log(`  file      settled ${c.settled} onTime ${c.onTime} CPs ${c.counterparties} outstanding ${c.outstandingReceivables.toLocaleString()} maxSettled ${c.maxSettledAmount.toLocaleString()}`);
  console.log(`  TREASURY  ${tt.tier}  advance ${tt.advanceBps/100}%  APR ${tt.aprBps/100}%  capacity ${tt.capacity.toLocaleString()}  limit ${tt.limit.toLocaleString()}  drawable ${tt.drawable.toLocaleString()}`);
  console.log(`  ACCESS    deposit ${s.creditAccess.requiredDepositBps/100}%`);
  return s;
}

const prior = JSON.parse(readFileSync('evidence/integration/round-trip.json','utf8'));
const sep = prior.steps.find(x => x.sepolia).sepolia;
writeFileSync(`${DIR}/sepolia-facts.json`, JSON.stringify(sep, null, 2));
console.log('resuming run-001');
console.log('  issue tx', sep.issueTx);
console.log('  pay tx  ', sep.payTx);

writeFileSync(`${DIR}/00-before.json`, JSON.stringify(await snapshot('BEFORE ANY PROOF'), null, 2));

// ---------------------------------------------------------------- proof 1
console.log('\nproving InvoiceIssued...');
const p1 = await proveAndSubmit(sep.issueTx, 'InvoiceIssued');
const s1 = await snapshot('AFTER InvoiceIssued PROVEN');
writeFileSync(`${DIR}/01-invoice-issued.json`, JSON.stringify({ proof: p1, state: s1 }, null, 2));

// ---------------------------------------------------------------- proof 2
console.log('\nproving InvoicePaid...');
const p2 = await proveAndSubmit(sep.payTx, 'InvoicePaid');
const s2 = await snapshot('AFTER InvoicePaid PROVEN');
writeFileSync(`${DIR}/02-invoice-paid.json`, JSON.stringify({ proof: p2, state: s2 }, null, 2));

// ---------------------------------------------------------------- rejections
// The claim is not that the ASC says no. It is that NOTHING downstream moved.
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

console.log('\n--- replay the settlement proof ---');
const r1 = await proveAndSubmit(sep.payTx, 'InvoicePaid');
const s3 = await snapshot('AFTER REPLAY ATTEMPT');
const replayClean = eq(s2.creditFile, s3.creditFile) && eq(s2.treasuryTerms, s3.treasuryTerms)
                 && eq(s2.creditAccess, s3.creditAccess);
console.log(`  rejected: ${r1.state}   downstream unchanged: ${replayClean}`);
writeFileSync(`${DIR}/03-rejection-replay.json`, JSON.stringify(
  { attempt: r1, stateAfter: s3, downstreamUnchanged: replayClean }, null, 2));

console.log('\n--- same proof, claimed as InvoiceDefaulted ---');
const r2 = await proveAndSubmit(sep.payTx, 'InvoiceDefaulted');
const s4 = await snapshot('AFTER FALSE-EVENT ATTEMPT');
const fakeClean = eq(s2.creditFile, s4.creditFile) && eq(s2.treasuryTerms, s4.treasuryTerms)
               && eq(s2.creditAccess, s4.creditAccess);
console.log(`  rejected: ${r2.state}   downstream unchanged: ${fakeClean}`);
writeFileSync(`${DIR}/04-rejection-fake-event.json`, JSON.stringify(
  { attempt: r2, stateAfter: s4, downstreamUnchanged: fakeClean }, null, 2));

writeFileSync(`${DIR}/summary.json`, JSON.stringify({
  run: 'run-001', finishedAt: new Date().toISOString(),
  sepolia: sep,
  transitions: [
    { step: 'InvoiceIssued', state: p1.state, creditEvents: p1.creditEventsCreated ?? 0, cc3Tx: p1.cc3Tx },
    { step: 'InvoicePaid',   state: p2.state, creditEvents: p2.creditEventsCreated ?? 0, cc3Tx: p2.cc3Tx },
  ],
  rejections: [
    { step: 'replay',     state: r1.state, reason: r1.reason, downstreamUnchanged: replayClean },
    { step: 'fake-event', state: r2.state, reason: r2.reason, downstreamUnchanged: fakeClean },
  ],
  finalTerms: s2.treasuryTerms,
}, null, 2));

console.log(`\n=== run-001 complete: ${DIR}/ ===`);
