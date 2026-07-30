<div align="center">

# TrendPulse GoldenGoose — E4

**A single-engine, fully open-source gold trading Expert Advisor for MetaTrader 5.**
Not a demo. Not a detuned trial. The real engine — source and all.

[![Free](https://img.shields.io/badge/price-free%20forever-C6A052)](https://trendpulselabs.netlify.app/)
[![License](https://img.shields.io/badge/license-see%20LICENSE-4B7BF5)](./LICENSE)
[![MT5](https://img.shields.io/badge/platform-MetaTrader%205-EDE6D6)](https://www.metatrader5.com/)
[![Gold](https://img.shields.io/badge/market-XAUUSD%20only-E9CD84)](#the-account-rule)

[Landing page](https://trendpulselabs.netlify.app/) · [Documentation](https://drive.google.com/drive/folders/1hs271IgDDpWyc_rVt1Ud6rA2V0ttW2GL?usp=sharing) · [Backtest results](https://drive.google.com/drive/folders/1g8kcJO-PKm7I-Pa6MYpyC3xMUGzcVQDb?usp=sharing) · [Live demo (FXBlue)](https://www.fxblue.com/users/EddyTrendPulse) · [Telegram](https://t.me/+ZJK0gS8BuREyN2Jk) · [Discord](https://discord.gg/8sKk7mD4b8)

</div>

---

## What this is

GoldenGoose is the **E4 "Pullback" engine** from TrendPulse APEX Pro, released on its own — free and fully open. It was the strongest single performer across every window we tested, so it's the one we give away. The code here is not a rewrite: the engine, sizing, ladder, flip, and fuel gate are the **same code that produced the published results**. The other three APEX engines were removed; nothing was re-implemented. A free tier is only worth anything if it's provably the engine that was measured.

**One market: gold.** Standard `XAUUSD`, or `XAUUSDmicro` for smaller accounts. Nothing else.

---

## Results (real, account-verified)

Gold (XAUUSD), $3,000 start, MetaTrader 5 Strategy Tester on **real ticks**.

| Run | Window | Trades | Win % | PF | Max DD | Net |
|-----|--------|-------:|------:|---:|-------:|----:|
| **Preset A · default** | Jan–Jul 2026 | 407 | 59.0% | 1.64 | 5.1% | **+36.9%** |
| **Out-of-sample** | Jan 2024–Jul 2026 | 1,913 | 60.7% | 1.06 | 31.1% | **+18.1%** |
| **Preset B · aggressive (5×)** | Jan–Jul 2026 | 514 | 67.7% | 1.52 | 27.0% | **+307%** |

**Read the out-of-sample row first.** Over 2½ years of market the engine was never tuned on, the edge compresses — profit factor falls to 1.06 and drawdown reaches 31%. That is not hidden; it is the point. GoldenGoose is a single engine tuned to the **current** regime. What you want from an OOS test is not perfection but survival: still positive, still trading, drawdown you can see coming.

Preset B (5× compounding) is real but **aggressive** — deeper drawdowns, for higher risk tolerance only. Never treat it as the expected case.

Full reports for every window are in the [results folder](https://drive.google.com/drive/folders/1g8kcJO-PKm7I-Pa6MYpyC3xMUGzcVQDb?usp=sharing).

---

## How the engine works

Everything below is in the source. Read it, change it, break it.

### Entry
- **Trigger B — Pullback (primary):** price pulls back to the M15 EMA20 and reclaims it in the direction of trend.
- **Trigger C — Structural breakout:** used in coiling/range regimes, a break of the recent structural high/low.
- **Bias gate:** H4 EMA50 — trades only align with the higher-timeframe direction.
- **Chop gate:** M15 chop index outside the 41–59 dead-zone.

### The fuel gate (verified, frozen)
The entry filter. A signal only becomes a trade when the bar's fuel is inside the derived box:

```
vol_ratio >= 1.171   AND   ADX < 29.3
```

This was fitted on E4's own trade record (expectancy-by-band plus a chronological stability check) and **ships exactly as measured**. It is *not* re-tuned in this free build — that limitation is deliberate and stated plainly. Set `InpFuelGateOn = false` to reproduce the original ungated run.

### Risk & exits
- **Risk unit:** 2.0 × ATR(M15). **Leg 1 disaster stop:** 1.0R. A hard stop ships with every order.
- **E4 stop-and-reverse flip:** after a cut, one flip to Leg 2 (0.5R disaster, max 2 legs).
- **5-rung partial ladder:** banks at 0.5 / 1.0 / 1.5 / 2.0 / 2.5 R, closing 25 / 25 / 20 / 15 / 10%.
- **Adaptive chandelier trail:** tightens by rung (k = 2.0 → 0.5).
- **R-anchored daily breaker:** 5.0R — scales with the bet instead of tripping harder as risk rises.
- **HWM %/R compounding** (`InpCompoundMode = 2`): sizes off the balance high-water mark.
- **Pyramiding:** on, adds at rung 2, max 3 tiers.
- **Friday weekend protection:** entry cutoff + force-close before the weekend gap.

### VLE — present, but OFF
The Validated Loss Engine is in the code and defaults to on, but the position-level derivation showed the floor **cost money** on this gated population (E4's $7 floor cut 123 of 174 trades and killed 45% of its winners). It's left in the code, off, honestly documented — the 1.0R disaster stop and chandelier already manage the loss side.

---

## The agentic AI layer

GoldenGoose ships as a **baseline that runs standalone** — no AI required to test it. Once you've verified the bare engine against the published numbers, you plug in the **agentic AI gatekeeper** (the Python sidecar in this repo).

**What it does:**
- **Wakes only on a signal.** When an engine fires, it queries the AI *before the trade opens* — dormant otherwise.
- **Reads the full context.** Multi-timeframe price action (M1–H4), the high-impact macro calendar, and a merged 8-wire news tape (markets + geopolitics).
- **Vetoes only on contradiction.** `REJECT` if the setup fights the higher-timeframe regime, walks into a pre-event trap, or runs against the tape. Otherwise `VALID` — aligned news confirms trades rather than blocking them.
- **Fails closed, logs everything.** No verdict means no trade — it never trades blind. Every decision plus 50+ context metrics lands in a CSV for scoring and tuning.

**Engines:** OpenAI `gpt-4o-mini` (~$0.0001/call) or a local `llama3` via Ollama — your choice, your keys.

```bash
pip install MetaTrader5 feedparser requests
# set your OpenAI key (or switch AI_ENGINE = "OLLAMA" for local), then:
python apex_gatekeeper.py
```

The sidecar serves on `127.0.0.1:8765`. The EA queries it on every signal; any failure returns HTTP 503, the EA logs "AI UNAVAILABLE" and skips the trade. A logged `REJECT` therefore always means the AI genuinely vetoed — never a crash in disguise.

---

## Install

1. Copy `TrendPulseGoldenGoose_E4.mq5` into `MQL5/Experts/` in your MT5 data folder.
2. Compile it in MetaEditor (F7).
3. Attach it to an `XAUUSD` (or `XAUUSDmicro`) chart. Auto-detect binds to the symbol you attach it to.
4. Load the shipped preset (`.set`) for Preset A or Preset B.

### The account rule
> **No compromise.** Accounts under **$500** use `XAUUSDmicro`. Accounts **$500 and above** use standard `XAUUSD`. Running standard lots on a small account is how good systems die to avoidable drawdown.

---

## Verify it yourself (the whole point)

1. Run the shipped `.set` over the **same window** as the published results, on real ticks, in your Strategy Tester.
2. Confirm the numbers match this README and the [results folder](https://drive.google.com/drive/folders/1g8kcJO-PKm7I-Pa6MYpyC3xMUGzcVQDb?usp=sharing).
3. **Then** plug in the AI sidecar and compare.
4. Cross-check against the live-tracked demo on [FXBlue](https://www.fxblue.com/users/EddyTrendPulse).

Don't trust the backtest — reproduce it.

---

## Support & feedback

GoldenGoose is free forever. It runs on optional [coffee coins](https://buymeacoffee.com/eddyforniai) from people it's helped, which cover the VPS and the next round of research. The next release is built from real forward-test data — send your CSV or a bug report on [Telegram](https://t.me/+ZJK0gS8BuREyN2Jk) or [Discord](https://discord.gg/8sKk7mD4b8) and you'll get early access plus a changelog credit.

Want the full four-engine ensemble, continuous re-tuning, and Squeeze v2? → **[TrendPulse APEX Pro v6](https://trendpulselabs.netlify.app/apex/)**

---

## Links

- **Home / landing page** — https://trendpulselabs.github.io/
- **Premium — APEX Pro v6** — https://trendpulselabs.github.io/apex/
- **Documentation & user guides** — https://drive.google.com/drive/folders/1hs271IgDDpWyc_rVt1Ud6rA2V0ttW2GL?usp=sharing
- **Backtest results** — https://drive.google.com/drive/folders/1g8kcJO-PKm7I-Pa6MYpyC3xMUGzcVQDb?usp=sharing
- **Live-tracked demo (FXBlue)** — https://www.fxblue.com/users/EddyTrendPulse
- **Telegram** — https://t.me/+ZJK0gS8BuREyN2Jk
- **Discord** — https://discord.gg/8sKk7mD4b8
- **Send your CSV / feedback** — https://docs.google.com/forms/d/e/1FAIpQLSdwKy7vUJCXWftAQZivyANXBWFeVtkoeUbS2Rur_Fj6tkW_KA/viewform
- **Support (coffee)** — https://buymeacoffee.com/eddyforniai

---

## Disclaimer

**Research and educational purposes only — not financial advice.** No promises, no guarantees. Past and hypothetical performance does not indicate future results. Trading gold and leveraged instruments is high-risk and can lose some or all of your capital. Backtests are historical simulations; the live-tracked record is a demo account. Software provided "as is." Verify everything yourself before risking real money.

See [LICENSE](./LICENSE) and [CONTRIBUTING.md](./CONTRIBUTING.md).
