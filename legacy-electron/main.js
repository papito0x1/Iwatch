'use strict';

const { app, BrowserWindow, ipcMain, shell } = require('electron');
const path = require('path');

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
const DEFAULT_RPC = 'https://api.mainnet-beta.solana.com';
const TOKEN_PROGRAM = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
const TOKEN_2022_PROGRAM = 'TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb';
const WSOL_MINT = 'So11111111111111111111111111111111111111112';

const JUP_SEARCH = 'https://lite-api.jup.ag/tokens/v2/search';
const JUP_PRICE = 'https://lite-api.jup.ag/price/v3';

// ---------------------------------------------------------------------------
// Small fetch helper with timeout
// ---------------------------------------------------------------------------
async function fetchJson(url, opts = {}, timeout = 20000) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeout);
  try {
    const res = await fetch(url, { ...opts, signal: ctrl.signal });
    if (!res.ok) throw new Error(`HTTP ${res.status} from ${url}`);
    return await res.json();
  } finally {
    clearTimeout(timer);
  }
}

function chunk(arr, size) {
  const out = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Retry transient throttling / 5xx with a short backoff. Public RPCs are strict,
// especially on batched calls, so a couple of retries smooths most hiccups.
async function withRetry(fn, attempts = 3) {
  let lastErr;
  for (let i = 0; i < attempts; i++) {
    try {
      return await fn();
    } catch (e) {
      lastErr = e;
      const msg = String(e && e.message || '');
      const transient = /\b429\b|HTTP 5\d\d|too many|rate|timeout|aborted|fetch failed/i.test(msg);
      if (transient && i < attempts - 1) {
        await sleep(700 * (i + 1));
        continue;
      }
      throw e;
    }
  }
  throw lastErr;
}

// ---------------------------------------------------------------------------
// Solana JSON-RPC
//
// We deliberately use single (non-batched) requests: public RPCs such as
// api.mainnet-beta.solana.com throttle batched JSON-RPC far more aggressively
// (single calls 200, a 3-call batch 429), so sequential singles are more
// reliable on the default endpoint.
// ---------------------------------------------------------------------------
async function rpc(url, method, params) {
  const data = await fetchJson(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  });
  if (data && data.error) throw new Error(data.error.message || 'RPC error');
  return data ? data.result : undefined;
}

const ADDRESS_RE = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;

// ---------------------------------------------------------------------------
// IPC: balances (heavier, on-chain)
// ---------------------------------------------------------------------------
ipcMain.handle('balances:get', async (_e, { address, rpcUrl }) => {
  if (!address || !ADDRESS_RE.test(address.trim())) {
    throw new Error('That does not look like a valid Solana address.');
  }
  const url = (rpcUrl && rpcUrl.trim()) || DEFAULT_RPC;
  const addr = address.trim();

  let balance, std, t22;
  try {
    balance = await withRetry(() => rpc(url, 'getBalance', [addr]));
    std = await withRetry(() => rpc(url, 'getTokenAccountsByOwner', [addr, { programId: TOKEN_PROGRAM }, { encoding: 'jsonParsed' }]));
    t22 = await withRetry(() => rpc(url, 'getTokenAccountsByOwner', [addr, { programId: TOKEN_2022_PROGRAM }, { encoding: 'jsonParsed' }]));
  } catch (e) {
    const msg = String(e && e.message || '');
    if (/\b429\b|too many|rate/i.test(msg) && !(rpcUrl && rpcUrl.trim())) {
      throw new Error('Public RPC is rate-limited (429). Add a custom RPC in Settings.');
    }
    throw e;
  }

  // Aggregate SPL token accounts by mint (a wallet can have several accounts per mint).
  const map = new Map();
  const accounts = [...(std?.value || []), ...(t22?.value || [])];
  for (const acc of accounts) {
    const info = acc?.account?.data?.parsed?.info;
    if (!info) continue;
    const ta = info.tokenAmount;
    const ui = Number(ta?.uiAmount || 0);
    if (!ui || ui <= 0) continue;
    const mint = info.mint;
    const prev = map.get(mint) || { mint, decimals: ta.decimals, uiAmount: 0 };
    prev.uiAmount += ui;
    map.set(mint, prev);
  }

  const tokens = [];
  // Native SOL first.
  const lamports = Number(balance?.value || 0);
  tokens.push({
    id: 'SOL',
    mint: WSOL_MINT,
    isNative: true,
    decimals: 9,
    uiAmount: lamports / 1e9,
  });
  for (const t of map.values()) {
    tokens.push({ id: t.mint, mint: t.mint, isNative: false, decimals: t.decimals, uiAmount: t.uiAmount });
  }

  return { asOf: Date.now(), address: addr, tokens };
});

// ---------------------------------------------------------------------------
// IPC: prices (light, frequent)
// ---------------------------------------------------------------------------
ipcMain.handle('prices:get', async (_e, { mints }) => {
  const unique = [...new Set((mints || []).filter(Boolean))];
  const out = {};
  const groups = chunk(unique, 50);
  for (let i = 0; i < groups.length; i++) {
    try {
      const data = await fetchJson(`${JUP_PRICE}?ids=${groups[i].join(',')}`);
      for (const [mint, info] of Object.entries(data || {})) {
        if (info && typeof info.usdPrice === 'number') {
          out[mint] = {
            usdPrice: info.usdPrice,
            priceChange24h: typeof info.priceChange24h === 'number' ? info.priceChange24h : null,
          };
        }
      }
    } catch (err) {
      // Leave missing mints unpriced; surface nothing fatal.
    }
    if (i < groups.length - 1) await sleep(120); // pace large (multi-chunk) wallets
  }
  return { asOf: Date.now(), prices: out };
});

// ---------------------------------------------------------------------------
// IPC: token metadata (symbol / name / icon) — cached in-process
// ---------------------------------------------------------------------------
const metaCache = new Map();

ipcMain.handle('tokens:meta', async (_e, { mints }) => {
  const unique = [...new Set((mints || []).filter(Boolean))];
  const missing = unique.filter((m) => !metaCache.has(m));

  const groups = chunk(missing, 50);
  for (let gi = 0; gi < groups.length; gi++) {
    const group = groups[gi];
    try {
      const data = await fetchJson(`${JUP_SEARCH}?query=${group.join(',')}`);
      const list = Array.isArray(data) ? data : [];
      for (const t of list) {
        if (!t?.id) continue;
        metaCache.set(t.id, {
          symbol: t.symbol || null,
          name: t.name || null,
          icon: t.icon || null,
          decimals: typeof t.decimals === 'number' ? t.decimals : null,
        });
      }
    } catch (err) {
      // ignore; unresolved mints fall back to truncated address in the UI
    }
    if (gi < groups.length - 1) await sleep(120);
  }

  const out = {};
  for (const m of unique) out[m] = metaCache.get(m) || null;
  return out;
});

ipcMain.handle('open:external', async (_e, url) => {
  if (typeof url === 'string' && /^https?:\/\//.test(url)) {
    await shell.openExternal(url);
  }
});

// ---------------------------------------------------------------------------
// Window
// ---------------------------------------------------------------------------
function createWindow() {
  const win = new BrowserWindow({
    width: 1320,
    height: 880,
    minWidth: 940,
    minHeight: 620,
    backgroundColor: '#0a0a12',
    title: 'Solana Wallet Tracker',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  win.removeMenu();
  win.maximize(); // open widescreen, filling the monitor
  win.loadFile(path.join(__dirname, 'src', 'index.html'));
}

app.whenReady().then(() => {
  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
