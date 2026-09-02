// Can ProofLine's six-gate pipeline consume Ethereum MAINNET?
//
// Reading mainnet costs no mainnet ETH: we deploy nothing there and take a transaction that
// already happened, emitted by a contract we do not control. If this verifies, the pipeline
// is chain-agnostic in fact rather than in principle.
//
// Bounded. Nothing here touches CreditFile, Treasury, CreditAccess or their evidence.
import 'dotenv/config';
import { ethers } from 'ethers';
import { proofProvider } from '@gluwa/usc-sdk';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { retry, tx } from '../script/net.mjs';

const E = process.env;
const CK = 3;                                   // Ethereum mainnet
const USDC = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
const TRANSFER = ethers.id('Transfer(address,address,uint256)');
mkdirSync('evidence/mainnet', { recursive: true });

const abiOf = (f, c) => JSON.parse(readFileSync(`out/${f}/${c}.json`, 'utf8'));
const mainnet = new ethers.JsonRpcProvider('https://ethereum-rpc.publicnode.com', undefined, { staticNetwork: true });
const cc3 = new ethers.Wallet(E.PRIVATE_KEY, new ethers.JsonRpcProvider(E.CC3_RPC_URL, undefined, { staticNetwork: true }));
const builder = new proofProvider.service.ProofBuilder(CK, E.PROVER_API_URL, 120_000);

const out = { ranAt: new Date().toISOString(), chainKey: CK };
const save = () => writeFileSync('evidence/mainnet/probe.json', JSON.stringify(out, null, 2));

// ---------------------------------------------------------------- find the attested frontier
const head = await retry('head', () => mainnet.getBlockNumber());
console.log(`mainnet head ${head}`);
let attested = null;
for (const back of [40, 80, 150, 300, 600]) {
  const h = head - back;
  try {
    await builder.waitUntilHeightAttested(CK, h);
    attested = h; console.log(`  height ${h} attested (head - ${back})`); break;
  } catch { console.log(`  height ${h} not attested yet`); }
}
if (!attested) { console.log('no attested mainnet height found in range; stopping'); out.verdict='no attested height'; save(); process.exit(0); }
out.attestedHeight = attested; out.headAtRun = head; out.lagBlocks = head - attested;

// ------------------------------------------------- pick a real single-emitter ERC-20 transfer
let target = null;
for (let h = attested; h > attested - 12 && !target; h--) {
  const blk = await retry('block', () => mainnet.getBlock(h, true));
  for (const txh of blk.transactions.slice(0, 60)) {
    const hash = typeof txh === 'string' ? txh : txh.hash;
    const r = await retry('receipt', () => mainnet.getTransactionReceipt(hash));
    if (!r || r.status !== 1) continue;
    const transfers = r.logs.filter(l => l.topics[0] === TRANSFER);
    if (!transfers.length) continue;
    // Every matching log must share one emitter, or gate 6 will correctly reject the batch.
    // A DEX swap carries Transfers from several tokens; a plain payment carries one.
    const emitters = new Set(transfers.map(l => l.address.toLowerCase()));
    if (emitters.size !== 1) continue;
    target = { hash, block: h, emitter: transfers[0].address,
               transferLogs: transfers.length, from: transfers[0].topics[1], to: transfers[0].topics[2] };
    break;
  }
}
if (!target) { console.log('no single-emitter transfer found in the attested window; stopping'); out.verdict='no candidate'; save(); process.exit(0); }
console.log(`\ncandidate: ${target.hash}\n  block ${target.block}, ${target.transferLogs} Transfer log(s) from ${target.emitter}`);
out.target = target; save();

// ---------------------------------------------------------------- prove it
const t0 = Date.now();
const res = await retry('getProof', () => builder.getProof(target.hash));
if (!res.success) { console.log('proof failed:', res.error); out.verdict='proof failed: '+res.error; save(); process.exit(0); }
const p = res.data;
console.log(`  proof built in ${Date.now()-t0}ms  header ${p.headerNumber}  txIndex ${p.txIndex}  siblings ${p.merkleProof.siblings.length}  roots ${p.continuityProof.roots.length}`);
out.proof = { ms: Date.now()-t0, headerNumber: p.headerNumber, txIndex: p.txIndex,
              siblings: p.merkleProof.siblings.length, continuityRoots: p.continuityProof.roots.length };
save();

// ---------------------------------------------------------------- deploy the throwaway probe
const art = abiOf('MainnetProbe.sol', 'MainnetProbe');
const probe = await new ethers.ContractFactory(art.abi, art.bytecode.object, cc3).deploy();
await probe.waitForDeployment();
const probeAddr = await probe.getAddress();
console.log(`\nMainnetProbe ${probeAddr}`);
await tx('authorize', () => probe.setAuthorizedSource(CK, target.emitter));
console.log(`  authorizedSource[3] = ${target.emitter}`);
out.probe = probeAddr;

// ---------------------------------------------------------------- run the six gates
const args = [BigInt(CK), BigInt(p.headerNumber), p.txBytes, p.merkleProof.root,
              p.merkleProof.siblings, p.continuityProof.lowerEndpointDigest,
              p.continuityProof.roots, TRANSFER];
try {
  const est = await probe.submitProof.estimateGas(...args);
  const t = await probe.submitProof(...args, { gasLimit: est * 12n / 10n });
  const r = await t.wait();
  const gates = r.logs.map(l => { try { return probe.interface.parseLog(l); } catch { return null; } })
                      .filter(x => x?.name === 'GateReached').map(x => `${x.args[0]}:${x.args[1]}`);
  const v = r.logs.map(l => { try { return probe.interface.parseLog(l); } catch { return null; } })
                  .find(x => x?.name === 'MainnetLogVerified');
  console.log(`\n  VERIFIED  gas ${r.gasUsed}`);
  console.log(`  gates [${gates.join(' ')}]`);
  if (v) console.log(`  emitter ${v.args.emitter}  logs ${v.args.logCount}  topics ${v.args.topicCount}  data ${v.args.dataBytes}b`);
  out.result = { verified: true, cc3Tx: t.hash, gasUsed: r.gasUsed.toString(), gates,
                 emitter: v?.args.emitter, logCount: Number(v?.args.logCount ?? 0) };
  out.verdict = 'Ethereum mainnet transaction verified on Creditcoin through the same six gates';
} catch (err) {
  let reason = err.shortMessage ?? err.message;
  try { const d = probe.interface.parseError(err.data ?? err.info?.error?.data); if (d) reason = `${d.name}(${d.args.join(', ')})`; } catch {}
  console.log(`\n  REJECTED  ${reason}`);
  out.result = { verified: false, reason };
  out.verdict = 'mainnet proof rejected: ' + reason;
}
save();
console.log(`\n=== ${out.verdict} ===`);
