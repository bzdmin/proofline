// ProofLine interface. Reads Creditcoin directly from the browser: no server, no indexer, no
// cache. Every figure is a contract read a judge can repeat with `cast call`.
//
// If Creditcoin does not answer, the page says so and shows the state recorded by
// script/ui-data.mjs, labelled as recorded. It never draws a figure it did not read: a file
// of zeros would be indistinguishable from a borrower with no history.

const TIER = ['NEW', 'STANDARD', 'GOOD', 'TRUSTED', 'WATCH', 'FROZEN'];
const ETYPE = ['ObligationCreated', 'ObligationSettled', 'ObligationOverdue', 'ObligationDefaulted'];
const EVERB = ['issued', 'settled', 'marked overdue', 'defaulted'];
const REPO = 'https://github.com/bzdmin/proofline/blob/main/';

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const num = (x) => Number(x);
const pct = (bps) => num(bps) / 100 + '%';
const short = (h) => h ? h.slice(0, 10) + '…' + h.slice(-6) : '';
const exact = (raw) => ethers.formatUnits(raw, 6) + ' mUSD';
function money(raw) {
  const n = Number(BigInt(raw)) / 1e6;
  const cents = Math.round(n * 100) % 100 !== 0;
  return '$' + n.toLocaleString('en-US', { minimumFractionDigits: cents ? 2 : 0, maximumFractionDigits: 2 });
}
const m = (raw) => `<span title="${exact(raw)}">${money(raw)}</span>`;

// Contract results to plain JSON, the same shape script/ui-data.mjs writes.
function plain(v) {
  if (typeof v === 'bigint') return v.toString();
  if (v && typeof v.toObject === 'function') {
    try { return plain(v.toObject()); } catch { return Array.from(v).map(plain); }
  }
  if (Array.isArray(v)) return v.map(plain);
  if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, plain(x)]));
  return v;
}

let CFG, ABIS, RECEIPTS, TL, DATA, chain = null;
const state = { event: 0, frame: 0, why: false };
const checks = {};

const getJSON = async (p) => {
  const r = await fetch(p);
  if (!r.ok) throw new Error(`${p}: ${r.status}`);
  return r.json();
};

async function load() {
  [CFG, ABIS, RECEIPTS, TL] = await Promise.all(
    ['config', 'abis', 'receipts', 'timeline'].map((n) => getJSON(`./data/${n}.json`)));
  try {
    DATA = await readLive();
  } catch (err) {
    chain = null;
    DATA = { ...(await getJSON('./data/snapshot.json')), mode: 'recorded', error: err.message };
  }
  state.event = DATA.events.length - 1;
  state.frame = TL.frames.length - 1;
  render();
}

async function readLive() {
  const p = new ethers.JsonRpcProvider(CFG.cc3Rpc, undefined, { staticNetwork: true });
  const c = {
    cf:  new ethers.Contract(CFG.CreditFile,   ABIS.CreditFile,   p),
    tre: new ethers.Contract(CFG.Treasury,     ABIS.Treasury,     p),
    acc: new ethers.Contract(CFG.CreditAccess, ABIS.CreditAccess, p),
  };
  const b = CFG.borrower;
  const read = (async () => {
    const block = await p.getBlockNumber();
    const o = { blockTag: block };
    const [file, events, debt, dep] = await Promise.all([
      c.cf.getCreditFile(b, o), c.cf.getCreditEvents(b, o), c.tre.debtOf(b, o), c.acc.requiredDepositBps(b, o),
    ]);
    const terms = await c.cf.getTermsWithDebt(b, debt, o);
    return { mode: 'live', block, file: plain(file), events: plain(events), terms: plain(terms),
             debt: debt.toString(), depositBps: dep.toString() };
  })();
  const late = new Promise((_, no) => setTimeout(() => no(new Error('no answer within 15 seconds')), 15000));
  const d = await Promise.race([read, late]);
  chain = c;
  return d;
}

function render() {
  const d = DATA, f = d.file, t = d.terms;
  const tier = TIER[num(t.tier)];
  const settled = num(f.settled);
  const onTime = settled ? Math.round(num(f.onTime) * 100 / settled) : 0;
  const when = d.recordedAt ? new Date(d.recordedAt).toISOString().slice(0, 16).replace('T', ' ') + ' UTC' : '';

  $('status').innerHTML = d.mode === 'live'
    ? `<span class="pill ok">live</span> Creditcoin block ${num(d.block).toLocaleString('en-US')}`
    : `<span class="pill warn">recorded</span> block ${num(d.block).toLocaleString('en-US')} &middot; ${when}`;

  $('app').innerHTML = `
    ${d.mode === 'recorded' ? `<div class="banner"><b>Creditcoin did not answer</b> (${esc(d.error)}).
      Showing the state recorded at block ${num(d.block).toLocaleString('en-US')} on ${when} by
      <code>script/ui-data.mjs</code>. Nothing on this page is live until it reloads.</div>` : ''}

    <div class="card who">
      <div class="eyebrow">Borrower &middot; tier under ProofLine policy v1</div>
      <div class="addr">${esc(CFG.borrower)}</div>
      <div class="tier">
        <span class="name t-${tier}">${tier}</span>
        <span class="rates">${pct(t.advanceBps)} advance &middot; ${pct(t.aprBps)} APR</span>
        <button class="btn" id="whybtn" aria-expanded="${state.why}" aria-controls="whybox">Why these terms?</button>
      </div>
      <div id="whybox" class="whybox" ${state.why ? '' : 'hidden'}>${whyHtml(d)}</div>
    </div>

    <section class="sec">
      <span class="eyebrow">Verified history</span>
      <div class="card vh">
        <div class="stats">
          <div class="stat"><div class="v">${settled}</div><div class="k">settlements verified through Attestcoin</div></div>
          <div class="stat"><div class="v">${num(f.counterparties)}</div><div class="k">registered counterparties</div></div>
          <div class="stat"><div class="v">${onTime}%</div><div class="k">on time</div></div>
          <div class="stat"><div class="v">${m(f.maxSettledAmount)}</div><div class="k">largest settlement</div></div>
        </div>
        <div class="limits">
          <div class="yes"><h3>What this proves</h3>
            <p>The source events were verified through Attestcoin and persisted in CreditFile.</p></div>
          <div class="no"><h3>What this does not prove</h3>
            <p>The counterparties are economically independent. This demonstration history was
            seeded by the builder.</p></div>
        </div>
      </div>
    </section>

    <section class="sec">
      <div class="groups">
        <div class="group">
          <div class="glabel">Earned from verified history <b>&middot; CreditFile</b></div>
          <div class="gcells">
            <div class="cell"><div class="k">Capacity</div><div class="v">${m(t.capacity)}</div></div>
            <div class="cell"><div class="k">Approved line</div><div class="v">${m(t.limit)}</div></div>
          </div>
          <div class="gnote">Derived only from verified CreditFile history.</div>
        </div>
        <div class="group consumer">
          <div class="glabel">Current consumer state <b>&middot; Treasury</b></div>
          <div class="gcells">
            <div class="cell"><div class="k">Available</div><div class="v">${m(t.drawable)}</div></div>
            <div class="cell${BigInt(d.debt) > 0n ? ' debt' : ''}"><div class="k">Debt</div><div class="v">${m(d.debt)}</div></div>
          </div>
          <div class="gnote">Calculated by Treasury from its own debt and receivable state.</div>
        </div>
      </div>
      <p class="rule">Borrowing changes availability, not earned capacity.</p>
    </section>

    <section class="sec">
      <span class="eyebrow">CreditFile history &middot; ${TL.frames.length} changes, each read at its own Creditcoin block</span>
      <div class="card rw">
        <p class="lead">Verified history changes earned capacity. Receivables and debt change availability.</p>
        <div id="rw"></div>
      </div>
    </section>

    <section class="sec cols">
      <div class="panel">
        <h2>Verified events &middot; ${d.events.length}</h2>
        <div id="events">${d.events.map(eventRow).join('')}</div>
      </div>
      <div class="panel">
        <h2>Receipts</h2>
        <div class="rc" id="rc"></div>
      </div>
    </section>

    <section class="sec cols even">
      <div class="panel">
        <h2>CreditAccess &middot; second read-only consumer</h2>
        <div class="pad">
          <div class="eyebrow">Deposit requirement it derives</div>
          <div class="big">${pct(d.depositBps)}</div>
          <p class="note">CreditAccess reads CreditFile state and derives its own deposit requirement:
            75% at STANDARD, 40% at GOOD, 0% at TRUSTED. It reads <code>tier</code> only and does not
            import Treasury. <b>No CreditAccess agreement was opened in this demonstration.</b></p>
        </div>
        <div class="foot-note">The same CreditFile state can be consumed independently, without
          giving the consumer ownership of the underlying credit history.</div>
      </div>

      <div class="panel">
        <h2>Verification boundary</h2>
        <div class="pad">
          <div class="refused">REFUSED</div>
          <div class="case">
            <h3>Replay-protected event substitution</h3>
            <p>The same source transaction was submitted as a different event type. Rejected before
              event decoding: its proof-derived identity had already been processed.</p>
            <div class="res">Result: AlreadyProcessed
              <a href="${REPO}evidence/integration/run-001/04-rejection-fake-event.json.note" target="_blank" rel="noopener">record</a>
              <a href="${CFG.sepoliaExplorer}/tx/${RECEIPTS['1:1:1'].source}" target="_blank" rel="noopener">source tx</a></div>
          </div>
          <div class="case">
            <h3>Unauthorized source</h3>
            <p>A real Ethereum mainnet transaction contained an event from an unauthorized emitter
              (WETH, where USDC was authorized).</p>
            <div class="res">Result: UnauthorizedSource
              <a href="${REPO}evidence/mainnet/README.md" target="_blank" rel="noopener">record</a></div>
          </div>
        </div>
        <div class="foot-note">These are recorded rejection cases, caught at gas estimation and never
          mined. Neither changes CreditFile.</div>
      </div>
    </section>

    <section class="sec">
      <div class="card">
        <div class="ledger">
          <div class="yes"><h3>Verified</h3><ul>
            <li>Ethereum source transaction inclusion</li>
            <li>Source receipt succeeded</li>
            <li>Expected event was emitted</li>
            <li>Event came from the authorized source</li>
            <li>Replay identity was unused</li>
            <li>Credit event was persisted to CreditFile</li>
            <li>Credit terms derived deterministically from that state</li>
          </ul></div>
          <div class="no"><h3>Not established</h3><ul>
            <li>Counterparties are economically independent</li>
            <li>The demonstration history represents external commercial activity</li>
            <li>CreditFile guarantees repayment</li>
            <li>Tier thresholds are Creditcoin protocol standards</li>
          </ul></div>
        </div>
        <div class="closing">ProofLine verifies evidence. It does not manufacture trust outside that evidence.</div>
      </div>
    </section>`;

  $('whybtn').onclick = () => {
    state.why = !state.why;
    $('whybox').hidden = !state.why;
    $('whybtn').setAttribute('aria-expanded', state.why);
  };
  document.querySelectorAll('.ev').forEach((el) => el.onclick = () => selectEvent(+el.dataset.i));
  renderReceipt();
  renderRewind();

  $('foot').innerHTML =
    `CreditFile ${CFG.CreditFile} &middot; ASCReceiver ${CFG.ASCReceiver} &middot; Creditcoin CC3, chain 102031<br>
     Receipts are checked against both chains by <code>script/ui-data.mjs</code> &middot;
     <a href="https://github.com/bzdmin/proofline" target="_blank" rel="noopener">source on GitHub</a>`;
}

/// Term provenance: every condition the tier depends on, read from the credit file.
function whyHtml(d) {
  const f = d.file, t = d.terms;
  const settled = num(f.settled);
  const onTime = settled ? Math.round(num(f.onTime) * 100 / settled) : 0;
  const row = (k, v, met) => `<div class="wrow"><span class="wk">${k}</span><span class="wv">${v}</span>
    <span class="wm ${met ? 'yes' : 'no'}">${met ? 'met' : 'not met'}</span></div>`;
  return `<p class="note" style="margin:0 0 8px">TRUSTED requires all five. Each is read from the
      credit file; the thresholds and rate table are ProofLine policy, fixed in UnderwritingLib.</p>
    ${row('Verified settlements (5 or more)', settled, settled >= 5)}
    ${row('Registered counterparties (3 or more)', num(f.counterparties), num(f.counterparties) >= 3)}
    ${row('On-time rate (90% or more)', onTime + '%', onTime >= 90)}
    ${row('Verified defaults', num(f.defaults), num(f.defaults) === 0)}
    ${row('Open delinquencies', num(f.openDelinquencies), num(f.openDelinquencies) === 0)}
    <p class="note" style="margin:12px 0 0"><b>Capacity ${money(t.capacity)}</b> is ${pct(t.advanceBps)} of
      ${money(f.maxSettledAmount)}, the largest settlement verified. Not the largest invoice issued:
      being paid is what earns capacity.</p>`;
}

function buyerOf(addr) {
  const hit = Object.entries(CFG.buyers).find(([, a]) => a.toLowerCase() === String(addr).toLowerCase());
  return hit ? `counterparty ${hit[0]}` : `counterparty ${short(addr)}`;
}

function eventRow(e, i) {
  const t = num(e.eventType);
  const chip = t === 1 ? '<span class="chip c-ok">settled</span>'
             : t === 0 ? '<span class="chip c-dim">issued</span>'
             : t === 2 ? '<span class="chip c-warn">overdue</span>'
             :           '<span class="chip c-bad">default</span>';
  const late = t === 1 && num(e.timestamp) > num(e.dueDate) ? '<span class="chip c-warn">late</span>' : '';
  return `<button class="ev ${i === state.event ? 'sel' : ''}" data-i="${i}">
    <div class="what">Invoice #${e.obligationId} ${EVERB[t]}${chip}${late}
      <small>${buyerOf(e.counterparty)} &middot; Ethereum block ${num(e.blockHeight).toLocaleString('en-US')}</small></div>
    <div class="amt">${m(e.amount)}</div>
  </button>`;
}

function selectEvent(i) {
  state.event = i;
  document.querySelectorAll('.ev').forEach((el) => el.classList.toggle('sel', +el.dataset.i === i));
  renderReceipt();
}

/// One credit event, as three things a judge can open independently.
function renderReceipt() {
  const e = DATA.events[state.event];
  if (!e) return;
  const key = `${e.chainKey}:${e.obligationId}:${e.eventType}`;
  const r = RECEIPTS[key];
  const src = r
    ? `<a href="${CFG.sepoliaExplorer}/tx/${r.source}" target="_blank" rel="noopener">${short(r.source)}</a>`
    : `not mapped in this UI &middot; <a href="${REPO}evidence/" target="_blank" rel="noopener">evidence</a>`;
  const ver = r
    ? `<a href="${CFG.cc3Explorer}/tx/${r.verification}" target="_blank" rel="noopener">${short(r.verification)}</a>`
    : `not mapped in this UI`;

  $('rc').innerHTML = `
    <div class="rstep">
      <div class="lbl">Source <b>&middot; Ethereum Sepolia</b></div>
      <div class="val">${src}</div>
      <div class="n">Ethereum source transaction. Block ${num(e.blockHeight).toLocaleString('en-US')},
        transaction index ${num(e.txIndex)}, as derived by the precompile from the proof and stored
        by CreditFile.</div>
    </div>
    <div class="arrow" aria-hidden="true">&darr;</div>
    <div class="rstep">
      <div class="lbl">Verification <b>&middot; Creditcoin CC3</b></div>
      <div class="val">${ver}</div>
      <div class="n">Creditcoin verification transaction. ASCReceiver ran six gates: replay,
        verifyAndEmit, txType, receiptStatus, logs found, authorized source.${r ? ` ${num(r.gasUsed).toLocaleString('en-US')} gas.` : ''}</div>
    </div>
    <div class="arrow" aria-hidden="true">&darr;</div>
    <div class="rstep">
      <div class="lbl">State <b>&middot; CreditFile</b></div>
      <div class="val">${ETYPE[num(e.eventType)]} &middot; ${money(e.amount)} &middot; invoice #${e.obligationId}</div>
      <div class="n">CreditFile state change, written only by ASCReceiver in the same transaction
        as verification.</div>
    </div>`;
}

/// The credit file at the block of each change. Frames were recorded by script/ui-data.mjs;
/// each one is re-read from Creditcoin at its own block when selected.
function renderRewind() {
  const frames = TL.frames;
  const i = state.frame, f = frames[i], p = frames[i - 1];
  const max = Math.max(...frames.map((x) => num(x.terms.capacity))) || 1;
  const tag = (x) => x.kind === 'borrow' ? 'draw' : x.kind === 'repay' ? 'repay'
    : `#${x.key.split(':')[1]} ${x.kind === 'settled' ? 'paid' : 'inv'}`;

  const cols = frames.map((x, j) => {
    const cap = num(x.terms.capacity), avail = num(x.terms.drawable), debt = num(x.debt);
    return `<button class="rcol ${j === i ? 'sel' : ''}" data-f="${j}" aria-label="${esc(x.label)}">
      <span class="cap" style="height:${cap / max * 100}%">
        <span class="avail" style="height:${cap ? avail / cap * 100 : 0}%"></span>
        <span class="dbt" style="height:${cap ? debt / cap * 100 : 0}%"></span>
      </span><span class="rl">${tag(x)}</span></button>`;
  }).join('');

  const cell = (k, now, was, fmt) => {
    const changed = p && String(now) !== String(was);
    return `<div class="fc ${changed ? 'chg' : ''}"><div class="k">${k}</div>
      <div class="v">${fmt(now)}</div>${changed ? `<div class="was">was ${fmt(was)}</div>` : ''}</div>`;
  };
  const tierFmt = (x) => TIER[num(x)];

  let why;
  if (!p) why = 'The first verified event. The file starts at NEW: no settlement yet, so no earned capacity.';
  else if (f.terms.capacity !== p.terms.capacity || f.terms.tier !== p.terms.tier)
    why = 'Earned capacity moved because the verified settlement history changed.';
  else if (f.terms.drawable !== p.terms.drawable || f.debt !== p.debt)
    why = 'Earned capacity did not move. Only availability changed.';
  else why = 'No figure changed.';

  const r = f.key ? RECEIPTS[f.key] : null;
  const links = r
    ? `<span>Ethereum source</span><a href="${CFG.sepoliaExplorer}/tx/${r.source}" target="_blank" rel="noopener">${short(r.source)}</a>
       <span>Creditcoin verification</span><a href="${CFG.cc3Explorer}/tx/${f.tx}" target="_blank" rel="noopener">${short(f.tx)}</a>`
    : `<span>Creditcoin transaction, Treasury.${f.kind}</span><a href="${CFG.cc3Explorer}/tx/${f.tx}" target="_blank" rel="noopener">${short(f.tx)}</a>`;

  $('rw').innerHTML = `
    <div class="chart" role="group" aria-label="Earned capacity, available and debt at each change">${cols}</div>
    <div class="legend"><span><i class="lc"></i>earned capacity</span><span><i class="la"></i>available</span><span><i class="ld"></i>debt</span></div>
    <input type="range" id="rwr" min="0" max="${frames.length - 1}" value="${i}" aria-label="Choose a change">
    <div class="frame">
      <div class="eyebrow">Change ${i + 1} of ${frames.length} &middot; Creditcoin block ${num(f.block).toLocaleString('en-US')}</div>
      <h3>${esc(f.label)}</h3>
      <p class="why">${why}</p>
      <div class="fcells">
        ${cell('Tier', f.terms.tier, p && p.terms.tier, tierFmt)}
        ${cell('Earned capacity', f.terms.capacity, p && p.terms.capacity, money)}
        ${cell('Approved line', f.terms.limit, p && p.terms.limit, money)}
        ${cell('Available', f.terms.drawable, p && p.terms.drawable, money)}
        ${cell('Debt', f.debt, p && p.debt, money)}
        ${cell('CreditAccess deposit requirement', f.depositBps, p && p.depositBps, pct)}
      </div>
      <div class="links">${links}</div>
      <div class="check" id="rwcheck"></div>
    </div>`;

  document.querySelectorAll('.rcol').forEach((el) => el.onclick = () => selectFrame(+el.dataset.f));
  $('rwr').oninput = (ev) => selectFrame(+ev.target.value);
  showCheck(i);
  checkFrame(i);
}

function selectFrame(i) {
  if (i === state.frame) return;
  state.frame = i;
  const focused = document.activeElement && document.activeElement.id === 'rwr';
  renderRewind();
  if (focused) $('rwr').focus();
}

function showCheck(i) {
  const el = $('rwcheck');
  if (!el || state.frame !== i) return;
  const f = TL.frames[i], c = checks[i], blk = num(f.block).toLocaleString('en-US');
  if (!chain) { el.className = 'check'; el.textContent = 'Not re-read: Creditcoin did not answer. Values are as recorded by script/ui-data.mjs.'; }
  else if (!c) { el.className = 'check'; el.textContent = `Re-reading Creditcoin at block ${blk}…`; }
  else if (c.err) { el.className = 'check bad'; el.textContent = `Could not re-read block ${blk}: ${c.err}`; }
  else if (c.ok) { el.className = 'check ok'; el.textContent = `Re-read from Creditcoin at block ${blk} just now: every figure matches.`; }
  else { el.className = 'check bad'; el.textContent = `Re-read at block ${blk} differs from the recorded change: ${c.diff}.`; }
}

async function checkFrame(i) {
  if (!chain || checks[i]) return;
  const f = TL.frames[i], b = CFG.borrower, o = { blockTag: f.block };
  try {
    const [debt, dep] = await Promise.all([chain.tre.debtOf(b, o), chain.acc.requiredDepositBps(b, o)]);
    const t = plain(await chain.cf.getTermsWithDebt(b, debt, o));
    const diff = ['tier', 'capacity', 'limit', 'drawable'].filter((k) => String(t[k]) !== String(f.terms[k]));
    if (debt.toString() !== f.debt) diff.push('debt');
    if (dep.toString() !== f.depositBps) diff.push('deposit');
    checks[i] = diff.length ? { ok: false, diff: diff.join(', ') } : { ok: true };
  } catch (err) {
    checks[i] = { err: err.shortMessage || err.message };
  }
  showCheck(i);
}

load().catch((err) => {
  $('app').innerHTML = `<div class="loading">could not load the page data: ${esc(err.message)}</div>`;
  $('status').textContent = 'not loaded';
});
