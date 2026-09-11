// Adds a third application to the live credit file, after the fact, and records that the
// credit file did not change to allow it.
//
// A fresh address, with no role in any ProofLine contract, deploys NetTermsDesk against the
// deployed CreditFile and asks it for one decision. CreditFile's code and event count are read
// before and after; the script stops if either moved.
//
// The fresh address is funded with test CTC by the ProofLine deployer, because that is the
// only CTC this project holds. It gains no permission from that: CreditFile has no allowlist
// for readers, so anyone with gas could have done the same.
//
//   node script/third-app.mjs
import 'dotenv/config';
import { ethers } from 'ethers';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';

const E = process.env;
const cc3 = new ethers.JsonRpcProvider(E.CC3_RPC_URL, undefined, { staticNetwork: true });
const deployer = new ethers.Wallet(E.PRIVATE_KEY, cc3);
const cfg = JSON.parse(readFileSync('ui/data/config.json', 'utf8'));
const art = JSON.parse(readFileSync('out/NetTermsDesk.sol/NetTermsDesk.json', 'utf8'));
const cf = new ethers.Contract(cfg.CreditFile,
  ['function eventCount(address) view returns (uint256)'], cc3);
const business = cfg.borrower;

const snapshot = async () => ({
  codeHash: ethers.keccak256(await cc3.getCode(cfg.CreditFile)),
  events: (await cf.eventCount(business)).toString(),
});

const before = await snapshot();
console.log('CreditFile before:', before);

// The key exists only in this process. It is never written anywhere.
const fresh = ethers.Wallet.createRandom().connect(cc3);
console.log('fresh address:', fresh.address);
const fund = await deployer.sendTransaction({ to: fresh.address, value: ethers.parseEther('3') });
await fund.wait();
console.log('funded:', fund.hash);

const factory = new ethers.ContractFactory(art.abi, art.bytecode.object, fresh);
const desk = await factory.deploy(cfg.CreditFile);
const deployTx = desk.deploymentTransaction();
await desk.waitForDeployment();
const deskAddr = await desk.getAddress();
console.log('NetTermsDesk:', deskAddr, 'tx', deployTx.hash);

const [q, basis] = await desk.quote(business);
const tx = await desk.decide(business);
const r = await tx.wait();
const ev = r.logs.map((l) => { try { return desk.interface.parseLog(l); } catch { return null; } })
  .find((x) => x?.name === 'TermsDecided');
console.log('decide:', tx.hash, 'net', ev.args.netDays.toString(), '|', ev.args.basis, '| gas', r.gasUsed.toString());

const after = await snapshot();
console.log('CreditFile after:', after);
if (after.codeHash !== before.codeHash || after.events !== before.events)
  throw new Error('CreditFile changed; this demonstration requires that it did not');

const cfCreation = await (await fetch(
  `${cfg.cc3Explorer}/api/v2/addresses/${cfg.CreditFile}`)).json().catch(() => ({}));

mkdirSync('evidence/third-app', { recursive: true });
writeFileSync('evidence/third-app/third-app.json', JSON.stringify({
  recordedAt: new Date().toISOString(),
  application: 'NetTermsDesk',
  address: deskAddr,
  deployedBy: fresh.address,
  fundedBy: deployer.address,
  fundingTx: fund.hash,
  deployTx: deployTx.hash,
  decideTx: tx.hash,
  decideGas: r.gasUsed.toString(),
  business,
  quote: { netDays: Number(q), basis },
  decision: { netDays: Number(ev.args.netDays), basis: ev.args.basis,
              settled: Number(ev.args.settled), counterparties: Number(ev.args.counterparties),
              verifiedVolume: ev.args.verifiedVolume.toString() },
  creditFile: { address: cfg.CreditFile, creationTx: cfCreation.creation_transaction_hash ?? null,
                before, after, unchanged: true },
}, null, 2) + '\n');
console.log('wrote evidence/third-app/third-app.json');
