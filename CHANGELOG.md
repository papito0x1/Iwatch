# Changelog

## 1.4.0

- **Branded loading screen.** Adding or switching a wallet now shows an animated, Yaru-styled
  loader (the app mark breathing over an orange→aubergine comet ring) and cross-fades into the
  full UI once the first balances arrive — no more flash of an empty layout. A failed first load
  shows an error state with Try again / Change wallet.
- **Single instance.** Launching Iwatch a second time now focuses the running window instead of
  opening another, so two instances can't fight over the saved wallet / preferences.
- **Robust balance reconstruction on large / many-token wallets.** Reconstruction is now
  per-token and incremental — a rate-limited candle fetch no longer aborts the whole window
  (which used to sit forever on "Collecting live history…"); each holding commits as it lands
  (biggest first), and series are anchored to the holding's real value so an odd-pool price can't
  blow the chart up to billions.

## 1.3.0

- **Balance graphs now show real history.** The portfolio "Total value" and per-token
  "Holdings value" charts (and the sidebar sparklines) are reconstructed from OHLCV candles
  — `value(t) = balance × close(t)`, summed across holdings — so they show a full window the
  moment a wallet loads, instead of only what had been collected live since the wallet was
  added.
- **Selectable window on the main balance chart** — 1D / 1W / 1M. The sidebar sparklines
  stay on the 24h window.
- **Faster price polling** — the Jupiter long-tail poll now refreshes every 6s (was 12s),
  matching the Jupiter mobile cadence. Balances still refresh at 90s (heavier, rate-limited
  RPC); the total/charts tick live off the price feed and the Coinbase WebSocket overlay
  between balance refreshes.

### Notes / limitations

- Reconstruction is bounded to the visible widget tokens to respect GeckoTerminal's keyless
  rate limit; dust holdings are folded into the total at their current value, and a token
  with no pool falls back to a flat line.
- The window prices *current* holdings at past candle closes, so right after a large swap the
  historical shape reflects today's balances, not what was actually held then.
- The candlestick price charts are a separate series and are unchanged.
