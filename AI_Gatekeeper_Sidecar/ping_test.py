#!/usr/bin/env python3
# ==============================================================================
#  ping_test.py  —  proves the AI gate chain works, without waiting for a signal.
#  Sends the SAME payload the EA sends, to the running sidecar.
#
#  Run it in a SECOND CMD window (leave the sidecar running in the first):
#      cd C:\Users\Administrator\Desktop\GateKeeper-SideCar
#      py ping_test.py
#
#  NOTE: this writes ONE test row into apex_ai_decisions.csv. Delete that row
#  (or the file) before you start counting your 7/10 — don't score a fake trade.
# ==============================================================================
import json, sys, urllib.request

URL    = "http://127.0.0.1:8765/"
SYMBOL = "XAUUSD"      # change to XAUUSDmicro if that's what you're testing
DIR    = 1             # 1 = BUY, -1 = SELL

payload = json.dumps({"symbol": SYMBOL, "direction": DIR}).encode("utf-8")
req = urllib.request.Request(URL, data=payload,
                             headers={"Content-Type": "application/json"})

print(f"→ pinging sidecar: {SYMBOL} {'BUY' if DIR > 0 else 'SELL'} ...")
try:
    with urllib.request.urlopen(req, timeout=30) as res:
        code = res.getcode()
        body = json.loads(res.read().decode("utf-8"))
    print(f"← HTTP {code}")
    print(f"← decision: {body.get('decision')}")
    if code == 200:
        print("\n✅ CHAIN WORKS. Sidecar + MT5 + OpenAI key all good.")
        print("   (Remember: delete the test row from apex_ai_decisions.csv.)")
    else:
        print("\n❌ Sidecar returned non-200 -> the EA would FAIL-CLOSED (skip the trade).")
except urllib.error.HTTPError as e:
    print(f"← HTTP {e.code}: {e.read().decode('utf-8', 'ignore')}")
    print("\n❌ Sidecar reachable but the verdict FAILED.")
    print("   Look at the SIDECAR window — it prints the real cause, e.g.:")
    print("     401 / invalid_api_key  -> wrong or admin key; use a standard sk-... key")
    print("     insufficient_quota     -> no credit on the OpenAI account")
    print("     MT5 / copy_rates       -> terminal not logged in")
except Exception as e:
    print(f"✗ {type(e).__name__}: {e}")
    print("\n❌ Could not reach the sidecar at all. Is it running in the other window?")
    sys.exit(1)
