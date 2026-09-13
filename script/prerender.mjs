// Writes a static copy of the page's evidence into ui/index.html, between the static markers,
// so a reader that does not run JavaScript (a crawler, a summariser, a reviewer's fetch tool)
// sees the same state, receipts, refusals and consumers the live page draws. When JavaScript
// runs, app.js replaces the copy with live reads from Creditcoin.
//
// Every value comes from the data files script/ui-data.mjs checked against both chains, and the
// copy says when it was recorded. Nothing here is typed by hand.
//
//   node script/ui-data.mjs && node script/prerender.mjs
import fs from 'node:fs';

const root = new URL('../', import.meta.url);
const rd = (p) => JSON.parse(fs.readFileSync(new URL(p, root)));
const CFG = rd('ui/data/config.json');
const R = rd('ui/data/receipts.json');
const TL = rd('ui/data/timeline.json');
const SNAP = rd('ui/data/snapshot.json');
const REF = rd('evidence/refusals/refusals.json');
const THIRD = rd('evidence/third-app/third-app.json');

const TIER = ['NEW', 'STANDARD', 'GOOD', 'TRUSTED', 'WATCH', 'FROZEN'];
const EVERB = ['issued', 'settled', 'marked overdue', 'defaulted'];
const money = (raw) => {
  const n = Number(BigInt(raw)) / 1e6;
  const cents = Math.round(n * 100) % 100 !== 0;
  return '$' + n.toLocaleString('en-US', { minimumFractionDigits: cents ? 2 : 0, maximumFractionDigits: 2 });
};
const pct = (bps) => Number(bps) / 100 + '%';
const short = (h) => h.slice(0, 10) + '…' + h.slice(-6);
const link = (base, kind, h) => `<a href="${base}/${kind}/${h}">${short(h)}</a>`;
const ES = CFG.sepoliaExplorer, EC = CFG.cc3Explorer;

const t = SNAP.terms, f = SNAP.file;
const when = new Date(SNAP.recordedAt).toISOString().slice(0, 16).replace('T', ' ') + ' UTC';
const settled = Number(f.settled);
const onTime = settled ? Math.round(Number(f.onTime) * 100 / settled) : 0;

const eventRows = SNAP.events.map((e) => {
  const r = R[`${e.chainKey}:${e.obligationId}:${e.eventType}`];
  return `<tr><td>Invoice #${e.obligationId} ${EVERB[Number(e.eventType)]}</td><td>${money(e.amount)}</td>` +
    `<td>${r ? link(ES, 'tx', r.source) : 'not mapped'}</td><td>${r ? link(EC, 'tx', r.verification) : 'not mapped'}</td></tr>`;
}).join('\n          ');
const loanRows = TL.frames.filter((x) => x.kind === 'borrow' || x.kind === 'repay').map((x) =>
  `<tr><td>${x.label}</td><td>debt ${money(x.debt)}, available ${money(x.terms.drawable)}</td>` +
  `<td>Treasury, Creditcoin</td><td>${link(EC, 'tx', x.tx)}</td></tr>`).join('\n          ');
const refusalRows = REF.cases.map((c) =>
  `<li><b>${c.case}</b>: <code>${c.reason.split('(')[0]}</code>, mined and reverted. ` +
  `Creditcoin ${link(EC, 'tx', c.creditcoinTx)}, source ${link(ES, 'tx', c.source)}</li>`).join('\n          ');

const html = `
    <div class="card static">
      <p class="note"><b>Recorded copy.</b> Written at Creditcoin block
        ${Number(SNAP.block).toLocaleString('en-US')} on ${when} by <code>script/prerender.mjs</code>
        from data checked against both chains. With JavaScript on, this page replaces it with live
        reads.</p>

      <h2>Borrower state</h2>
      <p><b>${TIER[Number(t.tier)]}</b>, ${pct(t.advanceBps)} advance, ${pct(t.aprBps)} APR, under
        ProofLine policy v1. Earned from verified history (CreditFile): capacity ${money(t.capacity)},
        approved line ${money(t.limit)}. Current consumer state (Treasury): available
        ${money(t.drawable)}, debt ${money(SNAP.debt)}.</p>
      <p>${settled} settlements verified through Attestcoin, ${Number(f.counterparties)} registered
        counterparties, ${onTime}% on time, largest settlement ${money(f.maxSettledAmount)}.
        <b>The counterparties are not shown to be economically independent: this demonstration
        history was seeded by the builder.</b></p>

      <h2>Receipts: every CreditFile event, both sides</h2>
      <div class="scroll"><table class="stbl">
        <thead><tr><th>Event</th><th>Amount</th><th>Ethereum source</th><th>Creditcoin verification</th></tr></thead>
        <tbody>
          ${eventRows}
          ${loanRows}
        </tbody>
      </table></div>

      <h2>Verification boundary: refused</h2>
      <ul>
          ${refusalRows}
      </ul>
      <p>Neither changed CreditFile.</p>

      <h2>Three applications, one credit file</h2>
      <ul>
        <li><b>Treasury</b> lends against the earned line:
          <a href="${EC}/address/${CFG.Treasury}?tab=contract">${short(CFG.Treasury)}</a></li>
        <li><b>CreditAccess</b> derives a deposit requirement from <code>tier</code> alone, currently
          ${pct(SNAP.depositBps)}. Read-only in this demonstration; no agreement was opened:
          <a href="${EC}/address/${CFG.CreditAccess}?tab=contract">${short(CFG.CreditAccess)}</a></li>
        <li><b>NetTermsDesk</b>, deployed ${CFG.netTermsDesk.deployedOn} by a fresh address with no
          ProofLine role, decided net ${THIRD.decision.netDays} days by its own rules. CreditFile's code
          and event count were unchanged: decision ${link(EC, 'tx', THIRD.decideTx)}</li>
      </ul>

      <h2>Verified, and not established</h2>
      <p><b>Verified:</b> source transaction inclusion; source receipt succeeded; expected event
        emitted; event from the authorized source; replay identity unused; credit event persisted to
        CreditFile; credit terms derived deterministically from that state.</p>
      <p><b>Not established:</b> counterparties are economically independent; the demonstration
        history represents external commercial activity; CreditFile guarantees repayment; tier
        thresholds are Creditcoin protocol standards; every late payment has already been
        reported.</p>
      <p><b>ProofLine verifies evidence. It does not manufacture trust outside that evidence.</b></p>
    </div>
    `;

const file = new URL('ui/index.html', root);
const page = fs.readFileSync(file, 'utf8');
const start = '<!-- static:start -->', end = '<!-- static:end -->';
const i = page.indexOf(start), j = page.indexOf(end);
if (i < 0 || j < i) throw new Error('static markers not found in ui/index.html');
fs.writeFileSync(file, page.slice(0, i + start.length) + html + page.slice(j));
console.log(`prerendered ${SNAP.events.length} events, ${REF.cases.length} refusals, block ${SNAP.block}`);
