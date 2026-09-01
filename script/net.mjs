// Shared network resilience. Both Sepolia endpoints we have tested drop connections
// intermittently (TIMEOUT, ECONNRESET, DNS). None of that is a protocol failure, and no
// script should crash on it. Contract reverts are rethrown immediately - retrying a
// deterministic revert is the conflation we already fixed once in the worker.
export function isTransient(err) {
  const m = err?.message ?? String(err);
  if (err?.code === 'CALL_EXCEPTION' || /execution reverted/i.test(m)) return false;
  return /TIMEOUT|ECONNRESET|ETIMEDOUT|ENOTFOUND|EAI_AGAIN|socket|network|failed to detect|SERVER_ERROR|502|503|504/i.test(m)
      || err?.code === 'NETWORK_ERROR' || err?.code === 'SERVER_ERROR';
}

export async function retry(what, fn, attempts = 6, waitMs = 4000) {
  for (let i = 1; i <= attempts; i++) {
    try { return await fn(); }
    catch (err) {
      if (!isTransient(err) || i === attempts) throw err;
      console.log(`    [retry ${i}/${attempts}] ${what}: ${(err.message ?? err).slice(0, 70)}`);
      await new Promise(r => setTimeout(r, waitMs));
    }
  }
}

/// Send a transaction and wait for it, retrying transport failures around both halves.
export async function tx(what, fn) {
  return retry(what, async () => { const t = await fn(); const r = await t.wait(); return { t, r }; });
}
