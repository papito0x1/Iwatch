'use strict';

// =============================================================================
// Solana Wallet Tracker — renderer
// =============================================================================

const MAX_POINTS = 720;      // points kept in memory per series
const PERSIST_POINTS = 360;  // points persisted to localStorage
const COLOR_UP = '#2ee6a6';
const COLOR_DOWN = '#ff5d73';

// Scaling guards (some wallets — e.g. exchanges — hold thousands of token accounts)
const DEFAULT_MAX_WIDGETS = 12; // graphs shown by default on a fresh wallet
const PRICE_TICK_CAP = 80;      // max mints repriced on each fast tick
const META_CAP = 80;            // max tokens we fetch symbol/icon for
const MANAGE_LIMIT = 60;        // max rows in the Manage widgets list
const WSOL = 'So11111111111111111111111111111111111111112';

const LS = {
  address: 'swt.address',
  rpc: 'swt.rpcUrl',
  priceInt: 'swt.priceInterval',
  balInt: 'swt.balanceInterval',
  sort: 'swt.sort',
  hidden: (a) => `swt.hidden.${a}`,
  history: (a) => `swt.history.${a}`,
};

// ----------------------------- State ----------------------------------------
const S = {
  address: '',
  rpcUrl: '',
  priceInterval: 12,
  balanceInterval: 90,
  sort: 'value',
  balances: [],            // [{id, mint, isNative, decimals, uiAmount}]
  meta: {},                // mint -> {symbol,name,icon,decimals}
  prices: {},              // mint -> {usdPrice, priceChange24h}
  history: { total: [], byId: {} },
  hidden: new Set(),
  hiddenInit: false,
  charts: { total: null, byId: {} },
  cards: {},               // id -> { el, refs }
  gridSig: '',
  timers: { price: null, balance: null, countdown: null },
  nextTickAt: 0,
  lastList: [],
};

// ----------------------------- DOM ------------------------------------------
const $ = (id) => document.getElementById(id);
const el = {
  form: $('wallet-form'),
  input: $('wallet-input'),
  status: $('status'),
  statusText: $('status-text'),
  empty: $('empty-state'),
  dash: $('dashboard'),
  totalValue: $('total-value'),
  totalChange: $('total-change'),
  tokenCount: $('token-count'),
  walletPill: $('wallet-pill'),
  walletShort: $('wallet-short'),
  lastUpdated: $('last-updated'),
  nextTick: $('next-tick'),
  totalChart: $('total-chart'),
  grid: $('token-grid'),
  visibleCount: $('visible-count'),
  sortSelect: $('sort-select'),
  manageBtn: $('manage-btn'),
  refreshBtn: $('refresh-btn'),
  settingsBtn: $('settings-btn'),
  manageModal: $('manage-modal'),
  manageList: $('manage-list'),
  settingsModal: $('settings-modal'),
  rpcInput: $('rpc-input'),
  priceIntervalInput: $('price-interval'),
  balanceIntervalInput: $('balance-interval'),
  saveSettings: $('save-settings'),
  clearData: $('clear-data'),
  cardTemplate: $('card-template'),
};

// ----------------------------- Formatters -----------------------------------
const fmtUsd = (n) =>
  n == null || isNaN(n)
    ? '—'
    : n.toLocaleString('en-US', { style: 'currency', currency: 'USD', minimumFractionDigits: 2, maximumFractionDigits: 2 });

function fmtPrice(n) {
  if (n == null || isNaN(n)) return '—';
  if (n === 0) return '$0';
  if (n < 0.0001) return '$' + n.toExponential(2);
  if (n < 1) return '$' + n.toPrecision(3);
  return fmtUsd(n);
}
function fmtCompactUsd(n) {
  if (n == null || isNaN(n)) return '';
  const a = Math.abs(n);
  if (a >= 1e9) return '$' + (n / 1e9).toFixed(1) + 'B';
  if (a >= 1e6) return '$' + (n / 1e6).toFixed(1) + 'M';
  if (a >= 1e3) return '$' + (n / 1e3).toFixed(1) + 'K';
  return '$' + n.toFixed(0);
}
function fmtAmount(n) {
  if (n == null || isNaN(n)) return '—';
  if (n >= 1e9) return (n / 1e9).toFixed(2) + 'B';
  if (n >= 1e6) return (n / 1e6).toFixed(2) + 'M';
  if (n >= 1) return n.toLocaleString('en-US', { maximumFractionDigits: 4 });
  return n.toLocaleString('en-US', { maximumFractionDigits: 6 });
}
function fmtPct(n) {
  if (n == null || isNaN(n)) return '—';
  return (n >= 0 ? '+' : '') + n.toFixed(2) + '%';
}
function fmtTime(ts) {
  return new Date(ts).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' });
}
const shortAddr = (a) => (a ? a.slice(0, 4) + '…' + a.slice(-4) : '—');

function setChangeEl(node, pct) {
  node.textContent = fmtPct(pct);
  node.classList.remove('up', 'down');
  if (pct != null && !isNaN(pct)) node.classList.add(pct >= 0 ? 'up' : 'down');
}

// ----------------------------- Charts ---------------------------------------
function gradientFill(ctx, hex) {
  const chart = ctx.chart;
  const area = chart.chartArea;
  if (!area) return hex + '00';
  const g = chart.ctx.createLinearGradient(0, area.top, 0, area.bottom);
  g.addColorStop(0, hex + '55');
  g.addColorStop(1, hex + '00');
  return g;
}

function makeLineChart(canvas, { mini }) {
  return new Chart(canvas, {
    type: 'line',
    data: {
      datasets: [{
        data: [],
        borderColor: COLOR_UP,
        borderWidth: mini ? 2 : 2.5,
        fill: true,
        backgroundColor: (c) => gradientFill(c, c.dataset.borderColor),
        tension: 0.35,
        pointRadius: 0,
        pointHoverRadius: mini ? 0 : 4,
        parsing: false,
      }],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      animation: false,
      interaction: { mode: 'index', intersect: false },
      scales: mini
        ? { x: { type: 'linear', display: false }, y: { display: false } }
        : {
            x: {
              type: 'linear',
              grid: { display: false },
              ticks: { color: '#6a6a82', maxTicksLimit: 6, callback: (v) => fmtTime(v) },
            },
            y: {
              position: 'right',
              grid: { color: 'rgba(255,255,255,0.05)' },
              ticks: { color: '#6a6a82', maxTicksLimit: 6, callback: (v) => fmtCompactUsd(v) },
            },
          },
      plugins: {
        legend: { display: false },
        tooltip: {
          displayColors: false,
          backgroundColor: 'rgba(10,10,18,0.95)',
          borderColor: 'rgba(255,255,255,0.12)',
          borderWidth: 1,
          padding: 10,
          callbacks: {
            title: (items) => fmtTime(items[0].parsed.x),
            label: (item) => fmtUsd(item.parsed.y),
          },
        },
      },
    },
  });
}

// ----------------------------- Persistence ----------------------------------
function loadSettings() {
  S.address = localStorage.getItem(LS.address) || '';
  S.rpcUrl = localStorage.getItem(LS.rpc) || '';
  S.priceInterval = clampInt(localStorage.getItem(LS.priceInt), 5, 600, 12);
  S.balanceInterval = clampInt(localStorage.getItem(LS.balInt), 30, 3600, 90);
  S.sort = localStorage.getItem(LS.sort) || 'value';
}
function clampInt(v, min, max, def) {
  const n = parseInt(v, 10);
  if (isNaN(n)) return def;
  return Math.min(max, Math.max(min, n));
}
function saveHidden() {
  try { localStorage.setItem(LS.hidden(S.address), JSON.stringify([...S.hidden])); } catch (_) {}
}
let histTimer = null;
function persistHistory() {
  if (histTimer) return;
  histTimer = setTimeout(() => {
    histTimer = null;
    try {
      const slim = { total: S.history.total.slice(-PERSIST_POINTS), byId: {} };
      for (const k in S.history.byId) slim.byId[k] = S.history.byId[k].slice(-PERSIST_POINTS);
      localStorage.setItem(LS.history(S.address), JSON.stringify(slim));
    } catch (_) {}
  }, 4000);
}

// ----------------------------- Status ---------------------------------------
function setStatus(kind, text) {
  el.status.className = 'status status--' + kind;
  el.statusText.textContent = text;
}

// ----------------------------- Data shaping ---------------------------------
function enrich() {
  return S.balances.map((b) => {
    const m = S.meta[b.mint] || {};
    const p = S.prices[b.mint] || {};
    const symbol = b.isNative ? 'SOL' : (m.symbol || b.mint.slice(0, 4) + '…' + b.mint.slice(-4));
    const name = b.isNative ? 'Solana' : (m.name || 'Unknown token');
    const price = typeof p.usdPrice === 'number' ? p.usdPrice : null;
    const value = price != null ? b.uiAmount * price : 0;
    return {
      id: b.id, mint: b.mint, isNative: b.isNative,
      symbol, name, icon: m.icon || null,
      amount: b.uiAmount, price, change: p.priceChange24h ?? null, value,
    };
  });
}

function sortList(list) {
  const arr = [...list];
  if (S.sort === 'name') arr.sort((a, b) => a.symbol.localeCompare(b.symbol));
  else if (S.sort === 'change') arr.sort((a, b) => (b.change ?? -1e9) - (a.change ?? -1e9));
  else arr.sort((a, b) => b.value - a.value);
  return arr;
}

function pushPoint(arr, x, y) {
  arr.push({ x, y });
  if (arr.length > MAX_POINTS) arr.splice(0, arr.length - MAX_POINTS);
}

// ----------------------------- Tracking lifecycle ---------------------------
function startTracking(address) {
  address = (address || '').trim();
  if (!address) return;

  // reset everything for the new wallet
  clearTimers();
  destroyCharts();
  el.grid.innerHTML = '';
  S.cards = {};
  S.gridSig = '';
  S.address = address;
  S.balances = [];
  S.meta = {};
  S.prices = {};
  S.history = { total: [], byId: {} };
  S.lastList = [];

  localStorage.setItem(LS.address, address);
  el.input.value = address;

  // restore saved hidden + history for this wallet
  try {
    const raw = localStorage.getItem(LS.hidden(address));
    if (raw) { S.hidden = new Set(JSON.parse(raw)); S.hiddenInit = true; }
    else { S.hidden = new Set(); S.hiddenInit = false; }
  } catch (_) { S.hidden = new Set(); S.hiddenInit = false; }

  try {
    const h = JSON.parse(localStorage.getItem(LS.history(address)));
    if (h && Array.isArray(h.total)) S.history = { total: h.total, byId: h.byId || {} };
  } catch (_) {}

  el.empty.classList.add('hidden');
  el.dash.classList.remove('hidden');
  el.walletShort.textContent = shortAddr(address);

  // build the total chart fresh
  S.charts.total = makeLineChart(el.totalChart, { mini: false });

  refreshBalances().then(startTimers);
}

function clearTimers() {
  for (const k of Object.keys(S.timers)) {
    if (S.timers[k]) clearInterval(S.timers[k]);
    S.timers[k] = null;
  }
}
function startTimers() {
  clearTimers();
  S.timers.price = setInterval(tickPrices, S.priceInterval * 1000);
  S.timers.balance = setInterval(refreshBalances, S.balanceInterval * 1000);
  S.timers.countdown = setInterval(updateCountdown, 1000);
  S.nextTickAt = Date.now() + S.priceInterval * 1000;
}
function destroyCharts() {
  if (S.charts.total) { S.charts.total.destroy(); S.charts.total = null; }
  for (const k in S.charts.byId) { try { S.charts.byId[k].destroy(); } catch (_) {} }
  S.charts.byId = {};
}

async function refreshBalances() {
  if (!S.address) return;
  setStatus('loading', 'Syncing…');
  try {
    const { tokens } = await window.walletAPI.getBalances({ address: S.address, rpcUrl: S.rpcUrl });
    S.balances = tokens;

    // Slow path: price every holding so the total is accurate (main paces the calls).
    const allMints = [...new Set(tokens.map((t) => t.mint))];
    const { prices } = await window.walletAPI.getPrices({ mints: allMints });
    S.prices = { ...S.prices, ...prices };

    // Only fetch metadata (symbol / icon) for the tokens we might actually show.
    const ranked = tokens
      .map((t) => ({ mint: t.mint, val: (S.prices[t.mint]?.usdPrice || 0) * t.uiAmount }))
      .sort((a, b) => b.val - a.val)
      .slice(0, META_CAP)
      .map((r) => r.mint);
    const meta = await window.walletAPI.getMeta({ mints: [...new Set([WSOL, ...ranked])] });
    S.meta = { ...S.meta, ...(meta || {}) };

    applyData(true);
    setStatus('live', 'Live');
  } catch (e) {
    setStatus('error', truncate(e.message || 'Failed to load wallet'));
    console.error(e);
  }
}

async function tickPrices() {
  if (!S.address || !S.balances.length) return;
  try {
    const { prices } = await window.walletAPI.getPrices({ mints: mintsForTick() });
    S.prices = { ...S.prices, ...prices }; // keep last-known prices for the long tail
    applyData(true);
    setStatus('live', 'Live');
  } catch (e) {
    setStatus('error', truncate(e.message || 'Price error'));
    console.error(e);
  }
  S.nextTickAt = Date.now() + S.priceInterval * 1000;
}

// On fast ticks we only reprice what's worth repricing: the visible widgets plus
// the highest-value holdings, capped — so a 3000-token wallet still costs ~1 call.
function mintsForTick() {
  const set = new Set();
  for (const t of S.lastList) if (!S.hidden.has(t.id)) set.add(t.mint);
  for (const t of [...S.lastList].sort((a, b) => b.value - a.value)) {
    if (set.size >= PRICE_TICK_CAP) break;
    set.add(t.mint);
  }
  if (!set.size) for (const b of S.balances.slice(0, PRICE_TICK_CAP)) set.add(b.mint);
  return [...set];
}

function truncate(s) { return s.length > 48 ? s.slice(0, 45) + '…' : s; }

// ----------------------------- Apply new data -------------------------------
function applyData(append) {
  const list = enrich();
  const total = list.reduce((s, t) => s + t.value, 0);

  // First time we have prices for a brand-new wallet: show only the top holdings by
  // value (keeps the grid fast and clean); everything else can be enabled in Manage.
  if (!S.hiddenInit && Object.keys(S.prices).length) {
    const keep = new Set(
      [...list].sort((a, b) => b.value - a.value)
        .filter((t) => t.value > 0)
        .slice(0, DEFAULT_MAX_WIDGETS)
        .map((t) => t.id)
    );
    list.forEach((t) => { if (!keep.has(t.id)) S.hidden.add(t.id); });
    S.hiddenInit = true;
    saveHidden();
  }

  const now = Date.now();
  if (append) {
    pushPoint(S.history.total, now, total);
    list.forEach((t) => {
      const arr = S.history.byId[t.id] || (S.history.byId[t.id] = []);
      pushPoint(arr, now, t.value);
    });
    persistHistory();
  }

  updateTotals(list, total);

  // rebuild grid only when the visible membership changes; otherwise update in place
  const visible = sortList(list.filter((t) => !S.hidden.has(t.id)));
  const sig = visible.map((t) => t.id).join('|');
  if (sig !== S.gridSig) renderGrid(visible);
  else updateCards(visible);

  updateTotalChart(total);
  S.lastList = list;
}

function updateTotals(list, total) {
  animateValue(el.totalValue, total, fmtUsd);

  let past = 0, cur = 0;
  list.forEach((t) => {
    if (t.price != null && t.change != null) {
      past += t.value / (1 + t.change / 100);
      cur += t.value;
    }
  });
  const pct = past > 0 ? (cur / past - 1) * 100 : null;
  setChangeEl(el.totalChange, pct);

  el.tokenCount.textContent = `${list.length} token${list.length === 1 ? '' : 's'}`;
  el.lastUpdated.textContent = fmtTime(Date.now());

  const shown = list.filter((t) => !S.hidden.has(t.id)).length;
  el.visibleCount.textContent = `${shown} of ${list.length} shown`;
}

function updateTotalChart(total) {
  const c = S.charts.total;
  if (!c) return;
  const series = S.history.total;
  const trendUp = series.length < 2 || series[series.length - 1].y >= series[0].y;
  c.data.datasets[0].borderColor = trendUp ? COLOR_UP : COLOR_DOWN;
  c.data.datasets[0].data = series;
  c.update('none');
}

// ----------------------------- Grid / cards ---------------------------------
function renderGrid(visible) {
  // destroy old card charts
  for (const k in S.charts.byId) { try { S.charts.byId[k].destroy(); } catch (_) {} }
  S.charts.byId = {};
  S.cards = {};
  el.grid.innerHTML = '';

  if (!visible.length) {
    const div = document.createElement('div');
    div.className = 'grid-empty';
    div.textContent = 'No token widgets shown. Use “Manage widgets” to add some.';
    el.grid.appendChild(div);
    S.gridSig = '';
    return;
  }

  for (const t of visible) {
    const node = el.cardTemplate.content.firstElementChild.cloneNode(true);
    const refs = {
      icon: node.querySelector('.tc-icon'),
      symbol: node.querySelector('.tc-symbol'),
      name: node.querySelector('.tc-name'),
      change: node.querySelector('.tc-change'),
      value: node.querySelector('.tc-value'),
      amount: node.querySelector('.tc-amount'),
      price: node.querySelector('.tc-price'),
      canvas: node.querySelector('canvas'),
      hide: node.querySelector('.tc-hide'),
    };
    setIcon(refs.icon, t);
    refs.symbol.textContent = t.symbol;
    refs.name.textContent = t.name;
    refs.hide.addEventListener('click', () => toggleHidden(t.id, true));

    el.grid.appendChild(node);
    S.cards[t.id] = { el: node, refs };
    S.charts.byId[t.id] = makeLineChart(refs.canvas, { mini: true });
  }
  S.gridSig = visible.map((t) => t.id).join('|');
  updateCards(visible);
}

function updateCards(visible) {
  for (const t of visible) {
    const card = S.cards[t.id];
    if (!card) continue;
    const r = card.refs;
    animateValue(r.value, t.value, fmtUsd);
    r.price.textContent = fmtPrice(t.price);
    r.amount.textContent = fmtAmount(t.amount);
    setChangeEl(r.change, t.change);

    const chart = S.charts.byId[t.id];
    if (chart) {
      const series = S.history.byId[t.id] || [];
      chart.data.datasets[0].borderColor = (t.change ?? 0) >= 0 ? COLOR_UP : COLOR_DOWN;
      chart.data.datasets[0].data = series;
      chart.update('none');
    }
  }
}

function setIcon(img, t) {
  if (t.icon) {
    img.src = t.icon;
    img.style.display = '';
    img.onerror = () => { img.style.visibility = 'hidden'; };
  } else {
    img.removeAttribute('src');
    img.style.visibility = 'hidden';
  }
}

function toggleHidden(id, hide) {
  if (hide) S.hidden.add(id); else S.hidden.delete(id);
  saveHidden();
  // force a grid rebuild on next applyData by clearing the signature
  S.gridSig = '__dirty__';
  if (S.lastList.length) {
    const visible = sortList(S.lastList.filter((t) => !S.hidden.has(t.id)));
    renderGrid(visible);
    updateTotals(S.lastList, S.lastList.reduce((s, t) => s + t.value, 0));
  }
  renderManageList();
}

// ----------------------------- Manage widgets -------------------------------
function renderManageList() {
  el.manageList.innerHTML = '';
  const full = sortList(S.lastList);
  if (!full.length) {
    el.manageList.innerHTML = '<p class="muted">No tokens found in this wallet yet.</p>';
    return;
  }
  const list = full.slice(0, MANAGE_LIMIT);
  for (const t of list) {
    const row = document.createElement('div');
    row.className = 'manage-row';

    const img = document.createElement('img');
    setIcon(img, t);

    const idDiv = document.createElement('div');
    idDiv.className = 'mr-id';
    idDiv.innerHTML = `<div class="mr-sym">${escapeHtml(t.symbol)}</div>
      <div class="mr-val">${fmtUsd(t.value)} · ${fmtAmount(t.amount)} ${escapeHtml(t.symbol)}</div>`;

    const label = document.createElement('label');
    label.className = 'switch';
    const cb = document.createElement('input');
    cb.type = 'checkbox';
    cb.checked = !S.hidden.has(t.id);
    cb.addEventListener('change', () => toggleHidden(t.id, !cb.checked));
    const slider = document.createElement('span');
    slider.className = 'slider';
    label.append(cb, slider);

    row.append(img, idDiv, label);
    el.manageList.appendChild(row);
  }

  if (full.length > list.length) {
    const note = document.createElement('p');
    note.className = 'muted';
    note.style.marginTop = '12px';
    note.textContent = `+${full.length - list.length} more lower-value tokens not listed.`;
    el.manageList.appendChild(note);
  }
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// ----------------------------- Misc UI --------------------------------------
function animateValue(node, to, fmt) {
  const from = node._v ?? to;
  node._v = to;
  if (from === to) { node.textContent = fmt(to); return; }
  const start = performance.now();
  const dur = 600;
  function step(now) {
    const k = Math.min(1, (now - start) / dur);
    const e = 1 - Math.pow(1 - k, 3);
    node.textContent = fmt(from + (to - from) * e);
    if (k < 1) requestAnimationFrame(step);
  }
  requestAnimationFrame(step);
}

function updateCountdown() {
  if (!S.nextTickAt) { el.nextTick.textContent = '—'; return; }
  const rem = Math.max(0, Math.ceil((S.nextTickAt - Date.now()) / 1000));
  el.nextTick.textContent = rem;
}

function openModal(node) { node.classList.remove('hidden'); }
function closeModal(node) { node.classList.add('hidden'); }

// ----------------------------- Events ---------------------------------------
el.form.addEventListener('submit', (e) => {
  e.preventDefault();
  const addr = el.input.value.trim();
  if (addr) startTracking(addr);
});

document.querySelectorAll('.sample').forEach((b) =>
  b.addEventListener('click', () => startTracking(b.dataset.addr)));

el.refreshBtn.addEventListener('click', () => refreshBalances());

el.manageBtn.addEventListener('click', () => { renderManageList(); openModal(el.manageModal); });

el.sortSelect.addEventListener('change', () => {
  S.sort = el.sortSelect.value;
  localStorage.setItem(LS.sort, S.sort);
  if (S.lastList.length) {
    S.gridSig = '__dirty__';
    renderGrid(sortList(S.lastList.filter((t) => !S.hidden.has(t.id))));
  }
});

el.settingsBtn.addEventListener('click', () => {
  el.rpcInput.value = S.rpcUrl;
  el.priceIntervalInput.value = S.priceInterval;
  el.balanceIntervalInput.value = S.balanceInterval;
  openModal(el.settingsModal);
});

el.saveSettings.addEventListener('click', () => {
  S.rpcUrl = el.rpcInput.value.trim();
  S.priceInterval = clampInt(el.priceIntervalInput.value, 5, 600, 12);
  S.balanceInterval = clampInt(el.balanceIntervalInput.value, 30, 3600, 90);
  localStorage.setItem(LS.rpc, S.rpcUrl);
  localStorage.setItem(LS.priceInt, String(S.priceInterval));
  localStorage.setItem(LS.balInt, String(S.balanceInterval));
  closeModal(el.settingsModal);
  if (S.address) { refreshBalances(); startTimers(); }
});

el.clearData.addEventListener('click', () => {
  if (S.address) {
    localStorage.removeItem(LS.hidden(S.address));
    localStorage.removeItem(LS.history(S.address));
  }
  Object.values(LS).forEach((v) => { if (typeof v === 'string') localStorage.removeItem(v); });
  clearTimers();
  destroyCharts();
  S.address = '';
  S.lastList = [];
  el.input.value = '';
  el.dash.classList.add('hidden');
  el.empty.classList.remove('hidden');
  setStatus('idle', 'Idle');
  closeModal(el.settingsModal);
});

el.walletPill.addEventListener('click', () => {
  if (S.address) window.walletAPI.openExternal('https://solscan.io/account/' + S.address);
});

document.querySelectorAll('[data-close]').forEach((node) =>
  node.addEventListener('click', () => { closeModal(el.manageModal); closeModal(el.settingsModal); }));

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') { closeModal(el.manageModal); closeModal(el.settingsModal); }
});

// ----------------------------- Boot -----------------------------------------
function boot() {
  if (typeof Chart === 'undefined') {
    setStatus('error', 'Chart library failed to load');
    return;
  }
  Chart.defaults.font.family = '"Inter", "Segoe UI", system-ui, sans-serif';
  Chart.defaults.color = '#8c8ca6';

  loadSettings();
  el.sortSelect.value = S.sort;
  if (S.address) startTracking(S.address);
  else setStatus('idle', 'Idle');
}

boot();
