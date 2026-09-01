// The integration gate: a real Ethereum economic event becomes real Creditcoin credit,
// and two independent consumers react. No frontend involved.
import 'dotenv/config';
import { ethers } from 'ethers';
import { readFileSync, writeFileSync } from 'node:fs';
import { proveAndSubmit } from '../worker/worker.mjs';

const E = process.env;
const M = 10n ** 6n;
const abiOf = (f, c) => JSON.parse(readFileSync(`out/${f}/${c}.json`, 'utf8')).abi;

const sep = new ethers.Wallet(E.PRIVATE_KEY, new ethers.JsonRpcProvider(E.SEPOLIA_RPC_URL));
const cc3P = new ethers.JsonRpcProvider(E.CC3_RPC_URL);
const cc3 = new ethers.Wallet(E.PRIVATE_KEY, cc3P);
const buyer = new ethers.Wallet(E.RELAYER_PRIVATE_KEY, new ethers.JsonRpcProvider(E.SEPOLIA_RPC_URL));

const usd = new ethers.Contract(E.MUSD_SEPOLIA, abiOf('MockERC20.sol','MockERC20'), sep);
const rec = new ethers.Contract(E.RECEIVABLE_ADDRESS, abiOf('Receivable.sol','Receivable'), sep);
const cf  = new ethers.Contract(E.CREDITFILE_ADDRESS, abiOf('CreditFile.sol','CreditFile'), cc3P);
const tre = new ethers.Contract(E.TREASURY_ADDRESS, abiOf('Treasury.sol','Treasury'), cc3);
const acc = new ethers.Contract(E.CREDITACCESS_ADDRESS, abiOf('CreditAccess.sol','CreditAccess'), cc3P);

const TIER = ['NEW','STANDARD','GOOD','TRUSTED','WATCH','FROZEN'];
const fmt = (x) => (Number(x) / 1e6).toLocaleString();
const out = { startedAt: new Date().toISOString(), steps: [] };
const rec_ = (k, v) => { out.steps.push({ [k]: v }); writeFileSync('evidence/integration/round-trip.json', JSON.stringify(out, null, 2)); };

async function showState(label) {
  const f = await cf.getCreditFile(sep.address);
  const t = await cf.getTerms(sep.address);
  const dep = await acc.requiredDepositBps(sep.address);
  const snap = {
    settled: Number(f.settled), onTime: Number(f.onTime),
    outstanding: fmt(f.outstandingReceivables), maxSettled: fmt(f.maxSettledAmount),
    counterparties: Number(f.counterparties),
    tier: TIER[Number(t.tier)], advanceBps: Number(t.advanceBps), aprBps: Number(t.aprBps),
    capacity: fmt(t.capacity), limit: fmt(t.limit), drawable: fmt(t.drawable),
    creditAccessDepositBps: Number(dep),
  };
  console.log(`\n=== ${label} ===`);
  console.log(`  file      settled ${snap.settled}  onTime ${snap.onTime}  CPs ${snap.counterparties}  outstanding ${snap.outstanding}`);
  console.log(`  TREASURY  tier ${snap.tier}  advance ${snap.advanceBps/100}%  APR ${snap.aprBps/100}%`);
  console.log(`            capacity ${snap.capacity}  limit ${snap.limit}  drawable ${snap.drawable}`);
  console.log(`  ACCESS    deposit required ${snap.creditAccessDepositBps/100}%`);
  rec_(label, snap);
  return snap;
}

// ---------------------------------------------------------------- setup
console.log('seller', sep.address, '\nbuyer ', buyer.address);
if ((await new ethers.JsonRpcProvider(E.SEPOLIA_RPC_URL).getBalance(buyer.address)) < ethers.parseEther('0.002')) {
  console.log('funding buyer with Sepolia ETH...');
  await (await sep.sendTransaction({ to: buyer.address, value: ethers.parseEther('0.005') })).wait();
}
if (!(await rec.registeredBuyer(buyer.address))) {
  await (await rec.connect(buyer).registerAsBuyer()).wait();
  console.log('buyer registered');
}
await (await usd.mint(buyer.address, 100_000n * M)).wait();
await (await usd.connect(buyer).approve(await rec.getAddress(), ethers.MaxUint256)).wait();

await showState('BEFORE ANY PROOF');

// ---------------------------------------------------------------- Sepolia facts
const AMOUNT = 12_000n * M;
const due = BigInt(Math.floor(Date.now() / 1000) + 3600);

const issueTx = await rec.issueInvoice(buyer.address, await usd.getAddress(), AMOUNT, due);
const issueR = await issueTx.wait();
const invoiceId = rec.interface.parseLog(issueR.logs.find(l => { try { return rec.interface.parseLog(l)?.name === 'InvoiceIssued'; } catch { return false; } })).args.id;
console.log(`\ninvoice #${invoiceId} issued for ${fmt(AMOUNT)} mUSD  tx ${issueTx.hash}`);

const usdBefore = await usd.balanceOf(buyer.address);
const payTx = await rec.connect(buyer).payInvoice(invoiceId);
await payTx.wait();
const moved = usdBefore - (await usd.balanceOf(buyer.address));
console.log(`invoice paid, ${fmt(moved)} mUSD actually moved  tx ${payTx.hash}`);
rec_('sepolia', { invoiceId: Number(invoiceId), amount: fmt(AMOUNT), issueTx: issueTx.hash, payTx: payTx.hash, valueMoved: fmt(moved) });

// ---------------------------------------------------------------- prove, in order
// Order matters: Created adds to the borrowing base, Settled removes it.
console.log('\nproving InvoiceIssued (one attestation wait covers both)...');
const r1 = await proveAndSubmit(issueTx.hash, 'InvoiceIssued');
rec_('proofIssued', r1);
await showState('AFTER InvoiceIssued PROVEN');

console.log('\nproving InvoicePaid...');
const r2 = await proveAndSubmit(payTx.hash, 'InvoicePaid');
rec_('proofPaid', r2);
const after = await showState('AFTER InvoicePaid PROVEN');

// ---------------------------------------------------------------- failure paths
console.log('\n=== failure paths through the real stack ===');
const fileBefore = await cf.getCreditFile(sep.address);

const replay = await proveAndSubmit(payTx.hash, 'InvoicePaid');
const fileAfterReplay = await cf.getCreditFile(sep.address);
const unchanged = fileBefore.settled === fileAfterReplay.settled
               && fileBefore.outstandingReceivables === fileAfterReplay.outstandingReceivables;
console.log(`  replay        ${replay.state}  credit file unchanged: ${unchanged}`);
rec_('replayRejected', { state: replay.state, reason: replay.reason, creditFileUnchanged: unchanged });

const wrongEvent = await proveAndSubmit(payTx.hash, 'InvoiceDefaulted');
console.log(`  wrong event   ${wrongEvent.state}  ${wrongEvent.reason ?? ''}`);
rec_('wrongEventRejected', { state: wrongEvent.state, reason: wrongEvent.reason });

out.finishedAt = new Date().toISOString();
writeFileSync('evidence/integration/round-trip.json', JSON.stringify(out, null, 2));
console.log('\n=== round trip complete - evidence/integration/round-trip.json ===');
