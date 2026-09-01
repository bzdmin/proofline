// G0-A deployment. Sepolia: SpikeSource + SpikeImposter. CC3: SpikeASC.
// Writes resulting addresses back into .env so the runner picks them up.
import 'dotenv/config';
import { ethers } from 'ethers';
import { readFileSync, writeFileSync } from 'node:fs';

const art = (c) => {
  const j = JSON.parse(readFileSync(`out/SpikeSource.sol/${c}.json`, 'utf8'));
  return { abi: j.abi, bytecode: j.bytecode.object };
};
const artASC = () => {
  const j = JSON.parse(readFileSync('out/SpikeASC.sol/SpikeASC.json', 'utf8'));
  return { abi: j.abi, bytecode: j.bytecode.object };
};

const {
  PRIVATE_KEY, SEPOLIA_RPC_URL, CC3_RPC_URL,
  CHAINKEY_SEPOLIA = '1', CC3_EXPLORER,
} = process.env;

const sepolia = new ethers.Wallet(PRIVATE_KEY, new ethers.JsonRpcProvider(SEPOLIA_RPC_URL));
const cc3     = new ethers.Wallet(PRIVATE_KEY, new ethers.JsonRpcProvider(CC3_RPC_URL));

async function deploy(signer, { abi, bytecode }, label, args = []) {
  const f = new ethers.ContractFactory(abi, bytecode, signer);
  const c = await f.deploy(...args);
  const tx = c.deploymentTransaction();
  await c.waitForDeployment();
  const addr = await c.getAddress();
  const rcpt = await tx.wait();
  console.log(`  ${label.padEnd(15)} ${addr}   gas ${rcpt.gasUsed}`);
  return { contract: c, address: addr, gasUsed: rcpt.gasUsed.toString() };
}

console.log('deployer', await sepolia.getAddress());

console.log('\n--- Sepolia (chainKey ' + CHAINKEY_SEPOLIA + ') ---');
const src  = await deploy(sepolia, art('SpikeSource'),   'SpikeSource');
const imp  = await deploy(sepolia, art('SpikeImposter'), 'SpikeImposter');

console.log('\n--- Creditcoin CC3 ---');
const asc  = await deploy(cc3, artASC(), 'SpikeASC');

console.log('\n--- authorizing source ---');
const authTx = await asc.contract.setAuthorizedSource(BigInt(CHAINKEY_SEPOLIA), src.address);
const authRcpt = await authTx.wait();
console.log(`  authorizedSource[${CHAINKEY_SEPOLIA}] = ${src.address}   gas ${authRcpt.gasUsed}`);
console.log(`  ${CC3_EXPLORER}/address/${asc.address}`);

// persist addresses
let env = readFileSync('.env', 'utf8');
const set = (k, v) => {
  env = env.match(new RegExp(`^${k}=.*$`, 'm'))
    ? env.replace(new RegExp(`^${k}=.*$`, 'm'), `${k}=${v}`)
    : env + `\n${k}=${v}`;
};
set('SPIKE_SOURCE_ADDRESS', src.address);
set('SPIKE_IMPOSTER_ADDRESS', imp.address);
set('SPIKE_ASC_ADDRESS', asc.address);
writeFileSync('.env', env);

writeFileSync('evidence/G0-A/deployment.json', JSON.stringify({
  deployedAt: new Date().toISOString(),
  deployer: await sepolia.getAddress(),
  sepolia: { chainKey: Number(CHAINKEY_SEPOLIA), source: src.address, imposter: imp.address,
             gas: { source: src.gasUsed, imposter: imp.gasUsed } },
  cc3: { asc: asc.address, gas: { asc: asc.gasUsed, authorize: authRcpt.gasUsed.toString() } },
}, null, 2));

console.log('\naddresses written to .env and evidence/G0-A/deployment.json');
