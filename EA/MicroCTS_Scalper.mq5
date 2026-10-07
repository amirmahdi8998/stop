//+------------------------------------------------------------------+
//|                                              MicroCTS_Scalper.mq5|
//|  M1 spike-scalper combining:                                     |
//|   - MicroMap trigger (MohammadAli Poursamadi, spike-cycle #3):   |
//|     spike -> counter-trend micro-channel -> break entry;         |
//|     max 3 attempts per setup, then the setup is invalidated.     |
//|   - CTS context filter (Hooman Moghrazadi, Comprehensive         |
//|     Trading Strategy): 1) HTF trend, 2) PRZ confluence zone,     |
//|     3) momentum (time-divergence / hidden RSI divergence),       |
//|     4) trigger = the MicroMap break.                             |
//|   - Anti-margin engine built after forensics of the compiled     |
//|     "Javier Gold Scalper V2" logs (2026-09-30..10-07):           |
//|     hard caps on concurrent positions, aggregate open risk,      |
//|     daily loss, free-margin and margin-level gates before EVERY  |
//|     send, basket stop, and quiet backoff instead of per-tick     |
//|     order spam (10019 No-Money / 10027 AT-disabled floods).      |
//|                                                                  |
//|  No grid. No martingale. Every position is born with a hard SL.  |
//|  Demo + Strategy Tester first. No profit is guaranteed.          |
//+------------------------------------------------------------------+
#property copyright "stop repo - arena build"
#property link      "https://poursamadi.com/micromap/"
#property version   "1.00"
#property description "MicroMap + CTS M1 scalper with hard anti-margin risk engine"

#include <Trade/Trade.mqh>

//--- enums ---------------------------------------------------------
enum ENUM_ENTRY_MODE
  {
   ENTRY_H1 = 1, // H1: break of last channel high (fastest, best R:R)
   ENTRY_H2 = 2, // H2: wait for H1 break + new high (higher winrate)
   ENTRY_H3 = 3  // H3: wait for 2 closes beyond H1 (max confirmation)
  };

enum ENUM_TP_MODE
  {
   TP_FIXED_R    = 0, // Fixed R multiple of SL distance
   TP_STRUCTURAL = 1, // Next HTF swing level (fallback: fixed R)
   TP_NONE       = 2  // No TP - manage with BE/trailing only
  };

enum ENUM_TRAIL_MODE
  {
   TRAIL_OFF    = 0, // No trailing
   TRAIL_ATR    = 1, // ATR(M1) distance trailing
   TRAIL_POINTS = 2  // Fixed points trailing (Javier-style, bounded)
  };

enum ENUM_MOMENTUM_MODE
  {
   MOM_OFF        = 0, // Momentum filter off
   MOM_TIMEDIV    = 1, // Time-divergence only (weak counter-move)
   MOM_HIDDENDIV  = 2, // Hidden RSI divergence only (HTF)
   MOM_BOTH       = 3, // Both required (max winrate)
   MOM_EITHER     = 4  // Either one (balanced)
  };

//--- identification ------------------------------------------------
input group "=== Identification ==="
input long   InpMagic                       = 20261007; // Magic number (keep unique!)
input string InpComment                     = "MCTS";   // Order comment

//--- risk engine (anti-margin core) --------------------------------
input group "=== Risk engine (anti-margin core) ==="
input double InpRiskPercent                 = 0.5;   // Risk per trade, % of equity
input double InpMaxTotalRiskPercent         = 1.5;   // Max SUM of open SL risk, % of equity
input int    InpMaxConcurrentPositions      = 2;     // Hard cap: simultaneous positions (1-5)
input double InpMaxLotCap                   = 0.10;  // Hard cap: lots per single position
input bool   InpNoAddWhileLosing            = true;  // Block new entry if same-dir position is in loss
input double InpDailyLossLimitPercent       = 3.0;   // Daily loss limit, % (0=off) - blocks new entries
input int    InpMaxTradesPerDay             = 12;    // Max entries per day (0=off)
input double InpBasketStopEquityPercent     = 2.0;   // Close ALL if floating loss >= x% equity (0=off)
input double InpMarginBufferFactor          = 5.0;   // Require free margin >= factor x order margin
input double InpMinMarginLevelAfterEntryPct = 1000;  // Require projected margin level >= x% (0=off)

//--- MicroMap trigger ----------------------------------------------
input group "=== MicroMap trigger (Poursamadi) ==="
input ENUM_ENTRY_MODE InpEntryMode          = ENTRY_H1; // Entry confirmation level
input int    InpSpikeLookbackBars           = 80;    // Bars to search for the spike
input int    InpSpikeMinCandles             = 2;     // Min candles in a spike run
input double InpSpikeMinBodyATR             = 0.8;   // Min candle body, x ATR(M1)
input double InpSpikeMinTotalATR            = 2.0;   // Min total spike range, x ATR(M1)
input double InpSpikeCloseExtremeFrac       = 0.25;  // Close within x of range from extreme
input int    InpChannelMinCandles           = 3;     // Min micro-channel candles
input int    InpChannelMaxCandles           = 25;    // Max micro-channel candles (stale setup)
input double InpChannelMaxBodyATR           = 0.5;   // Max channel candle body, x ATR(M1)
input int    InpChannelTolerancePoints      = 3;     // Lower-high tolerance, points
input double InpChannelMaxRetraceFrac       = 0.618; // Max pullback as fraction of spike range
input bool   InpUseInsideBarEntry           = true;  // Use inside-bar special entry when present
input int    InpMaxAttemptsPerSetup         = 3;     // MicroMap golden rule: 3 stops = setup dead
input double InpEntryBufferPoints           = 5;     // Stop-order buffer beyond level, points
input double InpSlBufferPoints              = 5;     // SL buffer beyond structure, points
input int    InpPendingExpiryBars           = 6;     // Delete unfilled pending after x M1 bars
input double InpMaxSlATR                    = 3.0;   // Reject setup if SL distance > x ATR(M1)

//--- CTS context filter (Moghrazadi) --------------------------------
input group "=== CTS context filter ==="
input ENUM_TIMEFRAMES InpHTF                = PERIOD_M15; // Higher timeframe for context
input bool   InpUseTrendFilter              = true;  // Step 1: trade only with HTF trend
input int    InpEmaFastHTF                  = 50;    // HTF fast EMA
input int    InpEmaSlowHTF                  = 200;   // HTF slow EMA
input bool   InpUseSwingStructure           = true;  // Trend also needs HH/HL (or LH/LL) structure
input int    InpSwingStrength               = 2;     // Swing fractal strength (bars each side)
input bool   InpUsePrzFilter                = true;  // Step 2: PRZ confluence required
input int    InpMinPrzScore                 = 2;     // Min PRZ confluence count
input double InpPrzProximityATR             = 0.6;   // Confluence proximity, x ATR(HTF)
input int    InpPrzFibLookbackHTF           = 120;   // HTF bars for fib range
input int    InpPrzSwingLookbackHTF         = 60;    // HTF bars for swing levels
input double InpRoundNumberStep             = 5.0;   // Round-number step in price (0=off; gold:5)
input bool   InpUsePivots                   = true;  // Daily pivots count as PRZ elements
input ENUM_MOMENTUM_MODE InpMomentumMode    = MOM_EITHER; // Step 3: momentum confirmation
input double InpTimeDivMinRatio             = 1.2;   // Time-divergence: impulse speed / pullback speed
input int    InpRsiPeriodHTF                = 14;    // HTF RSI period for hidden divergence

//--- exits ----------------------------------------------------------
input group "=== Exits ==="
input ENUM_TP_MODE InpTpMode                = TP_FIXED_R; // Take-profit mode
input double InpTpRiskMultiple              = 2.0;   // TP distance = x SL distance (fixed-R mode)
input double InpTpStructBufferPoints        = 10;    // Buffer before structural swing TP, points
input double InpBreakevenAtR                = 1.0;   // Move SL to BE at +xR (0=off)
input ENUM_TRAIL_MODE InpTrailMode          = TRAIL_ATR; // Trailing mode
input double InpTrailAtrMult                = 1.5;   // ATR trailing distance, x ATR(M1)
input double InpTrailActivateAtR            = 0.5;   // Start trailing at +xR
input int    InpTrailDistancePoints          = 60;   // Points-mode trailing distance
input int    InpTrailLockPoints              = 20;   // Points-mode min locked profit
input bool   InpPartialCloseEnabled          = false; // Partial close at R
input double InpPartialCloseAtR             = 1.0;   // Partial close at +xR
input double InpPartialCloseFraction        = 0.5;   // Fraction of volume to close

//--- market filters --------------------------------------------------
input group "=== Filters & misc ==="
input int    InpMaxSpreadPoints             = 45;    // Max spread, points (0=off)
input bool   InpUseSessionFilter            = true;  // Trade only inside session window
input int    InpSessionStartHour            = 7;     // Session start hour, server time
input int    InpSessionEndHour              = 20;    // Session end hour, server time
input int    InpAtrPeriod                   = 14;    // ATR(M1) period
input int    InpSlippagePoints              = 20;    // Max deviation, points
input int    InpCooldownAfterRejectSec      = 300;   // Pause new entries x sec after hard reject
input bool   InpShowChartComment            = true;  // Show status comment on chart

//--- globals ---------------------------------------------------------
CTrade   trade;
int      hAtrM1   = INVALID_HANDLE;
int      hEmaFast = INVALID_HANDLE;
int      hEmaSlow = INVALID_HANDLE;
int      hRsiHTF  = INVALID_HANDLE;
int      hAtrHTF  = INVALID_HANDLE;

double   g_atrM1  = 0.0;
double   g_atrHTF = 0.0;
datetime g_lastM1Bar = 0;
bool     g_hedging = true;

struct PosRec
  {
   ulong    ticket;
   int      dir;        // +1 buy, -1 sell
   double   openPrice;
   double   initSl;
   double   riskDist;   // |open - initSl|
   double   initVolume;
   bool     partialDone;
  };
PosRec   g_pos[];

struct SetupState
  {
   bool     active;
   datetime anchor;        // spike-end bar time = setup id
   int      dir;           // +1 buy, -1 sell
   int      attempts;      // losing SL exits taken on this setup
   double   channelExtreme;// channel low (buy) / high (sell): invalidation + SL base
   double   triggerLevel;  // current H1 trigger price (before buffers)
   double   slLevel;       // structural SL price (before buffers, incl. buffer offset)
   bool     awaitingRetry; // after a losing SL: place entry #2/#3 from next closed bar
   bool     insideBar;     // setup came from the inside-bar special case
   // H2/H3 confirmation state
   int      breakCloses;   // closed bars beyond H1 in setup direction
   double   postBreakHi;   // highest high since first break close
   double   postBreakLo;   // lowest low since first break close
   bool     postBreakValid;
   // momentum stats captured at detection
   double   impBars, impRange, chBars, chRange;
  };
SetupState g_st;

datetime g_pendingPlacedBar = 0;
bool     g_pendingIsRetry   = false;

// used setup anchors (expired / invalidated / consumed) - never re-arm them
datetime g_usedAnchors[];

// daily stats
int      g_day = -1;
double   g_dayStartEquity = 0.0;
int      g_tradesToday = 0;
bool     g_dailyBlocked = false;
bool     g_basketBlockedToday = false;

// backoff / throttled logging
datetime g_blockedUntil = 0;
datetime g_lastAtDisabledLog = 0;
string   g_lastBlockReason = "";
datetime g_lastBlockLog = 0;

//+------------------------------------------------------------------+
//| small helpers                                                    |
//+------------------------------------------------------------------+
double PointVal()  { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
int    DigitsVal() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }
double TickSize()  { return SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE); }

double NormPrice(double p)
  {
   double ts = TickSize();
   if(ts <= 0) return NormalizeDouble(p, DigitsVal());
   return NormalizeDouble(MathRound(p / ts) * ts, DigitsVal());
  }
// round SL away from market (conservative)
double NormSl(double p, bool buy)
  {
   double ts = TickSize();
   if(ts <= 0) return NormalizeDouble(p, DigitsVal());
   double units = buy ? MathFloor(p / ts + 1e-8) : MathCeil(p / ts - 1e-8);
   return NormalizeDouble(units * ts, DigitsVal());
  }
// round TP away from market (never promises a closer fill than requested)
double NormTp(double p, bool buy)
  {
   double ts = TickSize();
   if(ts <= 0) return NormalizeDouble(p, DigitsVal());
   double units = buy ? MathCeil(p / ts - 1e-8) : MathFloor(p / ts + 1e-8);
   return NormalizeDouble(units * ts, DigitsVal());
  }

bool NewM1Bar()
  {
   datetime t = iTime(_Symbol, PERIOD_M1, 0);
   if(t == 0) return false;
   if(t != g_lastM1Bar) { g_lastM1Bar = t; return true; }
   return false;
  }

double LastClosedAtrM1()
  {
   double b[]; ArraySetAsSeries(b, true);
   if(CopyBuffer(hAtrM1, 0, 1, 1, b) != 1) return 0.0;
   return b[0];
  }
double LastClosedAtrHTF()
  {
   double b[]; ArraySetAsSeries(b, true);
   if(CopyBuffer(hAtrHTF, 0, 1, 1, b) != 1) return 0.0;
   return b[0];
  }

void LogThrottled(string msg, int seconds = 300)
  {
   static string lastMsg = "";
   static datetime lastT = 0;
   datetime now = TimeCurrent();
   if(msg == lastMsg && now - lastT < seconds) return;
   lastMsg = msg; lastT = now;
   Print(msg);
  }

bool AnchorUsed(datetime a)
  {
   for(int i = 0; i < ArraySize(g_usedAnchors); i++)
      if(g_usedAnchors[i] == a) return true;
   return false;
  }
void MarkAnchorUsed(datetime a)
  {
   if(a == 0 || AnchorUsed(a)) return;
   int n = ArraySize(g_usedAnchors);
   ArrayResize(g_usedAnchors, n + 1);
   g_usedAnchors[n] = a;
   if(ArraySize(g_usedAnchors) > 200)
     {
      for(int i = 0; i < ArraySize(g_usedAnchors) - 1; i++)
         g_usedAnchors[i] = g_usedAnchors[i + 1];
      ArrayResize(g_usedAnchors, ArraySize(g_usedAnchors) - 1);
     }
  }

int MyPositionsCount(int dir = 0)
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(dir != 0)
        {
         int d = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         if(d != dir) continue;
        }
      n++;
     }
   return n;
  }

bool DirHasLosingPosition(int dir)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int d = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      if(d != dir) continue;
      if(PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) < 0.0) return true;
     }
   return false;
  }

double MyFloatingPL()
  {
   double s = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      s += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   return s;
  }

double MyOpenRiskMoney()
  {
   double sum = 0.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = TickSize();
   if(tickValue <= 0 || ts <= 0) return 0.0;
   for(int i = 0; i < ArraySize(g_pos); i++)
     {
      if(g_pos[i].riskDist <= 0.0) continue;
      sum += g_pos[i].initVolume * g_pos[i].riskDist / ts * tickValue;
     }
   return sum;
  }

ulong MyPendingTicket()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      return tk;
     }
   return 0;
  }

void DeleteMyPending(string why)
  {
   ulong tk = MyPendingTicket();
   if(tk == 0) return;
   if(trade.OrderDelete(tk))
      PrintFormat("Pending %I64u deleted (%s)", tk, why);
   else
      LogThrottled(StringFormat("Pending delete failed %I64u rc=%u", tk, trade.ResultRetcode()), 60);
   g_pendingIsRetry = false;
  }

//+------------------------------------------------------------------+
//| entry gates                                                      |
//+------------------------------------------------------------------+
bool AutoTradingOn()
  {
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) return false;
   long sm = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(sm != SYMBOL_TRADE_MODE_FULL) return false;
   return true;
  }

bool InSession()
  {
   if(!InpUseSessionFilter) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if(InpSessionStartHour <= InpSessionEndHour)
      return (h >= InpSessionStartHour && h < InpSessionEndHour);
   return (h >= InpSessionStartHour || h < InpSessionEndHour); // overnight window
  }

bool SpreadOK()
  {
   if(InpMaxSpreadPoints <= 0) return true;
   long sp = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (sp > 0 && sp <= InpMaxSpreadPoints);
  }

void UpdateDailyStats()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int today = dt.year * 1000 + dt.yday;
   if(today != g_day)
     {
      g_day = today;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_tradesToday = 0;
      g_dailyBlocked = false;
      g_basketBlockedToday = false;
     }
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(InpDailyLossLimitPercent > 0 && g_dayStartEquity > 0 &&
      (g_dayStartEquity - eq) / g_dayStartEquity * 100.0 >= InpDailyLossLimitPercent)
     {
      if(!g_dailyBlocked)
        {
         g_dailyBlocked = true;
         PrintFormat("Daily loss limit %.2f%% reached - new entries blocked until next day",
                     InpDailyLossLimitPercent);
         DeleteMyPending("daily loss limit");
        }
     }
  }

bool EntryGatesOK(int dir, string &reason)
  {
   reason = "";
   if(TimeCurrent() < g_blockedUntil) { reason = "cooldown after reject"; return false; }
   if(!AutoTradingOn())
     {
      // quiet wait with throttled log - no per-tick order spam (fixes the 10027 flood)
      if(TimeCurrent() - g_lastAtDisabledLog > 300)
        {
         g_lastAtDisabledLog = TimeCurrent();
         Print("AutoTrading not enabled (terminal/account/EA button or symbol mode) - waiting quietly");
        }
      reason = "autotrading off";
      return false;
     }
   if(g_dailyBlocked || g_basketBlockedToday) { reason = "daily block active"; return false; }
   if(InpMaxTradesPerDay > 0 && g_tradesToday >= InpMaxTradesPerDay) { reason = "max trades/day"; return false; }
   if(!InSession()) { reason = "outside session"; return false; }
   if(!SpreadOK()) { reason = "spread too wide"; return false; }
   int conc = MyPositionsCount();
   int cap = g_hedging ? MathMin(InpMaxConcurrentPositions, 5) : 1;
   if(conc >= cap) { reason = StringFormat("concurrency cap %d", cap); return false; }
   if(InpNoAddWhileLosing && DirHasLosingPosition(dir))
     { reason = "same-direction position in loss (NoAddWhileLosing)"; return false; }
   return true;
  }

// margin gates evaluated for a concrete order (fixes the 10019 No-Money storm)
bool MarginOK(ENUM_ORDER_TYPE type, double lots, double price, string &reason)
  {
   reason = "";
   double needMargin = 0.0;
   if(!OrderCalcMargin(type, _Symbol, lots, price, needMargin) || needMargin <= 0.0)
     { reason = "margin calc failed"; return false; }
   double freeM = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double usedM = AccountInfoDouble(ACCOUNT_MARGIN);
   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   if(freeM < needMargin * InpMarginBufferFactor)
     {
      reason = StringFormat("free margin %.2f < %.1fx required %.2f", freeM, InpMarginBufferFactor, needMargin);
      return false;
     }
   if(InpMinMarginLevelAfterEntryPct > 0)
     {
      double projLevel = (usedM + needMargin > 0) ? eq / (usedM + needMargin) * 100.0 : 0.0;
      if(projLevel > 0 && projLevel < InpMinMarginLevelAfterEntryPct)
        {
         reason = StringFormat("projected margin level %.0f%% < %.0f%%", projLevel, InpMinMarginLevelAfterEntryPct);
         return false;
        }
     }
   return true;
  }

//+------------------------------------------------------------------+
//| position bookkeeping & management                                |
//+------------------------------------------------------------------+
void SyncPositions()
  {
   for(int i = ArraySize(g_pos) - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(g_pos[i].ticket))
        {
         for(int j = i; j < ArraySize(g_pos) - 1; j++) g_pos[j] = g_pos[j + 1];
         ArrayResize(g_pos, ArraySize(g_pos) - 1);
        }
     }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      bool known = false;
      for(int j = 0; j < ArraySize(g_pos); j++) if(g_pos[j].ticket == tk) { known = true; break; }
      if(known) continue;
      PosRec rec;
      rec.ticket = tk;
      rec.dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      rec.openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      rec.initSl = PositionGetDouble(POSITION_SL);
      rec.riskDist = (rec.initSl > 0) ? MathAbs(rec.openPrice - rec.initSl) : 0.0;
      rec.initVolume = PositionGetDouble(POSITION_VOLUME);
      rec.partialDone = false;
      int n = ArraySize(g_pos);
      ArrayResize(g_pos, n + 1);
      g_pos[n] = rec;
      PrintFormat("Position tracked %I64u dir=%d open=%s sl=%s vol=%.2f",
                  tk, rec.dir, DoubleToString(rec.openPrice, DigitsVal()),
                  DoubleToString(rec.initSl, DigitsVal()), rec.initVolume);
     }
  }

double PosR(int idx, double &priceNow)
  {
   int d = g_pos[idx].dir;
   priceNow = (d > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(g_pos[idx].riskDist <= 0) return 0.0;
   return (priceNow - g_pos[idx].openPrice) * d / g_pos[idx].riskDist;
  }

void ManagePosition(int idx)
  {
   ulong tk = g_pos[idx].ticket;
   if(!PositionSelectByTicket(tk)) return;
   int d = g_pos[idx].dir;
   double curSl = PositionGetDouble(POSITION_SL);
   double curTp = PositionGetDouble(POSITION_TP);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double price = (d > 0) ? bid : ask;
   double pt = PointVal();
   long stopsLvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = MathMax((double)stopsLvl, (double)freezeLvl) * pt + TickSize();
   double dummy = 0.0;
   double r = PosR(idx, dummy);

   //--- partial close
   if(InpPartialCloseEnabled && !g_pos[idx].partialDone && InpPartialCloseAtR > 0 && r >= InpPartialCloseAtR)
     {
      double vol = PositionGetDouble(POSITION_VOLUME);
      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double minV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double closeV = MathFloor(vol * InpPartialCloseFraction / step) * step;
      if(closeV >= minV && (vol - closeV) >= minV)
        {
         if(trade.PositionClosePartial(tk, closeV))
           {
            g_pos[idx].partialDone = true;
            g_pos[idx].initVolume = vol - closeV;
            PrintFormat("Partial close %I64u vol=%.2f at R=%.2f", tk, closeV, r);
           }
        }
     }

   double newSl = curSl;

   //--- breakeven
   if(InpBreakevenAtR > 0 && g_pos[idx].riskDist > 0 && r >= InpBreakevenAtR)
     {
      double be = NormPrice(g_pos[idx].openPrice + d * pt);
      if(d > 0 && curSl < be && (bid - be) >= minDist)
         newSl = MathMax(newSl, be);
      if(d < 0 && (curSl == 0 || curSl > be) && (be - ask) >= minDist)
         newSl = (curSl == 0) ? be : MathMin(newSl, be);
     }

   //--- trailing
   if(InpTrailActivateAtR <= 0 || r >= InpTrailActivateAtR)
     {
      if(InpTrailMode == TRAIL_ATR && g_atrM1 > 0)
        {
         double prop = NormPrice(price - d * InpTrailAtrMult * g_atrM1);
         if(d > 0 && prop > newSl && (bid - prop) >= minDist) newSl = prop;
         if(d < 0 && (newSl == 0 || prop < newSl) && (prop - ask) >= minDist) newSl = prop;
        }
      else if(InpTrailMode == TRAIL_POINTS)
        {
         double prop = NormPrice(price - d * InpTrailDistancePoints * pt);
         double locked = (prop - g_pos[idx].openPrice) * d;
         if(locked >= InpTrailLockPoints * pt - 1e-8)
           {
            if(d > 0 && prop > newSl && (bid - prop) >= minDist) newSl = prop;
            if(d < 0 && (newSl == 0 || prop < newSl) && (prop - ask) >= minDist) newSl = prop;
           }
        }
     }

   if(newSl <= 0) return;
   newSl = NormSl(newSl, d > 0);
   if(MathAbs(newSl - curSl) >= pt * 0.5)
     {
      if(!trade.PositionModify(tk, newSl, curTp))
         LogThrottled(StringFormat("SL modify failed %I64u rc=%u", tk, trade.ResultRetcode()), 60);
     }
  }

void CloseAllMine(string why)
  {
   Print("Closing all EA positions: ", why);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(!trade.PositionClose(tk))
         LogThrottled(StringFormat("Basket close failed %I64u rc=%u", tk, trade.ResultRetcode()), 30);
     }
  }

void BasketStopCheck()
  {
   if(InpBasketStopEquityPercent <= 0 || g_basketBlockedToday) return;
   if(MyPositionsCount() == 0) return;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq <= 0) return;
   double fl = MyFloatingPL();
   double limit = -eq * InpBasketStopEquityPercent / 100.0;
   if(fl <= limit)
     {
      PrintFormat("BASKET STOP: floating %.2f <= -%.2f%% of equity", fl, InpBasketStopEquityPercent);
      CloseAllMine("basket stop");
      DeleteMyPending("basket stop");
      MarkAnchorUsed(g_st.anchor);
      g_st.active = false;
      g_basketBlockedToday = true; // no re-entry today after a basket stop
     }
  }

//+------------------------------------------------------------------+
//| CTS step 1: HTF trend                                            |
//+------------------------------------------------------------------+
int HtfTrend()
  {
   double f[], s[]; ArraySetAsSeries(f, true); ArraySetAsSeries(s, true);
   if(CopyBuffer(hEmaFast, 0, 1, 2, f) != 2) return 0;
   if(CopyBuffer(hEmaSlow, 0, 1, 2, s) != 2) return 0;
   MqlRates hr[]; ArraySetAsSeries(hr, true);
   if(CopyRates(_Symbol, InpHTF, 1, 3, hr) != 3) return 0;
   int dir = 0;
   if(f[0] > s[0] && hr[0].close > s[0]) dir = 1;
   else if(f[0] < s[0] && hr[0].close < s[0]) dir = -1;
   if(dir == 0) return 0;
   if(!InpUseSwingStructure) return dir;

   int need = InpPrzSwingLookbackHTF + 2 * InpSwingStrength + 5;
   MqlRates r[]; ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpHTF, 1, need, r) < need) return dir;
   int k = InpSwingStrength;
   double lastHi1 = 0, lastHi2 = 0, lastLo1 = 0, lastLo2 = 0;
   int hiCount = 0, loCount = 0;
   for(int i = k; i < need - k && (hiCount < 2 || loCount < 2); i++)
     {
      bool isHi = true, isLo = true;
      for(int j = 1; j <= k; j++)
        {
         if(r[i].high <= r[i - j].high || r[i].high <= r[i + j].high) isHi = false;
         if(r[i].low  >= r[i - j].low  || r[i].low  >= r[i + j].low ) isLo = false;
        }
      if(isHi)
        {
         if(hiCount == 0) lastHi1 = r[i].high;
         else if(hiCount == 1) lastHi2 = r[i].high;
         hiCount++;
        }
      if(isLo)
        {
         if(loCount == 0) lastLo1 = r[i].low;
         else if(loCount == 1) lastLo2 = r[i].low;
         loCount++;
        }
     }
   if(hiCount < 2 || loCount < 2) return dir;
   bool bullStruct = (lastHi1 > lastHi2) && (lastLo1 > lastLo2);
   bool bearStruct = (lastHi1 < lastHi2) && (lastLo1 < lastLo2);
   if(dir > 0 && !bullStruct) return 0;
   if(dir < 0 && !bearStruct) return 0;
   return dir;
  }

//+------------------------------------------------------------------+
//| CTS step 2: PRZ confluence score near a price level              |
//+------------------------------------------------------------------+
int PrzScore(int dir, double refPrice)
  {
   if(!InpUsePrzFilter) return InpMinPrzScore; // pass-through when disabled
   double prox = InpPrzProximityATR * g_atrHTF;
   if(prox <= 0) return 0;
   int score = 0;

   double f[], s[]; ArraySetAsSeries(f, true); ArraySetAsSeries(s, true);
   if(CopyBuffer(hEmaFast, 0, 1, 1, f) == 1 && MathAbs(refPrice - f[0]) <= prox) score++;
   if(CopyBuffer(hEmaSlow, 0, 1, 1, s) == 1 && MathAbs(refPrice - s[0]) <= prox) score++;

   int fibBars = InpPrzFibLookbackHTF;
   MqlRates hr[]; ArraySetAsSeries(hr, true);
   if(CopyRates(_Symbol, InpHTF, 1, fibBars, hr) == fibBars)
     {
      double hi = hr[0].high, lo = hr[0].low;
      for(int i = 1; i < fibBars; i++)
        {
         if(hr[i].high > hi) hi = hr[i].high;
         if(hr[i].low  < lo) lo = hr[i].low;
        }
      double rng = hi - lo;
      if(rng > 0)
        {
         double fibs[4];
         fibs[0] = hi - 0.382 * rng; fibs[1] = hi - 0.5 * rng;
         fibs[2] = hi - 0.618 * rng; fibs[3] = hi - 0.786 * rng;
         for(int i = 0; i < 4; i++)
            if(MathAbs(refPrice - fibs[i]) <= prox) { score++; break; } // fib cluster counts once
        }
     }

   int k = InpSwingStrength;
   int need = InpPrzSwingLookbackHTF + 2 * k + 5;
   MqlRates r[]; ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpHTF, 1, need, r) == need)
     {
      int counted = 0;
      for(int i = k; i < need - k && counted < 4; i++)
        {
         bool isHi = true, isLo = true;
         for(int j = 1; j <= k; j++)
           {
            if(r[i].high <= r[i - j].high || r[i].high <= r[i + j].high) isHi = false;
            if(r[i].low  >= r[i - j].low  || r[i].low  >= r[i + j].low ) isLo = false;
           }
         if(isHi && MathAbs(refPrice - r[i].high) <= prox) { score++; counted++; }
         else if(isLo && MathAbs(refPrice - r[i].low) <= prox) { score++; counted++; }
        }
     }

   if(InpRoundNumberStep > 0)
     {
      double nearest = MathRound(refPrice / InpRoundNumberStep) * InpRoundNumberStep;
      if(MathAbs(refPrice - nearest) <= prox) score++;
     }

   if(InpUsePivots)
     {
      double H = iHigh(_Symbol, PERIOD_D1, 1);
      double L = iLow(_Symbol, PERIOD_D1, 1);
      double C = iClose(_Symbol, PERIOD_D1, 1);
      if(H > 0 && L > 0 && C > 0)
        {
         double P = (H + L + C) / 3.0;
         double lv[5];
         lv[0] = P; lv[1] = 2 * P - L; lv[2] = 2 * P - H; lv[3] = P + (H - L); lv[4] = P - (H - L);
         for(int i = 0; i < 5; i++)
            if(MathAbs(refPrice - lv[i]) <= prox) { score++; break; } // pivot cluster counts once
        }
     }
   return score;
  }

//+------------------------------------------------------------------+
//| CTS step 3: momentum                                             |
//+------------------------------------------------------------------+
bool TimeDivergenceOK(double impBars, double impRange, double chBars, double chRange)
  {
   if(impBars <= 0 || impRange <= 0 || chBars <= 0 || chRange <= 0) return false;
   double impSpeed = impRange / impBars; // price per bar, impulse
   double chSpeed  = chRange  / chBars;  // price per bar, pullback
   if(chSpeed <= 0) return false;
   // impulse must be clearly faster than the counter-move => weak pullback
   return (impSpeed / chSpeed >= InpTimeDivMinRatio);
  }

bool HiddenDivergenceOK(int dir)
  {
   int k = InpSwingStrength;
   int need = InpPrzSwingLookbackHTF + 2 * k + 5;
   MqlRates r[]; ArraySetAsSeries(r, true);
   double rsi[]; ArraySetAsSeries(rsi, true);
   if(CopyRates(_Symbol, InpHTF, 1, need, r) < need) return false;
   if(CopyBuffer(hRsiHTF, 0, 1, need, rsi) < need) return false;
   double p1 = 0, p2 = 0, x1 = 0, x2 = 0; int cnt = 0;
   if(dir > 0)
     {
      for(int i = k; i < need - k && cnt < 2; i++)
        {
         bool isLo = true;
         for(int j = 1; j <= k; j++)
            if(r[i].low >= r[i - j].low || r[i].low >= r[i + j].low) { isLo = false; break; }
         if(isLo)
           {
            if(cnt == 0) { p1 = r[i].low; x1 = rsi[i]; }
            else if(cnt == 1) { p2 = r[i].low; x2 = rsi[i]; }
            cnt++;
           }
        }
      if(cnt < 2) return false;
      return (p1 < p2 && x1 > x2); // price LL + RSI HL = bullish hidden divergence
     }
   for(int i = k; i < need - k && cnt < 2; i++)
     {
      bool isHi = true;
      for(int j = 1; j <= k; j++)
         if(r[i].high <= r[i - j].high || r[i].high <= r[i + j].high) { isHi = false; break; }
      if(isHi)
        {
         if(cnt == 0) { p1 = r[i].high; x1 = rsi[i]; }
         else if(cnt == 1) { p2 = r[i].high; x2 = rsi[i]; }
         cnt++;
        }
     }
   if(cnt < 2) return false;
   return (p1 > p2 && x1 < x2); // price HH + RSI LH = bearish hidden divergence
  }

bool MomentumOK(int dir, double impBars, double impRange, double chBars, double chRange)
  {
   if(InpMomentumMode == MOM_OFF) return true;
   bool td = TimeDivergenceOK(impBars, impRange, chBars, chRange);
   bool hd = false;
   if(InpMomentumMode == MOM_HIDDENDIV || InpMomentumMode == MOM_BOTH || InpMomentumMode == MOM_EITHER)
      hd = HiddenDivergenceOK(dir);
   switch(InpMomentumMode)
     {
      case MOM_TIMEDIV:   return td;
      case MOM_HIDDENDIV: return hd;
      case MOM_BOTH:      return (td && hd);
      case MOM_EITHER:    return (td || hd);
     }
   return true;
  }

bool CtsFilterOK(int dir, double refPrice, double impBars, double impRange,
                 double chBars, double chRange, string &reason)
  {
   reason = "";
   if(InpUseTrendFilter)
     {
      int t = HtfTrend();
      if(t != dir) { reason = StringFormat("HTF trend %d != setup dir %d", t, dir); return false; }
     }
   if(InpUsePrzFilter)
     {
      int sc = PrzScore(dir, refPrice);
      if(sc < InpMinPrzScore) { reason = StringFormat("PRZ score %d < %d", sc, InpMinPrzScore); return false; }
     }
   if(!MomentumOK(dir, impBars, impRange, chBars, chRange))
     { reason = "momentum not confirmed"; return false; }
   return true;
  }

//+------------------------------------------------------------------+
//| MicroMap detection on closed M1 bars                             |
//+------------------------------------------------------------------+
bool IsSpikeCandle(const MqlRates &r[], int idx, int dir, double atr)
  {
   double body = MathAbs(r[idx].close - r[idx].open);
   double rng  = r[idx].high - r[idx].low;
   if(rng <= 0 || atr <= 0) return false;
   if(body < InpSpikeMinBodyATR * atr) return false;
   if(dir > 0)
     {
      if(r[idx].close <= r[idx].open) return false;
      if((r[idx].high - r[idx].close) > InpSpikeCloseExtremeFrac * rng) return false;
     }
   else
     {
      if(r[idx].close >= r[idx].open) return false;
      if((r[idx].close - r[idx].low) > InpSpikeCloseExtremeFrac * rng) return false;
     }
   return true;
  }

// detect the freshest micro-channel setup for a given direction,
// with the channel ending exactly at the last closed bar (series idx 1)
bool DetectMicroMapDir(int dir, double &trigger, double &slStruct, bool &insideBar,
                       double &impBars, double &impRange, double &chBars, double &chRange,
                       datetime &anchor, double &chanExtreme)
  {
   trigger = 0; slStruct = 0; insideBar = false; anchor = 0; chanExtreme = 0;
   impBars = impRange = chBars = chRange = 0;
   if(g_atrM1 <= 0) return false;
   int need = InpSpikeLookbackBars + InpChannelMaxCandles + 10;
   MqlRates r[]; ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, PERIOD_M1, 0, need, r) < need) return false;
   double tol = InpChannelTolerancePoints * PointVal();
   double buf = InpSlBufferPoints * PointVal();

   for(int e = 2; e <= InpSpikeLookbackBars; e++)
     {
      if(!IsSpikeCandle(r, e, dir, g_atrM1)) continue;
      int runStart = e;
      while(runStart + 1 < need && IsSpikeCandle(r, runStart + 1, dir, g_atrM1)) runStart++;
      int runLen = runStart - e + 1;
      if(runLen < InpSpikeMinCandles) continue;
      double hi = r[e].high, lo = r[e].low;
      for(int i = e + 1; i <= runStart; i++)
        {
         if(r[i].high > hi) hi = r[i].high;
         if(r[i].low  < lo) lo = r[i].low;
        }
      double spikeRange = hi - lo;
      if(spikeRange < InpSpikeMinTotalATR * g_atrM1) continue;

      int chanLen = e - 1;                    // channel bars: e-1 ... 1
      if(chanLen < InpChannelMinCandles) continue;
      if(chanLen > InpChannelMaxCandles) continue;

      bool ok = true;
      double chHi = r[e - 1].high, chLo = r[e - 1].low;
      for(int i = e - 1; i >= 1; i--)
        {
         double body = MathAbs(r[i].close - r[i].open);
         if(body > InpChannelMaxBodyATR * g_atrM1) { ok = false; break; }
         if(i < e - 1)
           {
            if(dir > 0 && r[i].high > r[i + 1].high + tol) { ok = false; break; } // lower highs
            if(dir < 0 && r[i].low  < r[i + 1].low  - tol) { ok = false; break; } // higher lows
           }
         if(r[i].high > chHi) chHi = r[i].high;
         if(r[i].low  < chLo) chLo = r[i].low;
         if(dir > 0 && r[i].high > hi) { ok = false; break; } // no new impulse high inside channel
         if(dir < 0 && r[i].low  < lo) { ok = false; break; }
        }
      if(!ok) continue;
      if(dir > 0 && chLo < hi - InpChannelMaxRetraceFrac * spikeRange) continue; // retrace cap
      if(dir < 0 && chHi > lo + InpChannelMaxRetraceFrac * spikeRange) continue;

      datetime a = r[e].time;
      if(AnchorUsed(a)) return false; // freshest setup already consumed - do not dig older ones

      bool ib = InpUseInsideBarEntry && (r[1].high < r[2].high) && (r[1].low > r[2].low);
      if(dir > 0)
        {
         trigger = r[1].high;                 // last channel high (H1) or inside-bar high
         slStruct = (ib ? r[1].low : chLo) - buf;
         chanExtreme = ib ? r[1].low : chLo;
        }
      else
        {
         trigger = r[1].low;                  // last channel low (L1) or inside-bar low
         slStruct = (ib ? r[1].high : chHi) + buf;
         chanExtreme = ib ? r[1].high : chHi;
        }
      insideBar = ib;
      anchor = a;
      impBars = (double)runLen; impRange = spikeRange;
      chBars = (double)chanLen; chRange = chHi - chLo;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| order construction                                               |
//+------------------------------------------------------------------+
double StructuralTp(int dir, double entryPrice, double slDist)
  {
   double fallback = entryPrice + dir * InpTpRiskMultiple * slDist;
   if(InpTpMode == TP_FIXED_R) return fallback;
   if(InpTpMode == TP_NONE) return 0.0;
   int k = InpSwingStrength;
   int need = InpPrzSwingLookbackHTF + 2 * k + 5;
   MqlRates r[]; ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpHTF, 1, need, r) < need) return fallback;
   double best = 0.0;
   double buf = InpTpStructBufferPoints * PointVal();
   for(int i = k; i < need - k; i++)
     {
      if(dir > 0)
        {
         bool isHi = true;
         for(int j = 1; j <= k; j++)
            if(r[i].high <= r[i - j].high || r[i].high <= r[i + j].high) { isHi = false; break; }
         if(isHi && r[i].high > entryPrice + buf)
           {
            double cand = r[i].high - buf;
            if(best == 0.0 || cand < best) best = cand; // nearest swing above
           }
        }
      else
        {
         bool isLo = true;
         for(int j = 1; j <= k; j++)
            if(r[i].low >= r[i - j].low || r[i].low >= r[i + j].low) { isLo = false; break; }
         if(isLo && r[i].low < entryPrice - buf)
           {
            double cand = r[i].low + buf;
            if(best == 0.0 || cand > best) best = cand; // nearest swing below
           }
        }
     }
   if(best == 0.0) return fallback;
   if((best - entryPrice) * dir < 0.5 * InpTpRiskMultiple * slDist) return fallback;
   return best;
  }

double CalcLots(double slDist, string &reason)
  {
   reason = "";
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = eq * InpRiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = TickSize();
   if(tickValue <= 0 || ts <= 0 || slDist <= 0) { reason = "lot calc inputs invalid"; return 0.0; }
   double lossPerLot = slDist / ts * tickValue;
   if(lossPerLot <= 0) { reason = "loss per lot <= 0"; return 0.0; }
   double lots = riskMoney / lossPerLot;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) { reason = "bad volume step"; return 0.0; }
   lots = MathFloor(lots / step) * step;
   double cap = MathMin(maxV, InpMaxLotCap);
   if(lots > cap) lots = MathFloor(cap / step) * step;
   if(lots < minV)
     { reason = StringFormat("risk-based lots below broker min %.2f", minV); return 0.0; }
   return lots;
  }

bool RiskSumOK(double newRiskMoney, string &reason)
  {
   reason = "";
   if(InpMaxTotalRiskPercent <= 0) return true;
   double openRisk = MyOpenRiskMoney();
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double cap = eq * InpMaxTotalRiskPercent / 100.0;
   if(openRisk + newRiskMoney > cap)
     {
      reason = StringFormat("total risk %.2f+%.2f > cap %.2f", openRisk, newRiskMoney, cap);
      return false;
     }
   return true;
  }

bool PendingLevelsValid(int dir, double entryPrice, double sl, double &minDist)
  {
   double pt = PointVal();
   long stopsLvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   minDist = MathMax((double)stopsLvl, (double)freezeLvl) * pt + TickSize();
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return false;
   if(dir > 0) return (entryPrice >= ask + minDist && (entryPrice - sl) >= minDist);
   return (entryPrice <= bid - minDist && (sl - entryPrice) >= minDist);
  }

bool PlaceStopOrder(int dir, double trigger, double slStruct, string tag)
  {
   string reason;
   if(!EntryGatesOK(dir, reason))
     {
      if(reason != g_lastBlockReason || TimeCurrent() - g_lastBlockLog > 600)
        {
         g_lastBlockReason = reason; g_lastBlockLog = TimeCurrent();
         PrintFormat("Entry blocked (%s): %s", tag, reason);
        }
      return false;
     }
   if(MyPendingTicket() != 0) return false; // one pending at a time

   double pt = PointVal();
   double entryPrice, sl, minDist;
   if(dir > 0)
     {
      entryPrice = NormPrice(trigger + InpEntryBufferPoints * pt);
      sl = NormSl(slStruct, true);
     }
   else
     {
      entryPrice = NormPrice(trigger - InpEntryBufferPoints * pt);
      sl = NormSl(slStruct, false);
     }
   if(!PendingLevelsValid(dir, entryPrice, sl, minDist)) return false; // too close to market; retry next bar

   double slDist = MathAbs(entryPrice - sl);
   if(g_atrM1 > 0 && slDist > InpMaxSlATR * g_atrM1)
     {
      LogThrottled(StringFormat("%s: SL distance %s > %.1fxATR - setup skipped",
                   tag, DoubleToString(slDist, DigitsVal()), InpMaxSlATR), 300);
      return false;
     }

   double lots = CalcLots(slDist, reason);
   if(lots <= 0) { LogThrottled(StringFormat("%s: %s", tag, reason), 300); return false; }

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double newRisk = lots * slDist / TickSize() * tickValue;
   if(!RiskSumOK(newRisk, reason))
     { LogThrottled(StringFormat("%s blocked: %s", tag, reason), 300); return false; }

   ENUM_ORDER_TYPE ot = (dir > 0) ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
   if(!MarginOK(ot, lots, entryPrice, reason))
     {
      LogThrottled(StringFormat("%s blocked by margin gate: %s", tag, reason), 300);
      g_blockedUntil = TimeCurrent() + InpCooldownAfterRejectSec;
      return false;
     }

   double tp = 0.0;
   if(InpTpMode != TP_NONE)
     {
      tp = StructuralTp(dir, entryPrice, slDist);
      if(tp > 0)
        {
         tp = NormTp(tp, dir > 0);
         if((tp - entryPrice) * dir < minDist)
            tp = NormTp(entryPrice + dir * InpTpRiskMultiple * slDist, dir > 0);
        }
     }

   bool sent = false;
   if(dir > 0) sent = trade.BuyStop(lots, entryPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, InpComment + " " + tag);
   else        sent = trade.SellStop(lots, entryPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, InpComment + " " + tag);

   uint rc = trade.ResultRetcode();
   if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL))
     {
      g_pendingPlacedBar = iTime(_Symbol, PERIOD_M1, 0);
      PrintFormat("PENDING %s dir=%s lots=%.2f entry=%s sl=%s tp=%s order=%I64u",
                  tag, dir > 0 ? "BUY" : "SELL", lots,
                  DoubleToString(entryPrice, DigitsVal()), DoubleToString(sl, DigitsVal()),
                  DoubleToString(tp, DigitsVal()), trade.ResultOrder());
      return true;
     }
   if(rc == TRADE_RETCODE_NO_MONEY || rc == TRADE_RETCODE_TRADE_DISABLED ||
      rc == TRADE_RETCODE_MARKET_CLOSED || rc == TRADE_RETCODE_SERVER_DISABLES_AT ||
      rc == TRADE_RETCODE_CLIENT_DISABLES_AT || rc == TRADE_RETCODE_TOO_MANY_REQUESTS ||
      rc == TRADE_RETCODE_LIMIT_ORDERS || rc == TRADE_RETCODE_LIMIT_VOLUME)
     {
      g_blockedUntil = TimeCurrent() + InpCooldownAfterRejectSec;
      LogThrottled(StringFormat("%s hard reject rc=%u - cooldown %ds", tag, rc, InpCooldownAfterRejectSec), 60);
     }
   else
      LogThrottled(StringFormat("%s send failed rc=%u", tag, rc), 60);
   return false;
  }

bool ModifyPending(ulong ticket, double entryPrice, double sl, double tp)
  {
   if(!OrderSelect(ticket)) return false;
   double eps = PointVal() * 0.5;
   if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - entryPrice) < eps &&
      MathAbs(OrderGetDouble(ORDER_SL) - sl) < eps &&
      MathAbs(OrderGetDouble(ORDER_TP) - tp) < eps) return true;
   if(!trade.OrderModify(ticket, entryPrice, sl, tp, ORDER_TIME_GTC, 0, 0.0))
     {
      LogThrottled(StringFormat("Pending modify failed %I64u rc=%u", ticket, trade.ResultRetcode()), 60);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| per-closed-bar strategy logic                                    |
//+------------------------------------------------------------------+
void OnClosedBar()
  {
   g_atrM1 = LastClosedAtrM1();
   g_atrHTF = LastClosedAtrHTF();
   if(g_atrM1 <= 0) return;

   MqlRates r[]; ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, PERIOD_M1, 0, 4, r) < 4) return;
   double lastClose = r[1].close, lastHigh = r[1].high, lastLow = r[1].low;
   double pt = PointVal();
   double buf = InpSlBufferPoints * pt;
   ulong pend = MyPendingTicket();

   //--- 1) structural invalidation of the active setup
   if(g_st.active && !g_st.awaitingRetry)
     {
      if((g_st.dir > 0 && lastClose < g_st.channelExtreme) ||
         (g_st.dir < 0 && lastClose > g_st.channelExtreme))
        {
         PrintFormat("Setup %s invalidated: close %s beyond structure %s",
                     TimeToString(g_st.anchor), DoubleToString(lastClose, DigitsVal()),
                     DoubleToString(g_st.channelExtreme, DigitsVal()));
         MarkAnchorUsed(g_st.anchor);
         g_st.active = false;
         DeleteMyPending("structure broken");
         pend = 0;
        }
     }

   //--- 2) retry entries (MicroMap entry #2/#3) from the new closed bar
   if(g_st.active && g_st.awaitingRetry)
     {
      if(g_st.attempts >= InpMaxAttemptsPerSetup)
        {
         PrintFormat("Setup %s dead after %d stops (MicroMap golden rule)",
                     TimeToString(g_st.anchor), g_st.attempts);
         MarkAnchorUsed(g_st.anchor);
         g_st.active = false;
         DeleteMyPending("attempts exhausted");
         return;
        }
      if((g_st.dir > 0 && lastClose < g_st.channelExtreme) ||
         (g_st.dir < 0 && lastClose > g_st.channelExtreme))
        {
         MarkAnchorUsed(g_st.anchor);
         g_st.active = false;
         DeleteMyPending("structure broken before retry");
         return;
        }
      if(MyPendingTicket() == 0 && MyPositionsCount(g_st.dir) == 0)
        {
         double trig = (g_st.dir > 0) ? lastHigh : lastLow;
         double slS  = (g_st.dir > 0) ? lastLow - buf : lastHigh + buf;
         if(PlaceStopOrder(g_st.dir, trig, slS, StringFormat("E%d", g_st.attempts + 1)))
           {
            g_pendingIsRetry = true;
            g_st.awaitingRetry = false;
           }
        }
      return; // while retrying, do not hunt other setups
     }

   //--- 3) pending expiry (first entries and retries alike)
   if(pend != 0 && InpPendingExpiryBars > 0)
     {
      int barsHeld = iBarShift(_Symbol, PERIOD_M1, g_pendingPlacedBar, false);
      if(barsHeld >= InpPendingExpiryBars)
        {
         DeleteMyPending(g_pendingIsRetry ? "retry expiry" : "expiry");
         MarkAnchorUsed(g_st.anchor);
         g_st.active = false;
         g_pendingIsRetry = false;
         pend = 0;
        }
     }

   //--- 4) maintain the active setup while a pending lives (H1 refresh)
   //       or drive the H2/H3 confirmation state machine
   if(g_st.active && !g_pendingIsRetry)
     {
      if(InpEntryMode == ENTRY_H1)
        {
         if(pend != 0)
           {
            // follow the newest channel extreme: tighter trigger, SL tracks channel low/high
            double trig = (g_st.dir > 0) ? lastHigh : lastLow;
            double chanEx = g_st.channelExtreme;
            double slS;
            if(g_st.dir > 0)
              {
               chanEx = MathMin(g_st.channelExtreme, lastLow);
               slS = chanEx - buf;
              }
            else
              {
               chanEx = MathMax(g_st.channelExtreme, lastHigh);
               slS = chanEx + buf;
              }
            double entryPrice = NormPrice(trig + (g_st.dir > 0 ? 1 : -1) * InpEntryBufferPoints * pt);
            double sl = NormSl(slS, g_st.dir > 0);
            double minDist;
            if(PendingLevelsValid(g_st.dir, entryPrice, sl, minDist) &&
               MathAbs(entryPrice - sl) <= InpMaxSlATR * g_atrM1)
              {
               double tp = 0.0;
               if(InpTpMode != TP_NONE)
                 {
                  tp = StructuralTp(g_st.dir, entryPrice, MathAbs(entryPrice - sl));
                  if(tp > 0) tp = NormTp(tp, g_st.dir > 0);
                 }
               if(ModifyPending(pend, entryPrice, sl, tp))
                 {
                  g_st.triggerLevel = trig;
                  g_st.channelExtreme = chanEx;
                  g_st.slLevel = slS;
                 }
              }
           }
         else if(MyPositionsCount(g_st.dir) == 0)
           {
            // pending gone (blocked/expired-send-fail) but setup still alive: re-arm
            PlaceStopOrder(g_st.dir, g_st.triggerLevel, g_st.slLevel, "E1-rearm");
           }
        }
      else // ENTRY_H2 / ENTRY_H3
        {
         double h1 = g_st.triggerLevel;
         bool beyond = (g_st.dir > 0) ? (lastClose > h1) : (lastClose < h1);
         int needed = (InpEntryMode == ENTRY_H2) ? 1 : 2;
         if(beyond)
           {
            if(g_st.breakCloses == 0)
              {
               g_st.postBreakHi = lastHigh;
               g_st.postBreakLo = lastLow;
               g_st.postBreakValid = true;
              }
            else
              {
               g_st.postBreakHi = MathMax(g_st.postBreakHi, lastHigh);
               g_st.postBreakLo = MathMin(g_st.postBreakLo, lastLow);
              }
            g_st.breakCloses++;
           }
         else if(g_st.postBreakValid)
           {
            g_st.postBreakHi = MathMax(g_st.postBreakHi, lastHigh);
            g_st.postBreakLo = MathMin(g_st.postBreakLo, lastLow);
           }
         if(g_st.breakCloses >= needed && g_st.postBreakValid && MyPositionsCount(g_st.dir) == 0)
           {
            double trig = (g_st.dir > 0) ? g_st.postBreakHi : g_st.postBreakLo;
            double slS = (g_st.dir > 0) ? g_st.postBreakLo - buf : g_st.postBreakHi + buf;
            if(pend == 0)
               PlaceStopOrder(g_st.dir, trig, slS, (InpEntryMode == ENTRY_H2 ? "H2" : "H3"));
            else
              {
               double entryPrice = NormPrice(trig + (g_st.dir > 0 ? 1 : -1) * InpEntryBufferPoints * pt);
               double sl = NormSl(slS, g_st.dir > 0);
               double minDist;
               if(PendingLevelsValid(g_st.dir, entryPrice, sl, minDist) &&
                  MathAbs(entryPrice - sl) <= InpMaxSlATR * g_atrM1)
                 {
                  double tp = 0.0;
                  if(InpTpMode != TP_NONE)
                    {
                     tp = StructuralTp(g_st.dir, entryPrice, MathAbs(entryPrice - sl));
                     if(tp > 0) tp = NormTp(tp, g_st.dir > 0);
                    }
                  ModifyPending(pend, entryPrice, sl, tp);
                 }
              }
           }
        }
      if(pend != 0 || MyPendingTicket() != 0) return;
     }

   //--- 5) hunt a fresh setup while below the concurrency cap and nothing pending
   int cap = g_hedging ? MathMin(InpMaxConcurrentPositions, 5) : 1;
   if(!g_st.active && MyPendingTicket() == 0 && MyPositionsCount() < cap)
     {
      for(int dir = 1; dir >= -1; dir -= 2)
        {
         double trigger, slStruct, impB, impR, chB, chR, chanEx;
         bool ib; datetime anchor;
         if(!DetectMicroMapDir(dir, trigger, slStruct, ib, impB, impR, chB, chR, anchor, chanEx))
            continue;
         string reason;
         if(!CtsFilterOK(dir, trigger, impB, impR, chB, chR, reason))
           {
            LogThrottled(StringFormat("Setup %s dir=%d rejected by CTS: %s",
                         TimeToString(anchor), dir, reason), 120);
            MarkAnchorUsed(anchor); // do not re-evaluate the same dead setup every bar
            continue;
           }
         g_st.active = true;
         g_st.anchor = anchor;
         g_st.dir = dir;
         g_st.attempts = 0;
         g_st.channelExtreme = chanEx;
         g_st.triggerLevel = trigger;
         g_st.slLevel = slStruct;
         g_st.awaitingRetry = false;
         g_st.insideBar = ib;
         g_st.breakCloses = 0;
         g_st.postBreakValid = false;
         g_st.impBars = impB; g_st.impRange = impR; g_st.chBars = chB; g_st.chRange = chR;
         PrintFormat("SETUP %s dir=%s spike=%.0f bars/%s channel=%.0f bars/%s trigger=%s sl=%s IB=%s mode=%s",
                     TimeToString(anchor), dir > 0 ? "BUY" : "SELL", impB, DoubleToString(impR, DigitsVal()),
                     chB, DoubleToString(chR, DigitsVal()), DoubleToString(trigger, DigitsVal()),
                     DoubleToString(slStruct, DigitsVal()), ib ? "yes" : "no",
                     EnumToString(InpEntryMode));
         if(InpEntryMode == ENTRY_H1)
           {
            if(PlaceStopOrder(dir, trigger, slStruct, ib ? "IB-E1" : "E1"))
               return;
            // gate refused (e.g. cooldown): keep setup alive, step 4 re-arms next bars
           }
         return; // H2/H3: state machine arms on following bars
        }
     }
  }

//+------------------------------------------------------------------+
//| OnTradeTransaction: attempt counting, setup lifecycle            |
//+------------------------------------------------------------------+
// a position belongs to the current setup only if it was OPENED after
// the setup anchor (spike-end bar). Prevents mis-attributing exits of
// older positions to the live setup's attempt counter.
bool PositionBelongsToSetup(long posId, datetime anchor)
  {
   if(anchor == 0) return false;
   if(!HistorySelectByPosition(posId)) return false;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
         return ((datetime)HistoryDealGetInteger(d, DEAL_TIME) >= anchor);
     }
   return false;
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;
   ENUM_DEAL_ENTRY de = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   ENUM_DEAL_REASON dr = (ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal, DEAL_REASON);
   ENUM_DEAL_TYPE dt = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   int dealDir = (dt == DEAL_TYPE_BUY) ? 1 : -1;

   if(de == DEAL_ENTRY_IN)
     {
      g_tradesToday++;
      return;
     }
   if(de != DEAL_ENTRY_OUT && de != DEAL_ENTRY_OUT_BY) return;

   int posDir = -dealDir; // closing a BUY position produces a SELL deal
   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) +
                   HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                   HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   if(dr == DEAL_REASON_SO)
     {
      Print("!!! STOP-OUT hit an EA position - caps were breached; review risk settings !!!");
      g_basketBlockedToday = true;
      MarkAnchorUsed(g_st.anchor);
      g_st.active = false;
      return;
     }

   if(!g_st.active || g_st.dir != posDir) return;
   long posId = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   if(!PositionBelongsToSetup(posId, g_st.anchor)) return;

   if(profit > 0.0)
     {
      // winning exit (TP or trailed SL in profit): setup consumed
      PrintFormat("Setup %s consumed by winning exit (%.2f)", TimeToString(g_st.anchor), profit);
      MarkAnchorUsed(g_st.anchor);
      g_st.active = false;
      DeleteMyPending("setup won");
      return;
     }
   if(dr == DEAL_REASON_SL)
     {
      g_st.attempts++;
      PrintFormat("SL exit on setup %s - attempt %d/%d used (%.2f)",
                  TimeToString(g_st.anchor), g_st.attempts, InpMaxAttemptsPerSetup, profit);
      if(g_st.attempts >= InpMaxAttemptsPerSetup)
        {
         Print("Setup invalidated: consecutive stops exhausted (MicroMap golden rule). No further try.");
         MarkAnchorUsed(g_st.anchor);
         g_st.active = false;
         DeleteMyPending("attempts exhausted");
        }
      else
         g_st.awaitingRetry = true; // entry #2/#3 from the next closed bar
      return;
     }
   // manual/other exit: do not fight the user - retire the setup
   MarkAnchorUsed(g_st.anchor);
   g_st.active = false;
   DeleteMyPending("position closed externally");
  }

//+------------------------------------------------------------------+
//| chart status                                                      |
//+------------------------------------------------------------------+
void UpdateComment()
  {
   if(!InpShowChartComment) { Comment(""); return; }
   string s = StringFormat("MicroCTS Scalper  magic=%I64d  %s M1  HTF=%s\n",
                           InpMagic, _Symbol, EnumToString(InpHTF));
   s += StringFormat("ATR(M1)=%s  ATR(HTF)=%s  spread=%d pt\n",
        DoubleToString(g_atrM1, DigitsVal()), DoubleToString(g_atrHTF, DigitsVal()),
        (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
   s += StringFormat("positions=%d/%d  pending=%s  trades today=%d\n",
        MyPositionsCount(), g_hedging ? InpMaxConcurrentPositions : 1,
        MyPendingTicket() == 0 ? "none" : IntegerToString((long)MyPendingTicket()), g_tradesToday);
   if(g_st.active)
      s += StringFormat("setup=%s dir=%s attempts=%d/%d trigger=%s struct=%s%s\n",
           TimeToString(g_st.anchor), g_st.dir > 0 ? "BUY" : "SELL",
           g_st.attempts, InpMaxAttemptsPerSetup,
           DoubleToString(g_st.triggerLevel, DigitsVal()),
           DoubleToString(g_st.channelExtreme, DigitsVal()),
           g_st.awaitingRetry ? "  [awaiting retry bar]" : "");
   else
      s += "setup: scanning...\n";
   s += StringFormat("floating=%.2f  equity=%.2f  dayStart=%.2f%s%s\n",
        MyFloatingPL(), AccountInfoDouble(ACCOUNT_EQUITY), g_dayStartEquity,
        g_dailyBlocked ? "  [DAILY LOSS BLOCK]" : "",
        g_basketBlockedToday ? "  [BASKET STOP TODAY]" : "");
   Comment(s);
  }

//+------------------------------------------------------------------+
//| init / deinit / tick                                              |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpRiskPercent <= 0 || InpRiskPercent > 10)
     { Print("InpRiskPercent must be in (0,10]"); return INIT_PARAMETERS_INCORRECT; }
   if(InpMaxConcurrentPositions < 1 || InpMaxConcurrentPositions > 5)
     { Print("InpMaxConcurrentPositions must be 1..5"); return INIT_PARAMETERS_INCORRECT; }
   if(InpMaxAttemptsPerSetup < 1 || InpMaxAttemptsPerSetup > 3)
     { Print("InpMaxAttemptsPerSetup must be 1..3 (MicroMap allows max 3 tries)"); return INIT_PARAMETERS_INCORRECT; }
   if(InpTpMode == TP_FIXED_R && InpTpRiskMultiple <= 0)
     { Print("InpTpRiskMultiple must be > 0"); return INIT_PARAMETERS_INCORRECT; }
   if(InpMaxLotCap <= 0)
     { Print("InpMaxLotCap must be > 0"); return INIT_PARAMETERS_INCORRECT; }

   g_hedging = ((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   if(!g_hedging)
      Print("Netting account detected: concurrency forced to 1");

   hAtrM1   = iATR(_Symbol, PERIOD_M1, InpAtrPeriod);
   hAtrHTF  = iATR(_Symbol, InpHTF, InpAtrPeriod);
   hEmaFast = iMA(_Symbol, InpHTF, InpEmaFastHTF, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow = iMA(_Symbol, InpHTF, InpEmaSlowHTF, 0, MODE_EMA, PRICE_CLOSE);
   hRsiHTF  = iRSI(_Symbol, InpHTF, InpRsiPeriodHTF, PRICE_CLOSE);
   if(hAtrM1 == INVALID_HANDLE || hAtrHTF == INVALID_HANDLE || hEmaFast == INVALID_HANDLE ||
      hEmaSlow == INVALID_HANDLE || hRsiHTF == INVALID_HANDLE)
     { Print("Indicator handle creation failed"); return INIT_FAILED; }

   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fm & 2) == 2)      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else if((fm & 1) == 1) trade.SetTypeFilling(ORDER_FILLING_FOK);
   else                   trade.SetTypeFilling(ORDER_FILLING_RETURN);

   g_st.active = false;
   g_st.awaitingRetry = false;
   g_st.breakCloses = 0;
   g_st.postBreakValid = false;
   ArrayResize(g_pos, 0);
   ArrayResize(g_usedAnchors, 0);
   SyncPositions();

   PrintFormat("MicroCTS Scalper initialized on %s M1, HTF=%s, %s account, magic=%I64d",
               _Symbol, EnumToString(InpHTF), g_hedging ? "hedging" : "netting", InpMagic);
   Print("Risk model: no grid, no martingale. Caps: concurrent=", InpMaxConcurrentPositions,
         " totalRisk%=", DoubleToString(InpMaxTotalRiskPercent, 2),
         " dailyLoss%=", DoubleToString(InpDailyLossLimitPercent, 2),
         " basketStop%=", DoubleToString(InpBasketStopEquityPercent, 2),
         " minMarginLevel%=", DoubleToString(InpMinMarginLevelAfterEntryPct, 0));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   Comment("");
   if(hAtrM1 != INVALID_HANDLE)   IndicatorRelease(hAtrM1);
   if(hAtrHTF != INVALID_HANDLE)  IndicatorRelease(hAtrHTF);
   if(hEmaFast != INVALID_HANDLE) IndicatorRelease(hEmaFast);
   if(hEmaSlow != INVALID_HANDLE) IndicatorRelease(hEmaSlow);
   if(hRsiHTF != INVALID_HANDLE)  IndicatorRelease(hRsiHTF);
  }

void OnTick()
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) return;
   UpdateDailyStats();
   SyncPositions();

   // every tick: protection and exits first
   BasketStopCheck();
   for(int i = 0; i < ArraySize(g_pos); i++)
      ManagePosition(i);

   // once per closed M1 bar: signals
   if(NewM1Bar())
      OnClosedBar();

   UpdateComment();
  }
//+------------------------------------------------------------------+
