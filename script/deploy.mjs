// Production deployment. Sepolia: mUSD + Receivable. CC3: CreditFile + ASCReceiver +
// Treasury + CreditAccess. Writes addresses to deployments.json and .env.
import 'dotenv/config';
import { ethers } from 'ethers';
import { readFileSync, writeFileSync } from 'node:fs';

const E = process.env;
const CK = BigInt(E.CHAINKEY_SEPOLIA ?? 1);
const GRACE = 10n * 60n;              // 10 minutes on testnet; 24h is the documented value
const art = (f, c) => {
  const j = JSON.parse(readFileSync(`out/${f}/${c}.json`, 'utf8'));
  return { abi: j.abi, bytecode: j.bytecode.object };
};

const sep = new ethers.Wallet(E.PRIVATE_KEY, new ethers.JsonRpcProvider(E.SEPOLIA_RPC_URL));
const cc3 = new ethers.Wallet(E.PRIVATE_KEY, new ethers.JsonRpcProvider(E.CC3_RPC_URL));

async function deploy(signer, a, label, args = []) {
  const c = await new ethers.ContractFactory(a.abi, a.bytecode, signer).deploy(...args);
  await c.waitForDeployment();
  const addr = await c.getAddress();
  const r = await c.deploymentTransaction().wait();
  console.log(`  ${label.padEnd(14)} ${addr}  gas ${r.gasUsed}`);
  return { c, addr, gas: r.gasUsed.toString() };
}

console.log('deployer', await sep.getAddress(), '\n');

console.log('--- Ethereum Sepolia ---');
const usd = await deploy(sep, art('MockERC20.sol', 'MockERC20'), 'mUSD');
const rec = await deploy(sep, art('Receivable.sol', 'Receivable'), 'Receivable', [GRACE]);

console.log('\n--- Creditcoin CC3 ---');
// CreditFile and ASCReceiver reference each other immutably. Predict the receiver's
// address from the deployer nonce so neither needs a mutable setter.
const nonce = await cc3.getNonce();
const predictedASC = ethers.getCreateAddress({ from: await cc3.getAddress(), nonce: nonce + 1 });
const cf  = await deploy(cc3, art('CreditFile.sol', 'CreditFile'), 'CreditFile', [predictedASC]);
const asc = await deploy(cc3, art('ASCReceiver.sol', 'ASCReceiver'), 'ASCReceiver', [cf.addr]);
if (asc.addr.toLowerCase() !== predictedASC.toLowerCase()) throw new Error('address prediction failed');

const cUsd = await deploy(cc3, art('MockERC20.sol', 'MockERC20'), 'mUSD (CC3)');
const tre  = await deploy(cc3, art('Treasury.sol', 'Treasury'), 'Treasury',
                          [cUsd.addr, cf.addr, await cc3.getAddress()]);
const acc  = await deploy(cc3, art('CreditAccess.sol', 'CreditAccess'), 'CreditAccess', [cf.addr]);

console.log('\n--- wiring ---');
await (await asc.c.setAuthorizedSource(CK, rec.addr)).wait();
console.log(`  authorizedSource[${CK}] = ${rec.addr}`);

const SIGS = {
  InvoiceIssued:    0, // ObligationCreated
  InvoicePaid:      1, // ObligationSettled
  InvoiceLate:      2, // ObligationOverdue
  InvoiceDefaulted: 3, // ObligationDefaulted
};
const sigHash = (n) => ethers.id(`${n}(uint256,address,address,address,uint256,uint64,uint64)`);
for (const [name, t] of Object.entries(SIGS)) {
  await (await asc.c.registerEventType(sigHash(name), t)).wait();
  console.log(`  ${name.padEnd(18)} -> ${['Created','Settled','Overdue','Defaulted'][t]}`);
}

// fund the treasury so borrowing is possible
await (await cUsd.c.mint(await cc3.getAddress(), 1_000_000n * 10n ** 6n)).wait();
await (await cUsd.c.approve(tre.addr, ethers.MaxUint256)).wait();
await (await tre.c.fund(500_000n * 10n ** 6n)).wait();
console.log('  treasury funded 500,000 mUSD');

const out = {
  deployedAt: new Date().toISOString(),
  deployer: await sep.getAddress(),
  sepolia: { chainKey: Number(CK), mUSD: usd.addr, Receivable: rec.addr, grace: Number(GRACE) },
  cc3: { CreditFile: cf.addr, ASCReceiver: asc.addr, mUSD: cUsd.addr, Treasury: tre.addr, CreditAccess: acc.addr },
  eventSignatures: Object.fromEntries(Object.keys(SIGS).map(n => [n, sigHash(n)])),
};
writeFileSync('deployments.json', JSON.stringify(out, null, 2));

let env = readFileSync('.env', 'utf8');
const set = (k, v) => {
  env = env.match(new RegExp(`^${k}=.*$`, 'm'))
    ? env.replace(new RegExp(`^${k}=.*$`, 'm'), `${k}=${v}`) : env + `\n${k}=${v}`;
};
set('MUSD_SEPOLIA', usd.addr); set('RECEIVABLE_ADDRESS', rec.addr);
set('CREDITFILE_ADDRESS', cf.addr); set('ASCRECEIVER_ADDRESS', asc.addr);
set('MUSD_CC3', cUsd.addr); set('TREASURY_ADDRESS', tre.addr); set('CREDITACCESS_ADDRESS', acc.addr);
writeFileSync('.env', env);

console.log('\nwritten to deployments.json and .env');
