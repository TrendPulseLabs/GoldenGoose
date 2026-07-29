#!/usr/bin/env python3
# ==============================================================================
#  TrendPulse Labs  ·  trendpulselabs.github.io  ·  free GoldenGoose + APEX Pro v6
# ==============================================================================
#  TrendPulse APEXPro-agentic v5  —  AI SEMANTIC GATEKEEPER  (Python sidecar)
# ------------------------------------------------------------------------------
#  The EA queries this server on every engine signal. This server pulls live
#  multi-timeframe price action + the macro calendar + live news, asks the AI
#  whether the mathematically-valid signal is contextually TOXIC, and returns
#  VALID or REJECT.
#
#  FAIL-CLOSED CONTRACT (matches the EA):
#    * genuine AI verdict  -> HTTP 200  {"decision":"VALID ..."} / {"decision":"REJECT ..."}
#    * ANY sidecar failure -> HTTP 503  (EA reads code!=200 -> logs "AI UNAVAILABLE" -> SKIPS trade)
#  So a logged REJECT always means the AI genuinely vetoed — never a crash in disguise.
#  That keeps your 7/10 tally honest.
#
#  Install:  pip install MetaTrader5 feedparser requests
#  Run:      set your OpenAI key, then:  python apex_gatekeeper.py
# ==============================================================================

import os, csv, json, time, threading, traceback
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

import requests
import feedparser
import numpy as np              # ships with the MetaTrader5 package
import MetaTrader5 as mt5

# ==============================================================================
#  CONFIGURATION  (the only fork: AI_ENGINE = "OPENAI" or "OLLAMA")
# ==============================================================================
AI_ENGINE   = "OPENAI"                    # <<< default per spec. Flip to "OLLAMA" for local llama3.

# --- OpenAI ---
OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY", "")   # NEVER hard-code. Set as env var.
OPENAI_MODEL   = "gpt-4o-mini"            # pinned; highest semantic reasoning, ~$0.0001/call
OPENAI_URL     = "https://api.openai.com/v1/chat/completions"

# --- Ollama (local) ---
OLLAMA_MODEL   = "llama3"
OLLAMA_URL     = "http://localhost:11434/api/generate"

# --- Server ---
HOST, PORT     = "127.0.0.1", 8765
LOG_FILE       = "apex_ai_decisions.csv"  # one line per genuine verdict -> your 7/10 scorecard

# --- Context sizing (keeps prompt small, inference fast) ---
BARS_PER_TF    = 4
MAX_EVENTS     = 6
MAX_HEADLINES  = 15                        # headlines shown to the AI (markets + geopolitics)
CALENDAR_TTL   = 900                       # re-fetch calendar every 15 min
NEWS_TTL       = 300                       # re-fetch news every 5 min
AI_TIMEOUT     = 6                         # seconds for the LLM call. Keep the WHOLE sidecar
                                           # round-trip under the EA's InpAITimeoutMs. If you see
                                           # HTTP 1003 (EA gave up waiting), raise InpAITimeoutMs
                                           # in the EA to ~8000ms, OR lower this.

# --- Decision thresholds (the AI is TOLD these; it doesn't invent them) ---
IMMINENT_MINS  = 60      # only an event <60min away counts as "imminent"
FRESH_MINS     = 45      # headline <45min old  -> FRESH (can move a flat market)
RECENT_MINS    = 180     # <3h -> RECENT; older -> STALE / already priced in
TREND_ADX      = 25      # ADX >= this = a real trend on that timeframe
STRONG_CLOSE   = 0.30    # close_pos <=0.30 = closed at lows (bearish) ; >=0.70 = at highs (bullish)
AI_CHOP_VETO   = 70.0    # AI may only cite chop above this. Engine's own gate sits ~61.8 ->
                         # this DEFERENCE BAND stops the AI re-litigating a gate the engine passed.

CALENDAR_JSON  = "https://nfs.faireconomy.media/ff_calendar_thisweek.json"

# Many wires reject non-browser agents (feedparser's default gets 403'd).
HTTP_HEADERS = {
    "User-Agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                   "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"),
    "Accept": "application/rss+xml, application/xml, text/xml, application/atom+xml, */*",
}
FEED_TIMEOUT = 2.5                         # per-feed fetch timeout (s). Kept SHORT: news is context,
                                           # not the decision-maker (structure/DXY are). A slow feed
                                           # must never delay the verdict past the EA's timeout.

# Free RSS sources -> ALL fetched, MERGED into one deduped, newest-first tape.
# The AI reads the whole tape at once and judges the overall balance.
# A dead/slow feed is skipped; the rest still carry the tape.
#   (name, url, max_items)
# MARKETS feeds get a bigger cap; WORLD/GEOPOLITICS feeds are capped tighter so
# generic world noise (elections, disasters) can't crowd out the markets tape --
# but war / escalation / sanctions headlines still reach the AI, which matters a
# lot for gold (the primary risk-off / safe-haven asset).
NEWS_FEEDS = [
    # ---- markets / macro ----
    ("forexlive",   "https://www.forexlive.com/feed",                        5),
    ("fxstreet",    "https://www.fxstreet.com/rss/news",                     5),
    ("marketwatch", "https://feeds.marketwatch.com/marketwatch/topstories/", 4),
    ("investing",   "https://www.investing.com/rss/news_301.rss",            4),
    ("wsj",         "https://feeds.a.dj.com/rss/RSSMarketsMain.xml",         4),
    # ---- world / geopolitics (war, escalation, sanctions -> gold risk-off) ----
    ("cnbc-world",  "https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=100727362", 3),
    ("aljazeera",   "https://www.aljazeera.com/xml/rss/all.xml",             3),
    ("bbc-world",   "https://feeds.bbci.co.uk/news/world/rss.xml",           3),
]

# ==============================================================================
#  CACHES  (survive the 8-book burst: several books can fire on the same tick)
# ==============================================================================
_lock          = threading.Lock()
_ctx_cache     = {}     # (symbol, m15_bar_epoch) -> multi-TF context string
_verdict_cache = {}     # (symbol, direction, m15_bar) -> verdict  (one setup = one AI call)
_cal_cache     = {"t": 0, "raw": None}
_news_cache    = {"t": 0, "raw": None}

TF_MAP = [(mt5.TIMEFRAME_M1, "M1"), (mt5.TIMEFRAME_M5, "M5"),
          (mt5.TIMEFRAME_M15, "M15"), (mt5.TIMEFRAME_H1, "H1"),
          (mt5.TIMEFRAME_H4, "H4")]


# ------------------------------------------------------------------------------
def relevant_currencies(symbol):
    """Currency-aware: which economies actually move this symbol."""
    s = symbol.upper()
    if "XAU" in s or "GOLD" in s:
        return {"USD"}                              # gold is a USD story
    ccy = {s[i:i+3] for i in (0, 3) if len(s) >= 6 and s[i:i+3].isalpha()}
    return ccy or {"USD"}


def m15_bar_epoch(symbol):
    r = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_M15, 0, 1)
    return int(r[0]['time']) if r is not None and len(r) else int(time.time() // 900 * 900)


def build_market_context(symbol):
    """Last N bars across M1..H4. Cached per (symbol, current M15 bar)."""
    key = (symbol, m15_bar_epoch(symbol))
    with _lock:
        if key in _ctx_cache:
            return _ctx_cache[key]

    lines = []
    for tf, name in TF_MAP:
        rates = mt5.copy_rates_from_pos(symbol, tf, 0, BARS_PER_TF)
        if rates is None or len(rates) == 0:
            lines.append(f"[{name}] (no data)")
            continue
        bars = " | ".join(f"O:{r['open']:.2f} H:{r['high']:.2f} "
                          f"L:{r['low']:.2f} C:{r['close']:.2f}" for r in rates)
        lines.append(f"[{name}] {bars}")
    ctx = "\n".join(lines)

    with _lock:
        _ctx_cache.clear()          # only the current bar matters; keep the dict tiny
        _ctx_cache[key] = ctx
    return ctx


def get_calendar(symbol):
    """FUTURE-ONLY high-impact events for the currencies that move THIS symbol.
    Returns (text, minutes_to_nearest_event or None).

    BUGFIX: the ff_calendar_thisweek.json feed returns the WHOLE week, including
    days already gone. The old code showed past events, so the AI kept vetoing on
    'imminent high-impact events approaching' for prints that had happened DAYS
    earlier. Now: past events are dropped, and each future event carries its real
    time-to-event so the AI can tell 'FOMC in 35min' from 'CPI in 3 days'."""
    now = time.time()
    with _lock:
        fresh = _cal_cache["raw"] is not None and (now - _cal_cache["t"]) < CALENDAR_TTL
    if not fresh:
        try:
            r = requests.get(CALENDAR_JSON, headers=HTTP_HEADERS, timeout=FEED_TIMEOUT)
            r.raise_for_status()
            with _lock:
                _cal_cache["raw"], _cal_cache["t"] = r.json(), now
        except Exception as e:
            return (f"(calendar unavailable: {e})", None)

    ccys = relevant_currencies(symbol)
    now_utc = datetime.now(timezone.utc)
    rows, mins_list = [], []
    for e in (_cal_cache["raw"] or []):
        if str(e.get("impact", "")).lower() != "high":
            continue
        if str(e.get("country", "")).upper() not in ccys:
            continue
        when = _parse_event_dt(e.get("date", ""))
        if when is None:
            continue
        mins = (when - now_utc).total_seconds() / 60.0
        if mins < 0:                      # <-- FUTURE ONLY. past events are dropped.
            continue
        mins_list.append(mins)
        rows.append((mins,
                     f"- in {_fmt_delta(mins):<9} | {e.get('country','')} {e.get('title','?')} "
                     f"(F:{e.get('forecast','N/A')} P:{e.get('previous','N/A')})"))

    if not rows:
        return ("No upcoming high-impact events for " + ",".join(sorted(ccys)) +
                " (nothing scheduled ahead — this is NOT a reason to reject).", None)

    rows.sort(key=lambda x: x[0])
    nearest = min(mins_list)
    txt = "\n".join(r[1] for r in rows[:MAX_EVENTS])
    if nearest <= IMMINENT_MINS:
        txt += f"\n>> NEAREST EVENT IS IMMINENT ({_fmt_delta(nearest)} away)."
    else:
        txt += (f"\n>> Nearest event is {_fmt_delta(nearest)} away — NOT imminent "
                f"(only <{IMMINENT_MINS}min counts as imminent).")
    return (txt, nearest)


def _parse_event_dt(s):
    """ff feed dates look like '2026-07-15T14:00:00-04:00'. Return tz-aware UTC."""
    if not s:
        return None
    try:
        dt = datetime.fromisoformat(str(s))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except Exception:
        return None


def _fmt_delta(mins):
    if mins < 60:
        return f"{int(mins)}min"
    if mins < 1440:
        return f"{mins/60:.1f}h"
    return f"{mins/1440:.1f}d"


def get_news():
    """Pull ALL feeds, merge into ONE deduped, newest-first headline block.
    The AI sees the whole tape at once and judges from the combined picture.
    A dead/slow feed never blocks the others — it's just skipped."""
    now = time.time()
    with _lock:
        fresh = _news_cache["raw"] is not None and (now - _news_cache["t"]) < NEWS_TTL
    if fresh:
        return _render_news(_news_cache["raw"])

    items, sources_ok, sources_bad = [], [], []
    for name, url, cap in NEWS_FEEDS:
        try:
            # Fetch with a browser User-Agent: most wires (forexlive, fxstreet,
            # marketwatch, investing, wsj) 403 the default feedparser agent.
            resp = requests.get(url, headers=HTTP_HEADERS, timeout=FEED_TIMEOUT)
            resp.raise_for_status()
            feed = feedparser.parse(resp.content)
            if not getattr(feed, "entries", None):
                sources_bad.append(name)
                continue
            for en in feed.entries[:cap]:
                title = (getattr(en, "title", "") or "").strip()
                if not title:
                    continue
                # published time -> for newest-first sorting (missing -> 0)
                ts = 0
                for attr in ("published_parsed", "updated_parsed"):
                    p = getattr(en, attr, None)
                    if p:
                        try:
                            ts = int(time.mktime(p)); break
                        except Exception:
                            pass
                items.append({"t": ts, "title": title, "src": name})
            sources_ok.append(name)
        except Exception as e:
            sources_bad.append(f"{name}({type(e).__name__})")

    # dedupe on normalised title (same story often runs on several wires)
    seen, uniq = set(), []
    for it in sorted(items, key=lambda x: x["t"], reverse=True):   # newest first
        k = "".join(ch for ch in it["title"].lower() if ch.isalnum())[:70]
        if k and k not in seen:
            seen.add(k)
            uniq.append(it)

    uniq = uniq[:MAX_HEADLINES]
    with _lock:
        _news_cache["raw"], _news_cache["t"] = uniq, now
    if sources_bad:
        print(f"[news] ok={len(sources_ok)} down={sources_bad} -> {len(uniq)} headlines")
    return _render_news(uniq)


def _render_news(items):
    """Tag each headline FRESH / RECENT / STALE by age. Stale news is already
    priced in — the AI is told it cannot drive a veto on it."""
    if not items:
        return "(no headlines available)"
    out = []
    for it in items:
        age_tag, when = "", ""
        if it.get("t"):
            mins = int((time.time() - it["t"]) / 60)
            if mins < 0:
                mins = 0
            when = f"{mins}m" if mins < 120 else f"{mins//60}h"
            if mins <= FRESH_MINS:
                age_tag = "FRESH"
            elif mins <= RECENT_MINS:
                age_tag = "RECENT"
            else:
                age_tag = "STALE/priced-in"
        else:
            age_tag = "unknown-age"
        out.append(f"- [{age_tag:<15}|{when:>4}] ({it['src']}) {it['title']}")
    return "\n".join(out)


# ==============================================================================
#  LOG-ONLY METRICS
#  Computed per signal, RECORDED to the CSV, but NEVER fed to the AI.
#  This keeps the baseline clean: the model still decides on the current context
#  only (multi-TF OHLC + calendar + news). These numbers ride along in the CSV so
#  you can later correlate misses with chop / body / regime and tune from
#  evidence. Turning them ON later is a one-line change in build_prompt().
#
#  All functions here are defensive and NEVER raise: every field is always
#  present (missing -> "") so the CSV can never go short or misaligned.
# ==============================================================================
METRIC_TFS = [(mt5.TIMEFRAME_M5, "M5"), (mt5.TIMEFRAME_M15, "M15"),
              (mt5.TIMEFRAME_M30, "M30"), (mt5.TIMEFRAME_H1, "H1"),
              (mt5.TIMEFRAME_H4, "H4")]
METRIC_BARS = 90            # enough closed-bar history for ADX(14) + Choppiness(14)
ATR_PERIOD  = 14
ADX_PERIOD  = 14
CHOP_PERIOD = 14

# fixed per-TF field order -> guarantees CSV column alignment
_METRIC_FIELDS = ["body_pct", "body_atr", "close_pos", "uwick",
                  "lwick", "adx", "chop", "regime",
                  "atr_exp", "swing_room", "vol_ratio"]   # <-- FUEL GAUGE (added for continuation analysis)

_metric_cache = {}         # (symbol, m15_bar_epoch) -> {tfname: {field: val}}


def _wilder(values, period):
    """Wilder's smoothing (RMA). Full-length array; nan until seeded."""
    v = np.asarray(values, dtype=float)
    out = np.full(len(v), np.nan)
    if len(v) < period:
        return out
    out[period - 1] = v[:period].mean()
    for i in range(period, len(v)):
        out[i] = (out[i - 1] * (period - 1) + v[i]) / period
    return out


def _empty_tf():
    return {f: "" for f in _METRIC_FIELDS}


def _compute_tf(symbol, tf):
    """Metrics for ONE timeframe on the last CLOSED bar. Never raises."""
    try:
        rates = mt5.copy_rates_from_pos(symbol, tf, 0, METRIC_BARS + 1)
        if rates is None or len(rates) < ATR_PERIOD + 3:
            return _empty_tf()
        rates = rates[:-1]                       # drop the forming bar -> closed only
        o = rates['open'].astype(float);  h = rates['high'].astype(float)
        l = rates['low'].astype(float);   c = rates['close'].astype(float)
        n = len(c)

        # --- True Range / ATR ---
        prev_c = np.roll(c, 1); prev_c[0] = c[0]
        tr = np.maximum(h - l, np.maximum(np.abs(h - prev_c), np.abs(l - prev_c)))
        atr_last = _wilder(tr, ATR_PERIOD)[-1]

        # --- ADX ---
        up = h - np.roll(h, 1); dn = np.roll(l, 1) - l
        up[0] = 0.0; dn[0] = 0.0
        plus_dm  = np.where((up > dn) & (up > 0), up, 0.0)
        minus_dm = np.where((dn > up) & (dn > 0), dn, 0.0)
        atr_s = _wilder(tr, ADX_PERIOD)
        pdi = 100.0 * np.divide(_wilder(plus_dm,  ADX_PERIOD), atr_s,
                                out=np.zeros(n), where=atr_s > 0)
        mdi = 100.0 * np.divide(_wilder(minus_dm, ADX_PERIOD), atr_s,
                                out=np.zeros(n), where=atr_s > 0)
        denom = pdi + mdi
        dx  = 100.0 * np.divide(np.abs(pdi - mdi), denom, out=np.zeros(n), where=denom > 0)
        adx_last = _wilder(dx, ADX_PERIOD)[-1]

        # --- Choppiness Index (last CHOP_PERIOD closed bars) ---
        chop = np.nan
        if n >= CHOP_PERIOD:
            w_tr = tr[-CHOP_PERIOD:]
            span = h[-CHOP_PERIOD:].max() - l[-CHOP_PERIOD:].min()
            if span > 0 and w_tr.sum() > 0:
                chop = 100.0 * np.log10(w_tr.sum() / span) / np.log10(CHOP_PERIOD)

        # --- Candle body analytics (last closed bar) ---
        O, H, L, C = o[-1], h[-1], l[-1], c[-1]
        rng = H - L
        body = abs(C - O)
        body_pct  = (100.0 * body / rng) if rng > 0 else 0.0
        body_atr  = (body / atr_last) if (atr_last and atr_last > 0) else 0.0
        close_pos = ((C - L) / rng) if rng > 0 else 0.5     # 0=closed at low, 1=at high
        uwick     = ((H - max(O, C)) / rng) if rng > 0 else 0.0
        lwick     = ((min(O, C) - L) / rng) if rng > 0 else 0.0

        adx_v  = float(adx_last) if adx_last == adx_last else 0.0   # nan-safe
        chop_v = float(chop)     if chop     == chop     else 0.0
        regime = "TREND" if adx_v >= 25 else ("CHOP" if chop_v >= 61.8 else "RANGE")

        # === FUEL GAUGE (continuation potential — added after the whipsaw session) ===
        # 1. ATR EXPANSION: current ATR vs its own longer average. >1 = range expanding
        #    (fuel building); <1 = contracting (move running out of gas).
        atr_series = _wilder(tr, ATR_PERIOD)
        atr_avg = np.nanmean(atr_series[-min(len(atr_series), ATR_PERIOD*2):])
        atr_exp = (atr_last / atr_avg) if (atr_avg and atr_avg > 0) else 1.0

        # 2. SWING ROOM: how far, in ATR multiples, price sits from the recent swing
        #    high/low it is heading into. Small = little room left to run before a wall.
        look = min(n, 20)
        swing_hi = h[-look:].max(); swing_lo = l[-look:].min()
        if atr_last and atr_last > 0:
            room_up   = (swing_hi - C) / atr_last     # room above (for a BUY)
            room_down = (C - swing_lo) / atr_last     # room below (for a SELL)
            swing_room = round(min(room_up, room_down), 2)   # nearest wall either way
        else:
            swing_room = ""

        # 3. VOLUME RATIO: last closed bar tick volume vs its recent average.
        try:
            v = rates['tick_volume'].astype(float)
            vavg = v[-min(len(v), 15):].mean()
            vol_ratio = round(v[-1] / vavg, 2) if vavg > 0 else ""
        except Exception:
            vol_ratio = ""

        r2 = lambda x: round(float(x), 2)
        return {"body_pct": r2(body_pct), "body_atr": r2(body_atr),
                "close_pos": r2(close_pos), "uwick": r2(uwick), "lwick": r2(lwick),
                "adx": r2(adx_v), "chop": r2(chop_v), "regime": regime,
                "atr_exp": r2(atr_exp),
                "swing_room": swing_room,
                "vol_ratio": vol_ratio}
    except Exception as e:
        print(f"[metrics] {symbol} tf={tf}: {e}")
        return _empty_tf()


def compute_metrics(symbol):
    """Full per-TF metric set, cached per (symbol, current M15 bar). Never raises."""
    try:
        key = (symbol, m15_bar_epoch(symbol))
    except Exception:
        key = (symbol, int(time.time() // 900))
    with _lock:
        if key in _metric_cache:
            return _metric_cache[key]
    out = {name: _compute_tf(symbol, tf) for tf, name in METRIC_TFS}
    with _lock:
        _metric_cache.clear()
        _metric_cache[key] = out
    return out


def metric_columns():
    cols = []
    for _, name in METRIC_TFS:
        cols += [f"{name}_{f}" for f in _METRIC_FIELDS]
    return cols


def metric_row(metrics):
    """Flatten aligned with metric_columns(); any gap -> '' so a row is never short."""
    row = []
    for _, name in METRIC_TFS:
        tfm = (metrics or {}).get(name, {})
        row += [tfm.get(f, "") for f in _METRIC_FIELDS]
    return row


# ==============================================================================
#  TREND AGREEMENT + PRICE ANCHOR
#  Python computes the STRUCTURAL FACTS and hands them to the AI as conclusions.
#  The AI is NOT asked to infer trend from raw candles -- that is exactly what it
#  failed at (138/138 rejects while H1 was in a confirmed downtrend, because it
#  could not read the trend off OHLC and fell back on the news narrative).
#  Here Python answers "is the signal with or against the dominant trend?" and the
#  AI's job shrinks to the ONE thing it is genuinely good at: judging whether the
#  news is a reason to override an established fact.
# ==============================================================================
def _tf_bias(m):
    """Directional read of one timeframe from its computed metrics.
    +1 bullish, -1 bearish, 0 neutral."""
    try:
        adx = float(m.get("adx") or 0)
        cp  = float(m.get("close_pos") or 0.5)
    except Exception:
        return 0
    if adx < TREND_ADX:
        return 0                                  # no trend -> no bias
    if cp <= STRONG_CLOSE:
        return -1                                 # closing at the lows
    if cp >= (1.0 - STRONG_CLOSE):
        return +1                                 # closing at the highs
    return 0


def analyze_structure(symbol, direction, metrics, price_now):
    """Return (facts_text, agrees_with_trend: bool, price_favours: bool)."""
    side = "BUY" if direction > 0 else "SELL"
    sgn  = 1 if direction > 0 else -1

    # ---- per-TF fact lines -------------------------------------------------
    lines = []
    for _, tf in METRIC_TFS:
        m = (metrics or {}).get(tf, {})
        if not m or m.get("adx") == "":
            lines.append(f"{tf:<4}: (no data)")
            continue
        b = _tf_bias(m)
        bias = "BULLISH" if b > 0 else ("BEARISH" if b < 0 else "neutral")
        cp = float(m.get("close_pos") or 0.5)
        loc = ("closed at LOWS" if cp <= STRONG_CLOSE else
               "closed at HIGHS" if cp >= (1.0 - STRONG_CLOSE) else "closed mid-range")
        lines.append(
            f"{tf:<4}: {str(m.get('regime','?')):<5} | ADX {float(m.get('adx') or 0):>4.1f} "
            f"| chop {float(m.get('chop') or 0):>4.1f} | body {float(m.get('body_pct') or 0):>4.1f}% "
            f"({float(m.get('body_atr') or 0):.1f}xATR) | {loc} -> {bias}")

    # ---- dominant trend = H1, backed by H4 ---------------------------------
    h1 = _tf_bias((metrics or {}).get("H1", {}))
    h4 = _tf_bias((metrics or {}).get("H4", {}))
    dom = h1 if h1 != 0 else h4                   # H1 leads; H4 is the fallback
    dom_name = "H1" if h1 != 0 else ("H4" if h4 != 0 else "none")

    if dom == 0:
        agree_txt = ("NO dominant HTF trend (H1/H4 are both flat/ranging). The signal cannot "
                     "'contradict the HTF regime' -- there is no regime to contradict. BUT there "
                     "is also no trend backing this trade: the market is directionless and "
                     "waiting for a catalyst, so FRESH news retains full weight here.")
        agrees = True          # can't contradict what doesn't exist
        trended = False        # <-- but there is NO trend backing it either
    elif dom == sgn:
        agree_txt = (f"*** The {side} signal AGREES WITH the dominant {dom_name} trend "
                     f"({'up' if dom>0 else 'down'}). It is a WITH-TREND entry. ***")
        agrees = True
        trended = True
    else:
        agree_txt = (f"*** WARNING: the {side} signal FIGHTS the dominant {dom_name} trend "
                     f"({'up' if dom>0 else 'down'}). This is a COUNTER-TREND entry. ***")
        agrees = False
        trended = True

    # ---- price anchor: has price already moved our way since the setup? -----
    ref = None
    m15 = (metrics or {}).get("M15", {})
    try:
        r = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_M15, 1, 1)  # last CLOSED M15
        if r is not None and len(r):
            ref = float(r[0]['close'])
    except Exception:
        ref = None

    if ref and price_now:
        move = (price_now - ref) * sgn            # >0 = moved in the signal's favour
        price_favours = move > 0
        anchor = (f"PRICE ANCHOR: since the last closed M15 ({ref:.2f}) price is now "
                  f"{price_now:.2f} -> the move is "
                  f"{'IN FAVOUR of' if price_favours else 'AGAINST'} the {side} "
                  f"({move:+.2f}).")
    else:
        price_favours = False
        anchor = "PRICE ANCHOR: unavailable."

    facts = ("\n".join(lines) + "\n\n" + agree_txt + "\n" + anchor)
    return facts, agrees, price_favours, trended


# ------------------------------------------------------------------------------
# ==============================================================================
#  UPGRADE LAYERS: MACRO (DXY) · SESSION · MICROSTRUCTURE
#  All three are computed in Python and handed to the AI as FACTS. None of them
#  is a standalone gate -- each is a modifier the AI must corroborate before it
#  may veto. (More veto conditions = more starvation risk; the reject-rate alarm
#  is the tripwire.)
# ==============================================================================
DXY_SYMBOL     = "DXYUSD"     # confirmed present in this broker's Market Watch
SPREAD_WIDE_X  = 1.8          # spread > 1.8x its rolling norm = WIDENED
VOL_LOW_X      = 0.60         # closed-bar tick volume < 0.60x avg = LOW participation

_dxy_cache     = {}           # (m15_bar) -> (text, bias)


def get_macro_dxy(direction):
    """DXY H1 bias, judged with the SAME ADX/close-pos machinery as everything else
    (NOT close-vs-SMA, which flags noise as trend).

    BIDIRECTIONAL: gold is inversely correlated to the dollar, so a conflict exists
    whenever DXY's direction MATCHES the gold trade's direction:
        gold BUY  + DXY rising  -> headwind
        gold SELL + DXY falling -> headwind
    The thesis only guarded BUYs; that would have slept through 138 straight SELLs.

    Returns (text, conflict: bool).  conflict=True means macro OPPOSES the trade."""
    sgn = 1 if direction > 0 else -1
    try:
        bar = m15_bar_epoch(DXY_SYMBOL)
    except Exception:
        bar = int(time.time() // 900)
    with _lock:
        hit = _dxy_cache.get(bar)
    if hit is None:
        m = _compute_tf(DXY_SYMBOL, mt5.TIMEFRAME_H1)     # reuse the proven metric engine
        if not m or m.get("adx") == "":
            hit = (f"DXY ({DXY_SYMBOL}): unavailable — add it to Market Watch to enable "
                   f"this layer. Macro check SKIPPED (this is NOT a reason to reject).", 0)
        else:
            b = _tf_bias(m)                                # +1 up / -1 down / 0 flat
            name = "RISING" if b > 0 else ("FALLING" if b < 0 else "FLAT/RANGING")
            hit = (f"DXY H1: {name} | ADX {float(m.get('adx') or 0):.1f} "
                   f"| closed {float(m.get('close_pos') or 0.5):.2f} of range "
                   f"| regime {m.get('regime','?')}", b)
        with _lock:
            _dxy_cache.clear()
            _dxy_cache[bar] = hit

    txt, dxy_bias = hit
    # inverse correlation: conflict when DXY direction == gold trade direction
    conflict = (dxy_bias != 0 and dxy_bias == sgn)
    side = "BUY" if sgn > 0 else "SELL"
    if dxy_bias == 0:
        txt += "\n  -> Dollar is not trending. NO macro headwind. Not a reason to reject."
    elif conflict:
        txt += (f"\n  -> *** MACRO HEADWIND: dollar {('rising' if dxy_bias>0 else 'falling')} "
                f"while we {side} gold. Gold is INVERSELY correlated to USD, so the macro "
                f"OPPOSES this trade. ***")
    else:
        txt += (f"\n  -> MACRO TAILWIND: dollar {('rising' if dxy_bias>0 else 'falling')} "
                f"SUPPORTS this gold {side} (inverse correlation). This CONFIRMS the trade.")
    return txt, conflict


def get_session():
    """Session as a MODIFIER, never a gate.

    Asian hours are genuinely choppier -- but 'reject all Asian breakouts' is the
    Trials/Aurum blanket-gate mistake. Asia only means: LOOK HARDER. It must be
    corroborated by a second concrete reason (low volume / wide spread / counter-
    trend) before it can contribute to a veto. In London/NY the session is stated
    as an explicit NON-FACTOR so the AI cannot invent a liquidity objection."""
    h = datetime.now(timezone.utc).hour
    if 22 <= h or h < 7:
        return ("ASIAN SESSION (thin liquidity, chop-prone).\n"
                "  -> This is NOT a veto by itself. Asia alone = VALID. It only means: require "
                "a SECOND concrete reason (low tick volume / widened spread / counter-trend) "
                "before rejecting. Do NOT reject a clean with-trend signal just because it is Asia.")
    if 7 <= h < 12:
        return ("LONDON SESSION (high liquidity, trend initiation).\n"
                "  -> Liquidity is healthy. SESSION IS A NON-FACTOR — do not cite it as a reason to reject.")
    if 12 <= h < 16:
        return ("LONDON/NY OVERLAP (peak liquidity, highest-quality breakouts).\n"
                "  -> Best conditions of the day. SESSION IS A NON-FACTOR — do not cite it as a reason to reject.")
    return ("NEW YORK SESSION (good liquidity, later: profit-taking).\n"
            "  -> Liquidity is adequate. SESSION IS A NON-FACTOR — do not cite it as a reason to reject.")


def get_microstructure(symbol):
    """LEADING chop/trap detector: tick volume + spread.
    Where the Choppiness Index is lagging (it confirms chop after the fakeout),
    volume and spread reveal participation in real time.

    Two bugs from the thesis are fixed here:
      1. spread does NOT exist on symbol_info_tick(). It's on symbol_info(), or
         (ask-bid)/point. The thesis version would have thrown, been swallowed by a
         bare except, and left this pillar SILENTLY DEAD while appearing installed.
      2. copy_rates_from_pos returns OLDEST->NEWEST, so rates[0] is the OLDEST bar,
         not 'current'. And index 0 from pos 0 is the FORMING bar, whose volume is
         always low mid-bar -> would fire false LOW-VOLUME traps constantly.
         We use the last CLOSED bar and compare it to the prior 15 closed bars.

    Returns (text, trap: bool). trap = LOW volume AND WIDENED spread (both -- 'either'
    is too trigger-happy and would starve the system)."""
    try:
        info = mt5.symbol_info(symbol)
        tick = mt5.symbol_info_tick(symbol)
        rates = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_M15, 0, 17)
        if info is None or tick is None or rates is None or len(rates) < 17:
            return ("Microstructure: unavailable (not a reason to reject).", False)

        # ---- spread, in POINTS, from live broker spec (works for XAUUSD + micro) ----
        point = getattr(info, "point", 0.0) or 0.0
        spread_pts = float(getattr(info, "spread", 0) or 0)
        if spread_pts <= 0 and point > 0:
            spread_pts = (tick.ask - tick.bid) / point

        # ---- volume: LAST CLOSED bar vs the 15 closed bars before it ----
        closed = rates[:-1]                      # drop the forming bar
        vols = [float(r['tick_volume']) for r in closed]
        cur_vol = vols[-1]                       # last CLOSED bar
        hist = vols[:-1]                         # the 15 before it
        avg_vol = sum(hist) / len(hist) if hist else 0.0
        vol_ratio = (cur_vol / avg_vol) if avg_vol > 0 else 1.0

        # ---- spread norm: compare to a typical spread for THIS symbol ----
        # broker-agnostic: flag only if spread is far above its own recent norm
        norm_spread = _spread_norm(symbol, spread_pts)
        spread_x = (spread_pts / norm_spread) if norm_spread > 0 else 1.0

        low_vol   = vol_ratio < VOL_LOW_X
        wide_sprd = spread_x >= SPREAD_WIDE_X
        trap = low_vol and wide_sprd             # BOTH required

        vs = "LOW (thin participation)" if low_vol else "NORMAL/HIGH (real participation)"
        ss = "WIDENED (trap risk)" if wide_sprd else "NORMAL"
        txt = (f"Tick volume (last CLOSED M15): {int(cur_vol)} vs 15-bar avg {int(avg_vol)} "
               f"= {vol_ratio:.2f}x -> {vs}\n"
               f"Spread: {spread_pts:.0f} pts (norm ~{norm_spread:.0f}) = {spread_x:.1f}x -> {ss}")
        if trap:
            txt += ("\n  -> *** MICROSTRUCTURE TRAP: thin volume AND widened spread. Nobody is "
                    "behind this move — it is a low-liquidity fakeout / stop-hunt. ***")
        else:
            txt += ("\n  -> No microstructure trap. (A trap requires BOTH low volume AND a widened "
                    "spread. One alone is NOT a reason to reject.)")
        return txt, trap
    except Exception as e:
        return (f"Microstructure: check failed ({type(e).__name__}) — not a reason to reject.", False)


_spread_hist = {}


def _spread_norm(symbol, cur):
    """Rolling median-ish spread norm per symbol, learned live (no hardcoded '25 pts',
    which would be wrong for XAUUSD vs XAUUSDmicro anyway)."""
    h = _spread_hist.setdefault(symbol, [])
    if cur > 0:
        h.append(cur)
        if len(h) > 200:
            del h[0]
    if len(h) < 10:
        return cur if cur > 0 else 1.0        # not enough history -> no false alarms
    s = sorted(h)
    return s[len(s) // 2]                     # median


def build_prompt(symbol, direction, price, metrics):
    side = "BUY" if direction > 0 else "SELL"
    facts, agrees, price_favours, trended = analyze_structure(symbol, direction, metrics, price)
    cal_txt, mins_to_event = get_calendar(symbol)
    imminent = (mins_to_event is not None and mins_to_event <= IMMINENT_MINS)

    # --- upgrade layers ---
    macro_txt, macro_conflict = get_macro_dxy(direction)
    session_txt              = get_session()
    micro_txt, micro_trap    = get_microstructure(symbol)

    # The hard rule that killed the last run: with-trend + price moving our way
    # => a news NARRATIVE is inadmissible as a veto. The market has seen the news.
    # NOTE: this requires a REAL trend (trended=True). In a flat/directionless market
    # there is no trend backing the trade, the market is waiting for a catalyst, and
    # FRESH news must keep its veto power -- otherwise the gate goes toothless exactly
    # where news matters most.
    if trended and agrees and price_favours:
        anchor_rule = (
            "!! BINDING RULE — THIS SIGNAL IS WITH-TREND AND PRICE IS ALREADY MOVING IN ITS "
            "FAVOUR. A news NARRATIVE is therefore INADMISSIBLE as grounds to REJECT. The "
            "market has SEEN this news and is moving this way ANYWAY — it is priced in. "
            "The TAPE is the arbiter, not the story. You may still reject on a HARD fact "
            f"(imminent event <{IMMINENT_MINS}min, an explicit MICROSTRUCTURE TRAP, or an "
            "explicit MACRO HEADWIND), but NOT on a story. Otherwise -> VALID. !!")
    elif trended and agrees:
        anchor_rule = (
            "NOTE: this signal is WITH the dominant trend. Do not reject it on a news "
            "narrative alone — require a concrete, FRESH catalyst actively driving price "
            "the other way, or a genuinely imminent high-impact event.")
    elif not trended:
        anchor_rule = (
            "NOTE: FLAT MARKET — there is no dominant trend backing this trade, and none "
            "opposing it. The market is directionless and waiting for a catalyst. FRESH news "
            "therefore KEEPS ITS FULL WEIGHT here: if a fresh, strong catalyst points against "
            f"the {side}, or a high-impact event is imminent, you MAY reject. But a STALE "
            "headline or a vague narrative is still NOT enough — the default remains VALID.")
    else:
        anchor_rule = (
            "!! COUNTER-TREND — this signal FIGHTS the dominant trend. REJECT IT. "
            "This is sufficient on its own: you do NOT need a news catalyst, a fresh headline, "
            "or any second reason. Counter-trend alone = REJECT. The ONLY thing that can save it "
            "is the price anchor showing price ALREADY moving in the signal's favour. !!")

    return f"""You are a risk-control agent for {symbol}. A validated quantitative engine has fired a {side} signal at {price}. The engine's own math (including its M15 chop gate) has ALREADY cleared this trade.

YOUR DEFAULT IS **VALID**. You are a rare, exceptional veto — not a filter. In normal conditions the great majority of signals must pass. Rejecting a good trade is a WORSE failure than allowing a mediocre one. Do NOT re-litigate the engine's math. If you are unsure, the answer is VALID.

[STRUCTURE — COMPUTED FACTS, AUTHORITATIVE. Do not re-derive these from candles.]
{facts}

[MACRO — DOLLAR CORRELATION (gold is inversely correlated to USD)]
{macro_txt}

[SESSION & LIQUIDITY]
{session_txt}

[MICROSTRUCTURE — leading chop/fakeout detector (volume + spread)]
{micro_txt}

{anchor_rule}

[UPCOMING HIGH-IMPACT EVENTS — future only, with real time-to-event]
{cal_txt}

[NEWS TAPE — markets + geopolitics, newest first. FRESH = can still move a flat market. STALE = already priced in.]
{get_news()}

You may REJECT **only** if one of these five is CONCRETELY TRUE from the facts stated above. You must be able to point to the specific fact. Do not infer, do not speculate:
1. COUNTER-TREND: the STRUCTURE section above explicitly says "COUNTER-TREND". This is SUFFICIENT ON ITS OWN — REJECT immediately. You do NOT need a news catalyst, a fresh headline, or any second reason. Counter-trend alone = REJECT. (The ONLY exception: if the price anchor shows price is ALREADY moving in the signal's favour, it may pass.)
2. IMMINENT EVENT: a high-impact event is <{IMMINENT_MINS}min away AND price is coiling/flat into it (a pre-event liquidity trap). An event hours or days away is NOT a reason to reject.
3. FRESH COUNTER-CATALYST: a FRESH (not STALE) headline is actively driving price AGAINST the signal, and the price anchor confirms price is moving against it.
4. MICROSTRUCTURE TRAP: the facts above explicitly say "MICROSTRUCTURE TRAP" (thin volume AND widened spread). Low volume alone, or a wide spread alone, is NOT enough.
5. MACRO HEADWIND: the facts above explicitly say "MACRO HEADWIND" (the dollar is trending AGAINST this gold trade) AND the signal is not already with-trend with price confirming it.

Rules you must obey:
- Conditions 1-5 are INDEPENDENT. Any ONE of them is enough. Never require two conditions to stack before rejecting — in particular, NEVER require a news catalyst to justify a COUNTER-TREND reject.
- STALE news is priced in and can NEVER justify a REJECT.
- A geopolitical narrative that price is IGNORING (price moving the other way) is NOT grounds to REJECT.
- CHOP alone is NEVER grounds to REJECT. The engine's chop gate already passed this. Chop may only be cited if it is above {AI_CHOP_VETO:.0f} AND the signal is counter-trend.
- SESSION alone is NEVER grounds to REJECT. Asian hours only mean "require a second concrete reason". In London/NY/Overlap the session must not be cited at all.
- If DXY or microstructure data is unavailable, that is NOT a reason to reject — simply ignore that layer.
- If none of the five conditions is CONCRETELY met -> VALID.

Reply with EXACTLY one word first — VALID or REJECT — then at most 8 words of reason. No other text."""


def call_openai(prompt):
    headers = {"Authorization": f"Bearer {OPENAI_API_KEY}", "Content-Type": "application/json"}
    payload = {"model": OPENAI_MODEL, "temperature": 0.0,
               "messages": [{"role": "user", "content": prompt}]}
    r = requests.post(OPENAI_URL, headers=headers, json=payload, timeout=AI_TIMEOUT)
    r.raise_for_status()
    return r.json()["choices"][0]["message"]["content"].strip()


def call_ollama(prompt):
    payload = {"model": OLLAMA_MODEL, "prompt": prompt, "stream": False,
               "options": {"temperature": 0.0}}
    r = requests.post(OLLAMA_URL, json=payload, timeout=AI_TIMEOUT)
    r.raise_for_status()
    return r.json()["response"].strip()


def _parse_verdict(raw):
    """Decide from the FIRST WORD only. The old parser did `if 'REJECT' in text`,
    which mislabelled replies like 'VALID - no concrete reason to reject' as REJECT
    (the word 'reject' appears in the reason). The prompt requires the verdict word
    FIRST, so we read the first token and ignore the rest.

    2 of 14 logged rows were corrupted this way -> VALID trades wrongly blocked."""
    s = raw.strip()
    if not s:
        raise ValueError("empty AI reply")
    # strip common leading punctuation/quotes, take the first alphabetic token
    first = ""
    for ch in s:
        if ch.isalpha():
            first += ch
        elif first:
            break
    head = first.upper()
    if head == "REJECT":
        return s if s.upper().startswith("REJECT") else "REJECT " + s
    if head == "VALID":
        return s if s.upper().startswith("VALID") else "VALID " + s
    # first word is neither -> try to recover from an explicit verdict word in the body
    up = s.upper()
    if "REJECT" in up and "VALID" not in up:
        return "REJECT " + s
    if "VALID" in up and "REJECT" not in up:
        return "VALID " + s
    # genuinely ambiguous -> contract broken -> caller raises -> EA fails closed
    raise ValueError(f"unparseable AI reply (first token={first!r}): {raw!r}")


def query_ai(symbol, direction, metrics):
    """One genuine AI verdict. CACHED per (symbol, direction, M15 bar) -- the last
    run fired 138 OpenAI calls in 11h (median 10s apart) re-asking the same
    question about the same bar. One setup = one verdict."""
    try:
        bar = m15_bar_epoch(symbol)
    except Exception:
        bar = int(time.time() // 900)
    key = (symbol, int(direction), bar)
    with _lock:
        hit = _verdict_cache.get(key)
    if hit:
        return hit, True                      # (verdict, from_cache)

    prompt = build_prompt(symbol, direction, current_price(symbol, direction), metrics)
    raw = call_openai(prompt) if AI_ENGINE == "OPENAI" else call_ollama(prompt)
    verdict = _parse_verdict(raw)      # first-token parse (see below)

    with _lock:
        if len(_verdict_cache) > 200:
            _verdict_cache.clear()
        _verdict_cache[key] = verdict
    return verdict, False


def current_price(symbol, direction):
    t = mt5.symbol_info_tick(symbol)
    if t is None:
        return 0.0
    return t.ask if direction > 0 else t.bid


BASE_COLUMNS = ["timestamp_utc", "symbol", "direction", "verdict",
                "reason", "engine", "price",
                "session", "dxy_bias", "dxy_conflict", "spread_pts", "spread_x",
                "vol_ratio", "micro_trap"]


def _upgrade_cols(symbol, direction):
    """The 7 new context columns, captured at decision time -> next tuning round is
    evidence-based (same discipline that found the trend/narrative bug)."""
    try:
        h = datetime.now(timezone.utc).hour
        sess = ("ASIAN" if (22 <= h or h < 7) else "LONDON" if h < 12
                else "OVERLAP" if h < 16 else "NY")
    except Exception:
        sess = ""
    try:
        _, conflict = get_macro_dxy(direction)
        m = _compute_tf(DXY_SYMBOL, mt5.TIMEFRAME_H1)
        b = _tf_bias(m) if m and m.get("adx") != "" else 0
        dxy_bias = "UP" if b > 0 else ("DOWN" if b < 0 else "FLAT")
    except Exception:
        dxy_bias, conflict = "", False
    try:
        info = mt5.symbol_info(symbol); tick = mt5.symbol_info_tick(symbol)
        point = getattr(info, "point", 0.0) or 0.0
        sp = float(getattr(info, "spread", 0) or 0)
        if sp <= 0 and point > 0:
            sp = (tick.ask - tick.bid) / point
        norm = _spread_norm(symbol, sp)
        sx = round(sp / norm, 2) if norm > 0 else ""
        rates = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_M15, 0, 17)
        closed = rates[:-1]
        vols = [float(r['tick_volume']) for r in closed]
        avg = sum(vols[:-1]) / max(len(vols[:-1]), 1)
        vr = round(vols[-1] / avg, 2) if avg > 0 else ""
        trap = (vr != "" and vr < VOL_LOW_X) and (sx != "" and sx >= SPREAD_WIDE_X)
        return [sess, dxy_bias, int(bool(conflict)), round(sp, 1), sx, vr, int(bool(trap))]
    except Exception:
        return [sess, dxy_bias, int(bool(conflict)), "", "", "", ""]


def log_decision(symbol, direction, verdict, price, metrics):
    """Append one row: base verdict fields + all log-only metric columns.
    Row width always == len(BASE_COLUMNS)+len(metric_columns()); no short rows."""
    side = "BUY" if direction > 0 else "SELL"
    head = verdict.split(None, 1)
    tag  = head[0].upper()
    reason = head[1] if len(head) > 1 else ""
    new = not os.path.exists(LOG_FILE)
    with open(LOG_FILE, "a", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        if new:
            w.writerow(BASE_COLUMNS + metric_columns())
        base = [datetime.now(timezone.utc).isoformat(timespec="seconds"),
                symbol, side, tag, reason, AI_ENGINE, f"{price:.2f}"] + \
               _upgrade_cols(symbol, direction)
        w.writerow(base + metric_row(metrics))


def _ensure_log_schema():
    """If an older CSV with a different header exists, archive it so columns
    never misalign against the new base+metric schema."""
    if not os.path.exists(LOG_FILE):
        return
    expected = BASE_COLUMNS + metric_columns()
    try:
        with open(LOG_FILE, newline="", encoding="utf-8") as f:
            existing = next(csv.reader(f), [])
        if existing != expected:
            bak = LOG_FILE + "." + datetime.now().strftime("%Y%m%d%H%M%S") + ".bak"
            os.rename(LOG_FILE, bak)
            print(f"⚠️  {LOG_FILE} had a different schema -> archived to {bak}")
    except Exception as e:
        print(f"[schema] {e}")


_stats = {"valid": 0, "reject": 0}


def _tally(verdict):
    if verdict.upper().startswith("REJECT"):
        _stats["reject"] += 1
    else:
        _stats["valid"] += 1


def _rate_note():
    """Live reject-rate + starvation alarm. The last run rejected 138/138 and it
    took a day to notice. Now it screams on the spot."""
    n = _stats["valid"] + _stats["reject"]
    if n == 0:
        return ""
    rate = 100.0 * _stats["reject"] / n
    note = f"   [{_stats['valid']}V/{_stats['reject']}R = {rate:.0f}% reject]"
    if n >= 8 and rate >= 60:
        note += "  ⚠️ STARVATION WARNING — vetoing too much, gate is too strict!"
    return note


# ==============================================================================
#  HTTP SERVER
# ==============================================================================
class Handler(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n) or b"{}")
            symbol    = req["symbol"]
            direction = int(req["direction"])
        except Exception as e:
            print(f"[BADREQ] {e}")
            return self._send(503, {"decision": "REJECT malformed-request"})  # 503 -> EA fails closed

        try:
            # metrics are now computed FIRST and FED INTO the decision (was log-only)
            metrics = compute_metrics(symbol)
            verdict, cached = query_ai(symbol, direction, metrics)
            price   = current_price(symbol, direction)
            if not cached:
                log_decision(symbol, direction, verdict, price, metrics)
                _tally(verdict)
            side = "BUY" if direction > 0 else "SELL"
            tag  = "cache" if cached else AI_ENGINE
            print(f"[{tag}] {symbol} {side} -> {verdict}{'' if cached else _rate_note()}")
            return self._send(200, {"decision": verdict})
        except Exception as e:
            # ANY failure (MT5, context, LLM down, unparseable) -> 503 -> EA logs "AI UNAVAILABLE" -> SKIP
            print(f"[FAIL-CLOSED] {symbol} dir={direction}: {e}")
            traceback.print_exc()
            return self._send(503, {"decision": f"UNAVAILABLE {type(e).__name__}"})

    def log_message(self, *args):   # silence default noisy logging
        return


def main():
    if not mt5.initialize():
        print("❌ MT5 initialize() failed — is the terminal running and logged in?")
        raise SystemExit(1)
    if AI_ENGINE == "OPENAI" and not OPENAI_API_KEY:
        print("❌ AI_ENGINE=OPENAI but OPENAI_API_KEY env var is empty. Set it and restart.")
        raise SystemExit(1)
    _ensure_log_schema()
    print(f"🧠 APEXPro-agentic v5 gatekeeper up on http://{HOST}:{PORT}  | engine={AI_ENGINE}")
    print("   TrendPulse Labs · trendpulselabs.github.io · GoldenGoose (free) + APEX Pro v6")
    print(f"   decisions -> {os.path.abspath(LOG_FILE)}")
    print(f"   metrics: {len(metric_columns())} cols across "
          f"{','.join(n for _, n in METRIC_TFS)} -> FED INTO the AI decision (trend/chop/body)")
    print(f"   layers : DXY macro ({DXY_SYMBOL}, bidirectional) | session (modifier, never a gate) "
          f"| microstructure (vol+spread trap)")
    print(f"   rules  : default=VALID | fail-CLOSED | calendar=FUTURE-ONLY (<{IMMINENT_MINS}min=imminent)"
          f" | news: FRESH<{FRESH_MINS}min, STALE>{RECENT_MINS}min=priced-in")
    try:
        if mt5.symbol_info(DXY_SYMBOL) is None:
            print(f"   ⚠️  {DXY_SYMBOL} NOT in Market Watch -> macro layer will be SKIPPED "
                  f"(right-click Market Watch -> Show All -> {DXY_SYMBOL})")
        else:
            mt5.symbol_select(DXY_SYMBOL, True)
            print(f"   ✅ {DXY_SYMBOL} found -> macro correlation layer ACTIVE")
    except Exception:
        pass
    HTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
