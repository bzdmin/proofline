// Step 1 of the verified credit history: create the real economic facts on Sepolia.
// Four more invoices across three distinct registered counterparties, real mUSD moving
// each time. Fast - no attestation involved. Writes the transaction list for step 2.
//
// Settlement #1 already exists: it is run-001, the integration gate. The history is not
// manufactured for the demo; it starts with the test that proved the system works.
import 'dotenv/config';
import { ethers } from 'ethers';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { retry, tx } from './net.mjs';

const E = process.env;
const M = 10n ** 6n;
const abiOf = (f, c) => JSON.parse(readFileSync(`out/${f}/${c}.json`, 'utf8')).abi;
const P = () => new ethers.JsonRpcProvider(E.SEPOLIA_RPC_URL, undefined, { staticNetwork: true });

const seller = new ethers.Wallet(E.PRIVATE_KEY, P());
const usd = new ethers.Contract(E.MUSD_SEPOLIA, abiOf('MockERC20.sol','MockERC20'), seller);
const rec = new ethers.Contract(E.RECEIVABLE_ADDRESS, abiOf('Receivable.sol','Receivable'), seller);

// buyerA is the relayer key, already registered in run-001. B and C are derived
// deterministically from it so anyone can reproduce the same addresses.
const buyerA = new ethers.Wallet(E.RELAYER_PRIVATE_KEY, P());
const derive = (n) => new ethers.Wallet(ethers.keccak256(
  ethers.toUtf8Bytes(`proofline-history-buyer-${n}:${E.RELAYER_PRIVATE_KEY}`)), P());
const buyerB = derive('B');
const buyerC = derive('C');
const buyers = { A: buyerA, B: buyerB, C: buyerC };

console.log('seller ', seller.address);
for (const [k, w] of Object.entries(buyers)) console.log(`buyer${k} `, w.address);

// ---------------------------------------------------------------- prepare buyers
for (const [k, w] of Object.entries(buyers)) {
  const bal = await retry('getBalance', () => seller.provider.getBalance(w.address));
  if (bal < ethers.parseEther('0.003')) {
    await tx('fund', () => seller.sendTransaction({ to: w.address, value: ethers.parseEther('0.004') }));
    console.log(`  funded buyer${k} with 0.004 ETH`);
  }
  if (!(await retry('registeredBuyer', () => rec.registeredBuyer(w.address)))) {
    await tx('registerAsBuyer', () => rec.connect(w).registerAsBuyer());
    console.log(`  buyer${k} self-registered`);
  }
  await tx('mint', () => usd.mint(w.address, 200_000n * M));
  const allowance = await retry('allowance', () => usd.allowance(w.address, E.RECEIVABLE_ADDRESS));
  if (allowance < 100_000n * M) {
    await tx('approve', () => usd.connect(w).approve(E.RECEIVABLE_ADDRESS, ethers.MaxUint256));
  }
  console.log(`  buyer${k} ready`);
}

// ---------------------------------------------------------------- the four remaining
// Amounts stay at or below 12,000 so the capacity anchor set in run-001 holds, making the
// final transition depend on counterparty diversity rather than a bigger invoice.
const PLAN = [
  { buyer: 'B', amount:  8_000n * M },
  { buyer: 'C', amount: 10_000n * M },
  { buyer: 'A', amount:  7_000n * M },
  { buyer: 'B', amount:  9_000n * M },   // the fifth settlement: GOOD -> TRUSTED
];

const emitted = [];
for (const [i, p] of PLAN.entries()) {
  const w = buyers[p.buyer];
  const due = BigInt(Math.floor(Date.now() / 1000) + 7200);

  const { t: it, r: ir } = await tx('issueInvoice',
    () => rec.issueInvoice(w.address, E.MUSD_SEPOLIA, p.amount, due));
  const id = rec.interface.parseLog(
    ir.logs.find(l => { try { return rec.interface.parseLog(l)?.name === 'InvoiceIssued'; } catch { return false; } })
  ).args.id;

  const before = await retry('balanceOf', () => usd.balanceOf(w.address));
  const { t: pt, r: pr } = await tx('payInvoice', () => rec.connect(w).payInvoice(id));
  const moved = before - (await retry('balanceOf', () => usd.balanceOf(w.address)));

  emitted.push(
    { seq: i * 2 + 1, invoiceId: Number(id), event: 'InvoiceIssued', txHash: it.hash, block: ir.blockNumber, buyer: p.buyer, amount: Number(p.amount) / 1e6 },
    { seq: i * 2 + 2, invoiceId: Number(id), event: 'InvoicePaid',   txHash: pt.hash, block: pr.blockNumber, buyer: p.buyer, amount: Number(moved) / 1e6 },
  );
  console.log(`  invoice #${id}  ${Number(p.amount)/1e6} mUSD  buyer${p.buyer}  paid, ${Number(moved)/1e6} moved`);
}

mkdirSync('evidence/integration/history', { recursive: true });
const maxBlock = Math.max(...emitted.map(e => e.block));
writeFileSync('evidence/integration/history/emitted.json', JSON.stringify({
  emittedAt: new Date().toISOString(),
  note: 'settlement #1 is evidence/integration/run-001 - not repeated here',
  buyers: Object.fromEntries(Object.entries(buyers).map(([k, w]) => [k, w.address])),
  blockSpan: { from: Math.min(...emitted.map(e => e.block)), to: maxBlock, span: maxBlock - Math.min(...emitted.map(e => e.block)) },
  events: emitted,
}, null, 2));

console.log(`\n${emitted.length} events across blocks ${Math.min(...emitted.map(e => e.block))}..${maxBlock}`);
console.log('written to evidence/integration/history/emitted.json');
console.log('next: node script/history-prove.mjs   (resumable - already-proven events are skipped)');
