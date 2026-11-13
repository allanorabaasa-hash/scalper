//+------------------------------------------------------------------+
//|                                                 XAUScalper.mq5   |
//|        XAUUSD Expert Advisor with on-chart control panel          |
//+------------------------------------------------------------------+
#property copyright "Allan"
#property link      "https://github.com/allanorabaasa-hash/scalper"
#property version   "4.00"
#property description "Phase B: independent risk manager. Strategy (interim): Trend Pullback."
#property description "Every entry is approved and sized by the risk manager."

#include <Trade\Trade.mqh>
#include <XAUScalper\RiskManager.mqh>

//==================================================================
//  INPUTS
//==================================================================
input group "General"
input long          InpMagic                = 20261112;      // Magic number (unique per EA)
input string        InpTradeComment         = "XAUScalper";  // Order comment prefix
input int           InpSlippagePoints       = 30;            // Max slippage (points)
input bool          InpJournal              = true;          // Log trades to MQL5/Files/XAUScalper_trades.csv

input group "Risk management"
input double        InpRiskPercent          = 0.5;           // Risk per trade (% of current equity)
input double        InpMinLotMaxRiskPct     = 10.0;          // If the minimum lot risks more than that, allow it up to this % (0 = reject)
input double        InpMaxDailyLossPct      = 2.0;           // Daily loss limit (% of the day's starting equity, 0 = off)
input double        InpDailyTargetPct       = 0.0;           // Daily profit target, stops new trades (%, 0 = off)
input int           InpMaxConsecLosses      = 3;             // Max losing trades in a row per day (0 = off)
input int           InpMaxPositions         = 1;             // Max open positions
input int           InpMaxDailyTrades       = 10;            // Max new trades per day (0 = off)
input int           InpMinSecBetweenTrades  = 60;            // Min seconds between new trades
input int           InpCooldownAfterLossMin = 15;            // Pause after a losing trade (minutes, 0 = off)
input double        InpEmergencyDDPct       = 15.0;          // Emergency: equity down this % today (0 = off)
input double        InpEmergencyMarginLevel = 150.0;         // Emergency: margin level below this % (0 = off)
input ENUM_EMERGENCY_POLICY InpEmergencyPolicy = EMERGENCY_CLOSE_ALL; // Emergency: what to do with open positions
input double        InpMarginBufferPct      = 50.0;          // Keep this % of free margin unused

input group "Market filters"
input double        InpMaxSpread            = 0.35;          // Max spread in price (0 = off)
input bool          InpUseSession           = false;         // Only trade between the session hours below
input int           InpStartHour            = 10;            // Session start hour (PC local time)
input int           InpStartMinute          = 0;             // Session start minute
input int           InpEndHour              = 19;            // Session end hour
input int           InpEndMinute            = 0;             // Session end minute
input bool          InpCloseAtSessionEnd    = true;          // Close bot positions when the session ends

input group "Trend Pullback strategy (interim: rebuilt as Strategy 1 in Phase C)"
input ENUM_TIMEFRAMES InpPB_EntryTF         = PERIOD_M5;     // Entry timeframe
input ENUM_TIMEFRAMES InpPB_TrendTF         = PERIOD_M15;    // Trend timeframe
input int           InpPB_TrendEMA          = 50;            // Trend EMA period (trend timeframe)
input int           InpPB_TrendSlopeBars    = 3;             // Trend EMA must rise/fall over N bars
input int           InpPB_PullEMA           = 20;            // Pullback EMA period (entry timeframe)
input int           InpPB_Lookback          = 5;             // Bars to look back for the pullback
input int           InpPB_ATRPeriod         = 14;            // ATR period (entry timeframe)
input double        InpPB_MinATR            = 0.80;          // Skip when ATR is below this (dead market)
input double        InpPB_SLBufferATR       = 0.20;          // SL buffer beyond the pullback swing (x ATR)
input double        InpPB_MinSLATR          = 0.50;          // Min SL distance (x ATR)
input double        InpPB_MaxSLATR          = 2.00;          // Max SL distance (x ATR), wider = skip
input double        InpPB_RewardR           = 1.50;          // Take profit (x risk)
input double        InpPB_BreakEvenR        = 1.00;          // Move SL to breakeven at (x risk), 0 = off
input double        InpPB_MaxSpreadPctSL    = 15.0;          // Skip if spread > this % of the SL distance
input int           InpPB_SkipFromHour      = 21;            // No new trades from server hour (rollover)...
input int           InpPB_SkipToHour        = 23;            // ...until server hour

input group "Connection safety"
input bool          InpPauseOnReconnect     = true;          // Pause bot after a connection drop
input bool          InpCloseOnReconnect     = false;         // Close all positions after a connection drop

input group "Panel"
input int           InpPanelX               = 10;            // Panel X offset
input int           InpPanelY               = 30;            // Panel Y offset

//==================================================================
//  STATE
//==================================================================
enum ENUM_BOT_STATE
  {
   BOT_STOPPED = 0,
   BOT_RUNNING = 1,
   BOT_PAUSED  = 2
  };

#define MAX_ROWS 6
#define PREFIX   "XS_"
#define STRATEGY_NAME "PULLBACK"

CTrade         g_trade;
CRiskManager   g_risk;
ENUM_BOT_STATE g_state           = BOT_STOPPED;
bool           g_wasConnected    = true;
bool           g_prevSessionOpen = false;
string         g_lastMsg         = "Ready. Press START to begin.";
color          g_lastMsgColor    = clrSilver;
ulong          g_rowTicket[MAX_ROWS];
bool           g_collapsed       = false;

int            g_hTrendEMA = INVALID_HANDLE;
int            g_hPullEMA  = INVALID_HANDLE;
int            g_hATR      = INVALID_HANDLE;
datetime       g_pbLastBar = 0;
string         g_pbStatus  = "waiting for the next bar";
double         g_sigSL     = 0.0;      // stop distance of the last signal (journal)
double         g_sigATR    = 0.0;      // ATR at the last signal (journal)
datetime       g_lastModifyFail = 0;

long           g_reasonPos[];          // positions closed by the bot, and why (journal)
string         g_reasonText[];

//--- Panel colours
const color CLR_BG      = C'22,27,34';
const color CLR_HEADER  = C'13,17,23';
const color CLR_BORDER  = C'48,54,61';
const color CLR_ROWALT  = C'28,33,40';
const color CLR_TEXT    = C'230,237,243';
const color CLR_MUTED   = C'139,148,158';
const color CLR_GREEN   = C'46,160,67';
const color CLR_RED     = C'218,54,51';
const color CLR_DARKRED = C'130,25,25';
const color CLR_AMBER   = C'210,153,34';
const color CLR_GREY    = C'87,96,106';
const color CLR_BLUE    = C'31,111,235';

//--- Panel geometry
#define PANEL_W  540
#define PANEL_H  472
#define ROW_Y0   240
#define ROW_H    22

//==================================================================
//  CLOSE REASONS (for the journal)
//==================================================================
void NoteCloseReason(const ulong ticket, const string why)
  {
   int n = ArraySize(g_reasonPos);
   if(n >= 200)
     {
      ArrayRemove(g_reasonPos, 0, 100);
      ArrayRemove(g_reasonText, 0, 100);
      n = ArraySize(g_reasonPos);
     }
   ArrayResize(g_reasonPos, n + 1);
   ArrayResize(g_reasonText, n + 1);
   g_reasonPos[n]  = (long)ticket;
   g_reasonText[n] = why;
  }

string TakeCloseReason(const long position)
  {
   for(int i = ArraySize(g_reasonPos) - 1; i >= 0; i--)
      if(g_reasonPos[i] == position)
        {
         string why = g_reasonText[i];
         ArrayRemove(g_reasonPos, i, 1);
         ArrayRemove(g_reasonText, i, 1);
         return why;
        }
   return "";
  }

//==================================================================
//  STRATEGY (interim): TREND PULLBACK
//==================================================================
// 1. Trend: trend-timeframe EMA is rising (falling) and price is above (below) it.
// 2. Pullback: within the last few entry bars price dipped back to the entry EMA.
// 3. Resumption: the last closed bar closes back beyond the EMA, in the trend
//    direction, and breaks the previous bar's high (low).
// 4. Stop beyond the pullback swing (ATR buffer), take profit at RewardR x risk,
//    breakeven at BreakEvenR x risk. Uses closed bars only.

bool RolloverHours()
  {
   if(InpPB_SkipFromHour == InpPB_SkipToHour)
      return false;
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(InpPB_SkipFromHour < InpPB_SkipToHour)
      return (t.hour >= InpPB_SkipFromHour && t.hour < InpPB_SkipToHour);
   return (t.hour >= InpPB_SkipFromHour || t.hour < InpPB_SkipToHour);
  }

// Evaluates once per new entry-timeframe bar. dir: +1 buy, -1 sell, 0 none.
void PullbackSignal(int &dir, double &slDist, double &tpDist)
  {
   dir = 0;
   slDist = 0.0;
   tpDist = 0.0;

   datetime bar = iTime(_Symbol, InpPB_EntryTF, 0);
   if(bar == 0 || bar == g_pbLastBar)
      return;

   int need = InpPB_Lookback + 1;
   double trend[], ema[], atrBuf[];
   MqlRates r[];
   ArraySetAsSeries(trend, true);
   ArraySetAsSeries(ema, true);
   ArraySetAsSeries(atrBuf, true);
   ArraySetAsSeries(r, true);
   if(CopyBuffer(g_hTrendEMA, 0, 1, InpPB_TrendSlopeBars + 1, trend) < InpPB_TrendSlopeBars + 1)
      return;
   if(CopyBuffer(g_hPullEMA, 0, 1, need, ema) < need)
      return;
   if(CopyBuffer(g_hATR, 0, 1, 1, atrBuf) < 1)
      return;
   if(CopyRates(_Symbol, InpPB_EntryTF, 1, need, r) < need)
      return;
   g_pbLastBar = bar;   // data is ready: this bar is now evaluated

   double atr        = atrBuf[0];
   double trendClose = iClose(_Symbol, InpPB_TrendTF, 1);
   int    trendDir   = 0;
   if(trend[0] > trend[InpPB_TrendSlopeBars] && trendClose > trend[0])
      trendDir = 1;
   else if(trend[0] < trend[InpPB_TrendSlopeBars] && trendClose < trend[0])
      trendDir = -1;

   if(trendDir == 0)
     {
      g_pbStatus = "no clear trend, standing aside";
      return;
     }
   string tName = (trendDir > 0) ? "UP" : "DOWN";
   if(atr < InpPB_MinATR)
     {
      g_pbStatus = "trend " + tName + ", market too quiet (ATR " + DoubleToString(atr, 2) + ")";
      return;
     }
   if(RolloverHours())
     {
      g_pbStatus = "rollover hours, no new trades";
      return;
     }

   bool   pulled = false;
   double swing  = (trendDir > 0) ? DBL_MAX : 0.0;
   for(int i = 0; i < InpPB_Lookback; i++)
     {
      if(trendDir > 0)
        {
         if(r[i].low <= ema[i])
            pulled = true;
         swing = MathMin(swing, r[i].low);
        }
      else
        {
         if(r[i].high >= ema[i])
            pulled = true;
         swing = MathMax(swing, r[i].high);
        }
     }
   if(!pulled)
     {
      g_pbStatus = "trend " + tName + ", waiting for a pullback";
      return;
     }

   bool resume = (trendDir > 0)
                 ? (r[0].close > ema[0] && r[0].close > r[0].open && r[0].close > r[1].high)
                 : (r[0].close < ema[0] && r[0].close < r[0].open && r[0].close < r[1].low);
   if(!resume)
     {
      g_pbStatus = "trend " + tName + ", pullback seen, waiting for resumption";
      return;
     }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;
   double entry = (trendDir > 0) ? tick.ask : tick.bid;
   double sl    = (trendDir > 0) ? swing - InpPB_SLBufferATR * atr : swing + InpPB_SLBufferATR * atr;
   slDist = (trendDir > 0) ? entry - sl : sl - entry;
   if(slDist < InpPB_MinSLATR * atr)
      slDist = InpPB_MinSLATR * atr;
   if(slDist > InpPB_MaxSLATR * atr)
     {
      g_pbStatus = "setup skipped: stop would be too wide";
      return;
     }
   double spread = tick.ask - tick.bid;
   if(spread > slDist * InpPB_MaxSpreadPctSL / 100.0)
     {
      g_pbStatus = "setup skipped: spread too large for this stop";
      return;
     }

   tpDist   = InpPB_RewardR * slDist;
   dir      = trendDir;
   g_sigSL  = slDist;
   g_sigATR = atr;
   g_pbStatus = "trend " + tName + ", signal";
  }

void RunPullback()
  {
   if(g_risk.OpenPositions() >= InpMaxPositions)
     {
      g_pbStatus = "in a trade, managing it";
      return;
     }
   int    dir;
   double slDist, tpDist;
   PullbackSignal(dir, slDist, tpDist);
   if(dir == 0)
      return;

   string why = EntryBlockReason();
   if(why != "")
     {
      Reject(StringFormat("%s signal rejected: %s", dir > 0 ? "BUY" : "SELL", why));
      return;
     }
   OpenTradeEx(dir, STRATEGY_NAME, slDist, tpDist);
  }

// Breakeven once price has gone BreakEvenR x the initial risk in our favour.
// The stop only ever moves towards profit, never adds risk.
void ManagePullback()
  {
   if(InpPB_BreakEvenR <= 0 || !TerminalInfoInteger(TERMINAL_CONNECTED))
      return;
   if(g_lastModifyFail > 0 && TimeCurrent() - g_lastModifyFail < 10)
      return;   // back off after a failed modification
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;
   int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double stopsLvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double freeze   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * point;
   double lock     = tick.ask - tick.bid;   // cover the spread

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurs())
         continue;
      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      if(sl == 0)
         continue;
      double risk = isBuy ? open - sl : sl - open;
      if(risk <= 0)
         continue;   // already at or beyond breakeven
      double profit = isBuy ? tick.bid - open : open - tick.ask;
      if(profit < InpPB_BreakEvenR * risk)
         continue;

      double newSL = NormalizeDouble(isBuy ? open + lock : open - lock, digits);
      if(isBuy && (newSL <= sl || newSL > tick.bid - stopsLvl))
         continue;
      if(!isBuy && (newSL >= sl || newSL < tick.ask + stopsLvl))
         continue;
      if(freeze > 0)
        {
         double price = isBuy ? tick.bid : tick.ask;
         if(MathAbs(price - sl) <= freeze || (tp > 0 && MathAbs(tp - price) <= freeze))
            continue;   // inside the broker's freeze level: modification not allowed
        }

      if(g_trade.PositionModify(ticket, newSL, tp))
         Msg("Breakeven set on #" + IntegerToString((long)ticket), CLR_MUTED);
      else
        {
         g_lastModifyFail = TimeCurrent();
         Msg(StringFormat("Breakeven on #%I64u failed (%u): %s", ticket, g_trade.ResultRetcode(),
                          g_trade.ResultRetcodeDescription()), CLR_RED);
        }
     }
  }

//==================================================================
//  LIFECYCLE
//==================================================================
string StateKey()
  {
   return "XS_state_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + IntegerToString(InpMagic);
  }

int OnInit()
  {
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetMarginMode();
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   ArrayInitialize(g_rowTicket, 0);
   ChartSetInteger(0, CHART_FOREGROUND, false);
   ChartSetInteger(0, CHART_SHOW_ONE_CLICK, false);   // MT5 one-click box would cover the panel

   if(InpRiskPercent <= 0 || InpMaxPositions < 1)
     {
      Print("XAUScalper: Risk % must be above 0 and Max positions at least 1");
      return INIT_PARAMETERS_INCORRECT;
     }

   RiskConfig cfg;
   cfg.magic                = InpMagic;
   cfg.riskPct              = InpRiskPercent;
   cfg.minLotMaxRiskPct     = InpMinLotMaxRiskPct;
   cfg.maxDailyLossPct      = InpMaxDailyLossPct;
   cfg.dailyTargetPct       = InpDailyTargetPct;
   cfg.maxConsecLosses      = InpMaxConsecLosses;
   cfg.maxPositions         = InpMaxPositions;
   cfg.maxDailyTrades       = InpMaxDailyTrades;
   cfg.minSecBetweenTrades  = InpMinSecBetweenTrades;
   cfg.cooldownAfterLossMin = InpCooldownAfterLossMin;
   cfg.emergencyDDPct       = InpEmergencyDDPct;
   cfg.emergencyMarginLevel = InpEmergencyMarginLevel;
   cfg.marginBufferPct      = InpMarginBufferPct;
   cfg.emergencyPolicy      = InpEmergencyPolicy;
   g_risk.Init(_Symbol, cfg);

   g_pbLastBar = 0;
   g_hTrendEMA = iMA(_Symbol, InpPB_TrendTF, InpPB_TrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_hPullEMA  = iMA(_Symbol, InpPB_EntryTF, InpPB_PullEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_hATR      = iATR(_Symbol, InpPB_EntryTF, InpPB_ATRPeriod);
   if(g_hTrendEMA == INVALID_HANDLE || g_hPullEMA == INVALID_HANDLE || g_hATR == INVALID_HANDLE)
     {
      Print("XAUScalper: could not create indicator handles");
      return INIT_FAILED;
     }

   g_state = BOT_STOPPED;
   // Keep RUNNING only across a timeframe switch or input change,
   // never across a terminal restart (power cut, reboot).
   string key = StateKey();
   if(GlobalVariableCheck(key))
     {
      g_state = (ENUM_BOT_STATE)(int)GlobalVariableGet(key);
      GlobalVariableDel(key);
     }
   if(MQLInfoInteger(MQL_TESTER))
      g_state = BOT_RUNNING;   // no START button to press in the Strategy Tester

   g_wasConnected    = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);
   g_prevSessionOpen = SessionOpen();

   if(StringFind(_Symbol, "XAU") < 0 && StringFind(_Symbol, "GOLD") < 0)
      Msg("Warning: attach this EA to a gold (XAUUSD) chart.", CLR_AMBER);

   BuildPanel();
   UpdatePanel();
   EventSetMillisecondTimer(500);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(reason == REASON_CHARTCHANGE || reason == REASON_PARAMETERS)
      GlobalVariableSet(StateKey(), (double)g_state);

   if(g_hTrendEMA != INVALID_HANDLE) IndicatorRelease(g_hTrendEMA);
   if(g_hPullEMA != INVALID_HANDLE)  IndicatorRelease(g_hPullEMA);
   if(g_hATR != INVALID_HANDLE)      IndicatorRelease(g_hATR);

   EventKillTimer();
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

void OnTick()
  {
   ManagePullback();            // runs even when stopped, so open trades stay managed
   if(MQLInfoInteger(MQL_TESTER))
     {
      // The tester does not use the timer: update the risk state once per second.
      static datetime lastRiskUpdate = 0;
      if(TimeCurrent() != lastRiskUpdate)
        {
         lastRiskUpdate = TimeCurrent();
         if(g_risk.Update())
            ApplyEmergency();
        }
     }
   if(g_state == BOT_RUNNING)
      RunPullback();
  }

void OnTimer()
  {
   CheckConnection();
   ManagePullback();
   if(g_risk.Update())
      ApplyEmergency();
   CheckSessionEnd();
   UpdatePanel();
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;
   if(StringFind(sparam, PREFIX) != 0)
      return;

   ObjectSetInteger(0, sparam, OBJPROP_STATE, false);

   if(sparam == P("b_start"))
      DoStart();
   else if(sparam == P("b_stop"))
      DoStop();
   else if(sparam == P("b_close"))
      DoCloseAll();
   else if(sparam == P("b_emerg"))
      DoEmergency();
   else if(sparam == P("b_min"))
     {
      g_collapsed = !g_collapsed;
      ApplyCollapse();
     }
   else if(StringFind(sparam, P("rx")) == 0)
     {
      int idx = (int)StringToInteger(StringSubstr(sparam, StringLen(P("rx"))));
      if(idx >= 0 && idx < MAX_ROWS && g_rowTicket[idx] > 0)
        {
         NoteCloseReason(g_rowTicket[idx], "manual (panel)");
         ClosePosition(g_rowTicket[idx]);
        }
     }

   g_risk.Update();
   UpdatePanel();
  }

//==================================================================
//  BUTTON ACTIONS
//==================================================================
void DoStart()
  {
   if(g_risk.Locked())
     {
      Msg("Cannot start: " + g_risk.LockText(), CLR_RED);
      return;
     }
   g_state = BOT_RUNNING;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      Msg("STARTED, but Algo Trading is OFF in the MT5 toolbar.", CLR_AMBER);
   else
      Msg("Bot STARTED.", CLR_GREEN);
  }

void DoStop()
  {
   g_state = BOT_STOPPED;
   if(CountOurPositions() > 0)
      Msg("STOPPED. Open positions stay on their SL/TP and are still managed.", CLR_AMBER);
   else
      Msg("Bot STOPPED.", CLR_MUTED);
  }

void DoCloseAll()
  {
   int n = CountOurPositions();
   if(n == 0)
     {
      Msg("No open positions to close.", CLR_MUTED);
      return;
     }
   int answer = MessageBox(StringFormat("Close all %d position(s) on %s now?", n, _Symbol),
                           "XAUScalper", MB_YESNO | MB_ICONQUESTION);
   if(answer == IDYES)
      CloseAll("manual close all");
  }

void DoEmergency()
  {
   string policy = (InpEmergencyPolicy == EMERGENCY_CLOSE_ALL)
                   ? "Open bot positions will be CLOSED."
                   : "Open bot positions will be kept on their SL/TP.";
   int answer = MessageBox("Emergency shutdown: stop the bot and block new trades until the next trading day.\n"
                           + policy + "\n\nContinue?", "XAUScalper", MB_YESNO | MB_ICONWARNING);
   if(answer != IDYES)
      return;
   g_risk.TriggerEmergency("manual");
   ApplyEmergency();
  }

// Applies the emergency policy after the risk manager locked trading.
void ApplyEmergency()
  {
   g_state = BOT_STOPPED;
   if(InpEmergencyPolicy == EMERGENCY_CLOSE_ALL && CountOurPositions() > 0)
      CloseAll("emergency");
   Msg("EMERGENCY: " + g_risk.LockText(), CLR_RED);
  }

//==================================================================
//  MARKET AND ENTRY CHECKS
//==================================================================
bool SessionOpen()
  {
   if(!InpUseSession)
      return true;
   MqlDateTime t;
   TimeToStruct(TimeLocal(), t);
   int now   = t.hour * 60 + t.min;
   int start = InpStartHour * 60 + InpStartMinute;
   int end   = InpEndHour * 60 + InpEndMinute;
   if(start == end)
      return true;
   if(start < end)
      return (now >= start && now < end);
   return (now >= start || now < end);   // session that crosses midnight
  }

double CurrentSpread()
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return 0.0;
   return tick.ask - tick.bid;
  }

// Market and permission checks. "" = OK.
string MarketBlockReason()
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
      return "no connection to broker";
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return "Algo Trading button is OFF in MT5";
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return "'Allow Algo Trading' is unticked in the EA settings";
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      return "this account does not allow EA trading";
   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
      return "market closed for " + _Symbol;
   if(!SessionOpen())
      return "outside session hours";
   double spread = CurrentSpread();
   if(InpMaxSpread > 0 && spread > InpMaxSpread)
      return StringFormat("spread too high (%s > %s)", DoubleToString(spread, _Digits), DoubleToString(InpMaxSpread, _Digits));
   return "";
  }

// Everything that must pass before a new entry: market, then risk manager.
string EntryBlockReason()
  {
   string why = MarketBlockReason();
   if(why != "")
      return why;
   return g_risk.CanOpen();
  }

void Reject(const string why)
  {
   g_pbStatus = why;
   Msg(why, CLR_AMBER);
  }

void CheckConnection()
  {
   bool connected = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);

   if(!connected && g_wasConnected)
     {
      g_wasConnected = false;
      Msg("Connection lost. No new trades until it returns.", CLR_RED);
     }
   else if(connected && !g_wasConnected)
     {
      g_wasConnected = true;
      if(g_state == BOT_RUNNING && InpPauseOnReconnect)
        {
         g_state = BOT_PAUSED;
         Msg("Reconnected. Bot PAUSED, press START to resume.", CLR_AMBER);
        }
      else
         Msg("Reconnected.", CLR_GREEN);

      if(InpCloseOnReconnect && CountOurPositions() > 0)
         CloseAll("reconnect");
     }
  }

void CheckSessionEnd()
  {
   bool open = SessionOpen();
   if(!open && g_prevSessionOpen && InpCloseAtSessionEnd && CountOurPositions() > 0)
     {
      CloseAll("session end");
      Msg("Session ended. Positions closed.", CLR_AMBER);
     }
   g_prevSessionOpen = open;
  }

//==================================================================
//  EXECUTION
//==================================================================
// Opens a trade sized and approved by the risk manager. Returns true only
// when the broker confirms the deal.
bool OpenTradeEx(const int dir, const string strategy, const double slWanted, const double tpWanted)
  {
   if(slWanted <= 0)
     {
      Reject("trade rejected: no valid stop loss");
      return false;
     }
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
     {
      Reject("trade rejected: no price for " + _Symbol);
      return false;
     }

   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point + (tick.ask - tick.bid);
   double slDist  = MathMax(slWanted, minDist);   // broker minimum; size is computed on the final stop
   double tpDist  = (tpWanted > 0) ? MathMax(tpWanted, minDist) : 0.0;

   string reason = "";
   double riskPct = 0.0;
   double lots = g_risk.SizeTrade(dir, slDist, reason, riskPct);
   if(lots <= 0)
     {
      Reject("trade rejected: " + reason);
      return false;
     }

   string comment = InpTradeComment + ":" + strategy;
   bool   sent;
   double price, sl, tp;
   if(dir > 0)
     {
      price = tick.ask;
      sl    = NormalizeDouble(price - slDist, digits);
      tp    = (tpDist > 0) ? NormalizeDouble(price + tpDist, digits) : 0.0;
      sent  = g_trade.Buy(lots, _Symbol, price, sl, tp, comment);
     }
   else
     {
      price = tick.bid;
      sl    = NormalizeDouble(price + slDist, digits);
      tp    = (tpDist > 0) ? NormalizeDouble(price - tpDist, digits) : 0.0;
      sent  = g_trade.Sell(lots, _Symbol, price, sl, tp, comment);
     }

   uint rc = g_trade.ResultRetcode();
   if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED) && g_trade.ResultDeal() > 0)
     {
      JournalWrite("OPEN", (long)g_trade.ResultOrder(), (dir > 0 ? "BUY" : "SELL"), strategy, lots,
                   g_trade.ResultPrice(), tick.ask - tick.bid, slDist, g_sigATR, riskPct, 0.0, 0.0, reason);
      Msg(StringFormat("%s %s %s lots @ %s, risk %.1f%%", strategy, (dir > 0 ? "BUY" : "SELL"),
                       DoubleToString(lots, 2), DoubleToString(g_trade.ResultPrice(), digits), riskPct), CLR_GREEN);
      g_risk.Update();
      return true;
     }

   Msg(StringFormat("Order NOT executed (%u): %s", rc, g_trade.ResultRetcodeDescription()), CLR_RED);
   return false;
  }

// Call after PositionGetTicket / PositionSelect.
bool IsOurs()
  {
   return PositionGetString(POSITION_SYMBOL) == _Symbol
          && PositionGetInteger(POSITION_MAGIC) == InpMagic;
  }

int CountOurPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      if(IsOurs())
         n++;
     }
   return n;
  }

bool ClosePosition(const ulong ticket)
  {
   if(g_trade.PositionClose(ticket, InpSlippagePoints))
     {
      Msg("Closed position #" + IntegerToString((long)ticket), CLR_MUTED);
      return true;
     }
   Msg(StringFormat("Close #%I64u failed (%u): %s", ticket, g_trade.ResultRetcode(),
                    g_trade.ResultRetcodeDescription()), CLR_RED);
   return false;
  }

int CloseAll(const string why)
  {
   int closed = 0, failed = 0;
   for(int attempt = 0; attempt < 2; attempt++)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !IsOurs())
            continue;
         NoteCloseReason(ticket, why);
         if(g_trade.PositionClose(ticket, InpSlippagePoints))
            closed++;
         else
           {
            failed++;
            PrintFormat("Close #%I64u failed (%u): %s", ticket, g_trade.ResultRetcode(),
                        g_trade.ResultRetcodeDescription());
           }
        }
      if(CountOurPositions() == 0)
         break;
     }
   PrintFormat("CloseAll (%s): closed %d, failed %d", why, closed, failed);
   if(CountOurPositions() > 0)
      Msg(StringFormat("Close all (%s): some positions could NOT be closed.", why), CLR_RED);
   else
      Msg(StringFormat("Close all (%s): %d position(s) closed.", why, closed), CLR_MUTED);
   return closed;
  }

//==================================================================
//  TRADE JOURNAL  (MQL5/Files/XAUScalper_trades.csv)
//==================================================================
void JournalWrite(const string event, const long position, const string side, const string strategy,
                  const double lots, const double price, const double spread, const double slDist,
                  const double atr, const double riskPct, const double profit, const double holdSec,
                  const string note)
  {
   if(!InpJournal || MQLInfoInteger(MQL_OPTIMIZATION))
      return;
   int h = FileOpen("XAUScalper_trades.csv", FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE)
     {
      Print("Journal: cannot open file, error ", GetLastError());
      return;
     }
   if(FileSize(h) == 0)
      FileWrite(h, "event", "time", "account", "position", "side", "strategy", "lots", "price",
                "spread", "sl_dist", "atr", "risk_pct", "profit", "hold_s", "note");
   FileSeek(h, 0, SEEK_END);
   bool isOpen = (event == "OPEN");
   FileWrite(h, event, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
             IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)), IntegerToString(position), side, strategy,
             DoubleToString(lots, 2), DoubleToString(price, _Digits), DoubleToString(spread, _Digits),
             isOpen ? DoubleToString(slDist, 2) : "", isOpen ? DoubleToString(atr, 2) : "",
             isOpen ? DoubleToString(riskPct, 2) : "",
             isOpen ? "" : DoubleToString(profit, 2), isOpen ? "" : DoubleToString(holdSec, 1), note);
   FileClose(h);
  }

string DealReasonText(const long reason)
  {
   switch((int)reason)
     {
      case DEAL_REASON_SL:     return "stop loss";
      case DEAL_REASON_TP:     return "take profit";
      case DEAL_REASON_EXPERT: return "bot";
      case DEAL_REASON_CLIENT: return "manual";
      case DEAL_REASON_MOBILE: return "mobile";
      case DEAL_REASON_SO:     return "stop out";
      default:                 return "other";
     }
  }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || !InpJournal)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;

   long   posId    = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   long   outMsc   = HistoryDealGetInteger(trans.deal, DEAL_TIME_MSC);
   long   dealType = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   double lots     = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
   double price    = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   long   reason   = HistoryDealGetInteger(trans.deal, DEAL_REASON);
   double profit   = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                     + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION) + HistoryDealGetDouble(trans.deal, DEAL_FEE);

   // Confirm the position was opened by this EA; find its entry time and strategy
   if(!HistorySelectByPosition(posId))
      return;
   bool   ours     = false;
   long   inMsc    = 0;
   string strategy = "";
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0 || HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;
      if(HistoryDealGetInteger(d, DEAL_MAGIC) == InpMagic)
        {
         ours  = true;
         inMsc = HistoryDealGetInteger(d, DEAL_TIME_MSC);
         profit += HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
         string c = HistoryDealGetString(d, DEAL_COMMENT);
         int sep = StringFind(c, ":");
         strategy = (sep >= 0) ? StringSubstr(c, sep + 1) : c;
        }
     }
   if(!ours)
      return;

   string side = (dealType == DEAL_TYPE_SELL) ? "BUY" : "SELL";   // a closing SELL closes a BUY
   double hold = (inMsc > 0 && outMsc >= inMsc) ? (outMsc - inMsc) / 1000.0 : 0.0;
   string why  = TakeCloseReason(posId);
   if(why == "")
     {
      why = DealReasonText(reason);
      if(reason == DEAL_REASON_SL && profit >= 0)
         why = "breakeven stop";
     }
   JournalWrite("CLOSE", posId, side, strategy, lots, price, CurrentSpread(), 0.0, 0.0, 0.0, profit, hold, why);
  }

//==================================================================
//  PANEL
//==================================================================
string P(const string name) { return PREFIX + name; }

void Msg(const string text, const color clr)
  {
   g_lastMsg      = text;
   g_lastMsgColor = clr;
   Print(text);
  }

// MT5 chart labels show at most 63 characters.
string Fit(const string text)
  {
   if(text == "")
      return " ";
   if(StringLen(text) > 63)
      return StringSubstr(text, 0, 60) + "...";
   return text;
  }

void MkRect(const string name, int x, int y, int w, int h, color bg, color border)
  {
   string o = P(name);
   if(ObjectFind(0, o) < 0)
      ObjectCreate(0, o, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, o, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, o, OBJPROP_XDISTANCE, InpPanelX + x);
   ObjectSetInteger(0, o, OBJPROP_YDISTANCE, InpPanelY + y);
   ObjectSetInteger(0, o, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, o, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, o, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, o, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, o, OBJPROP_COLOR, border);
   ObjectSetInteger(0, o, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, o, OBJPROP_BACK, false);
   ObjectSetInteger(0, o, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, o, OBJPROP_HIDDEN, true);
  }

void MkLabel(const string name, int x, int y, const string text, color clr,
             int size = 9, const string font = "Arial", ENUM_ANCHOR_POINT anchor = ANCHOR_LEFT_UPPER)
  {
   string o = P(name);
   if(ObjectFind(0, o) < 0)
      ObjectCreate(0, o, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, o, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, o, OBJPROP_XDISTANCE, InpPanelX + x);
   ObjectSetInteger(0, o, OBJPROP_YDISTANCE, InpPanelY + y);
   ObjectSetInteger(0, o, OBJPROP_ANCHOR, anchor);
   ObjectSetString(0, o, OBJPROP_FONT, font);
   ObjectSetInteger(0, o, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, o, OBJPROP_COLOR, clr);
   ObjectSetString(0, o, OBJPROP_TEXT, Fit(text));
   ObjectSetInteger(0, o, OBJPROP_BACK, false);
   ObjectSetInteger(0, o, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, o, OBJPROP_HIDDEN, true);
  }

void MkButton(const string name, int x, int y, int w, int h, const string text,
              color bg, color fg, int size = 9)
  {
   string o = P(name);
   if(ObjectFind(0, o) < 0)
      ObjectCreate(0, o, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, o, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, o, OBJPROP_XDISTANCE, InpPanelX + x);
   ObjectSetInteger(0, o, OBJPROP_YDISTANCE, InpPanelY + y);
   ObjectSetInteger(0, o, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, o, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, o, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, o, OBJPROP_BORDER_COLOR, bg);
   ObjectSetInteger(0, o, OBJPROP_COLOR, fg);
   ObjectSetString(0, o, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, o, OBJPROP_FONTSIZE, size);
   ObjectSetString(0, o, OBJPROP_TEXT, text);
   ObjectSetInteger(0, o, OBJPROP_STATE, false);
   ObjectSetInteger(0, o, OBJPROP_BACK, false);
   ObjectSetInteger(0, o, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, o, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, o, OBJPROP_ZORDER, 10);
  }

void SetText(const string name, const string text, color clr)
  {
   string o = P(name);
   ObjectSetString(0, o, OBJPROP_TEXT, Fit(text));
   ObjectSetInteger(0, o, OBJPROP_COLOR, clr);
  }

void ShowObj(const string name, bool show)
  {
   if(g_collapsed)
      show = false;
   ObjectSetInteger(0, P(name), OBJPROP_TIMEFRAMES, show ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS);
  }

string RowCell(int row, int col) { return "r" + IntegerToString(row) + "c" + IntegerToString(col); }

// Table column x positions (Ticket, Type, Lots, Open, SL, TP, P/L)
int ColX(int col)
  {
   switch(col)
     {
      case 0: return 12;
      case 1: return 100;
      case 2: return 150;
      case 3: return 200;
      case 4: return 280;
      case 5: return 360;
      default: return 488;   // P/L, right-aligned
     }
  }

bool AlwaysVisible(const string name)
  {
   return name == P("bg") || name == P("header") || name == P("title")
          || name == P("pill") || name == P("pill_t") || name == P("b_min") || name == P("mode");
  }

// Collapse the panel to its header bar, or expand it again.
void ApplyCollapse()
  {
   int total = ObjectsTotal(0, 0, -1);
   for(int i = 0; i < total; i++)
     {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, PREFIX) != 0 || AlwaysVisible(name))
         continue;
      ObjectSetInteger(0, name, OBJPROP_TIMEFRAMES, g_collapsed ? OBJ_NO_PERIODS : OBJ_ALL_PERIODS);
     }
   ObjectSetInteger(0, P("bg"), OBJPROP_YSIZE, g_collapsed ? 36 : PANEL_H);
   ObjectSetString(0, P("b_min"), OBJPROP_TEXT, g_collapsed ? "+" : "-");
   UpdatePanel();
  }

void BuildPanel()
  {
   // Frame and header
   MkRect("bg",     0, 0, PANEL_W, PANEL_H, CLR_BG, CLR_BORDER);
   MkRect("header", 0, 0, PANEL_W, 36, CLR_HEADER, CLR_BORDER);
   MkLabel("title", 14, 9, "XAU SCALPER", CLR_TEXT, 12, "Arial Bold");
   MkLabel("mode", 150, 12, "STRATEGY: " + STRATEGY_NAME, CLR_BLUE, 8, "Arial Bold");
   MkRect("pill", PANEL_W - 118, 8, 106, 20, CLR_GREY, CLR_GREY);
   MkLabel("pill_t", PANEL_W - 65, 18, "STOPPED", clrWhite, 8, "Arial Bold", ANCHOR_CENTER);
   MkButton("b_min", PANEL_W - 146, 8, 22, 20, "-", CLR_GREY, clrWhite, 10);
   MkLabel("info", 14, 44, " ", CLR_MUTED, 8);

   // Stats grid (2 rows x 3 columns)
   string titles[6] = {"BALANCE", "EQUITY", "DAY P/L (CLOSED + OPEN)", "FLOATING P/L", "SPREAD", "DRAWDOWN TODAY"};
   for(int i = 0; i < 6; i++)
     {
      int x = 14 + (i % 3) * 178;
      int y = 66 + (i / 3) * 40;
      MkLabel("s_t" + IntegerToString(i), x, y, titles[i], CLR_MUTED, 7);
      MkLabel("s_v" + IntegerToString(i), x, y + 13, "-", CLR_TEXT, 11, "Arial Bold");
     }

   // Risk status (two lines of up to 63 characters)
   MkLabel("risk1", 14, 146, " ", CLR_MUTED, 8);
   MkLabel("risk2", 286, 146, " ", CLR_MUTED, 8);

   // Buttons
   MkRect("sep1", 12, 166, PANEL_W - 24, 1, CLR_BORDER, CLR_BORDER);
   MkButton("b_start", 12,  176, 110, 32, "START",     CLR_GREEN,   clrWhite, 10);
   MkButton("b_stop",  130, 176, 110, 32, "STOP",      CLR_RED,     clrWhite, 10);
   MkButton("b_close", 248, 176, 120, 32, "CLOSE ALL", CLR_GREY,    clrWhite, 9);
   MkButton("b_emerg", 376, 176, 152, 32, "EMERGENCY", CLR_DARKRED, clrWhite, 9);

   // Positions table
   MkLabel("t_title", 14, 218, "OPEN POSITIONS (0)", CLR_MUTED, 7, "Arial Bold");
   string heads[7] = {"TICKET", "TYPE", "LOTS", "OPEN", "SL", "TP", "P/L"};
   for(int c = 0; c < 7; c++)
      MkLabel("h" + IntegerToString(c), ColX(c), ROW_Y0 - 4, heads[c], CLR_MUTED, 7,
              "Arial", c == 6 ? ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER);
   MkRect("sep2", 12, ROW_Y0 + 10, PANEL_W - 24, 1, CLR_BORDER, CLR_BORDER);

   for(int r = 0; r < MAX_ROWS; r++)
     {
      int y = ROW_Y0 + 14 + r * ROW_H;
      if(r % 2 == 1)
         MkRect("rbg" + IntegerToString(r), 12, y - 3, PANEL_W - 24, ROW_H, CLR_ROWALT, CLR_ROWALT);
      for(int c = 0; c < 7; c++)
         MkLabel(RowCell(r, c), ColX(c), y, " ", CLR_TEXT, 9,
                 "Arial", c == 6 ? ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER);
      MkButton("rx" + IntegerToString(r), 500, y - 2, 26, 18, "X", CLR_RED, clrWhite, 8);
      ShowObj("rx" + IntegerToString(r), false);
     }
   MkLabel("t_empty", PANEL_W / 2, ROW_Y0 + 60, "No open positions", CLR_MUTED, 9, "Arial", ANCHOR_UPPER);

   // Footer
   MkRect("sep3", 12, PANEL_H - 52, PANEL_W - 24, 1, CLR_BORDER, CLR_BORDER);
   MkLabel("f_msg",  14, PANEL_H - 44, g_lastMsg, g_lastMsgColor, 8);
   MkLabel("f_cond", 14, PANEL_H - 24, " ", CLR_MUTED, 8);

   ChartRedraw();
  }

string Money(const double v)  { return DoubleToString(v, 2); }
string Signed(const double v) { return (v >= 0 ? "+" : "") + DoubleToString(v, 2); }
color  PLColor(const double v){ return v > 0 ? CLR_GREEN : (v < 0 ? CLR_RED : CLR_TEXT); }

void UpdatePanel()
  {
   bool   connected = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);
   string currency  = AccountInfoString(ACCOUNT_CURRENCY);

   // Status pill
   string status = "STOPPED";
   color  pill   = CLR_GREY;
   if(!connected)                  { status = "OFFLINE"; pill = CLR_RED;   }
   else if(g_risk.Locked())        { status = "LOCKED";  pill = CLR_RED;   }
   else if(g_state == BOT_RUNNING) { status = "RUNNING"; pill = CLR_GREEN; }
   else if(g_state == BOT_PAUSED)  { status = "PAUSED";  pill = CLR_AMBER; }
   ObjectSetInteger(0, P("pill"), OBJPROP_BGCOLOR, pill);
   ObjectSetInteger(0, P("pill"), OBJPROP_COLOR, pill);
   SetText("pill_t", status, clrWhite);

   SetText("info", "Account " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "   |   "
           + AccountInfoString(ACCOUNT_SERVER) + "   |   " + _Symbol, CLR_MUTED);

   // Stats
   double spread = CurrentSpread();
   double dd     = g_risk.DrawdownPct();
   SetText("s_v0", Money(AccountInfoDouble(ACCOUNT_BALANCE)) + " " + currency, CLR_TEXT);
   SetText("s_v1", Money(AccountInfoDouble(ACCOUNT_EQUITY)) + " " + currency, CLR_TEXT);
   SetText("s_v2", Signed(g_risk.DayPL()), PLColor(g_risk.DayPL()));
   SetText("s_v3", Signed(g_risk.Floating()), PLColor(g_risk.Floating()));
   SetText("s_v4", DoubleToString(spread, _Digits), (InpMaxSpread > 0 && spread > InpMaxSpread) ? CLR_RED : CLR_TEXT);
   SetText("s_v5", DoubleToString(dd, 2) + "%", dd > 0 ? CLR_RED : CLR_TEXT);

   // Risk status
   double used = g_risk.DayLossUsedPct();
   string r1 = StringFormat("Risk %.1f%%/trade   Daily loss limit used: %.0f%%", g_risk.RiskPct(), used);
   if(g_risk.MaxDailyLossPct() <= 0)
      r1 = StringFormat("Risk %.1f%%/trade   Daily loss limit: OFF", g_risk.RiskPct());
   string r2 = StringFormat("Losses in a row %d/%d   Trades %d/%d   Wins %d/%d",
                            g_risk.ConsecLosses(), g_risk.MaxConsecLosses(),
                            g_risk.EntriesToday(), g_risk.MaxDailyTrades(),
                            g_risk.WinsToday(), g_risk.ClosedToday());
   SetText("risk1", r1, used >= 100 ? CLR_RED : (used >= 50 ? CLR_AMBER : CLR_MUTED));
   SetText("risk2", r2, (g_risk.MaxConsecLosses() > 0 && g_risk.ConsecLosses() >= g_risk.MaxConsecLosses()) ? CLR_RED : CLR_MUTED);

   // Positions table
   int row = 0, total = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurs())
         continue;
      total++;
      if(row >= MAX_ROWS)
         continue;

      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double pl    = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      SetText(RowCell(row, 0), IntegerToString((long)ticket), CLR_TEXT);
      SetText(RowCell(row, 1), isBuy ? "BUY" : "SELL", isBuy ? CLR_GREEN : CLR_RED);
      SetText(RowCell(row, 2), DoubleToString(PositionGetDouble(POSITION_VOLUME), 2), CLR_TEXT);
      SetText(RowCell(row, 3), DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), _Digits), CLR_TEXT);
      SetText(RowCell(row, 4), sl > 0 ? DoubleToString(sl, _Digits) : "-", CLR_MUTED);
      SetText(RowCell(row, 5), tp > 0 ? DoubleToString(tp, _Digits) : "-", CLR_MUTED);
      SetText(RowCell(row, 6), Signed(pl), PLColor(pl));
      g_rowTicket[row] = ticket;
      ShowObj("rx" + IntegerToString(row), true);
      row++;
     }
   for(; row < MAX_ROWS; row++)
     {
      for(int c = 0; c < 7; c++)
         SetText(RowCell(row, c), " ", CLR_TEXT);
      g_rowTicket[row] = 0;
      ShowObj("rx" + IntegerToString(row), false);
     }

   string tTitle = "OPEN POSITIONS (" + IntegerToString(total) + ")";
   if(total > MAX_ROWS)
      tTitle += "   showing first " + IntegerToString(MAX_ROWS);
   SetText("t_title", tTitle, CLR_MUTED);
   ShowObj("t_empty", total == 0);

   // Footer: last action, and why the bot is or is not trading right now
   SetText("f_msg", g_lastMsg, g_lastMsgColor);
   string cond;
   if(g_risk.Locked())
      cond = "Locked: " + g_risk.LockText();
   else if(g_state == BOT_RUNNING)
     {
      string why = EntryBlockReason();
      cond = (why == "") ? "Pullback: " + g_pbStatus : "Not trading: " + why;
     }
   else if(g_state == BOT_PAUSED)
      cond = "Paused after reconnect. Press START to resume.";
   else
      cond = "Stopped. No new trades will be opened.";
   SetText("f_cond", cond, g_risk.Locked() ? CLR_RED : CLR_MUTED);

   ChartRedraw();
  }
//+------------------------------------------------------------------+
