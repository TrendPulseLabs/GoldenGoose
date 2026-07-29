//+------------------------------------------------------------------+
//|                              TrendPulseGoldenGoose_E4.mq5
//|
//|   T R E N D P U L S E   ·   G O L D E N   G O O S E   ·   E4
//|
//|   ONE engine, run alone: PULLBACK — the E4 book from TrendPulse
//|   APEX Pro, which was the strongest single performer across every
//|   tested window. No ensemble, no split: E4 takes the full position,
//|   one magic, one CSV, one Telegram feed.
//|
//|   THIS FILE IS DERIVED FROM TrendPulseAPEX_Pro_v6.mq5, not rewritten.
//|   The engine, the sizing, the ladder, the flip, the VLE and the fuel
//|   gate are the SAME CODE that produced the published results — the
//|   other three engines were deleted, nothing was re-implemented. That
//|   is deliberate: a free tier is only worth anything if it is provably
//|   the engine that was measured.
//|
//|   WHAT IS IN IT
//|     * Fuel gauge, VERIFIED AND FROZEN: vol_ratio >= 1.171 and
//|       ADX < 29.3. Fitted on E4's own trade record. Ships as measured
//|       and is not re-tuned in this build.
//|     * VLE cut, auto-scaled (InpVleUnit=2): the $7 floor tracks the
//|       compounded lot, so it stays at a constant R as the account grows.
//|     * HWM %/R compounding (InpCompoundMode=2), with an optional
//|       drawdown brake (InpHwmDDBrakePct).
//|     * Daily breaker anchored in R (InpDailyMaxLossR = 5.0), so it
//|       scales with the bet instead of tripping harder as risk rises.
//|     * Banked rung ladder + on-rung pyramid, chandelier trail, and the
//|       E4 stop-and-reverse flip.
//|     * Dual symbol: XAUUSD and/or XAUUSDmicro.
//|
//|   Identity: E4  #88000104 (standard) / #88000114 (micro).
//+------------------------------------------------------------------+
#property copyright "TrendPulse GoldenGoose E4"
#property version   "2.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/OrderInfo.mqh>

CTrade trade;
CPositionInfo posInfo;
COrderInfo ordInfo;

#define DIV "━━━━━━━━━━━━━━━━━━"
#define MAX_BOOKS 16

//==================================================================
// INPUTS
//==================================================================
input group "=== GOLDEN GOOSE E4: identity ==="
input long   InpMagic            = 88000104;          // this engine's magic (E4 identity). Dual-symbol: standard 88000104, micro 88000114.
input double InpVleFloorUSD       = 7.0;               // E4's OWN validated VLE floor $, auto-scaled by lot (see InpVleUnit). This is E4's figure; 19 belongs to the other engines.
input bool   InpRiskSplitAcrossBooks = false;         // false = full risk per engine (E4 ran full-risk); true = each risks 1/4
input int    InpCsvFlushSecs     = 60;      // LIVE only: force-write pending trade rows every N seconds (0 = off, batch-only like the tester). Tester always batches at 32 rows, so backtest speed is unaffected.
input string InpRunTag           = "";        // leave BLANK -> file auto-names by run date (Trades_autoYYYYMMDD.csv). Or type a label, e.g. OOS_1yr.
input string InpOOSStartDate     = "";        // OOS split marker: rows dated >= this = "OOS", before = "IS". Format "YYYY.MM.DD". Blank = all rows tagged "-".

input group "=== Identity (base) ==="
input string InpComment          = "TPAPXP";  // base comment; per-book becomes TPAPXP-E1 etc.

input group "=== SYMBOL MODULE (gold: XAUUSD / XAUUSDmicro) ==="
input bool   InpAutoDetectSymbol = true;    // ON (default): trade the symbol the EA is ATTACHED to; the two switches below are ignored. OFF: use the switches.
input bool   InpTradeXAUUSD      = true;     // (used only when AutoDetect=OFF) trade standard XAUUSD
input bool   InpTradeXAUUSDmicro = false;    // (used only when AutoDetect=OFF) trade XAUUSDmicro. Both ON = 8 books, both symbols at once.
input string InpSymXAUUSD        = "XAUUSD";      // exact broker name for standard gold
input string InpSymXAUUSDmicro   = "XAUUSDmicro";  // exact broker name for micro gold

input group "=== Sizing ==="
input bool   InpUseRiskSizing    = true;
input int    InpCompoundMode     = 2;      // InpCompoundMode : 2=HWM %/R (E4 sizing — true high-water-mark compounding). 0=Fixed$/R  1=Fractional  3=Floored  4=Press  5=DAlembert  6=FixedRatio
input double InpRiskPerR_Pct     = 1.0;
input double InpRiskPerR_USD     = 30.0;
input double InpStreakFactor     = 1.25;
input double InpStreakCapMult    = 3.0;
input double InpHwmDDBrakePct    = 0.0;
input int    InpDalStartLevel    = 1;
input int    InpDalMaxLevel      = 5;
input double InpFRDelta          = 300.0;
input double InpMaxLot           = 0.0;   // 0 = use broker max (recommended). If >0: hard cap in the traded symbol's NATIVE lots. 1%/R + daily breaker are the real risk controls.
input double InpBaseLot          = 0.10;

input group "=== Signal 1: TrendPulse Core ==="
input int    InpTP_Fast          = 8;
input int    InpTP_Slow          = 21;
input ENUM_TIMEFRAMES InpTP_TF   = PERIOD_M1;

input group "=== Signal 2: DriftScalper Core ==="
input int    InpDS_Fast          = 12;
input int    InpDS_Slow          = 50;
input double InpMinMaGapPoints   = 5.0;
input bool   InpUseDriftGate     = true;
input int    InpDriftWindow      = 20;
input double InpDriftThreshold   = 0.35;

input group "=== Shared Filters (LEGACY) ==="
input bool   InpUseMtfBias       = false;
input ENUM_TIMEFRAMES InpTrendTF = PERIOD_M5;
input int    InpTrendEma         = 50;
input int    InpAdxPeriod        = 14;
input ENUM_TIMEFRAMES InpAdxTF   = PERIOD_M15;
input int    InpAtrPeriod        = 14;
input bool   InpRequireStrongClose = true;

input group "=== ENTRY SYSTEM v3 ==="
input bool   InpUseBiasGate      = true;
input ENUM_TIMEFRAMES InpBiasTF  = PERIOD_H4;
input int    InpBiasEMA          = 50;
input bool   InpUseBiasSlope     = false;
input int    InpBiasSlopeBars    = 6;
input bool   InpUseChopGate      = true;
input ENUM_TIMEFRAMES InpChopTF  = PERIOD_M15;
input int    InpChopPeriod       = 14;
input double InpChopLow          = 41.0;
input double InpChopHigh         = 59.0;

input group "=== CORE: PULLBACK (Trigger B+C — this engine) ==="
input bool   InpE4_EnableFlip     = true;       // E4 ONLY: stop-and-reverse to Leg 2 after a cut (the GoldenGoose-E4 flip). Other 3 engines never flip.
input bool   InpE4_VleFlipOnCut   = true;       // E4 ONLY: a VLE cut arms the flip (else only SL/disaster cuts flip)
input int    InpE4_MaxLegs        = 2;          // E4 ONLY: max legs in a cycle (2 = one flip)
input int    InpE4_FlipMaxRung    = 3;          // E4 ONLY: flip only if Leg 1 closed at/below this rung
input bool   InpTrigCross        = false;       // E4 Trigger A: dual-EMA cross (APEX baseline default = OFF)
input bool   InpTrigPullback     = true;        // E4 Trigger B: pullback-to-EMA reclaim (the primary E4 entry)
input ENUM_TIMEFRAMES InpPullbackTF = PERIOD_M15;// pullback timeframe
input int    InpPullbackEMA      = 20;          // pullback fast EMA period
input bool   InpTrigBreakout     = true;        // E4 Trigger C: structural breakout (used in COILING regime)
input bool   InpBreakoutInTrend  = false;       // also allow breakout while TRENDING
input ENUM_TIMEFRAMES InpBreakoutTF = PERIOD_M15;// breakout structure timeframe
input int    InpBreakoutLookback = 12;          // bars for the structural high/low
input double InpBreakoutBufferPts= 0.0;         // buffer beyond structure (points)

input group "=== Risk Unit & Legs ==="
input ENUM_TIMEFRAMES InpR_TF    = PERIOD_M15;
input double InpR_ATR_Mult       = 2.0;
input double InpLeg1_DisasterR   = 1.0;
input double InpLeg2_DisasterR   = 0.5;      // E4 flip-leg disaster SL (only used by E4 Leg 2; inert for the other 3)
input bool   InpEnableLeg1       = true;

input group "=== Daily Direction Cap (per book) ==="
input int    InpMaxBuysPerDay    = 5;
input int    InpMaxSellsPerDay   = 5;

input group "=== 5-Rung Partial Ladder ==="
input double InpR1_Arm = 0.5;  input double InpR1_ClosePct = 25.0;
input double InpR2_Arm = 1.0;  input double InpR2_ClosePct = 25.0;
input double InpR3_Arm = 1.5;  input double InpR3_ClosePct = 20.0;
input double InpR4_Arm = 2.0;  input double InpR4_ClosePct = 15.0;
input double InpR5_Arm = 2.5;  input double InpR5_ClosePct = 10.0;

input group "=== Adaptive Chandelier ==="
input double InpK_Rung0 = 2.0;
input double InpK_Rung1 = 1.5;
input double InpK_Rung2 = 1.1;
input double InpK_Rung3 = 0.8;
input double InpK_Rung4 = 0.6;
input double InpK_Rung5 = 0.5;

input group "=== Governance ==="
input int    InpMaxHoldHours     = 12;
input double InpDailyMaxLossUSD  = 150.0;   // LEGACY fixed $ per book (realized + floating). Used only when InpDailyMaxLossR = 0.
input double InpDailyMaxLossR    = 5.0;     // Daily breaker in R. 0 = use the fixed $ above.
                                            //   $150 was set when 1%/R on a $3,000 account made R = $30,
                                            //   i.e. the breaker was exactly 5.0R. A FIXED $ does not
                                            //   follow the bet: raise InpRiskPerR_Pct and the breaker
                                            //   stays put, so it trips on ever-fewer trades and halts
                                            //   engines mid-session (measured at 5%: E4 positions fell
                                            //   205 -> 130, total deals 820 -> 511). Expressed in R it
                                            //   tracks whatever the book is actually risking, on either
                                            //   symbol, under any compounding mode — and because it reads
                                            //   RiskUSDForMode() it also inherits InpHwmDDBrakePct
                                            //   automatically: if the DD brake cuts the bet, the breaker
                                            //   tightens with it.

input group "=== FUEL GAUGE (derived Jan-Jul 2026 — verified, FROZEN) ==="
//  The entry filter. A signal only becomes a trade when the bar's fuel is inside
//  this engine's derived box. The box came from expectancy-by-band plus a
//  chronological half/quarter stability check on the ungated run:
//     vol_ratio >= 1.171  AND  adx < 29.3     (306 trades, $1240, PF 1.80)
//  That is the highest-confidence box of the set, and it is why this engine
//  trades when it trades. It ships exactly as measured and is NOT re-tuned in
//  this build. Set InpFuelGateOn=false to reproduce the original ungated run.
input bool   InpFuelGateOn       = true;    // master switch for the fuel gate
input bool   InpFuelGateLog      = true;    // print each blocked signal to the journal
input bool   InpE4_GateOn        = true;    // vol_ratio floor + ADX ceiling
input double InpE4_MinVolRatio   = 1.171;
input double InpE4_MaxAdx        = 29.3;

input group "=== VLE: Validated Loss Engine  (OFF — derivation showed it costs money) ==="
//  Position-level sweep on the gated populations: NO floor beat the un-floored
//  baseline. The live floors were actively harmful — E4's $7 floor cut 123 of
//  174 trades and killed 45% of its winners ($1252 -> $405); E3's $19 took
//  $481 -> $87. Reason: the 1.0R disaster stop + chandelier already manage the
//  loss side, so VLE was a second, tighter cut on top. Left in the code, OFF.
input bool   InpVleEnabled       = true;
input int    InpVleMode          = 0;       // 0=hard cut, 1=time-gated
input int    InpVleMinMinutes    = 60;
input bool   InpVlePhantom       = false;
input int    InpVleUnit          = 2;       // InpVleUnit : 2=auto-scaled $ (E4 default — floor tracks lot, survives compounding). 0=fixed $  1=R-equiv
input double InpVleBaseLot       = 0.01;    // InpVleBaseLot : the ACTUAL entry lot the floor $ is calibrated at. At 1%/R on $3,000, entry lot = 0.01 (broker min). Auto-scale reference.

input group "=== Pyramiding ==="
input bool   InpPyrEnabled       = true;
input int    InpPyrTrigMode      = 0;
input int    InpPyrAddAtRung     = 2;
input int    InpPyrMaxTiers      = 3;
input double InpPyrFirstMult     = 0.5;
input double InpPyrSizeMult      = 0.5;
input double InpPyrMaxTotalMult  = 1.0;
input int    InpPyrBurstRung     = 3;
input int    InpPyrBurstSecs     = 1200;
input double InpPyrMomAdxMin     = 30.0;

input group "=== Friday Weekend Protection (Broker Server Time) ==="
input bool   InpUseFridayCutoff       = true;
input int    InpFridayEntryCutoffHour = 16;
input int    InpFridayForceCloseHour  = 21;
input int    InpFridayForceCloseMin   = 30;

input group "=== Phantom Logging ==="
input bool   InpPhantomEnable    = true;
input double InpPh1_Mult         = 1.5;
input double InpPh2_Mult         = 2.0;
input double InpPh3_Mult         = 2.5;

input group "=== Telegram (one channel for the whole ensemble) ==="
input bool   InpTgEnable         = true;
input string InpTgToken          = "";
input string InpTgChatID         = "";

input group "=== AI SEMANTIC GATEKEEPER (fail-CLOSED) ==="
//  OFF BY DEFAULT so Strategy-Tester verification reproduces the published
//  numbers exactly. Verify the baseline first, THEN flip InpUseAIGate=true to
//  arm the layer for live trading. When ON it is MANDATORY and fail-closed:
//  if the sidecar is unreachable the trade is SKIPPED, never taken blind — the
//  AI layer is required to trade live. The gate can only ever REMOVE trades,
//  never add, so it cannot change the mechanics — only make live more selective.
//  NOTE for open-source users: the gate needs the Python sidecar + an API key.
//  With it OFF (default) GoldenGoose trades the pure verified baseline and needs
//  none of that. See the README / User Guide before arming it.
input bool   InpUseAIGate        = false;                     // master switch. OFF (default) = trades exactly like the verified baseline. ON = AI layer armed, mandatory to trade.
input string InpAIGateURL        = "http://127.0.0.1:8765/";  // Python sidecar endpoint. MUST be whitelisted in Tools>Options>Expert Advisors>Allow WebRequest.
input int    InpAITimeoutMs      = 8000;                      // WebRequest timeout (ms). On timeout -> FAIL -> skip trade (fail-closed).
input bool   InpAIGateTgOnValid  = false;                     // also push VALID (allow) decisions to Telegram. REJECT/FAIL always alert regardless.

//==================================================================
// SHARED GLOBALS  (indicators, market spec, per-bar caches)
//==================================================================
double g_point, g_tickValue, g_tickSize;   // spec of the ATTACHED chart symbol (context helpers)

// ---- resolved trading symbols (1 in auto-detect, up to 2 in dual mode) ----
#define MAX_SYMS 2
struct SymSpec {
   string   name;
   double   point, tickValue, tickSize, minLot, maxLot, lotStep;
   int      digits, stopsLevel;
   double   contractRatio;   // relative to XAUUSD standard (micro=0.1) — scales the VLE $ floors
   // per-symbol indicator handles
   int hEmaF1,hEmaS1,hEmaF2,hEmaS2,hTrend,hAdx,hAtr,hBias,hPullEma;
   double chopVal; datetime chopBar;   // per-symbol choppiness cache
};
SymSpec  g_sym[MAX_SYMS];
int      g_nSyms=0;

int      g_nBooks=0;       // resolved at init
datetime g_runStart=0;     // captured at init; used to auto-name the trade CSV when tag is blank

// Trade log: rows are buffered in memory as trades close (inside the trade
// transaction handler, where direct file writes don't persist in the tester),
// then flushed to disk from OnTick — the same context Phantom logging uses,
// which IS reliable. Incremental: survives an aborted run, and the journal
// prints confirmation on the first write so you can SEE the version is live.
string   g_tradeBuf[];
datetime g_lastCsvFlush=0;   // live CSV timer (see FlushPendingTrades)
datetime g_oosStart=0;   // parsed InpOOSStartDate (0 = unset)
int      g_tradeWritten=0;   // how many buffered rows are already on disk
int      g_fuelBlocked=0;    // FUEL: signals rejected by the per-engine fuel gate

//==================================================================
// SHARED HELPERS
//==================================================================
double NormPrice(double p) { return NormalizeDouble(p,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS)); }
double SpreadPts()         { return (SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID))/g_point; }

double NormalizeLot(double lot) {
   double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(InpMaxLot>0 && InpMaxLot<mx) mx=InpMaxLot;
   double st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(st<=0) st=0.01;
   lot=MathMax(mn,MathMin(mx,lot));
   lot=MathRound(lot/st)*st;
   return NormalizeDouble(lot,2);
}
double PnlUSD(int dir,double entry,double price,double lot) {
   double diff = (dir>0) ? (price-entry) : (entry-price);
   return diff * lot * g_tickValue / g_tickSize;
}

// ---- symbol-aware overloads (per-book money math) ----
double PnlUSDs(SymSpec &sy,int dir,double entry,double price,double lot) {
   double diff = (dir>0) ? (price-entry) : (entry-price);
   return (sy.tickSize>0) ? diff * lot * sy.tickValue / sy.tickSize : 0.0;
}
double NormalizeLots(SymSpec &sy,double lot) {
   // Pure per-symbol sizing: clamp to the broker's own min/max for THIS symbol.
   // InpMaxLot (if >0) caps in this symbol's NATIVE lots. Sizing is 1%/R of whatever
   // account the EA runs on, so each symbol self-scales to its own equity. Micro's
   // fine min-lot is what lets small accounts hit a true 1%.
   double mn=sy.minLot, mx=sy.maxLot;
   if(InpMaxLot>0 && InpMaxLot<mx) mx=InpMaxLot;
   double st=sy.lotStep; if(st<=0) st=0.01;
   lot=MathMax(mn,MathMin(mx,lot));
   lot=MathRound(lot/st)*st;
   int dp=(st>=0.1)?1:2;   // decimals match the lot step
   return NormalizeDouble(lot,dp);
}
double NormPriceS(SymSpec &sy,double p){ return NormalizeDouble(p,sy.digits); }
double KForRung(int rung) {
   switch(rung) {
      case 0:  return InpK_Rung0; case 1: return InpK_Rung1; case 2: return InpK_Rung2;
      case 3:  return InpK_Rung3; case 4: return InpK_Rung4; default: return InpK_Rung5;
   }
}
void GetBrokerTime(int &dow,int &hour,int &minute) {
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   dow=dt.day_of_week; hour=dt.hour; minute=dt.min;
}
bool IsFridayEntryBlocked() {
   if(!InpUseFridayCutoff) return false;
   int dow,h,m; GetBrokerTime(dow,h,m);
   return (dow==5 && h>=InpFridayEntryCutoffHour);
}

//==================================================================
// TELEGRAM  (one channel, identity prefixed by each book)
//==================================================================
string UrlEncode(string s) {
   string o=""; uchar b[]; int n=StringToCharArray(s,b,0,WHOLE_ARRAY,CP_UTF8);
   for(int i=0;i<n;i++){
      uchar c=b[i]; if(c==0) continue;
      if((c>='A'&&c<='Z')||(c>='a'&&c<='z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='.'||c=='~') o+=CharToString(c);
      else o+=StringFormat("%%%02X",c);
   }
   return o;
}
bool SendTelegram(string text) {
   if(!InpTgEnable || InpTgToken=="" || InpTgChatID=="") return false;
   string url="https://api.telegram.org/bot"+InpTgToken+"/sendMessage";
   string p="chat_id="+InpTgChatID+"&text="+UrlEncode(text);
   char data[]; StringToCharArray(p,data,0,StringLen(p),CP_UTF8);
   char res[]; string rh;
   int r=WebRequest("POST",url,"Content-Type: application/x-www-form-urlencoded\r\n",5000,data,res,rh);
   return (r!=-1);
}
void AlertLog(string msg) { Print(msg); SendTelegram(msg); }

//==================================================================
// AI SEMANTIC GATEKEEPER — transport (ported verbatim from agentic v5)
// POSTs {"symbol","direction"} to the sidecar; returns 1 VALID / 0 REJECT /
// -1 FAIL. Any non-200, transport error, or unparseable body is -1, which the
// caller treats as fail-closed. The sidecar is symbol-agnostic (gold + forex).
//==================================================================
int AIGateQuery(string symbol,int dir,string &reason){
   reason="";
   string body=StringFormat("{\"symbol\":\"%s\",\"direction\":%d}",symbol,dir);
   char post[]; StringToCharArray(body,post,0,StringLen(body),CP_UTF8);
   char res[];  string rh;
   ResetLastError();
   int code=WebRequest("POST",InpAIGateURL,"Content-Type: application/json\r\n",InpAITimeoutMs,post,res,rh);
   if(code==-1){ reason="WebRequest err "+IntegerToString(GetLastError())+" (sidecar offline or URL not whitelisted?)"; return -1; }
   if(code!=200){ reason="HTTP "+IntegerToString(code); return -1; }
   string resp=CharArrayToString(res,0,WHOLE_ARRAY,CP_UTF8);
   StringTrimLeft(resp); StringTrimRight(resp);
   reason=resp;
   if(StringFind(resp,"REJECT")>=0) return 0;
   if(StringFind(resp,"VALID") >=0) return 1;
   return -1;
}

//==================================================================
// SHARED SIGNAL LOGIC  (identical across books -> evaluated once/bar)
//==================================================================
double DriftStrength(SymSpec &sy) {
   int n=InpDriftWindow;
   if(Bars(sy.name,PERIOD_M1)<n+3) return 0.0;
   double r[]; ArrayResize(r,n);
   for(int i=0;i<n;i++){
      double c1=iClose(sy.name,PERIOD_M1,i+1), c2=iClose(sy.name,PERIOD_M1,i+2);
      if(c1<=0.0||c2<=0.0) return 0.0;
      r[i]=MathLog(c1)-MathLog(c2);
   }
   double m=0; for(int i=0;i<n;i++) m+=r[i]; m/=n;
   double sd=0; for(int i=0;i<n;i++) sd+=(r[i]-m)*(r[i]-m); sd=MathSqrt(sd/n);
   return (sd>0.0)?MathAbs(m/sd):0.0;
}
int Signal1_TrendPulse(SymSpec &sy) {
   double eF[1],eS[1],tr[1];
   if(CopyBuffer(sy.hEmaF1,0,1,1,eF)<1) return 0;
   if(CopyBuffer(sy.hEmaS1,0,1,1,eS)<1) return 0;
   double m5Close=iClose(sy.name,InpTrendTF,1);
   if(InpUseMtfBias && CopyBuffer(sy.hTrend,0,1,1,tr)<1) return 0;
   double o1=iOpen(sy.name,InpTP_TF,1), c1=iClose(sy.name,InpTP_TF,1);
   double l1=iLow(sy.name,InpTP_TF,1), h1=iHigh(sy.name,InpTP_TF,1);
   double rng=MathMax(h1-l1,sy.point);
   bool biasUp=(!InpUseMtfBias)||(m5Close>tr[0]);
   bool biasDn=(!InpUseMtfBias)||(m5Close<tr[0]);
   bool strongUp=(!InpRequireStrongClose)||((c1-l1)/rng>=0.66);
   bool strongDn=(!InpRequireStrongClose)||((h1-c1)/rng>=0.66);
   if(biasUp && eF[0]>eS[0] && l1<=eF[0] && c1>eF[0] && c1>o1 && strongUp) return +1;
   if(biasDn && eF[0]<eS[0] && h1>=eF[0] && c1<eF[0] && c1<o1 && strongDn) return -1;
   return 0;
}
int Signal2_DriftScalper(SymSpec &sy) {
   double fB[1],sB[1];
   if(CopyBuffer(sy.hEmaF2,0,1,1,fB)<1) return 0;
   if(CopyBuffer(sy.hEmaS2,0,1,1,sB)<1) return 0;
   int maDir=(fB[0]>sB[0])?+1:((fB[0]<sB[0])?-1:0);
   if(maDir==0) return 0;
   double gapPts=MathAbs(fB[0]-sB[0])/sy.point;
   if(gapPts<InpMinMaGapPoints) return 0;
   if(InpUseDriftGate && DriftStrength(sy)<InpDriftThreshold) return 0;
   if(InpUseMtfBias){
      double tr[1]; if(CopyBuffer(sy.hTrend,0,1,1,tr)<1) return 0;
      double m5Close=iClose(sy.name,InpTrendTF,1);
      if(maDir>0 && !(m5Close>tr[0])) return 0;
      if(maDir<0 && !(m5Close<tr[0])) return 0;
   }
   if(InpRequireStrongClose){
      double o1=iOpen(sy.name,PERIOD_M1,1), c1=iClose(sy.name,PERIOD_M1,1);
      double l1=iLow(sy.name,PERIOD_M1,1), h1=iHigh(sy.name,PERIOD_M1,1);
      double rng=MathMax(h1-l1,sy.point);
      if(maDir>0 && !((c1-l1)/rng>=0.66 && c1>o1)) return 0;
      if(maDir<0 && !((h1-c1)/rng>=0.66 && c1<o1)) return 0;
   }
   return maDir;
}
double ChoppinessIndex(SymSpec &sy) {
   int n=InpChopPeriod; if(n<2) n=2;
   datetime bt=iTime(sy.name,InpChopTF,0);
   if(bt==sy.chopBar) return sy.chopVal;
   double hi[],lo[],cl[];
   ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true); ArraySetAsSeries(cl,true);
   if(CopyHigh (sy.name,InpChopTF,1,n+1,hi)<n+1) return sy.chopVal;
   if(CopyLow  (sy.name,InpChopTF,1,n+1,lo)<n+1) return sy.chopVal;
   if(CopyClose(sy.name,InpChopTF,1,n+1,cl)<n+1) return sy.chopVal;
   double sumTR=0.0, maxH=-DBL_MAX, minL=DBL_MAX;
   for(int i=0;i<n;i++){
      double pc=cl[i+1];
      double tr=MathMax(hi[i]-lo[i],MathMax(MathAbs(hi[i]-pc),MathAbs(lo[i]-pc)));
      sumTR+=tr;
      if(hi[i]>maxH) maxH=hi[i];
      if(lo[i]<minL) minL=lo[i];
   }
   double range=maxH-minL;
   if(range<=0.0 || sumTR<=0.0) return sy.chopVal;
   double chop=100.0*MathLog10(sumTR/range)/MathLog10((double)n);
   sy.chopBar=bt; sy.chopVal=chop;
   return chop;
}
int ChopRegime(SymSpec &sy) {
   if(!InpUseChopGate) return 1;
   double c=ChoppinessIndex(sy);
   if(c<InpChopLow)  return 1;
   if(c>InpChopHigh) return 2;
   return 0;
}
int BiasGateDir(SymSpec &sy) {
   double ema1[1]; if(CopyBuffer(sy.hBias,0,1,1,ema1)<1) return 0;
   double close1=iClose(sy.name,InpBiasTF,1);
   int dir=(close1>ema1[0])?+1:((close1<ema1[0])?-1:0);
   if(dir==0) return 0;
   if(InpUseBiasSlope){
      double emaP[1]; if(CopyBuffer(sy.hBias,0,1+InpBiasSlopeBars,1,emaP)<1) return 0;
      double slope=ema1[0]-emaP[0];
      if(dir>0 && slope<=0) return 0;
      if(dir<0 && slope>=0) return 0;
   }
   return dir;
}
string SizingDesc() {
   if(!InpUseRiskSizing) return "Lot "+DoubleToString(InpBaseLot,2)+"  (fixed lot)";
   string nm[7]={"Fixed $","Fractional %bal","HWM %peak","Floored %bal","Press streak","D'Alembert","FixedRatio"};
   int md=(InpCompoundMode>=0 && InpCompoundMode<=6)?InpCompoundMode:0;
   if(md==0) return "Risk  $"+DoubleToString(InpRiskPerR_USD,0)+" / R   ["+nm[0]+"]";
   if(md==5) return "Risk  $"+DoubleToString(InpRiskPerR_USD,0)+" x level   ["+nm[5]+"]";
   if(md==6) return "Risk  $"+DoubleToString(InpRiskPerR_USD,0)+" x N(Delta $"+DoubleToString(InpFRDelta,0)+")   ["+nm[6]+"]";
   return "Risk  "+DoubleToString(InpRiskPerR_Pct,1)+"% / R   ["+nm[md]+"]";
}
string PyrDesc(){
   if(!InpPyrEnabled) return "OFF (baseline rails)";
   string md[4]={"on-rung","burst","momentum","rung+burst"};
   int m=(InpPyrTrigMode>=0 && InpPyrTrigMode<=3)?InpPyrTrigMode:0;
   string s="["+md[m]+"]  maxTiers "+IntegerToString(InpPyrMaxTiers)+"  size "+DoubleToString(InpPyrFirstMult,2)+"x*"+DoubleToString(InpPyrSizeMult,2);
   return s;
}

//==================================================================
//  CBOOK  —  one full APEX engine, state namespaced per book
//==================================================================
struct LegState {
   ulong  ticket; int dir; int leg;
   double entry; double originalLot; double currentLot;
   int    rung; double peak; double R_price;
   datetime openTime; double mfe; double mae;
};
struct PhantomState {
   bool active; int dir; double entry; double lot;
   double sl[3], tp[3]; datetime openTime; double mfe, mae; int result[3];
};

int CrossTrigger(SymSpec &sy) {
   int s1=Signal1_TrendPulse(sy);
   int s2=Signal2_DriftScalper(sy);
   if(s1!=0 && s1==s2) return s1;
   return 0;
}
int PullbackTrigger(SymSpec &sy,int biasDir) {
   double ema[1]; if(CopyBuffer(sy.hPullEma,0,1,1,ema)<1) return 0;
   double o1=iOpen(sy.name,InpPullbackTF,1), c1=iClose(sy.name,InpPullbackTF,1);
   double l1=iLow (sy.name,InpPullbackTF,1), h1=iHigh(sy.name,InpPullbackTF,1);
   bool wantLong =(biasDir==0||biasDir>0);
   bool wantShort=(biasDir==0||biasDir<0);
   if(wantLong  && l1<=ema[0] && c1>ema[0] && c1>o1) return +1;
   if(wantShort && h1>=ema[0] && c1<ema[0] && c1<o1) return -1;
   return 0;
}
int BreakoutTrigger(SymSpec &sy,int biasDir) {
   int lb=InpBreakoutLookback; if(lb<2) lb=2;
   double hi[],lo[];
   ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true);
   if(CopyHigh(sy.name,InpBreakoutTF,1,lb,hi)<lb) return 0;
   if(CopyLow (sy.name,InpBreakoutTF,1,lb,lo)<lb) return 0;
   double hh=hi[0], ll=lo[0];
   for(int i=1;i<lb;i++){ if(hi[i]>hh) hh=hi[i]; if(lo[i]<ll) ll=lo[i]; }
   double buf=InpBreakoutBufferPts*sy.point;
   double ask=SymbolInfoDouble(sy.name,SYMBOL_ASK);
   double bid=SymbolInfoDouble(sy.name,SYMBOL_BID);
   if((biasDir==0||biasDir>0) && ask>hh+buf) return +1;
   if((biasDir==0||biasDir<0) && bid<ll-buf) return -1;
   return 0;
}

class CBook {
public:
   // --- identity / config (the only things that differ between books) ---
   string   m_id;          // "E1","E2",...
   long     m_magic;       // base + index
   double   m_vleFloor;    // VLE cut $
   string   m_comment;     // e.g. "TPGG-E1"
   double   m_riskMult;    // 1.0, or 1/N when InpRiskSplitAcrossBooks
   int      m_symIdx;      // which resolved symbol (index into g_sym[]) this book trades

   // --- engine state (was global in APEX) ---
   datetime m_lastSignalBar;
   double   m_dailyRealized;
   // per-engine run totals (for the Journal summary)
   double   m_cumNet, m_cumGP, m_cumGL, m_peakNet, m_maxDD;
   int      m_closes, m_wins, m_losses;
   datetime m_pnlDay;
   bool     m_haltedToday;
   int      m_buysToday, m_sellsToday;
   double   m_ctxDrift, m_ctxAdx, m_ctxSlope, m_ctxGap, m_ctxSpread;
   double   m_ctxAtrExp, m_ctxSwing, m_ctxVol;      // FUEL: added for fuel-gauge research
   bool     m_cycleActive;
   double   m_hwm; int m_winStreak;
   // --- E4-only stop-and-reverse (Leg 2). m_flipEnabled is false for E1/E2/E3,
   //     so every branch below is inert for them — zero behavioural change. ---
   bool     m_flipEnabled;          // set true ONLY for the E4 engine at Init
   int      m_cycleLegs;            // legs opened this cycle (1, or 2 after a flip)
   bool     m_pendingFlip; int m_flipDir;   // queued reversal for next tick
   bool     m_noFlip;               // forced-close guard (breaker/friday/time-stop) suppresses a flip
   bool     m_enabled;              // per-engine on/off
   int      m_core;                 // always 3 (PULLBACK) in this single-engine build
   string   m_coreName;             // engine name for reporting
   int      m_dalLevel; double m_startBal;
   ulong    m_pyrPosid[8]; int m_pyrOpen, m_pyrAdded, m_pyrLastRung;
   datetime m_rungReach[6];
   LegState m_leg;
   datetime m_vleCross15, m_vleCross20; bool m_vleCutThisLeg;
   PhantomState m_ph[50];

   void   Init(string id,long magic,double vleFloor,double riskMult,int core,bool enabled,int symIdx);
   void   ResetLeg();
   void   ResetPyramidState();
   double RiskUSDForMode();
   double DailyMaxLossUsd();
   double VleFloorEffFor(double lot);
   double BaseLotForR(double R_price);
   void   Say(string msg){ AlertLog("["+m_id+" #"+IntegerToString((int)m_magic)+"] "+msg); }
   void   Banner();

   bool   IsPyrTier(ulong posid);
   bool   PyrBurstReady();
   double PyrCumVol(int n,double primOrigLot);
   bool   PyrTrigger(double curAdx);
   void   AddPyramidTier(int dir,double primOrigLot,double targetSL);
   void   SyncPyramidStops(double targetSL,int dir,double bid,double ask);
   void   CloseAllPyramidTiers();

   void   OpenLeg(int dir,int leg=1);
   void   ManagePositions();
   void   CheckFloatingDD();
   void   CheckFridayForceClose();
   void   UpdatePhantoms();
   void   RegisterPhantom(int dir,double entry,double lot,double atrVal);
   void   LogClosedDeal(double exitPrice,double vol,double profit,string legTag,string reason);
   void   LogTierClose(double exitPrice,double vol,double profit,int tierDir);
   void   PhantomVleLog(int leg,int dir,double finalPnl,int rung);

   int    CorePULLBACK();
   int    EvaluateEntryBook();
   bool   AIGateAllows(int dir);   // fail-CLOSED AI gate: true ONLY on explicit VALID
   bool   FuelGateAllows();          // FUEL: per-engine entry box (see InpFuelGateOn)
   void   OnTickBook();
   void   OnDealOut(const MqlTradeTransaction& trans);
};

CBook books[MAX_BOOKS];
// forward declarations — the startup banners call these before they are defined
string BreakerDesc();
string SymLine();
string MagicLine();

//------------------------------------------------------------------
void CBook::Init(string id,long magic,double vleFloor,double riskMult,int core,bool enabled,int symIdx){
   m_symIdx=symIdx;
   m_id=id; m_magic=magic; m_vleFloor=vleFloor; m_riskMult=riskMult;
   m_core=core; m_enabled=enabled;
   m_coreName="PULLBACK";
   m_comment=InpComment+"-"+id;
   m_lastSignalBar=0; m_dailyRealized=0; m_haltedToday=false;
   m_cumNet=0; m_cumGP=0; m_cumGL=0; m_peakNet=0; m_maxDD=0; m_closes=0; m_wins=0; m_losses=0;
   m_buysToday=0; m_sellsToday=0;
   m_ctxDrift=0; m_ctxAdx=0; m_ctxSlope=0; m_ctxGap=0; m_ctxSpread=0;
   m_ctxAtrExp=0; m_ctxSwing=0; m_ctxVol=0;   // FUEL
   m_cycleActive=false;
   m_flipEnabled=(core==3 && InpE4_EnableFlip);   // E4 PULLBACK only
   m_cycleLegs=0; m_pendingFlip=false; m_flipDir=0; m_noFlip=false;
   m_winStreak=0;
   m_dalLevel=(InpDalStartLevel>=1?InpDalStartLevel:1);
   m_hwm=AccountInfoDouble(ACCOUNT_BALANCE);
   m_startBal=AccountInfoDouble(ACCOUNT_BALANCE);
   ResetLeg(); ResetPyramidState();
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt); dt.hour=0; dt.min=0; dt.sec=0;
   m_pnlDay=StructToTime(dt);
   for(int i=0;i<50;i++) m_ph[i].active=false;
}
void CBook::ResetLeg(){
   m_leg.ticket=0; m_leg.dir=0; m_leg.leg=0; m_leg.entry=0; m_leg.originalLot=0;
   m_leg.currentLot=0; m_leg.rung=0; m_leg.peak=0; m_leg.R_price=0; m_leg.openTime=0;
   m_leg.mfe=0; m_leg.mae=0;
}
void CBook::ResetPyramidState(){
   m_pyrOpen=0; m_pyrAdded=0; m_pyrLastRung=0;
   for(int i=0;i<8;i++) m_pyrPosid[i]=0;
   for(int i=0;i<6;i++) m_rungReach[i]=0;
}
double CBook::RiskUSDForMode(){
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double r;
   switch(InpCompoundMode){
      case 1: r=bal*InpRiskPerR_Pct/100.0; break;
      case 2: {
         double peak=(m_hwm>0?m_hwm:bal);
         if(InpHwmDDBrakePct>0 && bal < peak*(1.0-InpHwmDDBrakePct/100.0)) peak=bal;
         r=peak*InpRiskPerR_Pct/100.0; break;
      }
      case 3: r=MathMax(bal*InpRiskPerR_Pct/100.0, InpRiskPerR_USD); break;
      case 4: r=InpRiskPerR_USD*MathMin(InpStreakCapMult,MathPow(InpStreakFactor,(double)m_winStreak)); break;
      case 5: { int lvl=m_dalLevel; if(lvl<1) lvl=1; if(lvl>InpDalMaxLevel) lvl=InpDalMaxLevel; r=InpRiskPerR_USD*(double)lvl; break; }
      case 6: {
         double prof=bal-(m_startBal>0?m_startBal:bal);
         double N=1.0;
         if(InpFRDelta>0 && prof>0) N=0.5+MathSqrt(0.25+2.0*prof/InpFRDelta);
         if(N<1.0) N=1.0;
         r=InpRiskPerR_USD*N; break;
      }
      default: r=InpRiskPerR_USD; break;
   }
   return r*m_riskMult;   // 1.0 (pure spec) or 1/N (aggregate-risk-matched)
}
double CBook::BaseLotForR(double R_price){
   if(!InpUseRiskSizing) return InpBaseLot*m_riskMult;
   double moneyPerPricePerLot = (g_sym[m_symIdx].tickSize>0) ? g_sym[m_symIdx].tickValue/g_sym[m_symIdx].tickSize : 0.0;
   if(moneyPerPricePerLot<=0 || R_price<=0) return InpBaseLot*m_riskMult;
   double riskUSD = RiskUSDForMode();
   if(riskUSD<=0) return InpBaseLot*m_riskMult;
   return riskUSD / (R_price * moneyPerPricePerLot);
}
// The EFFECTIVE VLE floor in $ for a given entry lot — the SAME formula
// ManagePositions() uses to decide the cut:
//        base $  x  (lot / InpVleBaseLot)  x  contractRatio
// The cycle cards used to print the raw base ($7), which is NOT what cuts. On a
// 0.03 lot the real floor is $21, and on 2.70 micro lots it is $18.90 — so a
// trade showing MAE -$14.85 was never near its floor even though the card said
// "$7". Printing the base was actively misleading; this prints both.
double CBook::VleFloorEffFor(double lot){
   double eff=m_vleFloor;
   if(InpVleUnit!=0 && InpVleBaseLot>0.0 && lot>0.0) eff = m_vleFloor*(lot/InpVleBaseLot);
   return eff*g_sym[m_symIdx].contractRatio;
}

void CBook::Banner(){
   Say("🟡 online — VLE floor $"+DoubleToString(VleFloorEffFor(g_sym[m_symIdx].minLot),2)+
       " @ min lot  (base $"+DoubleToString(m_vleFloor,0)+" @ "+DoubleToString(InpVleBaseLot,2)+" lot)"+
       "  ·  "+SizingDesc()+(m_riskMult<1.0?("  ·  risk×"+DoubleToString(m_riskMult,2)):""));
}

//------------------------------------------------------------------ pyramiding
bool CBook::IsPyrTier(ulong posid){
   for(int i=0;i<m_pyrOpen;i++) if(m_pyrPosid[i]==posid) return true;
   return false;
}
bool CBook::PyrBurstReady(){
   int br=InpPyrBurstRung; if(br<1) br=1; if(br>5) br=5;
   if(m_rungReach[br]==0) return false;
   return ((long)(m_rungReach[br]-m_leg.openTime) <= (long)InpPyrBurstSecs);
}
double CBook::PyrCumVol(int n,double primOrigLot){
   double v=0, m=InpPyrFirstMult;
   for(int k=0;k<n;k++){ v+=primOrigLot*m; m*=InpPyrSizeMult; }
   return v;
}
bool CBook::PyrTrigger(double curAdx){
   if(!InpPyrEnabled) return false;
   if(m_leg.dir==0 || m_leg.ticket==0) return false;
   if(m_pyrAdded>=InpPyrMaxTiers) return false;
   if(m_leg.rung<=m_pyrLastRung) return false;
   bool rungOK=(m_leg.rung>=InpPyrAddAtRung);
   switch(InpPyrTrigMode){
      case 0: return rungOK;
      case 1: return PyrBurstReady();
      case 2: return (rungOK && curAdx>=InpPyrMomAdxMin);
      case 3: return (rungOK && PyrBurstReady());
   }
   return false;
}
void CBook::AddPyramidTier(int dir,double primOrigLot,double targetSL){
   if(m_pyrAdded>=InpPyrMaxTiers || m_pyrOpen>=8) return;
   double prospective=PyrCumVol(m_pyrAdded+1,primOrigLot);
   if(prospective > primOrigLot*InpPyrMaxTotalMult + 1e-9) return;
   double mult=InpPyrFirstMult; for(int k=0;k<m_pyrAdded;k++) mult*=InpPyrSizeMult;
   double lot=NormalizeLots(g_sym[m_symIdx],primOrigLot*mult);
   double mn=SymbolInfoDouble(g_sym[m_symIdx].name,SYMBOL_VOLUME_MIN);
   if(lot<mn) return;
   double ask=SymbolInfoDouble(g_sym[m_symIdx].name,SYMBOL_ASK);
   double bid=SymbolInfoDouble(g_sym[m_symIdx].name,SYMBOL_BID);
   string cmt=m_comment+"|PYR";
   trade.SetExpertMagicNumber(m_magic);
   trade.SetTypeFillingBySymbol(g_sym[m_symIdx].name);
   bool ok=(dir>0)?trade.Buy(lot,g_sym[m_symIdx].name,ask,0,0,cmt):trade.Sell(lot,g_sym[m_symIdx].name,bid,0,0,cmt);
   if(!ok){ Print(m_id," AddPyramidTier failed: ",trade.ResultRetcode()); return; }
   ulong pid=trade.ResultOrder();
   if(m_pyrOpen<8){ m_pyrPosid[m_pyrOpen]=pid; m_pyrOpen++; }
   m_pyrAdded++; m_pyrLastRung=m_leg.rung;
   double stopsLvl=(double)SymbolInfoInteger(g_sym[m_symIdx].name,SYMBOL_TRADE_STOPS_LEVEL)*g_sym[m_symIdx].point;
   bool legal=(dir>0)?(targetSL>0 && targetSL<bid-stopsLvl):(targetSL>0 && targetSL>ask+stopsLvl);
   if(legal && PositionSelectByTicket(pid)) trade.PositionModify(pid,NormPriceS(g_sym[m_symIdx],targetSL),0);
   Say("⛏ PYRAMID TIER "+IntegerToString(m_pyrAdded)+"  ·  "+(dir>0?"BUY":"SELL")+
       "  add "+DoubleToString(lot,2)+"  (rung "+IntegerToString(m_leg.rung)+")");
}
void CBook::SyncPyramidStops(double targetSL,int dir,double bid,double ask){
   if(m_pyrOpen<=0 || targetSL<=0) return;
   double stopsLvl=(double)SymbolInfoInteger(g_sym[m_symIdx].name,SYMBOL_TRADE_STOPS_LEVEL)*g_sym[m_symIdx].point;
   double tSL=NormPriceS(g_sym[m_symIdx],targetSL);
   for(int i=0;i<m_pyrOpen;i++){
      ulong pid=m_pyrPosid[i]; if(pid==0) continue;
      if(!PositionSelectByTicket(pid)) continue;
      double curSL=PositionGetDouble(POSITION_SL);
      bool improves=(dir>0)?(curSL==0 || tSL>curSL+g_sym[m_symIdx].point):(curSL==0 || tSL<curSL-g_sym[m_symIdx].point);
      bool legal   =(dir>0)?(tSL<bid-stopsLvl):(tSL>ask+stopsLvl);
      if(improves && legal) trade.PositionModify(pid,tSL,0);
   }
}
void CBook::CloseAllPyramidTiers(){
   trade.SetExpertMagicNumber(m_magic);
   for(int i=0;i<m_pyrOpen;i++){
      ulong pid=m_pyrPosid[i]; if(pid==0) continue;
      if(PositionSelectByTicket(pid)) trade.PositionClose(pid);
   }
}

//------------------------------------------------------------------ execution
void CBook::OpenLeg(int dir,int leg=1){
   // leg=1 normal entry (all engines). leg=2 flip (E4 only, via pending-flip path).
   double atr[1];
   if(CopyBuffer(g_sym[m_symIdx].hAtr,0,1,1,atr)<1) return;
   double atrVal=atr[0]; if(atrVal<=0) return;
   double R_price=InpR_ATR_Mult*atrVal;
   double disasterR=(leg==2)?InpLeg2_DisasterR:InpLeg1_DisasterR;
   double slDist=disasterR*R_price;
   double baseLot=BaseLotForR(R_price);
   double lot=NormalizeLots(g_sym[m_symIdx],baseLot);
   double ask=SymbolInfoDouble(g_sym[m_symIdx].name,SYMBOL_ASK);
   double bid=SymbolInfoDouble(g_sym[m_symIdx].name,SYMBOL_BID);
   if(leg==1){
      m_ctxDrift=DriftStrength(g_sym[m_symIdx]);
      double adxB[1]; m_ctxAdx=(CopyBuffer(g_sym[m_symIdx].hAdx,0,1,1,adxB)>=1)?adxB[0]:0.0;
      double trB[6];  m_ctxSlope=(CopyBuffer(g_sym[m_symIdx].hTrend,0,1,6,trB)>=6)?(trB[0]-trB[5])/g_sym[m_symIdx].point:0.0;
      double f2[1],s2[1];
      double ef=(CopyBuffer(g_sym[m_symIdx].hEmaF2,0,1,1,f2)>=1)?f2[0]:0.0;
      double es=(CopyBuffer(g_sym[m_symIdx].hEmaS2,0,1,1,s2)>=1)?s2[0]:0.0;
      m_ctxGap=(ef-es)/g_sym[m_symIdx].point;
      m_ctxSpread=SpreadPts();
      //--- FUEL: atr_exp / swing_room / vol_ratio on the last CLOSED M15 bar.
      //    Same definitions used by EngineLab v1/v2 so the numbers are comparable.
      m_ctxAtrExp=1.0; m_ctxSwing=0.0; m_ctxVol=1.0;
      {
         MqlRates fr[]; ArraySetAsSeries(fr,true);
         int fgot=CopyRates(g_sym[m_symIdx].name,PERIOD_M15,1,40,fr);
         if(fgot>=20 && atrVal>0){
            double trsum=0; int cnt=0;
            for(int k=0;k<MathMin(fgot-1,28);k++){
               double tr=MathMax(fr[k].high-fr[k].low,
                          MathMax(MathAbs(fr[k].high-fr[k+1].close),MathAbs(fr[k].low-fr[k+1].close)));
               trsum+=tr; cnt++;
            }
            double travg=(cnt>0)?trsum/cnt:0;
            m_ctxAtrExp=(travg>0)?atrVal/travg:1.0;
            double fhi=fr[0].high, flo=fr[0].low;
            for(int k=0;k<MathMin(fgot,20);k++){ if(fr[k].high>fhi)fhi=fr[k].high; if(fr[k].low<flo)flo=fr[k].low; }
            double fc=fr[0].close;
            m_ctxSwing=MathMin((fhi-fc)/atrVal,(fc-flo)/atrVal);
            double vsum=0; int vc=0;
            for(int k=0;k<MathMin(fgot,15);k++){ vsum+=(double)fr[k].tick_volume; vc++; }
            double vavg=(vc>0)?vsum/vc:0;
            m_ctxVol=(vavg>0)?(double)fr[0].tick_volume/vavg:1.0;
         }
      }
   }
   double entry=(dir>0)?ask:bid;
   double sl=(dir>0)?NormPriceS(g_sym[m_symIdx],entry-slDist):NormPriceS(g_sym[m_symIdx],entry+slDist);
   string cmt=m_comment+"|L"+IntegerToString(leg);
   trade.SetExpertMagicNumber(m_magic);
   trade.SetTypeFillingBySymbol(g_sym[m_symIdx].name);
   bool ok=(dir>0)?trade.Buy(lot,g_sym[m_symIdx].name,ask,sl,0,cmt):trade.Sell(lot,g_sym[m_symIdx].name,bid,sl,0,cmt);
   if(!ok){ Print(m_id," OpenLeg failed: ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription()); return; }
   ResetLeg();
   m_leg.ticket=trade.ResultOrder();
   m_leg.dir=dir; m_leg.leg=leg; m_leg.entry=entry;
   m_leg.originalLot=lot; m_leg.currentLot=lot;
   m_leg.rung=0; m_leg.peak=entry; m_leg.R_price=R_price; m_leg.openTime=TimeCurrent();
   m_vleCross15=0; m_vleCross20=0; m_vleCutThisLeg=false;
   m_cycleActive=true; m_cycleLegs=leg;
   if(leg==1){ if(dir>0) m_buysToday++; else m_sellsToday++; ResetPyramidState(); }
   string ds=(dir>0)?"BUY":"SELL";
   string head=(leg==2)?"⚡ REVERSAL FLIP":((dir>0?"🟢":"🔴")+" NEW CYCLE");
   // APEX-style styled entry card, engine-tagged so 4 concurrent engines stay distinct.
   Say(head+"  ·  ["+m_id+"-"+m_coreName+"]  ["+ds+"]\n"+
       DIV+"\n"+
       "Symbol:  "+g_sym[m_symIdx].name+"\n"+
       "Price:   "+DoubleToString(entry,_Digits)+"\n"+
       "SL:      "+DoubleToString(sl,_Digits)+"   ("+DoubleToString(disasterR,1)+"R disaster)\n"+
       "Lots:    "+DoubleToString(lot,2)+"\n"+
       "R:       "+DoubleToString(R_price,_Digits)+"   ("+DoubleToString(InpR_ATR_Mult,1)+"×ATR)\n"+
       "VLE:     $"+DoubleToString(VleFloorEffFor(lot),2)+" effective   (base $"+DoubleToString(m_vleFloor,0)+" @ "+DoubleToString(InpVleBaseLot,2)+" lot)\n"+
       "Drift "+DoubleToString(m_ctxDrift,2)+"  ·  ADX "+DoubleToString(m_ctxAdx,1)+"\n"+
       DIV+"\n"+
       "🎯 Riding the bias...");
   RegisterPhantom(dir,entry,lot,atrVal);
}

//------------------------------------------------------------------ management
void CBook::ManagePositions(){
   double atr[1];
   if(CopyBuffer(g_sym[m_symIdx].hAtr,0,0,1,atr)<1) return;
   double atrVal=atr[0]; if(atrVal<=0) return;
   double bid=SymbolInfoDouble(g_sym[m_symIdx].name,SYMBOL_BID);
   double ask=SymbolInfoDouble(g_sym[m_symIdx].name,SYMBOL_ASK);
   bool found=false;
   for(int i=PositionsTotal()-1;i>=0;i--){
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic()!=m_magic || posInfo.Symbol()!=g_sym[m_symIdx].name) continue;
      if(IsPyrTier(posInfo.Ticket())) continue;
      m_leg.ticket=posInfo.Ticket();
      m_leg.dir=(posInfo.PositionType()==POSITION_TYPE_BUY)?1:-1;
      m_leg.entry=posInfo.PriceOpen();
      m_leg.currentLot=posInfo.Volume();
      if(m_leg.originalLot==0) m_leg.originalLot=m_leg.currentLot;
      if(m_leg.R_price==0)     m_leg.R_price=InpR_ATR_Mult*atrVal;
      found=true; break;
   }
   if(!found) return;
   int    dir   = m_leg.dir;
   double entry = m_leg.entry;
   double price = (dir>0)?bid:ask;
   double R_usd = PnlUSDs(g_sym[m_symIdx],dir,entry,(dir>0?entry+m_leg.R_price:entry-m_leg.R_price),m_leg.currentLot);
   double profitUSD = PnlUSDs(g_sym[m_symIdx],dir,entry,price,m_leg.currentLot);
   if(profitUSD>m_leg.mfe) m_leg.mfe=profitUSD;
   if(profitUSD<m_leg.mae) m_leg.mae=profitUSD;
   long vleAgeMin=(long)((TimeCurrent()-m_leg.openTime)/60);
   if(m_vleCross15==0 && profitUSD<=-15.0) m_vleCross15=TimeCurrent();
   if(m_vleCross20==0 && profitUSD<=-20.0) m_vleCross20=TimeCurrent();
   // --- effective VLE floor: auto-scaled-$ tracks the (compounded) lot so the cut stays at a constant R ---
   double vleFloorEff = m_vleFloor;                                  // unit 0: plain fixed $
   if(InpVleUnit!=0 && InpVleBaseLot>0.0){                           // unit 1/2: scale floor by lot/baseLot
      double refLot = (m_leg.originalLot>0.0 ? m_leg.originalLot : m_leg.currentLot);
      vleFloorEff = m_vleFloor * (refLot / InpVleBaseLot);
   }
   vleFloorEff *= g_sym[m_symIdx].contractRatio;                     // per-symbol: $ floor tracks money-per-move (micro 0.1x). Keeps -R fraction identical across symbols.
   if(InpVleEnabled && profitUSD<=-vleFloorEff){
      bool timeOK=(InpVleMode==0) || (vleAgeMin>=InpVleMinMinutes);
      if(timeOK){
         m_vleCutThisLeg=true;
         bool doFlip=(m_flipEnabled && InpE4_VleFlipOnCut && m_leg.leg==1 && m_leg.rung<=InpE4_FlipMaxRung);
         m_noFlip=!doFlip;   // inert for E1/E2/E3 (m_flipEnabled=false => doFlip=false => m_noFlip=true, but they never read it in a flip branch)
         CloseAllPyramidTiers();
         Say("✂ VLE-CUT  ·  Leg "+IntegerToString(m_leg.leg)+"   floating $"+DoubleToString(profitUSD,2)+
             " <= -$"+DoubleToString(vleFloorEff,2)+(doFlip?"  — flipping.":"  — cycle ends."));
         trade.SetExpertMagicNumber(m_magic);
         trade.PositionClose(m_leg.ticket);
         return;
      }
   }
   if(dir>0) m_leg.peak=MathMax(m_leg.peak,bid);
   else      m_leg.peak=MathMin(m_leg.peak,ask);
   if(InpMaxHoldHours>0 && (TimeCurrent()-m_leg.openTime)>(long)InpMaxHoldHours*3600){
      m_noFlip=true;
      CloseAllPyramidTiers();
      Say("⌛ TIME-STOP  ·  Leg "+IntegerToString(m_leg.leg)+"  held > "+IntegerToString(InpMaxHoldHours)+"h — flat, no flip.");
      trade.SetExpertMagicNumber(m_magic);
      trade.PositionClose(m_leg.ticket);
      return;
   }
   double arms[5]={InpR1_Arm,InpR2_Arm,InpR3_Arm,InpR4_Arm,InpR5_Arm};
   double pcts[5]={InpR1_ClosePct,InpR2_ClosePct,InpR3_ClosePct,InpR4_ClosePct,InpR5_ClosePct};
   int targetRung=m_leg.rung;
   for(int r=5;r>=1;r--){ if(profitUSD>=arms[r-1]*R_usd && m_leg.rung<r){ targetRung=r; break; } }
   if(targetRung>m_leg.rung){
      double cumPct=0; for(int r=m_leg.rung; r<targetRung; r++) cumPct+=pcts[r];
      double minLot=SymbolInfoDouble(g_sym[m_symIdx].name,SYMBOL_VOLUME_MIN);
      double volToClose=NormalizeLots(g_sym[m_symIdx],m_leg.originalLot*(cumPct/100.0));
      double maxClosable=m_leg.currentLot-minLot;
      if(maxClosable<minLot) volToClose=0;
      else if(volToClose>maxClosable) volToClose=NormalizeLots(g_sym[m_symIdx],maxClosable);
      if(volToClose>=minLot){ trade.SetExpertMagicNumber(m_magic); trade.PositionClosePartial(m_leg.ticket,volToClose); }
      for(int rr=m_leg.rung+1; rr<=targetRung && rr<=5; rr++) if(m_rungReach[rr]==0) m_rungReach[rr]=TimeCurrent();
      m_leg.rung=targetRung;
      Say("🔔 RUNG "+IntegerToString(targetRung)+"  ·  Leg "+IntegerToString(m_leg.leg)+
          (volToClose>=minLot?("  banked "+DoubleToString(cumPct,0)+"%"):"  (runner small)")+
          "   k→"+DoubleToString(KForRung(targetRung),2)+"×ATR   daily $"+DoubleToString(m_dailyRealized,2));
   }
   double k=KForRung(m_leg.rung);
   double chandelier=(dir>0)?(m_leg.peak-k*atrVal):(m_leg.peak+k*atrVal);
   double disaster  =(dir>0)?(entry-InpLeg1_DisasterR*m_leg.R_price)
                            :(entry+InpLeg1_DisasterR*m_leg.R_price);
   double targetSL  =(dir>0)?MathMax(disaster,chandelier):MathMin(disaster,chandelier);
   targetSL=NormPriceS(g_sym[m_symIdx],targetSL);
   double curSL=posInfo.StopLoss();
   double stopsLvl=(double)SymbolInfoInteger(g_sym[m_symIdx].name,SYMBOL_TRADE_STOPS_LEVEL)*g_sym[m_symIdx].point;
   bool improves=(dir>0)?(curSL==0 || targetSL>curSL+g_sym[m_symIdx].point):(curSL==0 || targetSL<curSL-g_sym[m_symIdx].point);
   bool legal=(dir>0)?(targetSL < bid-stopsLvl):(targetSL > ask+stopsLvl);
   if(improves && legal){ trade.SetExpertMagicNumber(m_magic); trade.PositionModify(m_leg.ticket,targetSL,0); }
   if(InpPyrEnabled){
      double curAdx=0; { double a[1]; if(CopyBuffer(g_sym[m_symIdx].hAdx,0,1,1,a)>=1) curAdx=a[0]; }
      if(PyrTrigger(curAdx)) AddPyramidTier(dir,m_leg.originalLot,targetSL);
      SyncPyramidStops(targetSL,dir,bid,ask);
   }
}

//------------------------------------------------------------------ risk / friday
// Effective daily breaker in $ for THIS book, always POSITIVE.
// Anchored to the book's own R (RiskUSDForMode already includes m_riskMult and
// the HWM drawdown brake), so it scales with compounding instead of fighting it.
double CBook::DailyMaxLossUsd(){
   if(InpDailyMaxLossR > 0.0) return InpDailyMaxLossR * RiskUSDForMode();
   return InpDailyMaxLossUSD;
}

void CBook::CheckFloatingDD(){
   double floating=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic()!=m_magic || posInfo.Symbol()!=g_sym[m_symIdx].name) continue;
      floating+=posInfo.Profit()+posInfo.Swap();
   }
   double total=m_dailyRealized+floating;
   double brk=DailyMaxLossUsd();
   if(brk>0.0 && total<=-brk){
      trade.SetExpertMagicNumber(m_magic);
      for(int i=PositionsTotal()-1;i>=0;i--){
         ulong tk=PositionGetTicket(i); if(tk==0) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=m_magic || PositionGetString(POSITION_SYMBOL)!=g_sym[m_symIdx].name) continue;
         trade.PositionClose(tk);
      }
      for(int i=OrdersTotal()-1;i>=0;i--){
         ulong tk=OrderGetTicket(i); if(tk==0) continue;
         if(OrderGetInteger(ORDER_MAGIC)!=m_magic || OrderGetString(ORDER_SYMBOL)!=g_sym[m_symIdx].name) continue;
         trade.OrderDelete(tk);
      }
      m_cycleActive=false; ResetLeg();
      ResetPyramidState(); m_haltedToday=true;
      Say("🛑 DAILY BREAKER  ·  realized+floating ≤ -$"+DoubleToString(brk,2)+
          (InpDailyMaxLossR>0.0? ("  ("+DoubleToString(InpDailyMaxLossR,1)+"R at R $"+DoubleToString(RiskUSDForMode(),2)+")") : "")+
          "  — halted till tomorrow.");
   }
}
void CBook::CheckFridayForceClose(){
   if(!InpUseFridayCutoff) return;
   int dow,h,m; GetBrokerTime(dow,h,m);
   bool isCloseTime=(dow==5 && (h>InpFridayForceCloseHour || (h==InpFridayForceCloseHour && m>=InpFridayForceCloseMin)));
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt); dt.hour=0; dt.min=0; dt.sec=0;
   datetime today=StructToTime(dt);
   static datetime lastCloseArr[MAX_BOOKS];
   int idx=m_symIdx; if(idx<0||idx>=MAX_BOOKS) idx=0;   // one book per symbol in this build
   if(isCloseTime && lastCloseArr[idx]!=today){
      trade.SetExpertMagicNumber(m_magic);
      for(int i=PositionsTotal()-1;i>=0;i--){
         ulong tk=PositionGetTicket(i); if(tk==0) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=m_magic || PositionGetString(POSITION_SYMBOL)!=g_sym[m_symIdx].name) continue;
         trade.PositionClose(tk);
      }
      for(int i=OrdersTotal()-1;i>=0;i--){
         ulong tk=OrderGetTicket(i); if(tk==0) continue;
         if(OrderGetInteger(ORDER_MAGIC)!=m_magic || OrderGetString(ORDER_SYMBOL)!=g_sym[m_symIdx].name) continue;
         trade.OrderDelete(tk);
      }
      m_cycleActive=false; ResetLeg(); ResetPyramidState();
      Say("🔒 FRIDAY FORCE-CLOSE — flat for the weekend.");
      lastCloseArr[idx]=today;
   }
}

//------------------------------------------------------------------ phantom
void CBook::UpdatePhantoms(){
   if(!InpPhantomEnable) return;
   double bid=SymbolInfoDouble(g_sym[m_symIdx].name,SYMBOL_BID);
   double ask=SymbolInfoDouble(g_sym[m_symIdx].name,SYMBOL_ASK);
   for(int i=0;i<50;i++){
      if(!m_ph[i].active) continue;
      double price=(m_ph[i].dir>0)?bid:ask;
      double prof=(m_ph[i].dir>0)?(price-m_ph[i].entry):(m_ph[i].entry-price);
      double usd=prof*m_ph[i].lot*g_sym[m_symIdx].tickValue/g_sym[m_symIdx].tickSize;
      if(usd>m_ph[i].mfe) m_ph[i].mfe=usd;
      if(usd<m_ph[i].mae) m_ph[i].mae=usd;
      bool allDone=true;
      for(int c=0;c<3;c++){
         if(m_ph[i].result[c]!=0) continue;
         bool tpHit=(m_ph[i].dir>0)?(bid>=m_ph[i].tp[c]):(ask<=m_ph[i].tp[c]);
         bool slHit=(m_ph[i].dir>0)?(bid<=m_ph[i].sl[c]):(ask>=m_ph[i].sl[c]);
         if(slHit) m_ph[i].result[c]=-1;
         else if(tpHit) m_ph[i].result[c]=1;
         else if(TimeCurrent()-m_ph[i].openTime>3600*InpMaxHoldHours) m_ph[i].result[c]=2;
         if(m_ph[i].result[c]==0) allDone=false;
      }
      if(allDone){
         int h=FileOpen("TrendPulseGoldenGoose_Phantom.csv",FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON,',');
         if(h!=INVALID_HANDLE){
            FileSeek(h,0,SEEK_END);
            if(FileSize(h)==0) FileWrite(h,"engine","magic","Time","Dir","Entry","MFE","MAE","P1","P2","P3");
            FileWrite(h,m_id,IntegerToString((int)m_magic),TimeToString(m_ph[i].openTime),(m_ph[i].dir>0?"BUY":"SELL"),
                      DoubleToString(m_ph[i].entry,_Digits),DoubleToString(m_ph[i].mfe,2),DoubleToString(m_ph[i].mae,2),
                      IntegerToString(m_ph[i].result[0]),IntegerToString(m_ph[i].result[1]),IntegerToString(m_ph[i].result[2]));
            FileClose(h);
         }
         m_ph[i].active=false;
      }
   }
}
void CBook::RegisterPhantom(int dir,double entry,double lot,double atrVal){
   if(!InpPhantomEnable) return;
   int slot=-1; for(int i=0;i<50;i++){ if(!m_ph[i].active){ slot=i; break; } }
   if(slot<0) return;
   m_ph[slot].active=true; m_ph[slot].dir=dir; m_ph[slot].entry=entry; m_ph[slot].lot=lot;
   m_ph[slot].openTime=TimeCurrent(); m_ph[slot].mfe=0; m_ph[slot].mae=0;
   double mults[3]={InpPh1_Mult,InpPh2_Mult,InpPh3_Mult};
   for(int c=0;c<3;c++){
      double dist=InpR_ATR_Mult*mults[c]*atrVal;
      m_ph[slot].sl[c]=(dir>0)?entry-dist:entry+dist;
      m_ph[slot].tp[c]=(dir>0)?entry+dist*2:entry-dist*2;
      m_ph[slot].result[c]=0;
   }
}

//------------------------------------------------------------------ unified CSV
void CBook::LogClosedDeal(double exitPrice,double vol,double profit,string legTag,string reason){
   // Buffer one CSV row in memory; FlushTradeLog() writes the file in OnDeinit.
   string split=(g_oosStart==0)?"-":((TimeCurrent()>=g_oosStart)?"OOS":"IS");
   string row=
      m_id+","+g_sym[m_symIdx].name+","+IntegerToString((int)m_magic)+","+DoubleToString(m_vleFloor,0)+","+
      TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS)+","+legTag+","+
      (m_leg.dir>0?"BUY":"SELL")+","+DoubleToString(vol,2)+","+
      DoubleToString(m_leg.entry,_Digits)+","+DoubleToString(exitPrice,_Digits)+","+
      DoubleToString(profit,2)+","+DoubleToString(m_dailyRealized,2)+","+reason+","+split+","+
      DoubleToString(m_leg.mfe,2)+","+DoubleToString(m_leg.mae,2)+","+DoubleToString(m_ctxSpread,0)+","+
      DoubleToString(m_ctxAdx,1)+","+DoubleToString(m_ctxSlope,1)+","+DoubleToString(m_ctxGap,1)+","+DoubleToString(m_ctxDrift,3)+","+
      DoubleToString(m_ctxAtrExp,3)+","+DoubleToString(m_ctxSwing,3)+","+DoubleToString(m_ctxVol,3);   // FUEL
   int n=ArraySize(g_tradeBuf);
   ArrayResize(g_tradeBuf,n+1);
   g_tradeBuf[n]=row;
}

// Log a PYRAMID-TIER close as its own CSV row so the file reconciles to balance.
// Tiers have no rung/MFE/MAE of their own; context columns inherit the cycle's.
void CBook::LogTierClose(double exitPrice,double vol,double profit,int tierDir){
   string split=(g_oosStart==0)?"-":((TimeCurrent()>=g_oosStart)?"OOS":"IS");
   string row=
      m_id+","+g_sym[m_symIdx].name+","+IntegerToString((int)m_magic)+","+DoubleToString(m_vleFloor,0)+","+
      TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS)+",PYR,"+
      (tierDir>0?"BUY":"SELL")+","+DoubleToString(vol,2)+","+
      DoubleToString(m_leg.entry,_Digits)+","+DoubleToString(exitPrice,_Digits)+","+
      DoubleToString(profit,2)+","+DoubleToString(m_dailyRealized,2)+",PYRTIER,"+split+","+
      "0.00,0.00,"+DoubleToString(m_ctxSpread,0)+","+
      DoubleToString(m_ctxAdx,1)+","+DoubleToString(m_ctxSlope,1)+","+DoubleToString(m_ctxGap,1)+","+DoubleToString(m_ctxDrift,3)+","+
      DoubleToString(m_ctxAtrExp,3)+","+DoubleToString(m_ctxSwing,3)+","+DoubleToString(m_ctxVol,3);   // FUEL
   int n=ArraySize(g_tradeBuf);
   ArrayResize(g_tradeBuf,n+1);
   g_tradeBuf[n]=row;
}

// Flush any not-yet-written buffered rows to the unified CSV. Called every tick
// from OnTick (reliable context) and once more in OnDeinit. On the first write
// of a run it truncates and writes the header; thereafter it appends only the
// new rows, so it's cheap (most ticks have nothing new and return immediately).
void FlushPendingTrades(bool force){
   int total=ArraySize(g_tradeBuf);
   if(total<=g_tradeWritten) return;                       // nothing new
   // Batching rule. In the TESTER we still wait for ~32 rows, so backtest speed is
   // untouched. LIVE, waiting for 32 rows means the file does not appear for days
   // at ~4 trades/session — so live also flushes on a timer once anything is
   // pending. Rows were never lost before this, they simply sat in g_tradeBuf
   // until OnDeinit; this just makes them visible while the EA is still running.
   bool live = !MQLInfoInteger(MQL_TESTER);
   if(!force){
      bool batchReady = ((total-g_tradeWritten)>=32);
      bool timeReady  = (live && InpCsvFlushSecs>0 &&
                         (TimeCurrent()-g_lastCsvFlush) >= (long)InpCsvFlushSecs);
      if(!batchReady && !timeReady) return;
   }
   g_lastCsvFlush=TimeCurrent();
   string tag=InpRunTag;
   StringTrimLeft(tag); StringTrimRight(tag);          // <- kills the trailing-space err=5004 bug
   StringReplace(tag," ","_");                          // any internal space -> underscore (portable filename)
   if(tag==""){                                         // blank tag -> auto-name by run-start date, so nothing to remember
      datetime t=(g_runStart>0?g_runStart:TimeCurrent());
      MqlDateTime dt; TimeToStruct(t,dt);
      tag=StringFormat("auto%04d%02d%02d",dt.year,dt.mon,dt.day);
   }
   string _fn="TrendPulseGoldenGoose_Trades_"+tag+".csv";
   bool first=(g_tradeWritten==0);
   int flags = first ? (FILE_WRITE|FILE_ANSI|FILE_COMMON) : (FILE_READ|FILE_WRITE|FILE_ANSI|FILE_COMMON);
   int h=FileOpen(_fn,flags);
   if(h==INVALID_HANDLE){ Print("TRADE-LOG: could not open ",_fn," err=",GetLastError()); return; }
   if(first){
      FileWriteString(h,"engine,symbol,magic,vle_floor,time,leg,dir,lot,entry,exit,profit_usd,daily_usd,reason,split,mfe_usd,mae_usd,spread_pts,adx,m5_slope_pts,ema_gap_pts,drift,atr_exp,swing_room,vol_ratio\r\n");
      Print("TRADE-LOG: v1.2 incremental writer ACTIVE -> ",_fn);   // <= proof the right build is running
   } else {
      FileSeek(h,0,SEEK_END);
   }
   for(int i=g_tradeWritten;i<total;i++) FileWriteString(h,g_tradeBuf[i]+"\r\n");
   FileClose(h);
   g_tradeWritten=total;
}
void CBook::PhantomVleLog(int leg,int dir,double finalPnl,int rung){
   if(!InpVlePhantom) return;
   int h=FileOpen("TrendPulseGoldenGoose_Loss.csv",FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON,',');
   if(h==INVALID_HANDLE) return;
   bool isNew=(FileSize(h)==0); FileSeek(h,0,SEEK_END);
   if(isNew) FileWrite(h,"engine","magic","vle_floor","time","leg","dir","final_pnl","mae_usd","mfe_usd","age_min","cross15_min","cross20_min","rung","vle_cut");
   long ageMin=(long)((TimeCurrent()-m_leg.openTime)/60);
   long c15=(m_vleCross15>0)?(long)((m_vleCross15-m_leg.openTime)/60):-1;
   long c20=(m_vleCross20>0)?(long)((m_vleCross20-m_leg.openTime)/60):-1;
   FileWrite(h,m_id,IntegerToString((int)m_magic),DoubleToString(m_vleFloor,0),
             TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),IntegerToString(leg),(dir>0?"BUY":"SELL"),
             DoubleToString(finalPnl,2),DoubleToString(m_leg.mae,2),DoubleToString(m_leg.mfe,2),
             IntegerToString((int)ageMin),IntegerToString((int)c15),IntegerToString((int)c20),
             IntegerToString(rung),(m_vleCutThisLeg?"1":"0"));
   FileClose(h);
}




int CBook::CorePULLBACK(){
   // E4 core: APEX Trigger B (pullback-to-EMA reclaim) + Trigger C (structural breakout).
   // Gates (bias/chop) are applied by EvaluateEntryBook upstream; here we need the regime
   // to route pullback (trending) vs breakout (coiling), exactly as E4's EvaluateEntry did.
   int biasDir=0;
   if(InpUseBiasGate) biasDir=BiasGateDir(g_sym[m_symIdx]);          // upstream already ensured !=0 when gate on
   int regime=ChopRegime(g_sym[m_symIdx]);
   bool trending=(!InpUseChopGate)||(regime==1);
   bool coiling =( InpUseChopGate && regime==2);
   int dir=0;
   if(trending){
      if(InpTrigCross){ int c=CrossTrigger(g_sym[m_symIdx]); if(c!=0 && (biasDir==0||c==biasDir)) dir=c; }
      if(dir==0 && InpTrigPullback){ int p=PullbackTrigger(g_sym[m_symIdx],biasDir); if(p!=0) dir=p; }
   }
   if(dir==0 && InpTrigBreakout && (coiling || (trending && InpBreakoutInTrend))){
      int b=BreakoutTrigger(g_sym[m_symIdx],biasDir); if(b!=0) dir=b;
   }
   return dir;
}

// MASTER — shared gates (identical for every book), then this book's own core.
//------------------------------------------------------------------ FUEL GATE
// Per-engine entry box. Uses the SAME context metrics that get logged to the
// CSV, computed on the last closed M15 bar, so what gates a trade is exactly
// what lands in the file. Returns true = fuel is inside the box, take the trade.
bool CBook::FuelGateAllows(){
   if(!InpFuelGateOn) return true;                       // master off -> original v4

   // --- compute the metrics this gate needs (same defs as the logger) ---
   double adxv=0.0, atrExp=1.0, volRatio=1.0;
   { double a[1]; if(CopyBuffer(g_sym[m_symIdx].hAdx,0,1,1,a)>=1) adxv=a[0]; }
   double atrB[1];
   double atrNow=(CopyBuffer(g_sym[m_symIdx].hAtr,0,1,1,atrB)>=1)?atrB[0]:0.0;
   MqlRates fr[]; ArraySetAsSeries(fr,true);
   int fgot=CopyRates(g_sym[m_symIdx].name,PERIOD_M15,1,40,fr);
   if(fgot>=20 && atrNow>0){
      double trsum=0; int cnt=0;
      for(int k=0;k<MathMin(fgot-1,28);k++){
         double tr=MathMax(fr[k].high-fr[k].low,
                    MathMax(MathAbs(fr[k].high-fr[k+1].close),MathAbs(fr[k].low-fr[k+1].close)));
         trsum+=tr; cnt++;
      }
      double travg=(cnt>0)?trsum/cnt:0;
      atrExp=(travg>0)?atrNow/travg:1.0;
      double vsum=0; int vc=0;
      for(int k=0;k<MathMin(fgot,15);k++){ vsum+=(double)fr[k].tick_volume; vc++; }
      double vavg=(vc>0)?vsum/vc:0;
      volRatio=(vavg>0)?(double)fr[0].tick_volume/vavg:1.0;
   }

   // THE FUEL GAUGE — E4's verified box, FROZEN.
   // vol_ratio floor 1.171 and ADX ceiling 29.3 were fitted on E4's own trade
   // record and are the reason this engine trades when it trades. They ship as
   // measured and are not re-tuned in this build.
   bool pass=true; string why="";
   if(InpE4_GateOn){
      if(volRatio<InpE4_MinVolRatio){ pass=false; why="vol_ratio "+DoubleToString(volRatio,3)+" < "+DoubleToString(InpE4_MinVolRatio,3); }
      else if(adxv>=InpE4_MaxAdx)   { pass=false; why="adx "+DoubleToString(adxv,1)+" >= "+DoubleToString(InpE4_MaxAdx,1); }
   }
   if(!pass){
      g_fuelBlocked++;
      if(InpFuelGateLog) Print("⛔ FUEL BLOCK [",m_id,"-",m_coreName,"] ",why);
   }
   return pass;
}

int CBook::EvaluateEntryBook(){
   int biasDir=0;
   if(InpUseBiasGate){ biasDir=BiasGateDir(g_sym[m_symIdx]); if(biasDir==0) return 0; }   // flat/whipsaw => stand aside
   if(InpUseChopGate && ChopRegime(g_sym[m_symIdx])==0) return 0;                         // dead zone => stand aside
   int dir=0;
   dir=CorePULLBACK();          // single engine: E4 is the only core in this build
   if(dir==0) return 0;
   if(biasDir!=0 && dir!=biasDir) return 0;                                // with-trend only (never fade the bias)
   return dir;
}

//------------------------------------------------------------------ per-book tick
//------------------------------------------------------------------
// AI gate for the book. Fail-CLOSED: VALID is the only pass. REJECT and
// FAIL/OFFLINE both veto and both alert to Telegram, so a skipped trade is
// never silent — you always see WHY nothing fired.
//------------------------------------------------------------------
bool CBook::AIGateAllows(int dir){
   string sym  = g_sym[m_symIdx].name;
   string tag  = (dir>0 ? "BUY" : "SELL");
   string who  = m_id + "-" + m_coreName;
   string reason="";
   int v = AIGateQuery(sym, dir, reason);
   if(v==1){
      Print(EMO(0x1F9E0),"\u2705 [",who," #",IntegerToString((int)m_magic),"] AI VALID  ",tag," ",sym,"  |  ",reason);
      if(InpAIGateTgOnValid) SendTelegram(EMO(0x1F9E0)+EMO(0x2705)+" AI VALID "+who+" "+tag+" "+sym+" | "+reason);
      return true;
   }
   if(v==0){
      AlertLog(EMO(0x1F9E0)+EMO(0x1F6D1)+" AI REJECT  "+tag+" "+sym+"  -> trade aborted  |  "+reason);
      return false;
   }
   AlertLog(EMO(0x1F9E0)+EMO(0x26A0)+" AI UNAVAILABLE  "+tag+" "+sym+"  -> trade SKIPPED (fail-closed)  |  "+reason);
   return false;
}

void CBook::OnTickBook(){
   CheckFridayForceClose();
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt); dt.hour=0; dt.min=0; dt.sec=0;
   datetime d=StructToTime(dt);
   if(m_pnlDay!=d){ m_pnlDay=d; m_dailyRealized=0; m_haltedToday=false; m_buysToday=0; m_sellsToday=0; }
   UpdatePhantoms();
   CheckFloatingDD();
   if(m_haltedToday) return;
   if(m_flipEnabled && m_pendingFlip){          // E4 only: execute the queued reversal
      m_pendingFlip=false;
      if(m_cycleActive && m_cycleLegs<InpE4_MaxLegs && !IsFridayEntryBlocked())
         OpenLeg(m_flipDir,m_cycleLegs+1);
      else { m_cycleActive=false; m_cycleLegs=0; ResetLeg(); }
      return;
   }
   ManagePositions();
   if(m_cycleActive) return;
   if(!m_enabled) return;                       // engine benched by input (leftovers still managed above)
   if(IsFridayEntryBlocked()) return;
   datetime bar=iTime(g_sym[m_symIdx].name,PERIOD_M1,0);
   if(bar==m_lastSignalBar) return;
   int sig=EvaluateEntryBook();                 // evaluated fresh every tick until it fires (GG lesson: caching under-trades)
   if(sig!=0){
      m_lastSignalBar=bar;
      if(sig>0 && m_buysToday>=InpMaxBuysPerDay){ return; }
      if(sig<0 && m_sellsToday>=InpMaxSellsPerDay){ return; }
      if(!FuelGateAllows()) return;             // FUEL GATE: no fuel in the bar -> stand aside
      // === AI SEMANTIC GATE (fail-CLOSED) — VALID is the ONLY pass ===
      if(InpUseAIGate && !AIGateAllows(sig)) return;   // REJECT or FAIL/OFFLINE -> skip, wait for next signal
      if(InpEnableLeg1) OpenLeg(sig);
   }
}

//------------------------------------------------------------------ per-book deal-out (was OnTradeTransaction body)
void CBook::OnDealOut(const MqlTradeTransaction& trans){
   double profit=HistoryDealGetDouble(trans.deal,DEAL_PROFIT)+HistoryDealGetDouble(trans.deal,DEAL_SWAP)+HistoryDealGetDouble(trans.deal,DEAL_COMMISSION);
   double exitPrice=HistoryDealGetDouble(trans.deal,DEAL_PRICE);
   double dvol=HistoryDealGetDouble(trans.deal,DEAL_VOLUME);
   ulong  posid=(ulong)HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);
   m_dailyRealized+=profit;
   // --- per-engine accounting for the end-of-run Journal summary ---
   m_cumNet+=profit;
   if(profit>0) m_cumGP+=profit; else if(profit<0) m_cumGL+=profit;
   if(m_cumNet>m_peakNet) m_peakNet=m_cumNet;
   double _dd=m_peakNet-m_cumNet; if(_dd>m_maxDD) m_maxDD=_dd;
   if(IsPyrTier(posid)){
      LogTierClose(exitPrice,dvol,profit,m_leg.dir);   // reconcile CSV to balance: tiers were previously unlogged
      for(int i=0;i<m_pyrOpen;i++){
         if(m_pyrPosid[i]==posid){ for(int j=i;j<m_pyrOpen-1;j++) m_pyrPosid[j]=m_pyrPosid[j+1]; m_pyrOpen--; m_pyrPosid[m_pyrOpen]=0; break; }
      }
      return;
   }
   bool stillOpen=PositionSelectByTicket(posid);
   string legTag="L"+IntegerToString(m_leg.leg);
   string reason= stillOpen ? "PARTIAL" : "CLOSE";
   LogClosedDeal(exitPrice,dvol,profit,legTag,reason);
   if(stillOpen){ return; }
   int closedLeg=m_leg.leg;
   m_closes++; if(profit>0) m_wins++; else if(profit<0) m_losses++;
   int closedDir=m_leg.dir;
   int closedRung=m_leg.rung;
   CloseAllPyramidTiers();
   string ds=(closedDir>0)?"BUY":"SELL";
   string emo=(profit>0)?"✅":(profit<0?"❌":"➖");
   string res=(profit>0)?"WIN":(profit<0?"LOSS":"BE");
   { double _b=AccountInfoDouble(ACCOUNT_BALANCE); if(_b>m_hwm) m_hwm=_b; if(profit>0) m_winStreak++; else if(profit<0) m_winStreak=0; }
   if(InpCompoundMode==5){ if(profit<0) m_dalLevel=MathMin(InpDalMaxLevel,m_dalLevel+1); else if(profit>0) m_dalLevel=MathMax(1,m_dalLevel-1); }
   bool willFlip=(m_flipEnabled && !m_noFlip && m_cycleActive && closedLeg==1 && m_cycleLegs<InpE4_MaxLegs && closedRung<=InpE4_FlipMaxRung);
   string next;
   if(willFlip)                                         next="⚡ Flipping to Leg 2 ["+(closedDir>0?"SELL":"BUY")+"] next tick...";
   else if(m_flipEnabled && m_noFlip)                   next="🔒 Forced close — no flip.";
   else if(m_flipEnabled && closedRung>InpE4_FlipMaxRung) next="🏆 Matured (rung "+IntegerToString(closedRung)+") — took the win.";
   else                                                 next="✔ Cycle complete. "+m_id+"-"+m_coreName+" waiting for its next signal.";
   // APEX-style styled outcome card, engine-tagged.
   Say(emo+" CYCLE CLOSED  ·  "+res+"  ["+ds+"]   ["+m_id+"-"+m_coreName+"]\n"+
       DIV+"\n"+
       "Symbol:  "+g_sym[m_symIdx].name+"\n"+
       "Exit:    "+DoubleToString(exitPrice,_Digits)+"   (reached rung "+IntegerToString(closedRung)+")\n"+
       "P/L:     $"+DoubleToString(profit,2)+"   ·   Daily $"+DoubleToString(m_dailyRealized,2)+"\n"+
       "MFE $"+DoubleToString(m_leg.mfe,2)+"  /  MAE $"+DoubleToString(m_leg.mae,2)+"\n"+
       DIV+"\n"+
       next);
   PhantomVleLog(closedLeg,closedDir,profit,closedRung);
   if(willFlip){ m_pendingFlip=true; m_flipDir=-closedDir; }   // E4 only
   else { m_cycleActive=false; m_cycleLegs=0; ResetLeg(); }
   m_noFlip=false;
}

//==================================================================
// EVENT HANDLERS
//==================================================================


//==================================================================
// STARTUP BANNER  (new style — clean, per your spec)
//==================================================================
// Build an emoji/codepoint string. Handles astral-plane (>0xFFFF) via UTF-16 surrogate
// pairs, which is what MT5's string+Telegram pipeline needs to render emoji correctly.
string EMO(int cp){
   if(cp<=0xFFFF) return ShortToString((ushort)cp);
   cp-=0x10000;
   ushort hi=(ushort)(0xD800+(cp>>10));
   ushort lo=(ushort)(0xDC00+(cp&0x3FF));
   return ShortToString(hi)+ShortToString(lo);
}

void PrintStartupBanner(){
   //--------------------------------------------------------------
   // Two renderings:
   //   logb  = CLEAN ASCII  -> Experts/Journal (Print). No emoji, no box chars.
   //   tgb   = RICH EMOJI   -> Telegram (SendTelegram). Emoji via codepoints so
   //           MT5's UTF-8 pipeline renders them correctly (raw \x escapes corrupt).
   //--------------------------------------------------------------
   string symline="";
   for(int i=0;i<g_nSyms;i++){ symline+=(i? " + ":"")+g_sym[i].name; }

   // ---------- CLEAN ASCII banner for the Experts tab ----------
   string NEST=".oOo.oOo.oOo.oOo.oOo.oOo.oOo.oOo.oOo.oOo.oOo.oOo.";   // the nest rail
   string L   ="- - - - - - - - - - - - - - - - - - - - - - - - - ";
   string logb=
   "\n"+
   NEST+"\n"+
   "    T R E N D P U L S E   G O L D E N   G O O S E\n"+
   "    E4  ·  PULLBACK  ·  single engine  ·  open source\n"+
   "    "+symline+"\n"+
   NEST+"\n"+
   "  Sizing      "+SizingDesc()+"\n"+
   "  R           "+DoubleToString(InpR_ATR_Mult,1)+" x ATR @ "+StringSubstr(EnumToString(InpR_TF),7)+"   |  VLE unit "+IntegerToString(InpVleUnit)+" (auto-$)\n"+
   "  Pyramid     "+PyrDesc()+"\n"+
   "  Disaster    L1 "+DoubleToString(InpLeg1_DisasterR,1)+"R  |  L2 "+DoubleToString(InpLeg2_DisasterR,1)+"R (flip leg)\n"+
   "  Fuel gauge  "+(InpFuelGateOn&&InpE4_GateOn? ("ON   vol_ratio >= "+DoubleToString(InpE4_MinVolRatio,3)+"   ADX < "+DoubleToString(InpE4_MaxAdx,1)+"   [verified, frozen]") : "OFF")+"\n"+
   "  Rungs       +0.5 -> +2.5R  (banked ladder)\n"+
   "  k-trail     2.0 -> 1.5 -> 1.1 -> 0.8 -> 0.6 -> 0.5 x ATR\n"+
   "  Flip        <= rung "+IntegerToString(InpE4_FlipMaxRung)+"  |  max legs "+IntegerToString(InpE4_MaxLegs)+"  |  "+IntegerToString(InpMaxHoldHours)+"h stop\n"+
   "  Breaker     "+BreakerDesc()+"  (realized+floating)\n"+
   "  Day cap     "+IntegerToString(InpMaxBuysPerDay)+" buys / "+IntegerToString(InpMaxSellsPerDay)+" sells  (1 at a time, L2 free)\n"+
   "  AI gate     "+(InpUseAIGate?("ON  [fail-CLOSED]  "+InpAIGateURL+"  timeout "+IntegerToString(InpAITimeoutMs)+"ms"):"OFF  (verified baseline — flip ON for live)")+"\n"+
   "  Friday      "+IntegerToString(InpFridayEntryCutoffHour)+":00 cut / "+IntegerToString(InpFridayForceCloseHour)+":"+StringFormat("%02d",InpFridayForceCloseMin)+" flat\n"+
   L+"\n";
   for(int i=0;i<g_nBooks;i++){
      double _mlot=g_sym[books[i].m_symIdx].minLot;   // floor shown at this symbol's ACTUAL min lot (the value that will really fire)
      double _lotScale=(InpVleUnit!=0 && InpVleBaseLot>0.0)?(_mlot/InpVleBaseLot):1.0;
      double effFloor=books[i].m_vleFloor*_lotScale*g_sym[books[i].m_symIdx].contractRatio;
      logb+="  "+books[i].m_id+"  PULLBACK"+
            "   #"+IntegerToString((int)books[i].m_magic)+
            "   VLE $"+DoubleToString(effFloor,2)+" @ min lot"+
            "  (base $"+DoubleToString(books[i].m_vleFloor,0)+" @ "+DoubleToString(InpVleBaseLot,2)+" lot)"+
            (books[i].m_flipEnabled?"   [flip]":"")+
            (books[i].m_enabled?"":"   [OFF]")+"\n";
   }
   logb+=NEST+"\n"+
         "  risk: "+(InpRiskSplitAcrossBooks?("split 1/"+IntegerToString(g_nBooks)):"full")+
         "     GOLDEN GOOSE E4 online - "+(InpUseAIGate?"AI gate armed, hunting setups...":"hunting setups...");
   Print("\n"+logb);

   // ---------- RICH EMOJI banner for Telegram ----------
   if(InpTgEnable){
      // GoldenGoose livery: a DEEP GOLD + GREEN rail instead of APEX's heavy
      // line, with the goose and the egg as the signature. Same EMO() surrogate
      // mechanism APEX uses, so everything here renders wherever APEX's does.
      string GOLD=EMO(0x1F7E8), GREEN=EMO(0x1F7E9);     // large gold / green squares
      string RULE="";
      for(int i=0;i<6;i++) RULE+=GOLD+GREEN;            // gold-green-gold-green rail
      // NOTE: 0x1FABF is the goose. If your client shows a box instead, swap it
      // for 0x1F9A2 (swan) — everything else in this banner is long-established.
      string goose=EMO(0x1FABF), egg=EMO(0x1F95A);
      string gdot=EMO(0x1F7E1), grn=EMO(0x1F7E2);       // gold / green dots
      string tgb=
      goose+egg+GOLD+"  T R E N D P U L S E   G O L D E N   G O O S E   ·   E4  "+GOLD+egg+goose+"\n"+
      "single engine  -  "+symline+"  -  PULLBACK  -  open source\n"+
      RULE+"\n"+
      EMO(0x1F4B0)+" "+SizingDesc()+"\n"+
      EMO(0x1F4D0)+" R = "+DoubleToString(InpR_ATR_Mult,1)+"xATR @ "+StringSubstr(EnumToString(InpR_TF),7)+"   VLE unit "+IntegerToString(InpVleUnit)+" (auto-$)\n"+
      EMO(0x1F9F1)+" Pyramid  "+PyrDesc()+"\n"+
      EMO(0x1F512)+" Disaster  L1 "+DoubleToString(InpLeg1_DisasterR,1)+"R  -  L2 "+DoubleToString(InpLeg2_DisasterR,1)+"R (flip leg)\n"+
      EMO(0x26FD)+" Fuel  "+(InpFuelGateOn&&InpE4_GateOn? ("vol>="+DoubleToString(InpE4_MinVolRatio,3)+"  ADX<"+DoubleToString(InpE4_MaxAdx,1)+"  [frozen]") : "OFF")+"\n"+
      EMO(0x1FA9C)+" Rungs  +0.5 -> +2.5R  (banked ladder)\n"+
      EMO(0x1F4C9)+" k-trail  2.0->1.5->1.1->0.8->0.6->0.5 xATR\n"+
      EMO(0x26A1)+" Flip <= rung "+IntegerToString(InpE4_FlipMaxRung)+"  -  max legs "+IntegerToString(InpE4_MaxLegs)+"  -  "+IntegerToString(InpMaxHoldHours)+"h stop\n"+
      EMO(0x1F6A7)+" Breaker  "+BreakerDesc()+"  (realized+floating)\n"+
      EMO(0x1F4C6)+" Day cap  "+IntegerToString(InpMaxBuysPerDay)+" buys - "+IntegerToString(InpMaxSellsPerDay)+" sells  (1 at a time, L2 free)\n"+
      EMO(0x1F9E0)+" AI gate  "+(InpUseAIGate?("ON  -  fail-CLOSED  -  timeout "+IntegerToString(InpAITimeoutMs)+"ms"):"OFF  (verified baseline)")+"\n"+
      EMO(0x1F4C5)+" Friday  "+IntegerToString(InpFridayEntryCutoffHour)+":00 cut / "+IntegerToString(InpFridayForceCloseHour)+":"+StringFormat("%02d",InpFridayForceCloseMin)+" flat\n"+
      RULE+"\n";
      for(int i=0;i<g_nBooks;i++){
            double _mlot=g_sym[books[i].m_symIdx].minLot;   // floor shown at this symbol's ACTUAL min lot (the value that will really fire)
      double _lotScale=(InpVleUnit!=0 && InpVleBaseLot>0.0)?(_mlot/InpVleBaseLot):1.0;
      double effFloor=books[i].m_vleFloor*_lotScale*g_sym[books[i].m_symIdx].contractRatio;
         tgb+=egg+" "+books[i].m_id+"  PULLBACK   #"+IntegerToString((int)books[i].m_magic)+
              "   VLE $"+DoubleToString(effFloor,2)+" @min lot (base $"+DoubleToString(books[i].m_vleFloor,0)+")"+
              (books[i].m_flipEnabled?"  "+EMO(0x26A1)+"flip":"")+
              (books[i].m_enabled?"":"  [OFF]")+"\n";
      }
      tgb+=RULE+"\n"+grn+" GOLDEN GOOSE E4 online "+EMO(0x2014)+(InpUseAIGate?" AI gate armed, hunting setups...":" hunting setups...");
      SendTelegram(tgb);
   }
}

int OnInit(){
   trade.SetDeviationInPoints(20);

   // ---------- resolve which symbol(s) to trade ----------
   g_nSyms=0;
   string want[MAX_SYMS]; int nWant=0;
   if(InpAutoDetectSymbol){
      // trade EXACTLY the attached chart symbol, if it is a recognised gold symbol
      if(_Symbol==InpSymXAUUSD || _Symbol==InpSymXAUUSDmicro){ want[nWant++]=_Symbol; }
      else {
         Print("⛔ AutoDetect ON but attached symbol '",_Symbol,"' is not ",InpSymXAUUSD," or ",InpSymXAUUSDmicro,". EA will not trade. Attach to a gold symbol, or turn AutoDetect OFF and use the switches.");
         return INIT_FAILED;
      }
   } else {
      if(InpTradeXAUUSD)      want[nWant++]=InpSymXAUUSD;
      if(InpTradeXAUUSDmicro) want[nWant++]=InpSymXAUUSDmicro;
      if(nWant==0){ Print("⛔ AutoDetect OFF and no symbol switch is ON. Enable InpTradeXAUUSD and/or InpTradeXAUUSDmicro."); return INIT_FAILED; }
   }

   // ---------- load spec + create handles for each symbol ----------
   for(int w=0; w<nWant; w++){
      string sym=want[w];
      if(!SymbolSelect(sym,true)){ Print("⛔ Cannot select symbol ",sym," in Market Watch."); return INIT_FAILED; }
      SymSpec sp;
      sp.name=sym;
      sp.point    =SymbolInfoDouble(sym,SYMBOL_POINT);
      sp.tickValue=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_VALUE);
      sp.tickSize =SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE);
      sp.minLot   =SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN);
      sp.maxLot   =SymbolInfoDouble(sym,SYMBOL_VOLUME_MAX);
      sp.lotStep  =SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP);
      sp.digits   =(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
      sp.stopsLevel=(int)SymbolInfoInteger(sym,SYMBOL_TRADE_STOPS_LEVEL);
      sp.chopVal=50.0; sp.chopBar=0;
      if(sp.tickValue<=0 || sp.tickSize<=0){ Print("⛔ Bad tick spec for ",sym); return INIT_FAILED; }
      // contract ratio vs XAUUSD standard: use contract size if available, else tickValue ratio.
      double cs=SymbolInfoDouble(sym,SYMBOL_TRADE_CONTRACT_SIZE);
      double csStd=SymbolInfoDouble(InpSymXAUUSD,SYMBOL_TRADE_CONTRACT_SIZE);
      sp.contractRatio=(csStd>0 && cs>0)? cs/csStd : 1.0;   // micro(10oz)/std(100oz)=0.1
      if(sym==InpSymXAUUSD) sp.contractRatio=1.0;           // standard is the reference
      // handles
      sp.hEmaF1=iMA(sym,InpTP_TF,InpTP_Fast,0,MODE_EMA,PRICE_CLOSE);
      sp.hEmaS1=iMA(sym,InpTP_TF,InpTP_Slow,0,MODE_EMA,PRICE_CLOSE);
      sp.hEmaF2=iMA(sym,PERIOD_M1,InpDS_Fast,0,MODE_EMA,PRICE_CLOSE);
      sp.hEmaS2=iMA(sym,PERIOD_M1,InpDS_Slow,0,MODE_EMA,PRICE_CLOSE);
      sp.hTrend=iMA(sym,InpTrendTF,InpTrendEma,0,MODE_EMA,PRICE_CLOSE);
      sp.hAdx=iADX(sym,InpAdxTF,InpAdxPeriod);
      sp.hAtr=iATR(sym,InpR_TF,InpAtrPeriod);
      sp.hBias=iMA(sym,InpBiasTF,InpBiasEMA,0,MODE_EMA,PRICE_CLOSE);
      sp.hPullEma=iMA(sym,InpPullbackTF,InpPullbackEMA,0,MODE_EMA,PRICE_CLOSE);
      if(sp.hEmaF1==INVALID_HANDLE||sp.hEmaS1==INVALID_HANDLE||sp.hEmaF2==INVALID_HANDLE||sp.hEmaS2==INVALID_HANDLE||
         sp.hTrend==INVALID_HANDLE||sp.hAdx==INVALID_HANDLE||sp.hAtr==INVALID_HANDLE||
         sp.hBias==INVALID_HANDLE||sp.hPullEma==INVALID_HANDLE){
         Print("⛔ Handle creation failed for ",sym); return INIT_FAILED; }
      g_sym[g_nSyms++]=sp;
   }
   // attached-symbol spec mirror for the few context helpers that use globals
   g_point=g_sym[0].point; g_tickValue=g_sym[0].tickValue; g_tickSize=g_sym[0].tickSize;

   // ---------- instantiate books: 4 engines PER active symbol ----------
   g_runStart=TimeCurrent();
   g_oosStart=(StringLen(InpOOSStartDate)>=8)?StringToTime(InpOOSStartDate):0;
   ArrayResize(g_tradeBuf,0); g_tradeWritten=0; g_lastCsvFlush=TimeCurrent();
   // ONE book per active symbol — E4 takes the full position.
   g_nBooks=g_nSyms;
   double rm = InpRiskSplitAcrossBooks ? (1.0/(double)g_nBooks) : 1.0;

   for(int sIx=0; sIx<g_nSyms; sIx++){
      string id="E4";
      if(g_nSyms>1) id=id+"@"+(g_sym[sIx].name==InpSymXAUUSDmicro?"m":"S");   // tag symbol when dual
      long mg=InpMagic+(sIx*10);              // 88000104 standard, 88000114 micro
      books[sIx].Init(id,mg,InpVleFloorUSD,rm,3,true,sIx);   // core 3 = PULLBACK
   }

   PrintStartupBanner();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason){
   FlushPendingTrades(true);   // force-write all remaining rows
   // ===== PER-ENGINE SUMMARY -> JOURNAL (copy/paste this block) =====
   PrintFormat("FUEL GATE: %s   signals blocked = %d   |   VLE: %s   |   MAPT: not fitted (rung ladder already banks)",
               (InpFuelGateOn?"ON":"OFF"), g_fuelBlocked, (InpVleEnabled?"ON":"OFF"));
   Print("============== GOLDEN GOOSE E4  PER-ENGINE SUMMARY ==============");
   Print("tag=",InpRunTag,"  books=",g_nBooks,"  (net = sum of all that engine's deal P&L)");
   Print("engine  magic     floor    net      grossP    grossL     PF     maxDD   pos   W/L");
   double tNet=0,tGP=0,tGL=0;
   for(int i=0;i<g_nBooks;i++){
      double pf=(books[i].m_cumGL!=0)? books[i].m_cumGP/MathAbs(books[i].m_cumGL) : 0.0;
      tNet+=books[i].m_cumNet; tGP+=books[i].m_cumGP; tGL+=books[i].m_cumGL;
      Print(StringFormat("%-6s %-9d $%-5.0f  %8.2f  %8.2f  %9.2f  %5.3f  %7.2f  %4d  %d/%d",
         books[i].m_id, (int)books[i].m_magic, books[i].m_vleFloor,
         books[i].m_cumNet, books[i].m_cumGP, books[i].m_cumGL, pf,
         books[i].m_maxDD, books[i].m_closes, books[i].m_wins, books[i].m_losses));
   }
   double tpf=(tGL!=0)? tGP/MathAbs(tGL):0.0;
   Print(StringFormat("COMBINED net %.2f   grossP %.2f   grossL %.2f   PF %.3f", tNet,tGP,tGL,tpf));
   Print("=================================================================");
   for(int i=0;i<g_nSyms;i++){
      IndicatorRelease(g_sym[i].hEmaF1); IndicatorRelease(g_sym[i].hEmaS1);
      IndicatorRelease(g_sym[i].hEmaF2); IndicatorRelease(g_sym[i].hEmaS2);
      IndicatorRelease(g_sym[i].hTrend); IndicatorRelease(g_sym[i].hAdx); IndicatorRelease(g_sym[i].hAtr);
      IndicatorRelease(g_sym[i].hBias); IndicatorRelease(g_sym[i].hPullEma);
   }
}

void OnTick(){
   // Each book evaluates ITS OWN core fresh every tick until it fires
   // (the GG under-trading lesson: never cache the signal once per bar).
   for(int i=0;i<g_nBooks;i++) books[i].OnTickBook();
   FlushPendingTrades(false);  // batched write from the reliable OnTick context
}

void OnTradeTransaction(const MqlTradeTransaction& trans,const MqlTradeRequest& request,const MqlTradeResult& result){
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   long mg=HistoryDealGetInteger(trans.deal,DEAL_MAGIC);
   long entryType=HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
   if(entryType!=DEAL_ENTRY_OUT) return;
   for(int i=0;i<g_nBooks;i++){
      if(books[i].m_magic==mg){ books[i].OnDealOut(trans); return; }
   }
}
//+------------------------------------------------------------------+


//==================================================================
// RUN SUMMARY — printed to the Strategy-Tester Journal at run end.
// One copy-paste block with every metric needed to judge the run.
//==================================================================
// Active symbols and the ACTUAL book magics, for the run-summary header.
// The old header derived magics as base+1 .. base+nBooks, which is wrong once
// a second symbol exists (its magics are base+11..14, not base+5..8).
string BreakerDesc(){
   if(InpDailyMaxLossR<=0.0)
      return "$"+DoubleToString(InpDailyMaxLossUSD,0)+" fixed (does NOT scale with risk)";
   double r=(g_nBooks>0? books[0].RiskUSDForMode() : 0.0);
   return DoubleToString(InpDailyMaxLossR,1)+"R"+(r>0? ("  = $"+DoubleToString(InpDailyMaxLossR*r,2)+" at R $"+DoubleToString(r,2)) : "");
}

string SymLine(){
   string o="";
   for(int i=0;i<g_nSyms;i++) o+=(i? " + ":"")+g_sym[i].name;
   return (o==""? _Symbol : o);
}
string MagicLine(){
   long lo=0, hi=0;
   for(int b=0;b<g_nBooks;b++){
      long m=books[b].m_magic;
      if(lo==0 || m<lo) lo=m;
      if(m>hi) hi=m;
   }
   if(lo==0) return "n/a";
   return IntegerToString((int)lo)+"-"+IntegerToString((int)hi);
}

void PrintRunSummary() {
   // ---- tester statistics (identical to the tester report values) ----
   double dep = TesterStatistics(STAT_INITIAL_DEPOSIT);
   double net = TesterStatistics(STAT_PROFIT);
   double gp  = TesterStatistics(STAT_GROSS_PROFIT);
   double gl  = TesterStatistics(STAT_GROSS_LOSS);        // negative
   double pf  = TesterStatistics(STAT_PROFIT_FACTOR);
   double ep  = TesterStatistics(STAT_EXPECTED_PAYOFF);
   double rf  = TesterStatistics(STAT_RECOVERY_FACTOR);
   double sr  = TesterStatistics(STAT_SHARPE_RATIO);
   double bdd = TesterStatistics(STAT_BALANCE_DD);
   double bddp= TesterStatistics(STAT_BALANCEDD_PERCENT);
   double edd = TesterStatistics(STAT_EQUITY_DD);
   double eddp= TesterStatistics(STAT_EQUITYDD_PERCENT);
   int    tr  = (int)TesterStatistics(STAT_TRADES);
   int    wt  = (int)TesterStatistics(STAT_PROFIT_TRADES);
   int    lt  = (int)TesterStatistics(STAT_LOSS_TRADES);
   int    lg  = (int)TesterStatistics(STAT_LONG_TRADES);
   int    sh  = (int)TesterStatistics(STAT_SHORT_TRADES);
   int    lgW = (int)TesterStatistics(STAT_PROFIT_LONGTRADES);
   int    shW = (int)TesterStatistics(STAT_PROFIT_SHORTTRADES);
   double maxW= TesterStatistics(STAT_MAX_PROFITTRADE);
   double maxL= TesterStatistics(STAT_MAX_LOSSTRADE);
   int    cw  = (int)TesterStatistics(STAT_MAX_CONWINS);
   int    cl  = (int)TesterStatistics(STAT_MAX_CONLOSSES);
   double cwP = TesterStatistics(STAT_CONPROFITMAX);
   double clP = TesterStatistics(STAT_CONLOSSMAX);

   double wr   =(tr>0)?100.0*wt/tr:0.0;
   double avgW =(wt>0)?gp/wt:0.0;
   double avgL =(lt>0)?MathAbs(gl)/lt:0.0;
   double payR =(avgL>0.0)?avgW/avgL:0.0;
   double netP =(dep>0)?100.0*net/dep:0.0;
   double lgWR =(lg>0)?100.0*lgW/lg:0.0;
   double shWR =(sh>0)?100.0*shW/sh:0.0;

   // ---- hold-time scan: per position-id (partials = one trade), magic-filtered ----
   //
   // FIXED: this scan used to return n=0 and print a 1970 date range, because
   // BOTH of its filters were wrong once the EA became multi-symbol:
   //   * the magic test assumed magics were contiguous (base+1 .. base+nBooks),
   //     but they are laid out base + sIx*10 + engine — so on a two-symbol run
   //     every 882000211-214 deal fell outside the range. Now matched against
   //     the ACTUAL book magics.
   //   * the symbol test compared against _Symbol only, discarding every deal
   //     belonging to the second symbol.
   // t0/t1 are set inside this loop, so when everything was filtered out they
   // stayed 0 and printed as 1970.01.01 — one root cause, two symptoms.
   HistorySelect(0,TimeCurrent()+86400);
   int nd=HistoryDealsTotal();
   ulong ids[]; datetime tin[]; datetime tout[];
   ArrayResize(ids,nd); ArrayResize(tin,nd); ArrayResize(tout,nd);
   int np=0; datetime t0=0,t1=0;
   for(int i=0;i<nd;i++){
      ulong dk=HistoryDealGetTicket(i); if(dk==0) continue;
      long dmg=HistoryDealGetInteger(dk,DEAL_MAGIC);
      bool ourMagic=false;
      for(int b=0;b<g_nBooks;b++) if(books[b].m_magic==dmg){ ourMagic=true; break; }
      if(!ourMagic) continue;
      string dsym=HistoryDealGetString(dk,DEAL_SYMBOL);
      bool ourSym=false;
      for(int y=0;y<g_nSyms;y++) if(g_sym[y].name==dsym){ ourSym=true; break; }
      if(!ourSym) continue;
      long ent=HistoryDealGetInteger(dk,DEAL_ENTRY);
      datetime dt=(datetime)HistoryDealGetInteger(dk,DEAL_TIME);
      if(t0==0||dt<t0) t0=dt;
      if(dt>t1) t1=dt;
      ulong pid=(ulong)HistoryDealGetInteger(dk,DEAL_POSITION_ID);
      int idx=-1;
      for(int j=0;j<np;j++) if(ids[j]==pid){ idx=j; break; }
      if(idx<0){ idx=np; ids[np]=pid; tin[np]=0; tout[np]=0; np++; }
      if(ent==DEAL_ENTRY_IN  && (tin[idx]==0||dt<tin[idx])) tin[idx]=dt;
      if(ent==DEAL_ENTRY_OUT &&  dt>tout[idx])              tout[idx]=dt;
   }
   double sumMin=0; long maxMin=0; int nh=0;
   for(int j=0;j<np;j++){
      if(tin[j]==0||tout[j]==0) continue;
      long mins=(long)((tout[j]-tin[j])/60);
      sumMin+=(double)mins; if(mins>maxMin) maxMin=mins; nh++;
   }
   double avgHold=(nh>0)?sumMin/nh:0.0;

   string b="\n"+
   "+==========================================================+\n"+
   "|      RUN SUMMARY  ·  TRENDPULSE GOLDEN GOOSE E4  (single engine: PULLBACK)\n"+
   "|      "+SymLine()+"   "+((t0>0)?(TimeToString(t0,TIME_DATE)+" -> "+TimeToString(t1,TIME_DATE)):"(range n/a)")
        +"   Magic "+MagicLine()+"\n"+
   "+--- P&L --------------------------------------------------+\n"+
   "|  Initial deposit    $"+DoubleToString(dep,2)+"\n"+
   "|  Net profit         $"+DoubleToString(net,2)+"   ("+DoubleToString(netP,2)+"%)\n"+
   "|  Gross profit       $"+DoubleToString(gp,2)+"\n"+
   "|  Gross loss         $"+DoubleToString(gl,2)+"\n"+
   "|  Profit factor      "+DoubleToString(pf,3)+"\n"+
   "|  Expected payoff    $"+DoubleToString(ep,2)+" / trade\n"+
   "|  Recovery factor    "+DoubleToString(rf,2)+"\n"+
   "|  Sharpe ratio       "+DoubleToString(sr,2)+"\n"+
   "+--- TRADES -----------------------------------------------+\n"+
   "|  Total trades       "+IntegerToString(tr)+"    Win rate "+DoubleToString(wr,2)+"%\n"+
   "|  Wins / Losses      "+IntegerToString(wt)+" / "+IntegerToString(lt)+"\n"+
   "|  Longs              "+IntegerToString(lg)+"  (WR "+DoubleToString(lgWR,2)+"%)    Shorts  "
        +IntegerToString(sh)+"  (WR "+DoubleToString(shWR,2)+"%)\n"+
   "|  Avg win / loss     $"+DoubleToString(avgW,2)+" / $"+DoubleToString(avgL,2)
        +"    Payoff ratio "+DoubleToString(payR,2)+"\n"+
   "|  Largest win/loss   $"+DoubleToString(maxW,2)+" / $"+DoubleToString(maxL,2)+"\n"+
   "|  Max consec wins    "+IntegerToString(cw)+"  ($"+DoubleToString(cwP,2)+")    Max consec losses  "
        +IntegerToString(cl)+"  ($"+DoubleToString(clP,2)+")\n"+
   "|  Avg hold           "+DoubleToString(avgHold,1)+" min    Max hold  "
        +IntegerToString((int)maxMin)+" min    (per position-id, n="+IntegerToString(nh)+")\n"+
   "+--- RISK -------------------------------------------------+\n"+
   "|  Balance max DD     $"+DoubleToString(bdd,2)+"   ("+DoubleToString(bddp,2)+"%)\n"+
   "|  Equity  max DD     $"+DoubleToString(edd,2)+"   ("+DoubleToString(eddp,2)+"%)\n"+
   "+==========================================================+";
   Print(b);
   PrintFuelByEngine();
}

//==================================================================
// FUEL-GAUGE BREAKDOWN — per engine, straight off the buffered CSV rows.
// This is the research print: for every engine it shows, split by winners
// vs losers, the mean of every fuel metric we log. A metric whose W-mean
// and L-mean separate is a fuel-gauge candidate for THAT engine.
// It also prints the giveback stats (the MAPT signal) and the MAE
// distribution hint (the VLE-cut signal).
// Reads only g_tradeBuf, so it costs nothing and can't affect trading.
//==================================================================
void PrintFuelByEngine(){
   int total=ArraySize(g_tradeBuf);
   if(total<=0){ Print("FUEL: no trades buffered — nothing to summarise."); return; }

   string engines[8]; int nEng=0;
   for(int i=0;i<total;i++){
      string f[]; if(StringSplit(g_tradeBuf[i],',',f)<24) continue;
      if(f[12]=="PYRTIER") continue;                       // tiers carry no MFE/MAE of their own
      bool seen=false;
      for(int e=0;e<nEng;e++) if(engines[e]==f[0]){ seen=true; break; }
      if(!seen && nEng<8){ engines[nEng]=f[0]; nEng++; }
   }

   string outp="\n+==========================================================+\n"+
               "|      FUEL-GAUGE BREAKDOWN BY ENGINE   ("+_Symbol+")\n"+
               "|      W = mean over winners · L = mean over losers\n"+
               "|      A metric whose W and L separate is a gate candidate.\n"+
               "+==========================================================+";

   for(int e=0;e<nEng;e++){
      int nW=0,nL=0;
      double sW=0,sL=0;                                    // profit sums
      double adxW=0,adxL=0, aeW=0,aeL=0, gapW=0,gapL=0;
      double swW=0,swL=0, vrW=0,vrL=0, drW=0,drL=0, slpW=0,slpL=0;
      double mfeW=0,mfeL=0, maeW=0,maeL=0, gbW=0,gbL=0;
      double maeWorst=0, mfeLoserMax=0;
      int    loserPeaked=0;                                // losers that were >= $15 up

      for(int i=0;i<total;i++){
         string f[]; if(StringSplit(g_tradeBuf[i],',',f)<24) continue;
         if(f[0]!=engines[e]) continue;
         if(f[12]=="PYRTIER") continue;
         double p  =StringToDouble(f[10]);
         double mfe=StringToDouble(f[14]), mae=StringToDouble(f[15]);
         double adx=StringToDouble(f[17]), slp=StringToDouble(f[18]);
         double gap=StringToDouble(f[19]), dr =StringToDouble(f[20]);
         double ae =StringToDouble(f[21]), sw =StringToDouble(f[22]), vr=StringToDouble(f[23]);
         double gb =(mfe>0)?(mfe-p)/mfe*100.0:0.0;
         if(mae<maeWorst) maeWorst=mae;
         if(p>0){
            nW++; sW+=p; adxW+=adx; aeW+=ae; gapW+=gap; swW+=sw; vrW+=vr; drW+=dr; slpW+=slp;
            mfeW+=mfe; maeW+=mae; gbW+=gb;
         } else {
            nL++; sL+=p; adxL+=adx; aeL+=ae; gapL+=gap; swL+=sw; vrL+=vr; drL+=dr; slpL+=slp;
            mfeL+=mfe; maeL+=mae; gbL+=gb;
            if(mfe>=15.0) loserPeaked++;
            if(mfe>mfeLoserMax) mfeLoserMax=mfe;
         }
      }
      int n=nW+nL; if(n==0) continue;
      double pf=(sL!=0.0)?sW/MathAbs(sL):0.0;
      double dW=(nW>0)?1.0/nW:0.0, dL=(nL>0)?1.0/nL:0.0;

      outp+="\n|  ["+engines[e]+"]  trades "+IntegerToString(n)+
            "   W "+IntegerToString(nW)+" / L "+IntegerToString(nL)+
            "   WR "+DoubleToString((n>0?100.0*nW/n:0),1)+"%"+
            "   net $"+DoubleToString(sW+sL,2)+"   PF "+DoubleToString(pf,2)+"\n"+
            "|    metric        winners        losers      separation\n"+
            "|    adx          "+DoubleToString(adxW*dW,2)+"   vs   "+DoubleToString(adxL*dL,2)+
                                 "     d="+DoubleToString(adxW*dW-adxL*dL,2)+"\n"+
            "|    atr_exp      "+DoubleToString(aeW*dW,3)+"   vs   "+DoubleToString(aeL*dL,3)+
                                 "     d="+DoubleToString(aeW*dW-aeL*dL,3)+"\n"+
            "|    drift        "+DoubleToString(drW*dW,3)+"   vs   "+DoubleToString(drL*dL,3)+
                                 "     d="+DoubleToString(drW*dW-drL*dL,3)+"\n"+
            "|    swing_room   "+DoubleToString(swW*dW,3)+"   vs   "+DoubleToString(swL*dL,3)+
                                 "     d="+DoubleToString(swW*dW-swL*dL,3)+"\n"+
            "|    vol_ratio    "+DoubleToString(vrW*dW,3)+"   vs   "+DoubleToString(vrL*dL,3)+
                                 "     d="+DoubleToString(vrW*dW-vrL*dL,3)+"\n"+
            "|    ema_gap      "+DoubleToString(gapW*dW,1)+"   vs   "+DoubleToString(gapL*dL,1)+
                                 "     d="+DoubleToString(gapW*dW-gapL*dL,1)+"\n"+
            "|    m5_slope     "+DoubleToString(slpW*dW,1)+"   vs   "+DoubleToString(slpL*dL,1)+
                                 "     d="+DoubleToString(slpW*dW-slpL*dL,1)+"\n"+
            "|    -- MAPT signal (giveback) --\n"+
            "|    avg MFE      W $"+DoubleToString(mfeW*dW,2)+"   L $"+DoubleToString(mfeL*dL,2)+"\n"+
            "|    avg giveback W "+DoubleToString(gbW*dW,1)+"%   L "+DoubleToString(gbL*dL,1)+"%\n"+
            "|    losers that peaked >= $15:  "+IntegerToString(loserPeaked)+
                 " of "+IntegerToString(nL)+"   (max loser peak $"+DoubleToString(mfeLoserMax,2)+")\n"+
            "|    -- VLE signal (adverse excursion) --\n"+
            "|    avg MAE      W $"+DoubleToString(maeW*dW,2)+"   L $"+DoubleToString(maeL*dL,2)+
                 "   worst $"+DoubleToString(maeWorst,2)+"\n";
   }
   outp+="+==========================================================+\n"+
         "  NOTE: means only — the CSV carries every trade for the full\n"+
         "  expectancy-by-band analysis (that is where the real box comes from).";
   Print(outp);
}

// Tester hook — fires once at the end of every Strategy-Tester run.
double OnTester() {
   PrintRunSummary();
   return TesterStatistics(STAT_PROFIT_FACTOR);   // custom criterion = PF
}

