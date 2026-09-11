// Records two rejections at the production ASCReceiver as mined Creditcoin transactions that
// anyone can open on Blockscout.
//
// Gas estimation would stop both before broadcast, which is how the worker normally sees a
// rejection. Here each call is first dry-run to confirm the exact error, then sent with a
// fixed gas limit and allowed to revert on-chain. A reverted transaction writes nothing, so
// neither case can change CreditFile.
//
//   1. Replay-protected event substitution: the already-verified InvoicePaid transaction,
//      resubmitted as InvoiceDefaulted. Expected: AlreadyProcessed, at gate 1.
//   2. Unauthorized source: a real Circle USDC transfer on Sepolia, validly proven. Expected:
//      UnauthorizedSource(USDC, Receivable), at gate 6, after the proof itself has verified.
//
//   node script/refusals.mjs
import 'dotenv/config';
import { ethers } from 'ethers';
import { proofProvider } from '@gluwa/usc-sdk';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';

const E = process.env;
const CK = Number(E.CHAINKEY_SEPOLIA ?? 1);
const cc3 = new ethers.JsonRpcProvider(E.CC3_RPC_URL, undefined, { staticNetwork: true });
// The relayer key, not the deployer: submission is permissionless, so a rejection seen from
// an ordinary relayer is the case that matters.
const wallet = new ethers.Wallet(E.RELAYER_PRIVATE_KEY, cc3);
const abi = JSON.parse(readFileSync('out/ASCReceiver.sol/ASCReceiver.json', 'utf8')).abi;
const asc = new ethers.Contract(E.ASCRECEIVER_ADDRESS, abi, wallet);
const builder = new proofProvider.service.ProofBuilder(CK, E.PROVER_API_URL, 120_000);

const invoiceSig = (name) => ethers.id(`${name}(uint256,address,address,address,uint256,uint64,uint64)`);
const CASES = [
  {
    name: 'Replay-protected event substitution',
    source: '0x6d909c470c9be3fc0226ce05e00d770b6eaa62ba6b35ee78bf2e71c30b0b64e3',
    sourceNote: 'InvoicePaid for invoice #1, verified in evidence/integration/run-001',
    eventSignature: invoiceSig('InvoiceDefaulted'),
    eventNote: 'InvoiceDefaulted',
    expect: 'AlreadyProcessed',
  },
  {
    name: 'Unauthorized source',
    source: '0x606d7a6d17ee168fcec7134aff26e8d97f7f0372c92b315064df3458af17d99f',
    sourceNote: 'a Circle USDC Transfer on Ethereum Sepolia, from a contract ProofLine did not deploy',
    eventSignature: ethers.id('Transfer(address,address,uint256)'),
    eventNote: 'Transfer(address,address,uint256)',
    expect: 'UnauthorizedSource',
  },
];

const retry = async (f, n = 5) => {
  for (let i = 1; ; i++) {
    try { return await f(); } catch (e) {
      if (i >= n) throw e;
      await new Promise((r) => setTimeout(r, 4000 * i));
    }
  }
};
const decode = (err) => {
  try {
    const d = asc.interface.parseError(err.data ?? err.info?.error?.data ?? err.error?.data);
    if (d) return { name: d.name, text: `${d.name}(${d.args.join(', ')})` };
  } catch {}
  return { name: null, text: err.shortMessage ?? err.message };
};

const results = [];
for (const c of CASES) {
  console.log(`\n--- ${c.name}`);
  const res = await retry(() => builder.getProof(c.source));
  if (!res.success) throw new Error(`proof construction failed for ${c.source}: ${res.error}`);
  const p = res.data;
  const args = [
    BigInt(CK), BigInt(p.headerNumber), p.txBytes,
    p.merkleProof.root, p.merkleProof.siblings,
    p.continuityProof.lowerEndpointDigest, p.continuityProof.roots,
    c.eventSignature,
  ];

  // Dry run first. Refuse to broadcast anything whose outcome is not the expected rejection.
  let predicted;
  try {
    await asc.submitProof.staticCall(...args);
    throw new Error('dry run succeeded; refusing to broadcast a call that would be accepted');
  } catch (err) {
    if (/refusing to broadcast/.test(err.message)) throw err;
    predicted = decode(err);
  }
  console.log(`  predicted: ${predicted.text}`);
  if (predicted.name !== c.expect) throw new Error(`expected ${c.expect}, got ${predicted.text}; not broadcasting`);

  const tx = await asc.submitProof(...args, { gasLimit: 6_000_000n });
  console.log(`  sent ${tx.hash}`);
  let r;
  try { r = await tx.wait(); } catch { r = await retry(() => cc3.getTransactionReceipt(tx.hash)); }
  if (!r) r = await retry(() => cc3.getTransactionReceipt(tx.hash));
  console.log(`  mined in block ${r.blockNumber}, status ${r.status}, gas ${r.gasUsed}`);
  if (r.status !== 0) throw new Error(`${tx.hash} did not revert`);

  results.push({
    case: c.name, expected: c.expect, reason: predicted.text,
    source: c.source, sourceNote: c.sourceNote, sourceBlock: Number(p.headerNumber), sourceTxIndex: Number(p.txIndex),
    eventSignature: c.eventNote,
    creditcoinTx: tx.hash, creditcoinBlock: r.blockNumber, status: r.status, gasUsed: r.gasUsed.toString(),
    relayer: wallet.address,
  });
}

mkdirSync('evidence/refusals', { recursive: true });
writeFileSync('evidence/refusals/refusals.json', JSON.stringify({
  recordedAt: new Date().toISOString(),
  receiver: E.ASCRECEIVER_ADDRESS,
  note: 'Each case was dry-run first and broadcast only when the dry run returned the expected error. Both transactions reverted on-chain, so neither changed any state.',
  cases: results,
}, null, 2) + '\n');
console.log('\nwrote evidence/refusals/refusals.json');
