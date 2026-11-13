//+------------------------------------------------------------------+
//|                                                 XAUScalper.mq5   |
//|        Controlled Directional Grid for XAUUSD, with panel         |
//+------------------------------------------------------------------+
#property copyright "Allan"
#property link      "https://github.com/allanorabaasa-hash/scalper"
#property version   "11.00"
#property description "Daily trend trader: one 0.01 position in the daily EMA 21/55 direction, never adds to a loser."
#property description "Take profit +$50, stop loss -$20, both on the broker's server. A new trade opens after each close."

#include <XAUScalper\RiskManager.mqh>
#include <XAUScalper\Execution.mqh>
#include <XAUScalper\Journal.mqh>

//==================================================================
//  INPUTS (defaults = the strategy rules)
//==================================================================
input group "Direction filter (Daily)"
input int             InpEmaFast            = 21;            // Daily EMA fast
input int             InpEmaSlow            = 55;            // Daily EMA slow
input double          InpFlatGapAtr         = 0.10;          // "Flat": EMA gap below this x ATR(D1,14) -> no new grid

input group "Trade"
input double          InpLot                = 0.01;          // Lot (fixed)
input double          InpTakeProfitUSD      = 50.0;          // Take profit: close the winner at +this many USD
input double          InpStopLossUSD        = 20.0;          // Stop loss: close the loser at -this many USD

input group "Risk controls"
input double          InpDailyLossPct       = 0;             // No new trades for the rest of the day after this % loss (0 = off, testing)
input double          InpEmergencyMarginLevel = 100;         // Emergency: close all below this margin level % (0 = off)
input bool            InpAllowReal          = false;         // Allow trading on a REAL account
input bool            InpAutoStart          = true;          // Start/resume automatically whenever connected (STOP is remembered)

input group "General"
input long            InpMagic              = 20261114;      // Magic number (unique per EA)
input string          InpTradeComment       = "XAUGrid";     // Order comment
input int             InpSlippagePoints     = 30;            // Max slippage (points)
input bool            InpJournal            = true;          // Trade journal (Common/Files/XAUScalper_trades.csv)
input int             InpPanelX             = 10;            // Panel X offset
input int             InpPanelY             = 30;            // Panel Y offset

//==================================================================
//  STATE
//==================================================================
enum ENUM_BOT_STATE
  {
   BOT_STOPPED = 0,
   BOT_RUNNING = 1
  };

#define MAX_ROWS 6
#define PREFIX   "XS_"

CRiskManager   g_risk;
CExecution     g_exec;

ENUM_BOT_STATE g_state        = BOT_STOPPED;
bool           g_wasConnected = true;
string         g_lastMsg      = "Ready.";
color          g_lastMsgColor = clrSilver;
ulong          g_rowTicket[MAX_ROWS];
bool           g_collapsed    = false;

int            g_hDFast = INVALID_HANDLE, g_hDSlow = INVALID_HANDLE, g_hDAtr = INVALID_HANDLE;
int            g_filter       = 0;    // +1 buy grids, -1 sell grids, 0 none
string         g_filterText   = "-";
string         g_block        = "";   // why no new grid / level right now
datetime       g_lastTry      = 0;
int            g_trades = 0, g_wins = 0, g_losses = 0;

long           g_reasonPos[];         // positions closed by the bot, and why (journal)
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

#define PANEL_W  540
#define PANEL_H  470
#define ROW_Y0   234
#define ROW_H    22

//==================================================================
//  HELPERS
//==================================================================
string StateKey()
  {
   return "XS_state_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + IntegerToString(InpMagic);
  }
string ManualStopKey() { return StateKey() + "_manualstop"; }
bool   ManualStop()    { return GlobalVariableCheck(ManualStopKey()); }

bool IsRealAccount()
  {
   return !MQLInfoInteger(MQL_TESTER) && AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL;
  }

// Call after PositionGetTicket / PositionSelect.
bool IsOurs()
  {
   return PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic;
  }

int CountOurs()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetTicket(i) != 0 && IsOurs())
         n++;
   return n;
  }

// The active grid, rebuilt from the open positions (survives restarts).
struct GridInfo
  {
   int    levels;     // open positions
   int    dir;        // +1 buy grid, -1 sell grid (0 = none)
   double lastLevel;  // lowest buy / highest sell open price
   double pl;         // floating profit + swap
  };

void ReadGrid(GridInfo &g)
  {
   g.levels = 0;  g.dir = 0;  g.lastLevel = 0;  g.pl = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0 || !IsOurs())
         continue;
      int    d = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      double p = PositionGetDouble(POSITION_PRICE_OPEN);
      g.pl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(g.levels == 0 || (d > 0 && p < g.lastLevel) || (d < 0 && p > g.lastLevel))
         g.lastLevel = p;
      g.dir = d;
      g.levels++;
     }
  }

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

bool Value(const int handle, const int shift, double &v)
  {
   double b[];
   if(CopyBuffer(handle, 0, shift, 1, b) != 1)
      return false;
   v = b[0];
   return v != EMPTY_VALUE;
  }

// Daily direction filter from the last two COMPLETED daily candles.
void UpdateFilter()
  {
   g_filter = 0;
   double f1, s1, f2, s2, atr;
   if(iBars(_Symbol, PERIOD_D1) < InpEmaSlow + 3 || !Value(g_hDFast, 1, f1) || !Value(g_hDSlow, 1, s1)
      || !Value(g_hDFast, 2, f2) || !Value(g_hDSlow, 2, s2) || !Value(g_hDAtr, 1, atr))
     {
      g_filterText = "waiting for daily data";
      return;
     }
   if((f1 - s1) * (f2 - s2) <= 0)
     {
      g_filterText = "EMAs crossing: no new grid";
      return;
     }
   if(MathAbs(f1 - s1) < InpFlatGapAtr * atr)
     {
      g_filterText = StringFormat("EMAs flat (gap %.2f): no new grid", MathAbs(f1 - s1));
      return;
     }
   g_filter = (f1 > s1) ? 1 : -1;
   g_filterText = g_filter > 0 ? "UP: buy grids only" : "DOWN: sell grids only";
  }

//==================================================================
//  DAILY LOSS LIMIT (server day, closed + floating)
//==================================================================
string DayKey() { return StateKey() + "_day"; }

double DayStartBalance()
  {
   datetime today = (datetime)(TimeCurrent() / 86400 * 86400);
   if(!GlobalVariableCheck(DayKey()) || (datetime)(long)GlobalVariableGet(DayKey()) != today)
     {
      GlobalVariableSet(DayKey(), (double)today);
      GlobalVariableSet(DayKey() + "_bal", AccountInfoDouble(ACCOUNT_BALANCE));
     }
   return GlobalVariableGet(DayKey() + "_bal");
  }

double DayPL() { return AccountInfoDouble(ACCOUNT_EQUITY) - DayStartBalance(); }

bool DailyLimitHit()
  {
   double start = DayStartBalance();
   return InpDailyLossPct > 0 && start > 0 && -DayPL() >= start * InpDailyLossPct / 100.0;
  }

//==================================================================
//  LIFECYCLE
//==================================================================
int OnInit()
  {
   ArrayInitialize(g_rowTicket, 0);
   ChartSetInteger(0, CHART_FOREGROUND, false);
   ChartSetInteger(0, CHART_SHOW_ONE_CLICK, false);

   if(InpLot <= 0 || InpTakeProfitUSD <= 0 || InpStopLossUSD <= 0 || InpEmaSlow <= InpEmaFast)
     {
      Print("XAUScalper: check the inputs (lot, take profit and stop loss above 0; slow EMA above fast)");
      return INIT_PARAMETERS_INCORRECT;
     }
   g_hDFast = iMA(_Symbol, PERIOD_D1, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hDSlow = iMA(_Symbol, PERIOD_D1, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hDAtr  = iATR(_Symbol, PERIOD_D1, 14);
   if(g_hDFast == INVALID_HANDLE || g_hDSlow == INVALID_HANDLE || g_hDAtr == INVALID_HANDLE)
     {
      Print("XAUScalper: could not create the daily indicators");
      return INIT_FAILED;
     }
   g_exec.Init(_Symbol, InpMagic, InpSlippagePoints);
   JournalInit(InpJournal);

   // Risk manager: day statistics and the margin-level emergency only (the grid has its own limits).
   RiskConfig cfg;
   cfg.magic = InpMagic;  cfg.riskPct = 1.0;  cfg.minLotMaxRiskPct = 0;  cfg.maxDailyLossPct = 0;
   cfg.dailyTargetPct = 0;  cfg.maxConsecLosses = 0;  cfg.maxPositions = 1;  cfg.maxDailyTrades = 0;
   cfg.minSecBetweenTrades = 0;  cfg.cooldownAfterLossMin = 0;  cfg.emergencyDDPct = 0;
   cfg.emergencyMarginLevel = InpEmergencyMarginLevel;  cfg.marginBufferPct = 0;
   cfg.emergencyPolicy = EMERGENCY_CLOSE_ALL;
   g_risk.Init(_Symbol, cfg);

   g_state = BOT_STOPPED;
   string key = StateKey();
   if(GlobalVariableCheck(key))
     {
      g_state = (ENUM_BOT_STATE)(int)GlobalVariableGet(key);
      GlobalVariableDel(key);
     }
   if(MQLInfoInteger(MQL_TESTER))
      g_state = BOT_RUNNING;
   g_wasConnected = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);
   DayStartBalance();

   if(StringFind(_Symbol, "XAU") < 0 && StringFind(_Symbol, "GOLD") < 0)
      Msg("Warning: the $ settings are made for gold (XAUUSD).", CLR_AMBER);
   if(IsRealAccount() && !InpAllowReal)
      Msg("REAL account: no new trades unless 'Allow trading on a REAL account' is on.", CLR_RED);

   if(!MQLInfoInteger(MQL_TESTER))
     {
      BuildPanel();
      UpdatePanel();
     }
   EventSetMillisecondTimer(500);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(reason == REASON_CHARTCHANGE || reason == REASON_PARAMETERS)
      GlobalVariableSet(StateKey(), (double)g_state);
   EventKillTimer();
   IndicatorRelease(g_hDFast);  IndicatorRelease(g_hDSlow);  IndicatorRelease(g_hDAtr);
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

void OnTick()
  {
   if(MQLInfoInteger(MQL_TESTER))
     {
      static datetime last = 0;
      if(TimeCurrent() != last)
        {
         last = TimeCurrent();
         if(g_risk.Update())
            ApplyEmergency();
        }
     }
   Grid();
  }

void OnTimer()
  {
   CheckConnection();
   CheckAutoStart();
   Grid();
   if(g_risk.Update())
      ApplyEmergency();
   if(!MQLInfoInteger(MQL_TESTER))
      UpdatePanel();
  }

//==================================================================
//  TRADE ENGINE
//==================================================================
// Price distance that gains or loses `usd` on InpLot (0.01 lot of gold: $1 per $1 move).
double UsdToDistance(const double usd)
  {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(ts <= 0 || tv <= 0)
      return 0;
   return usd / (InpLot * tv / ts);
  }

// One position at a time. Its stop loss and take profit sit on the broker's server, so they
// work even when MT5 or the internet is down. Nothing is ever added to a losing position.
// After every close a new trade opens in the daily direction, until STOP.
void Grid()
  {
   GridInfo g;
   ReadGrid(g);
   if(g_state != BOT_RUNNING)
     {
      g_block = "";
      return;
     }
   if(g.levels > 0)
     {
      g_block = "";
      return;                           // in a trade: the server closes it at TP or SL
     }
   datetime now = TimeCurrent();
   if(now == g_lastTry)                 // at most one order attempt per second
      return;
   g_lastTry = now;

   g_block = PlatformBlockReason();
   if(g_block != "")
      return;
   if(g_risk.Locked())
     {
      g_block = g_risk.LockText();
      return;
     }
   UpdateFilter();
   if(DailyLimitHit())
     {
      g_block = StringFormat("daily loss limit %.1f%% reached: no new trade today", InpDailyLossPct);
      return;
     }
   if(g_filter == 0)
     {
      g_block = g_filterText;
      return;
     }
   OpenTrade(g_filter);
  }

bool OpenTrade(const int dir)
  {
   double sl = UsdToDistance(InpStopLossUSD);
   double tp = UsdToDistance(InpTakeProfitUSD);
   if(sl <= 0 || tp <= 0)
     {
      g_block = "no tick value for " + _Symbol;
      return false;
     }
   double minDist = g_exec.MinStopDistance();
   if(sl < minDist || tp < minDist)
     {
      g_block = StringFormat("SL/TP closer than the broker allows (%.2f)", minDist);
      return false;
     }
   string err;
   double fill = 0;
   MqlTick tk;
   SymbolInfoTick(_Symbol, tk);
   ulong pos = g_exec.Open(dir, InpLot, sl, tp, InpTradeComment, err, fill);
   if(pos == 0)
     {
      g_block = "order rejected: " + err;
      Msg("Order failed: " + err, CLR_RED);
      return false;
     }
   g_trades++;
   JournalOpen((long)pos, dir, "TREND", g_filterText, InpLot, fill, tk.ask - tk.bid, sl, tp, 0, InpStopLossUSD,
               0, 0, "");
   Msg(StringFormat("%s %.2f at %s   SL %s (-%.0f)   TP %s (+%.0f)", dir > 0 ? "BUY" : "SELL", InpLot,
                    DoubleToString(fill, _Digits), DoubleToString(fill - dir * sl, _Digits), InpStopLossUSD,
                    DoubleToString(fill + dir * tp, _Digits), InpTakeProfitUSD), CLR_BLUE);
   return true;
  }

//==================================================================
//  CONTROLS
//==================================================================
string PlatformBlockReason()
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
   if(IsRealAccount() && !InpAllowReal)
      return "REAL account: not allowed in the inputs";
   return "";
  }

void CheckAutoStart()
  {
   if(!InpAutoStart || MQLInfoInteger(MQL_TESTER) || g_state == BOT_RUNNING)
      return;
   if(ManualStop() || g_risk.Locked() || !TerminalInfoInteger(TERMINAL_CONNECTED))
      return;
   g_state = BOT_RUNNING;
   Msg("AUTO-STARTED: connected to the broker.", CLR_GREEN);
  }

void CheckConnection()
  {
   bool connected = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);
   if(!connected && g_wasConnected)
     {
      g_wasConnected = false;
      Msg("Connection lost. SL and TP stay on the broker's server.", CLR_RED);
     }
   else if(connected && !g_wasConnected)
     {
      g_wasConnected = true;
      Msg("Reconnected.", CLR_GREEN);
     }
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id != CHARTEVENT_OBJECT_CLICK || StringFind(sparam, PREFIX) != 0)
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
         string err;
         NoteCloseReason(g_rowTicket[idx], "manual (panel)");
         if(!g_exec.Close(g_rowTicket[idx], err))
            Msg(err, CLR_RED);
        }
     }
   g_risk.Update();
   UpdatePanel();
  }

void DoStart()
  {
   if(g_risk.Locked())
     {
      Msg("Cannot start: " + g_risk.LockText(), CLR_RED);
      return;
     }
   g_state = BOT_RUNNING;
   GlobalVariableDel(ManualStopKey());
   if(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      Msg("Bot STARTED.", CLR_GREEN);
   else
      Msg("STARTED, but Algo Trading is OFF in MT5.", CLR_AMBER);
  }

void DoStop()
  {
   g_state = BOT_STOPPED;
   GlobalVariableSet(ManualStopKey(), 1);
   Msg("STOPPED: no new trades. The open trade keeps its SL and TP.", CLR_AMBER);
  }

void DoCloseAll()
  {
   int n = CountOurs();
   if(n == 0)
     {
      Msg("No open positions to close.", CLR_MUTED);
      return;
     }
   if(MessageBox(StringFormat("Close all %d position(s) on %s now?", n, _Symbol), "XAUScalper",
                 MB_YESNO | MB_ICONQUESTION) == IDYES)
      CloseAll("manual close all");
  }

void DoEmergency()
  {
   if(MessageBox("Emergency: close ALL positions, stop the bot and block new trades until the next trading day.\n\nContinue?",
                 "XAUScalper", MB_YESNO | MB_ICONWARNING) != IDYES)
      return;
   g_risk.TriggerEmergency("manual");
   GlobalVariableSet(ManualStopKey(), 1);
   ApplyEmergency();
  }

void ApplyEmergency()
  {
   g_state = BOT_STOPPED;
   CloseAll("emergency");
   Msg("EMERGENCY: " + g_risk.LockText(), CLR_RED);
  }

int CloseAll(const string why)
  {
   int closed = 0;
   for(int attempt = 0; attempt < 3; attempt++)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !IsOurs())
            continue;
         NoteCloseReason(ticket, why);
         string err;
         if(g_exec.Close(ticket, err))
            closed++;
         else
            Print(err);
        }
      if(CountOurs() == 0)
         break;
     }
   if(CountOurs() > 0)
      Msg(StringFormat("Close all (%s): some positions could NOT be closed.", why), CLR_RED);
   else
      Msg(StringFormat("Close all (%s): %d position(s) closed.", why, closed), CLR_MUTED);
   return closed;
  }

//==================================================================
//  JOURNAL: CLOSED POSITIONS
//==================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || !HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;

   long   posId  = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   long   outMsc = HistoryDealGetInteger(trans.deal, DEAL_TIME_MSC);
   long   type   = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   long   reason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
   double lots   = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
   double price  = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   double comm   = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION) + HistoryDealGetDouble(trans.deal, DEAL_FEE);
   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP) + comm;

   if(!HistorySelectByPosition(posId))
      return;
   bool ours = false;
   long inMsc = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0 || HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;
      if(HistoryDealGetInteger(d, DEAL_MAGIC) == InpMagic)
        {
         ours  = true;
         inMsc = HistoryDealGetInteger(d, DEAL_TIME_MSC);
         double c = HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
         comm   += c;
         profit += c;
        }
     }
   if(!ours)
      return;
   string why = TakeCloseReason(posId);
   if(why == "")
      why = (reason == DEAL_REASON_TP) ? "take profit" : (reason == DEAL_REASON_SL) ? "stop loss"
            : (reason == DEAL_REASON_SO) ? "stop out" : "other";
   if(profit > 0)
      g_wins++;
   else
      g_losses++;
   double hold = (inMsc > 0 && outMsc >= inMsc) ? (outMsc - inMsc) / 1000.0 : 0.0;
   JournalClose(posId, type == DEAL_TYPE_SELL ? "BUY" : "SELL", "GRID", lots, price, profit, comm, hold, 0, false, why);
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

void MkButton(const string name, int x, int y, int w, int h, const string text, color bg, color fg, int size = 9)
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
   ObjectSetString(0, P(name), OBJPROP_TEXT, Fit(text));
   ObjectSetInteger(0, P(name), OBJPROP_COLOR, clr);
  }

void ShowObj(const string name, bool show)
  {
   if(g_collapsed)
      show = false;
   ObjectSetInteger(0, P(name), OBJPROP_TIMEFRAMES, show ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS);
  }

string RowCell(int row, int col) { return "r" + IntegerToString(row) + "c" + IntegerToString(col); }

int ColX(int col)
  {
   switch(col)
     {
      case 0: return 12;
      case 1: return 100;
      case 2: return 150;
      case 3: return 240;
      case 4: return 340;
     }
   return 488;
  }

bool AlwaysVisible(const string name)
  {
   return name == P("bg") || name == P("header") || name == P("title") || name == P("mode")
          || name == P("pill") || name == P("pill_t") || name == P("b_min");
  }

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
   MkRect("bg",     0, 0, PANEL_W, PANEL_H, CLR_BG, CLR_BORDER);
   MkRect("header", 0, 0, PANEL_W, 36, CLR_HEADER, CLR_BORDER);
   MkLabel("title", 14, 9, "XAU SCALPER", CLR_TEXT, 12, "Arial Bold");
   MkLabel("mode", 150, 12, "DAILY TREND  TP +" + DoubleToString(InpTakeProfitUSD, 0) + " / SL -" + DoubleToString(InpStopLossUSD, 0), CLR_BLUE, 8, "Arial Bold");
   MkRect("pill", PANEL_W - 118, 8, 106, 20, CLR_GREY, CLR_GREY);
   MkLabel("pill_t", PANEL_W - 65, 18, "STOPPED", clrWhite, 8, "Arial Bold", ANCHOR_CENTER);
   MkButton("b_min", PANEL_W - 146, 8, 22, 20, "-", CLR_GREY, clrWhite, 10);
   MkLabel("info", 14, 44, " ", CLR_MUTED, 8);

   string titles[6] = {"BALANCE", "EQUITY", "DAY P/L", "OPEN P/L", "SPREAD", "MARGIN LEVEL"};
   for(int i = 0; i < 6; i++)
     {
      int x = 14 + (i % 3) * 178;
      int y = 66 + (i / 3) * 40;
      MkLabel("s_t" + IntegerToString(i), x, y, titles[i], CLR_MUTED, 7);
      MkLabel("s_v" + IntegerToString(i), x, y + 13, "-", CLR_TEXT, 11, "Arial Bold");
     }
   MkLabel("sig1", 14, 146, " ", CLR_TEXT, 8, "Arial Bold");
   MkLabel("sig2", 14, 162, " ", CLR_MUTED, 8);

   MkRect("sep1", 12, 180, PANEL_W - 24, 1, CLR_BORDER, CLR_BORDER);
   MkButton("b_start", 12,  188, 110, 32, "START",     CLR_GREEN,   clrWhite, 10);
   MkButton("b_stop",  130, 188, 110, 32, "STOP",      CLR_RED,     clrWhite, 10);
   MkButton("b_close", 248, 188, 120, 32, "CLOSE ALL", CLR_GREY,    clrWhite, 9);
   MkButton("b_emerg", 376, 188, 152, 32, "EMERGENCY", CLR_DARKRED, clrWhite, 9);

   MkLabel("t_title", 14, 226, "OPEN POSITION (0)", CLR_MUTED, 7, "Arial Bold");
   string heads[6] = {"TICKET", "TYPE", "OPEN", "STOP LOSS", "TAKE PROFIT", "P/L"};
   for(int c = 0; c < 6; c++)
      MkLabel("h" + IntegerToString(c), ColX(c), ROW_Y0 + 6, heads[c], CLR_MUTED, 7, "Arial",
              c == 5 ? ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER);
   MkRect("sep2", 12, ROW_Y0 + 20, PANEL_W - 24, 1, CLR_BORDER, CLR_BORDER);
   for(int r = 0; r < MAX_ROWS; r++)
     {
      int y = ROW_Y0 + 24 + r * ROW_H;
      for(int c = 0; c < 6; c++)
         MkLabel(RowCell(r, c), ColX(c), y, " ", CLR_TEXT, 9, "Arial", c == 5 ? ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER);
      MkButton("rx" + IntegerToString(r), 500, y - 2, 26, 18, "X", CLR_RED, clrWhite, 8);
      ShowObj("rx" + IntegerToString(r), false);
     }
   MkLabel("t_empty", PANEL_W / 2, ROW_Y0 + 60, "No open position", CLR_MUTED, 9, "Arial", ANCHOR_UPPER);

   MkRect("sep3", 12, PANEL_H - 52, PANEL_W - 24, 1, CLR_BORDER, CLR_BORDER);
   MkLabel("f_msg",  14, PANEL_H - 44, g_lastMsg, g_lastMsgColor, 8);
   MkLabel("f_cond", 14, PANEL_H - 24, " ", CLR_MUTED, 8);
   ChartRedraw();
  }

string Signed(const double v) { return (v >= 0 ? "+" : "") + DoubleToString(v, 2); }
color  PLColor(const double v){ return v > 0 ? CLR_GREEN : (v < 0 ? CLR_RED : CLR_TEXT); }

void UpdatePanel()
  {
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE))
      return;
   bool   connected = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   GridInfo g;
   ReadGrid(g);
   if(g.levels == 0)
      UpdateFilter();

   string status = "STOPPED";
   color  pill   = CLR_GREY;
   if(!connected)                  { status = "OFFLINE"; pill = CLR_RED;   }
   else if(g_risk.Locked())        { status = "LOCKED";  pill = CLR_RED;   }
   else if(g_state == BOT_RUNNING) { status = "RUNNING"; pill = CLR_GREEN; }
   ObjectSetInteger(0, P("pill"), OBJPROP_BGCOLOR, pill);
   ObjectSetInteger(0, P("pill"), OBJPROP_COLOR, pill);
   SetText("pill_t", status, clrWhite);
   SetText("info", AccountInfoString(ACCOUNT_COMPANY) + " | " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
           + " (" + AccountMode() + ") | " + _Symbol, CLR_MUTED);

   MqlTick tick;
   double spread = SymbolInfoTick(_Symbol, tick) ? tick.ask - tick.bid : 0.0;
   double ml = AccountInfoDouble(ACCOUNT_MARGIN) > 0 ? AccountInfoDouble(ACCOUNT_MARGIN_LEVEL) : 0.0;
   double day = DayPL();
   SetText("s_v0", DoubleToString(bal, 2) + " " + cur, CLR_TEXT);
   SetText("s_v1", DoubleToString(eq, 2) + " " + cur, CLR_TEXT);
   SetText("s_v2", Signed(day) + StringFormat("  (%.1f%%)", DayStartBalance() > 0 ? day / DayStartBalance() * 100 : 0),
           PLColor(day));
   SetText("s_v3", Signed(g.pl), PLColor(g.pl));
   SetText("s_v4", DoubleToString(spread, _Digits), CLR_TEXT);
   SetText("s_v5", ml > 0 ? DoubleToString(ml, 0) + "%" : "-", CLR_TEXT);

   SetText("sig1", "Daily trend: " + g_filterText, g_filter > 0 ? CLR_GREEN : (g_filter < 0 ? CLR_RED : CLR_AMBER));
   SetText("sig2", StringFormat("Trades %d   won %d   lost %d   lot %.2f   daily limit %s", g_trades, g_wins, g_losses,
                                InpLot, InpDailyLossPct > 0 ? DoubleToString(InpDailyLossPct, 1) + "%" : "off"), CLR_MUTED);

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
      double pl    = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double psl   = PositionGetDouble(POSITION_SL);
      double ptp   = PositionGetDouble(POSITION_TP);
      SetText(RowCell(row, 0), IntegerToString((long)ticket), CLR_TEXT);
      SetText(RowCell(row, 1), isBuy ? "BUY" : "SELL", isBuy ? CLR_GREEN : CLR_RED);
      SetText(RowCell(row, 2), DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), _Digits), CLR_TEXT);
      SetText(RowCell(row, 3), psl > 0 ? DoubleToString(psl, _Digits) : "none", psl > 0 ? CLR_RED : CLR_AMBER);
      SetText(RowCell(row, 4), ptp > 0 ? DoubleToString(ptp, _Digits) : "none", ptp > 0 ? CLR_GREEN : CLR_AMBER);
      SetText(RowCell(row, 5), Signed(pl), PLColor(pl));
      g_rowTicket[row] = ticket;
      ShowObj("rx" + IntegerToString(row), true);
      row++;
     }
   for(; row < MAX_ROWS; row++)
     {
      for(int c = 0; c < 6; c++)
         SetText(RowCell(row, c), " ", CLR_TEXT);
      g_rowTicket[row] = 0;
      ShowObj("rx" + IntegerToString(row), false);
     }
   SetText("t_title", "OPEN POSITION (" + IntegerToString(total) + ")", CLR_MUTED);
   ShowObj("t_empty", total == 0);

   SetText("f_msg", g_lastMsg, g_lastMsgColor);
   string cond;
   color  cc = CLR_MUTED;
   if(g_risk.Locked())
     {
      cond = "Locked: " + g_risk.LockText();
      cc = CLR_RED;
     }
   else if(g_state == BOT_RUNNING && g_block != "")
     {
      cond = "Waiting: " + g_block;
      cc = CLR_AMBER;
     }
   else if(g_state == BOT_RUNNING)
      cond = total > 0 ? "In a trade: the broker closes it at TP or SL." : "Running: opening a trade.";
   else if(InpAutoStart && ManualStop())
      cond = "Stopped by you: press START to resume.";
   else
      cond = "Stopped.";
   SetText("f_cond", cond, cc);
   ChartRedraw();
  }
//+------------------------------------------------------------------+
