// Builds the interface's data files from the recorded evidence, checked against both chains.
//
//   ui/data/receipts.json  every CreditFile event -> its Ethereum source transaction and its
//                          Creditcoin verification transaction
//   ui/data/timeline.json  the credit file read from Creditcoin at the block of each change
//   ui/data/snapshot.json  the current state, shown only when the live read fails
//
// No mapping is taken on trust. A source transaction is accepted only if its Sepolia block
// and transaction index equal the ones the precompile derived and CreditFile stored, and a
// verification transaction only if it succeeded and was sent to ASCReceiver.
//
//   node script/ui-data.mjs
import fs from 'node:fs';
import { ethers } from 'ethers';

const root = new URL('../', import.meta.url);
const rd = (p) => JSON.parse(fs.readFileSync(new URL(p, root)));
const wr = (p, o) => fs.writeFileSync(new URL(p, root), JSON.stringify(o, null, 1) + '\n');

const CFG = rd('ui/data/config.json');
const ABIS = rd('ui/data/abis.json');
// Needs a node that still serves receipts from early September; some public ones prune them.
const SEPOLIA_RPC = process.env.SEPOLIA_PUBLIC_RPC || 'https://sepolia.gateway.tenderly.co';

const cc3 = new ethers.JsonRpcProvider(CFG.cc3Rpc, undefined, { staticNetwork: true });
const sep = new ethers.JsonRpcProvider(SEPOLIA_RPC, undefined, { staticNetwork: true });
const cf  = new ethers.Contract(CFG.CreditFile,   ABIS.CreditFile,   cc3);
const tre = new ethers.Contract(CFG.Treasury,     ABIS.Treasury,     cc3);
const acc = new ethers.Contract(CFG.CreditAccess, ABIS.CreditAccess, cc3);
const b = CFG.borrower;

const retry = async (f, n = 5) => {
  for (let i = 1; ; i++) {
    try { return await f(); } catch (e) {
      if (i >= n) throw e;
      await new Promise((r) => setTimeout(r, 1500 * i));
    }
  }
};
const plain = (v) => typeof v === 'bigint' ? v.toString()
  : Array.isArray(v) ? v.map(plain)
  : v && typeof v === 'object' ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, plain(x)]))
  : v;
const struct = (r) => plain(r.toObject ? r.toObject(true) : r);

// ---- 1. what the evidence says ------------------------------------------------------------
const TYPE = { InvoiceIssued: 0, InvoicePaid: 1 };
const claimed = [];
for (const f of ['01-invoice-issued', '02-invoice-paid']) {
  const { proof } = rd(`evidence/integration/run-001/${f}.json`);
  claimed.push({ invoiceId: 1, event: proof.eventName, src: proof.txHash, verify: proof.cc3Tx });
}
const emitted = rd('evidence/integration/history/emitted.json');
const progress = rd('evidence/integration/history/progress.json');
for (const e of emitted.events) {
  const done = progress.done[e.txHash + e.event];
  claimed.push({ invoiceId: e.invoiceId, event: e.event, src: e.txHash, verify: done.cc3Tx });
}
const borrow = rd('evidence/integration/borrow/borrow.json');
claimed.push({ invoiceId: borrow.newInvoice.id, event: 'InvoiceIssued',
  src: borrow.newInvoice.issueTx, verify: borrow.issuanceProof.cc3Tx });

// ---- 2. check every pairing against both chains -------------------------------------------
const events = (await retry(() => cf.getCreditEvents(b))).map(struct);
const receipts = {};
for (const c of claimed) {
  const key = `${CFG.sepolia.chainKey}:${c.invoiceId}:${TYPE[c.event]}`;
  const ev = events.find((e) => `${e.chainKey}:${e.obligationId}:${e.eventType}` === key);
  if (!ev) throw new Error(`no CreditFile event for ${key}`);

  const s = await retry(() => sep.getTransactionReceipt(c.src));
  if (BigInt(s.blockNumber) !== BigInt(ev.blockHeight) || BigInt(s.index) !== BigInt(ev.txIndex))
    throw new Error(`${key}: source ${c.src} is block ${s.blockNumber} index ${s.index}, ` +
                    `CreditFile stored ${ev.blockHeight}/${ev.txIndex}`);

  const v = await retry(() => cc3.getTransactionReceipt(c.verify));
  if (v.status !== 1 || v.to.toLowerCase() !== CFG.ASCReceiver.toLowerCase())
    throw new Error(`${key}: ${c.verify} is not a successful ASCReceiver call`);

  receipts[key] = { source: c.src, sourceBlock: s.blockNumber, verification: c.verify,
                    verificationBlock: v.blockNumber, gasUsed: v.gasUsed.toString() };
  console.log(`  ${key.padEnd(7)} source ${c.src.slice(0, 10)}  verification ${c.verify.slice(0, 10)}  ok`);
}
if (Object.keys(receipts).length !== events.length)
  throw new Error(`${events.length} CreditFile events but ${Object.keys(receipts).length} mapped`);

// ---- 3. the credit file at the block of each change ---------------------------------------
const readAt = async (blockTag) => {
  const o = { blockTag };
  const [file, debt, depositBps] = await Promise.all([
    retry(() => cf.getCreditFile(b, o)), retry(() => tre.debtOf(b, o)),
    retry(() => acc.requiredDepositBps(b, o)),
  ]);
  const terms = await retry(() => cf.getTermsWithDebt(b, debt, o));
  return { file: struct(file), terms: struct(terms), debt: debt.toString(), depositBps: depositBps.toString() };
};

const usd = (n) => Number(n).toLocaleString('en-US');
const frames = [];
for (const [key, r] of Object.entries(receipts).sort((x, y) => x[1].verificationBlock - y[1].verificationBlock)) {
  const [, id, t] = key.split(':');
  const label = Number(t) === 1 ? `Invoice #${id} settled` : `Invoice #${id} issued`;
  frames.push({ label, kind: Number(t) === 1 ? 'settled' : 'issued', key, tx: r.verification, block: r.verificationBlock });
}
for (const [label, kind, h] of [
  [`Borrowed ${usd(borrow.borrowTx.amount)}`, 'borrow', borrow.borrowTx.hash],
  [`Repaid ${usd(borrow.repayTx.amount)}`, 'repay', borrow.repayTx.hash],
]) {
  const r = await retry(() => cc3.getTransactionReceipt(h));
  if (r.status !== 1) throw new Error(`${label}: ${h} did not succeed`);
  frames.push({ label, kind, tx: h, block: r.blockNumber });
}
for (const f of frames) {
  Object.assign(f, await readAt(f.block));
  console.log(`  block ${f.block}  ${f.label.padEnd(20)} tier ${f.terms.tier}  capacity ${f.terms.capacity}  drawable ${f.terms.drawable}  debt ${f.debt}`);
}

// ---- 4. current state, for when the live read fails ---------------------------------------
const head = await retry(() => cc3.getBlockNumber());
const now = await readAt(head);

wr('ui/data/receipts.json', receipts);
wr('ui/data/timeline.json', { borrower: b, frames });
wr('ui/data/snapshot.json', { recordedAt: new Date().toISOString(), block: head, ...now, events });
console.log(`\nwrote receipts (${Object.keys(receipts).length}), timeline (${frames.length} frames), snapshot at block ${head}`);
