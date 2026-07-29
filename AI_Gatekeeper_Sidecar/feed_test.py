#!/usr/bin/env python3
# ==============================================================================
#  feed_test.py  —  tests EVERY news feed individually and tells you exactly
#  which work, which fail, and WHY. Also tests the economic calendar.
#
#  Run:  cd C:\Users\Administrator\Desktop\GateKeeper-SideCar
#        py feed_test.py
#
#  Does NOT touch MT5, OpenAI, or the CSV. Safe to run any time.
# ==============================================================================
import requests, feedparser

HTTP_HEADERS = {
    "User-Agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                   "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"),
    "Accept": "application/rss+xml, application/xml, text/xml, application/atom+xml, */*",
}
TIMEOUT = 8

NEWS_FEEDS = [
    ("forexlive",     "https://www.forexlive.com/feed"),
    ("fxstreet",      "https://www.fxstreet.com/rss/news"),
    ("marketwatch",   "https://feeds.marketwatch.com/marketwatch/topstories/"),
    ("investing",     "https://www.investing.com/rss/news_301.rss"),
    ("wsj",           "https://feeds.a.dj.com/rss/RSSMarketsMain.xml"),
    ("cnbc-world",    "https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=100727362"),
    ("aljazeera",     "https://www.aljazeera.com/xml/rss/all.xml"),
    ("bbc-world",     "https://feeds.bbci.co.uk/news/world/rss.xml"),
]
CALENDAR = "https://nfs.faireconomy.media/ff_calendar_thisweek.json"

print("=" * 74)
print("  FEED DIAGNOSTIC  (browser User-Agent)")
print("=" * 74)

ok = bad = 0
for name, url in NEWS_FEEDS:
    try:
        r = requests.get(url, headers=HTTP_HEADERS, timeout=TIMEOUT)
        if r.status_code != 200:
            print(f"  ❌ {name:<14} HTTP {r.status_code}  (blocked/moved)")
            bad += 1
            continue
        f = feedparser.parse(r.content)
        n = len(getattr(f, "entries", []) or [])
        if n == 0:
            print(f"  ⚠️  {name:<14} HTTP 200 but 0 entries (not a valid feed?)")
            bad += 1
            continue
        top = f.entries[0].title[:52]
        print(f"  ✅ {name:<14} {n:>3} items | {top}")
        ok += 1
    except Exception as e:
        print(f"  ❌ {name:<14} {type(e).__name__}: {str(e)[:44]}")
        bad += 1

print("-" * 74)
print(f"  NEWS: {ok} working / {bad} failing")

print("-" * 74)
try:
    r = requests.get(CALENDAR, headers=HTTP_HEADERS, timeout=TIMEOUT)
    r.raise_for_status()
    data = r.json()
    high = [e for e in data if str(e.get("impact", "")).lower() == "high"]
    usd_high = [e for e in high if str(e.get("country", "")).upper() == "USD"]
    print(f"  ✅ calendar      {len(data)} events | {len(high)} high-impact | {len(usd_high)} USD high-impact")
    for e in usd_high[:3]:
        print(f"       - {str(e.get('date',''))[:16]} {e.get('title','?')}")
    if not usd_high:
        print("       (none scheduled this week — normal on quiet weeks)")
except Exception as e:
    print(f"  ❌ calendar      {type(e).__name__}: {str(e)[:44]}")

print("=" * 74)
print("  Any ❌ above -> tell Claude which ones and they'll be swapped out.")
