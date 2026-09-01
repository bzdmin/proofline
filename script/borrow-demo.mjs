// The last missing live state: earned credit actually being used.
//
// One new invoice, deliberately left UNSETTLED so a receivable stays outstanding and
// drawable becomes non-zero. No new settlement, no second credit improvement - the
// TRUSTED history is already the evidence. This invoice exists only to make the earned
// line usable.
//
//   5 proven settlements -> TRUSTED -> 9,600 earned capacity
//   -> new receivable -> borrow -> debt reduces available credit
import 'dotenv/config';
import { ethers } from 'ethers';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { proveAndSubmit } from '../worker/worker.mjs';
import { retry, tx } from './net.mjs';

const E = process.env, M = 10n ** 6n;
const DIR = 'evidence/integration/borrow';
mkdirSync(DIR, { recursive: true });
const abiOf = (f, c) => JSON.parse(readFileSync(`out/${f}/${c}.json`, 'utf8')).abi;

const sepP = new ethers.JsonRpcProvider(E.SEPOLIA_RPC_URL, undefined, { staticNetwork: true });
const cc3P = new ethers.JsonRpcProvider(E.CC3_RPC_URL, undefined, { staticNetwork: true });
const seller = new ethers.Wallet(E.PRIVATE_KEY, sepP);
const cc3 = new ethers.Wallet(E.PRIVATE_KEY, cc3P);

const rec = new ethers.Contract(E.RECEIVABLE_ADDRESS, abiOf('Receivable.sol','Receivable'), seller);
const cf  = new ethers.Contract(E.CREDITFILE_ADDRESS, abiOf('CreditFile.sol','CreditFile'), cc3P);
const tre = new ethers.Contract(E.TREASURY_ADDRESS, abiOf('Treasury.sol','Treasury'), cc3);
const acc = new ethers.Contract(E.CREDITACCESS_ADDRESS, abiOf('CreditAccess.sol','CreditAccess'), cc3P);
const cUsd = new ethers.Contract(E.MUSD_CC3, abiOf('MockERC20.sol','MockERC20'), cc3);

const TIER = ['NEW','STANDARD','GOOD','TRUSTED','WATCH','FROZEN'];
const u = (x) => Number(x) / 1e6;
const B = seller.address;

async function snap(label) {
  const debt = await retry('debtOf', () => tre.debtOf(B));
  const [f, t, dep] = await Promise.all([
    retry('file', () => cf.getCreditFile(B)),
    retry('terms', () => cf.getTermsWithDebt(B, debt)),
    retry('dep', () => acc.requiredDepositBps(B)),
  ]);
  const s = {
    label, tier: TIER[Number(t.tier)],
    advanceBps: Number(t.advanceBps), aprBps: Number(t.aprBps),
    capacity: u(t.capacity), limit: u(t.limit), drawable: u(t.drawable),
    debt: u(debt), outstandingReceivables: u(f.outstandingReceivables),
    settled: Number(f.settled), counterparties: Number(f.counterparties),
    maxSettled: u(f.maxSettledAmount), depositBps: Number(dep),
    treasuryLiquidity: u(await retry('avail', () => tre.available())),
  };
  console.log(`\n=== ${label} ===`);
  console.log(`  ${s.tier}  ${s.advanceBps/100}%/${s.aprBps/100}%   outstanding ${s.outstandingReceivables.toLocaleString()}`);
  console.log(`  capacity ${s.capacity.toLocaleString()}   line ${s.limit.toLocaleString()}   available ${s.drawable.toLocaleString()}   debt ${s.debt.toLocaleString()}`);
  console.log(`  CreditAccess deposit ${s.depositBps/100}%`);
  return s;
}

const out = { startedAt: new Date().toISOString(), borrower: B, steps: [] };
const push = (s) => { out.steps.push(s); writeFileSync(`${DIR}/borrow.json`, JSON.stringify(out, null, 2)); };

push(await snap('BEFORE — earned credit, nothing to draw against'));

// ------------------------------------------------------- one new receivable, unsettled
const buyerC = JSON.parse(readFileSync('evidence/integration/history/emitted.json','utf8')).buyers.C;
const AMOUNT = 12_000n * M;
const due = BigInt(Math.floor(Date.now()/1000) + 7200);
const { t: it, r: ir } = await tx('issueInvoice', () => rec.issueInvoice(buyerC, E.MUSD_SEPOLIA, AMOUNT, due));
const id = rec.interface.parseLog(ir.logs.find(l => { try { return rec.interface.parseLog(l)?.name==='InvoiceIssued'; } catch { return false; } })).args.id;
console.log(`\ninvoice #${id} issued for ${u(AMOUNT).toLocaleString()} to buyerC — deliberately left unsettled`);
out.newInvoice = { id: Number(id), amount: u(AMOUNT), buyer: buyerC, issueTx: it.hash, block: ir.blockNumber };

console.log('proving InvoiceIssued...');
const proof = await proveAndSubmit(it.hash, 'InvoiceIssued');
out.issuanceProof = { state: proof.state, cc3Tx: proof.cc3Tx, gasUsed: proof.gasUsed,
                      attestationMinutes: proof.attestationMinutes };
if (proof.state !== 'VERIFIED') { console.log('proof failed:', proof.reason); process.exit(1); }

const afterIssue = await snap('AFTER receivable proven — line now usable');
push(afterIssue);

// ------------------------------------------------------- draw
const DRAW = 6_300n * M;
console.log(`\nborrowing ${u(DRAW).toLocaleString()} from Treasury...`);
const { t: bt, r: br } = await tx('borrow', () => tre.borrow(DRAW));
console.log(`  ${bt.hash}  gas ${br.gasUsed}`);
out.borrowTx = { hash: bt.hash, amount: u(DRAW), gasUsed: br.gasUsed.toString() };

const afterBorrow = await snap('AFTER BORROWING');
push(afterBorrow);

// the assertions that matter
const checks = {
  debtIncreased:        afterBorrow.debt === u(DRAW),
  drawableFellByDraw:   Math.abs((afterIssue.drawable - afterBorrow.drawable) - u(DRAW)) < 0.01,
  capacityUnchanged:    afterIssue.capacity === afterBorrow.capacity,
  limitUnchanged:       afterIssue.limit === afterBorrow.limit,
  tierUnchanged:        afterIssue.tier === afterBorrow.tier,
  depositUnchanged:     afterIssue.depositBps === afterBorrow.depositBps,
  capitalActuallyMoved: u(await retry('bal', () => cUsd.balanceOf(B))) >= u(DRAW),
};
out.assertions = checks;
console.log('\n--- assertions ---');
for (const [k, v] of Object.entries(checks)) console.log(`  ${v ? 'PASS' : 'FAIL'}  ${k}`);

// ------------------------------------------------------- repay half
const half = DRAW / 2n;
console.log(`\nrepaying ${u(half).toLocaleString()}...`);
await tx('approve', () => cUsd.approve(E.TREASURY_ADDRESS, ethers.MaxUint256));
const { t: rt, r: rr } = await tx('repay', () => tre.repay(half));
console.log(`  ${rt.hash}  gas ${rr.gasUsed}`);
out.repayTx = { hash: rt.hash, amount: u(half), gasUsed: rr.gasUsed.toString() };

const afterRepay = await snap('AFTER PARTIAL REPAYMENT');
push(afterRepay);
out.repayAssertions = {
  debtRoughlyHalved: Math.abs(afterRepay.debt - u(half)) < 5,
  drawableRecovered: afterRepay.drawable > afterBorrow.drawable,
  capacityStillUnchanged: afterRepay.capacity === afterIssue.capacity,
};
console.log('\n--- repayment assertions ---');
for (const [k, v] of Object.entries(out.repayAssertions)) console.log(`  ${v ? 'PASS' : 'FAIL'}  ${k}`);

out.finishedAt = new Date().toISOString();
writeFileSync(`${DIR}/borrow.json`, JSON.stringify(out, null, 2));
console.log(`\n=== ${DIR}/borrow.json ===`);
