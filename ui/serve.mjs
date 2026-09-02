// Minimal static server for the interface. No dependencies.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join } from 'node:path';
const TYPES = { '.html':'text/html', '.js':'text/javascript', '.json':'application/json',
                '.css':'text/css', '.png':'image/png' };
const root = new URL('.', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');
const server = createServer(async (req, res) => {
  const p = join(root, req.url === '/' ? 'index.html' : decodeURIComponent(req.url.split('?')[0]));
  try {
    const body = await readFile(p);
    res.writeHead(200, { 'content-type': TYPES[extname(p)] ?? 'application/octet-stream' });
    res.end(body);
  } catch { res.writeHead(404); res.end('not found'); }
});

// Try a few ports rather than crashing with EADDRINUSE on a reviewer's machine.
let port = Number(process.env.PORT) || 4173;
server.on('error', (e) => {
  if (e.code === 'EADDRINUSE' && port < 4180) {
    console.log(`port ${port} busy, trying ${port + 1}`);
    server.listen(++port);
  } else {
    console.error(e.message);
    process.exit(1);
  }
});
server.listen(port, () => {
  console.log(`ProofLine ui on http://localhost:${port}`);
  console.log('  read-only. no wallet, no test tokens, no deployment, no API key.');
  console.log('  reads the deployed Sepolia and Creditcoin CC3 contracts live.');
});
