//+------------------------------------------------------------------+
//|                                                 XAUScalper.mq5   |
//|        XAUUSD scalping Expert Advisor with on-chart control panel |
//+------------------------------------------------------------------+
#property copyright "Allan"
#property link      "https://github.com/allanorabaasa-hash/scalper"
#property version   "1.20"
#property description "XAUUSD scalper with an on-chart control panel."
#property description "Strategy: Momentum Burst. Enters on fast one-way tick moves, stacks winners, exits fast."

#include <Trade\Trade.mqh>

//==================================================================
//  INPUTS
//==================================================================
enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0,   // Fixed lot size
   LOT_RISK_PERCENT = 1    // % of balance risked per trade
  };

input group "General"
input long          InpMagic             = 20261112;      // Magic number (unique per EA)
input string        InpTradeComment      = "XAUScalper";  // Order comment

input group "Position sizing"
input ENUM_LOT_MODE InpLotMode           = LOT_RISK_PERCENT; // Lot mode
input double        InpFixedLots         = 0.01;          // Fixed lots (if Lot mode = Fixed)
input double        InpRiskPercent       = 1.0;           // Risk % per trade (if Lot mode = Risk %)
input double        InpMaxRiskAtMinLot   = 5.0;           // Small accounts: allow min lot if its risk <= this % (0 = never)
input double        InpMarginBuffer      = 50.0;          // Keep at least this % of free margin unused

input group "Stops (price distance: 2.00 = a $2 move in gold)"
input double        InpStopLoss          = 1.50;          // Hard stop loss distance (required)
input double        InpTakeProfit        = 1.50;          // Take profit distance (0 = none)

input group "Filters and limits (Max positions / cooldown / trades per minute are used in Custom profile)"
input double        InpMaxSpread         = 0.35;          // Max spread in price (0 = off)
input int           InpMaxPositions      = 3;             // Max open positions at once
input int           InpCooldownSec       = 2;             // Seconds between new trades
input int           InpMaxTradesPerMin   = 20;            // Max new trades per minute (0 = off)
input int           InpSlippagePoints    = 30;            // Max slippage (points)
input double        InpMaxDailyLossPct   = 5.0;           // Daily loss limit % (0 = off)
input double        InpDailyTargetPct    = 0.0;           // Daily profit target % (0 = off)

enum ENUM_PROFILE
  {
   PROFILE_SAFE       = 0,  // Safe: fewer, stronger bursts
   PROFILE_BALANCED   = 1,  // Balanced
   PROFILE_AGGRESSIVE = 2,  // Aggressive: more trades, faster exits
   PROFILE_CUSTOM     = 3   // Custom: use the values below
  };

input group "Momentum burst strategy (values below are used in Custom profile)"
input ENUM_PROFILE  InpProfile           = PROFILE_BALANCED; // Profile (can also be switched on the panel)
input bool          InpJournal           = true;          // Write every trade to MQL5/Files/XAUScalper_journal.csv
input int           InpBurstWindowMs     = 3000;          // Burst window (milliseconds)
input double        InpBurstSpreadMult   = 3.0;           // Burst must move at least N x spread
input double        InpBurstMinMove      = 0.50;          // ...and at least this price distance
input int           InpBurstMinTicks     = 6;             // Min price changes inside the window
input double        InpBurstDirRatio     = 0.70;          // Share of ticks in the burst direction (0.5-1)
input int           InpMaxStack          = 3;             // Max positions stacked in one direction
input double        InpStackStep         = 0.30;          // Add only when newest position is up this much
input bool          InpReverseOnBurst    = true;          // Opposite burst: close all and reverse
input double        InpBreakEvenTrigger  = 0.30;          // Move SL to breakeven at this profit (0 = off)
input double        InpBreakEvenLock     = 0.05;          // Profit locked at breakeven
input double        InpTrailStart        = 0.50;          // Start trailing at this profit (0 = off)
input double        InpTrailDistance     = 0.30;          // Trailing distance behind price
input double        InpTrailStep         = 0.05;          // Min SL move before modifying
input int           InpMaxHoldSec        = 20;            // Close any trade after N seconds (0 = off)

input group "Session (PC local time)"
input bool          InpUseSession        = false;         // Limit trading to session hours (false = trade any time)
input int           InpStartHour         = 10;            // Session start hour
input int           InpStartMinute       = 0;             // Session start minute
input int           InpEndHour           = 19;            // Session end hour
input int           InpEndMinute         = 0;             // Session end minute
input bool          InpCloseAtSessionEnd = true;          // Close all positions when session ends

input group "Connection safety"
input bool          InpPauseOnReconnect  = true;          // Pause bot after a connection drop
input bool          InpCloseOnReconnect  = false;         // Close all positions after a connection drop

input group "Panel"
input bool          InpShowManualButtons = true;          // Show manual BUY / SELL buttons
input int           InpPanelX            = 10;            // Panel X offset
input int           InpPanelY            = 30;            // Panel Y offset

//==================================================================
//  STATE
//==================================================================
enum ENUM_BOT_STATE
  {
   BOT_STOPPED = 0,
   BOT_RUNNING = 1,
   BOT_PAUSED  = 2
  };

#define MAX_ROWS 8
#define PREFIX   "XS_"

CTrade         g_trade;
ENUM_BOT_STATE g_state           = BOT_STOPPED;
bool           g_dailyLimitHit   = false;
datetime       g_dailyLimitDay   = 0;
datetime       g_lastTradeTime   = 0;
bool           g_wasConnected    = true;
bool           g_prevSessionOpen = false;
double         g_todayClosed     = 0.0;
double         g_floating        = 0.0;
string         g_lastMsg         = "Ready. Press START to begin.";
color          g_lastMsgColor    = clrSilver;
ulong          g_rowTicket[MAX_ROWS];
bool           g_collapsed       = false;
datetime       g_openTimes[];                 // entry times, for the trades-per-minute limit
double         g_lastMove        = 0.0;       // last measured burst move (for the panel)
double         g_lastNeed        = 0.0;       // move required to trigger
double         g_lastRatio       = 0.0;       // share of ticks in the move's direction
int            g_lastTicks       = 0;         // price changes inside the window
int            g_tradesToday     = 0;
int            g_winsToday       = 0;

struct StrategyParams
  {
   int    windowMs;
   double spreadMult;
   double minMove;
   int    minTicks;
   double dirRatio;
   int    maxStack;
   double stackStep;
   int    maxPositions;
   int    cooldownSec;
   int    maxTradesPerMin;
   double beTrigger;
   double beLock;
   double trailStart;
   double trailDist;
   int    maxHoldSec;
  };
StrategyParams g_p;
ENUM_PROFILE   g_profile = PROFILE_BALANCED;

string ProfileName(ENUM_PROFILE p)
  {
   switch(p)
     {
      case PROFILE_SAFE:       return "SAFE";
      case PROFILE_BALANCED:   return "BALANCED";
      case PROFILE_AGGRESSIVE: return "AGGRESSIVE";
      default:                 return "CUSTOM";
     }
  }

void SetParams(int window, double mult, double minMove, int ticks, double ratio, int stack, double step,
               int cooldown, int perMin, double beT, double beL, double trS, double trD, int hold)
  {
   g_p.windowMs = window;  g_p.spreadMult = mult;  g_p.minMove = minMove;  g_p.minTicks = ticks;
   g_p.dirRatio = ratio;   g_p.maxStack = stack;   g_p.stackStep = step;   g_p.maxPositions = stack;
   g_p.cooldownSec = cooldown;  g_p.maxTradesPerMin = perMin;
   g_p.beTrigger = beT;  g_p.beLock = beL;  g_p.trailStart = trS;  g_p.trailDist = trD;  g_p.maxHoldSec = hold;
  }

void ApplyProfile()
  {
   switch(g_profile)
     {
      //                   window mult  min   ticks ratio stack step cool /min  BE    lock  trail dist hold
      case PROFILE_SAFE:       SetParams(3000, 3.0, 0.50, 6, 0.70, 2, 0.30, 3, 10, 0.30, 0.05, 0.50, 0.30, 20); break;
      case PROFILE_BALANCED:   SetParams(2000, 2.5, 0.40, 5, 0.68, 3, 0.25, 1, 20, 0.25, 0.05, 0.40, 0.25, 15); break;
      case PROFILE_AGGRESSIVE: SetParams(1500, 2.0, 0.30, 4, 0.65, 5, 0.20, 0, 40, 0.20, 0.03, 0.30, 0.20, 10); break;
      default:
         SetParams(InpBurstWindowMs, InpBurstSpreadMult, InpBurstMinMove, InpBurstMinTicks, InpBurstDirRatio,
                   InpMaxStack, InpStackStep, InpCooldownSec, InpMaxTradesPerMin, InpBreakEvenTrigger,
                   InpBreakEvenLock, InpTrailStart, InpTrailDistance, InpMaxHoldSec);
         g_p.maxPositions = InpMaxPositions;
         break;
     }
  }

//--- Panel colours
const color CLR_BG      = C'22,27,34';
const color CLR_HEADER  = C'13,17,23';
const color CLR_BORDER  = C'48,54,61';
const color CLR_ROWALT  = C'28,33,40';
const color CLR_TEXT    = C'230,237,243';
const color CLR_MUTED   = C'139,148,158';
const color CLR_GREEN   = C'46,160,67';
const color CLR_RED     = C'218,54,51';
const color CLR_AMBER   = C'210,153,34';
const color CLR_GREY    = C'87,96,106';
const color CLR_BLUE    = C'31,111,235';

//--- Panel geometry
#define PANEL_W  540
#define PANEL_H  454
#define ROW_Y0   222
#define ROW_H    22

//==================================================================
//  STRATEGY: MOMENTUM BURST
//==================================================================
// 1. Watch raw ticks. A burst = price moved at least max(N x spread, min move)
//    within the window, with most ticks pointing the same way.
// 2. Enter in the burst direction. Stack more positions only while the newest
//    one is already in profit (never add to a loser).
// 3. Opposite burst: close everything and reverse.
// 4. Exits: hard SL on every order, breakeven, trailing stop, max hold time.

ulong NowMsc()
  {
   MqlTick tick;
   ulong t = 0;
   if(SymbolInfoTick(_Symbol, tick))
      t = (ulong)tick.time_msc;
   ulong srv = (ulong)TimeTradeServer() * 1000;
   return (t > srv ? t : srv);
  }

// +1 = up burst, -1 = down burst, 0 = none
int BurstDirection()
  {
   MqlTick now;
   if(!SymbolInfoTick(_Symbol, now))
      return 0;

   ulong to   = (ulong)now.time_msc;
   ulong from = (to > (ulong)g_p.windowMs) ? to - (ulong)g_p.windowMs : 0;
   MqlTick ticks[];
   int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_INFO, from, to);
   if(n < 2)
      return 0;

   int up = 0, down = 0;
   for(int i = 1; i < n; i++)
     {
      double d = ticks[i].bid - ticks[i - 1].bid;
      if(d > 0)
         up++;
      else if(d < 0)
         down++;
     }
   int changes = up + down;
   double spread = now.ask - now.bid;
   g_lastMove = ticks[n - 1].bid - ticks[0].bid;
   g_lastNeed = MathMax(g_p.minMove, g_p.spreadMult * spread);
   g_lastTicks = changes;
   g_lastRatio = (changes > 0) ? (double)(g_lastMove >= 0 ? up : down) / changes : 0.0;

   if(changes < g_p.minTicks)
      return 0;
   if(g_lastMove >= g_lastNeed && (double)up / changes >= g_p.dirRatio)
      return 1;
   if(-g_lastMove >= g_lastNeed && (double)down / changes >= g_p.dirRatio)
      return -1;
   return 0;
  }

// Our positions in one direction: count, and profit (price distance) of the newest.
void SideInfo(const int dir, int &count, double &newestProfit)
  {
   count = 0;
   newestProfit = 0.0;
   long newestTime = 0;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0 || !IsOurs())
         continue;
      bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      if((dir > 0) != isBuy)
         continue;
      count++;
      long t = PositionGetInteger(POSITION_TIME_MSC);
      if(t > newestTime)
        {
         newestTime = t;
         double open = PositionGetDouble(POSITION_PRICE_OPEN);
         newestProfit = isBuy ? tick.bid - open : open - tick.ask;
        }
     }
  }

void CloseSide(const int dir)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurs())
         continue;
      bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      if((dir > 0) == isBuy)
         g_trade.PositionClose(ticket, InpSlippagePoints);
     }
  }

void RunStrategy()
  {
   int dir = BurstDirection();
   if(dir == 0)
      return;

   int oppCount, sameCount;
   double oppProfit, sameProfit;
   SideInfo(-dir, oppCount, oppProfit);
   if(oppCount > 0)
     {
      if(!InpReverseOnBurst)
         return;
      CloseSide(-dir);
      Msg(StringFormat("Reverse: closed %d %s position(s)", oppCount, dir > 0 ? "SELL" : "BUY"), CLR_AMBER);
     }

   SideInfo(dir, sameCount, sameProfit);
   if(sameCount >= g_p.maxStack)
      return;
   if(sameCount > 0 && sameProfit < g_p.stackStep)
      return;   // only add to a position that is already winning
   if(BlockReason() != "")
      return;

   OpenTrade(dir, sameCount > 0 ? "STACK" : "BURST");
  }

// Breakeven, trailing stop and max hold time for every open position of this EA.
void ManagePositions()
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
      return;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double stopsLvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   ulong  nowMsc   = NowMsc();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurs())
         continue;

      bool   isBuy  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open   = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl     = PositionGetDouble(POSITION_SL);
      double tp     = PositionGetDouble(POSITION_TP);
      ulong  openMs = (ulong)PositionGetInteger(POSITION_TIME_MSC);
      double profit = isBuy ? tick.bid - open : open - tick.ask;

      // Max hold time
      if(g_p.maxHoldSec > 0 && nowMsc > openMs && nowMsc - openMs >= (ulong)g_p.maxHoldSec * 1000)
        {
         g_trade.PositionClose(ticket, InpSlippagePoints);
         continue;
        }

      double newSL = sl;

      // Breakeven
      if(g_p.beTrigger > 0 && profit >= g_p.beTrigger)
        {
         double be = isBuy ? open + g_p.beLock : open - g_p.beLock;
         if(isBuy && (newSL == 0 || be > newSL))
            newSL = be;
         if(!isBuy && (newSL == 0 || be < newSL))
            newSL = be;
        }

      // Trailing stop
      if(g_p.trailStart > 0 && profit >= g_p.trailStart)
        {
         double trail = isBuy ? tick.bid - g_p.trailDist : tick.ask + g_p.trailDist;
         if(isBuy && (newSL == 0 || trail > newSL))
            newSL = trail;
         if(!isBuy && (newSL == 0 || trail < newSL))
            newSL = trail;
        }

      newSL = NormalizeDouble(newSL, digits);
      if(newSL == sl || MathAbs(newSL - sl) < InpTrailStep)
         continue;
      // respect the broker's minimum stop distance
      if(isBuy && newSL > tick.bid - stopsLvl)
         continue;
      if(!isBuy && newSL < tick.ask + stopsLvl)
         continue;
      g_trade.PositionModify(ticket, newSL, tp);
     }
  }

int TradesLastMinute()
  {
   datetime cutoff = TimeCurrent() - 60;
   int kept = 0;
   int n = ArraySize(g_openTimes);
   for(int i = 0; i < n; i++)
      if(g_openTimes[i] >= cutoff)
         g_openTimes[kept++] = g_openTimes[i];
   ArrayResize(g_openTimes, kept);
   return kept;
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

   g_profile = InpProfile;
   string pkey = StateKey() + "_p";
   if(GlobalVariableCheck(pkey))
     {
      g_profile = (ENUM_PROFILE)(int)GlobalVariableGet(pkey);
      GlobalVariableDel(pkey);
     }
   ApplyProfile();

   // MT5 keeps global variables when inputs change, so re-check the lock here
   if(InpMaxDailyLossPct <= 0 && InpDailyTargetPct <= 0)
      g_dailyLimitHit = false;

   g_state = BOT_STOPPED;
   // Keep RUNNING state only across a timeframe switch or input change,
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
   RefreshStats();
   UpdatePanel();
   EventSetMillisecondTimer(500);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(reason == REASON_CHARTCHANGE || reason == REASON_PARAMETERS)
     {
      GlobalVariableSet(StateKey(), (double)g_state);
      if(g_profile != InpProfile)
         GlobalVariableSet(StateKey() + "_p", (double)g_profile);
     }

   EventKillTimer();
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

void OnTick()
  {
   ManagePositions();          // runs even when stopped, so open trades stay managed
   if(g_state == BOT_RUNNING)
      RunStrategy();
  }

void OnTimer()
  {
   CheckConnection();
   ManagePositions();
   RefreshStats();
   CheckDailyLimits();
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
   else if(sparam == P("b_buy"))
      DoManual(1);
   else if(sparam == P("b_sell"))
      DoManual(-1);
   else if(sparam == P("b_mode"))
     {
      g_profile = (ENUM_PROFILE)(((int)g_profile + 1) % 4);
      ApplyProfile();
      Msg("Profile: " + ProfileName(g_profile), CLR_BLUE);
     }
   else if(sparam == P("b_min"))
     {
      g_collapsed = !g_collapsed;
      ApplyCollapse();
     }
   else if(StringFind(sparam, P("rx")) == 0)
     {
      int idx = (int)StringToInteger(StringSubstr(sparam, StringLen(P("rx"))));
      if(idx >= 0 && idx < MAX_ROWS && g_rowTicket[idx] > 0)
         ClosePosition(g_rowTicket[idx]);
     }

   RefreshStats();
   UpdatePanel();
  }

//==================================================================
//  BUTTON ACTIONS
//==================================================================
void DoStart()
  {
   if(g_dailyLimitHit)
     {
      Msg("Daily limit reached. Trading is locked until tomorrow.", CLR_RED);
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
      Msg("Bot STOPPED. Open positions stay protected by their SL/TP.", CLR_AMBER);
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

void DoManual(const int dir)
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
     {
      Msg("No connection to the broker.", CLR_RED);
      return;
     }
   OpenTrade(dir, "MANUAL");
  }

//==================================================================
//  SAFETY CHECKS
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

// Empty string = allowed to open a new trade, otherwise the reason it is blocked.
string BlockReason()
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
   if(g_dailyLimitHit)
      return "daily limit reached";
   if(!SessionOpen())
      return "outside session hours";
   double spread = CurrentSpread();
   if(InpMaxSpread > 0 && spread > InpMaxSpread)
      return StringFormat("spread %s > max %s", DoubleToString(spread, _Digits), DoubleToString(InpMaxSpread, _Digits));
   if(CountOurPositions() >= g_p.maxPositions)
      return "max open positions reached";
   if(TimeCurrent() - g_lastTradeTime < g_p.cooldownSec)
      return "cooldown after last trade";
   if(g_p.maxTradesPerMin > 0 && TradesLastMinute() >= g_p.maxTradesPerMin)
      return "max trades per minute reached";
   return "";
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

void CheckDailyLimits()
  {
   // Both limits switched off: never lock, and clear a lock left from earlier.
   if(InpMaxDailyLossPct <= 0 && InpDailyTargetPct <= 0)
     {
      if(g_dailyLimitHit)
        {
         g_dailyLimitHit = false;
         Msg("Daily limits are off. Lock cleared.", CLR_MUTED);
        }
      return;
     }
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(g_dailyLimitHit && today != 0 && today != g_dailyLimitDay)
     {
      g_dailyLimitHit = false;
      Msg("New trading day. Daily limit reset.", CLR_MUTED);
     }
   if(g_dailyLimitHit)
      return;

   double dayResult    = g_todayClosed + g_floating;
   double startBalance = AccountInfoDouble(ACCOUNT_BALANCE) - g_todayClosed;
   if(startBalance <= 0)
      return;

   string reason = "";
   if(InpMaxDailyLossPct > 0 && dayResult <= -startBalance * InpMaxDailyLossPct / 100.0)
      reason = "Daily loss limit hit";
   else if(InpDailyTargetPct > 0 && dayResult >= startBalance * InpDailyTargetPct / 100.0)
      reason = "Daily profit target reached";

   if(reason != "")
     {
      g_dailyLimitHit = true;
      g_dailyLimitDay = today;
      g_state         = BOT_STOPPED;
      CloseAll(reason);
      Msg(reason + ". Locked until tomorrow.", reason == "Daily loss limit hit" ? CLR_RED : CLR_GREEN);
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
//  TRADING
//==================================================================
int VolumeDigits(double step)
  {
   int d = 0;
   while(step < 1.0 - 1e-9 && d < 8)
     {
      step *= 10.0;
      d++;
     }
   return d;
  }

// Returns 0 if a valid lot size cannot be produced.
double CalcLots(const double slDistance)
  {
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lots   = InpFixedLots;

   if(InpLotMode == LOT_RISK_PERCENT)
     {
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tickValue <= 0)
         tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tickSize <= 0 || tickValue <= 0 || slDistance <= 0)
         return 0.0;
      double lossPerLot = slDistance / tickSize * tickValue;
      double riskMoney  = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
      lots = riskMoney / lossPerLot;
     }

   if(step > 0)
      lots = MathFloor(lots / step + 1e-9) * step;
   if(lots < minLot)
     {
      // Small account: the minimum lot risks more than Risk %. Allow it only
      // while that risk stays within InpMaxRiskAtMinLot.
      if(InpLotMode != LOT_RISK_PERCENT || InpMaxRiskAtMinLot <= 0)
         return 0.0;
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tickValue <= 0)
         tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(tickSize <= 0 || tickValue <= 0 || balance <= 0)
         return 0.0;
      double riskAtMin = slDistance / tickSize * tickValue * minLot / balance * 100.0;
      if(riskAtMin > InpMaxRiskAtMinLot)
         return 0.0;
      lots = minLot;
     }
   if(lots > maxLot)
      lots = maxLot;
   return NormalizeDouble(lots, VolumeDigits(step));
  }

bool OpenTrade(const int dir, const string tag)
  {
   if(InpStopLoss <= 0)
     {
      Msg("Stop loss must be greater than 0.", CLR_RED);
      return false;
     }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
     {
      Msg("No price available for " + _Symbol, CLR_RED);
      return false;
     }

   int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minDist  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point + (tick.ask - tick.bid);
   double slDist   = MathMax(InpStopLoss, minDist);
   double tpDist   = MathMax(InpTakeProfit, minDist);

   double lots = CalcLots(slDist);
   if(lots <= 0)
     {
      Msg("Too small for min lot at this SL. Use a Cent account.", CLR_AMBER);
      return false;
     }

   // Margin check: never use more than (100 - buffer)% of free margin
   double margin = 0.0;
   ENUM_ORDER_TYPE otype = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double refPrice = (dir > 0) ? tick.ask : tick.bid;
   if(OrderCalcMargin(otype, _Symbol, lots, refPrice, margin)
      && margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * (100.0 - InpMarginBuffer) / 100.0)
     {
      Msg("Not enough free margin for another trade. Skipped.", CLR_AMBER);
      return false;
     }

   bool   sent;
   double price, sl, tp;
   if(dir > 0)
     {
      price = tick.ask;
      sl    = NormalizeDouble(price - slDist, digits);
      tp    = (InpTakeProfit > 0) ? NormalizeDouble(price + tpDist, digits) : 0.0;
      sent  = g_trade.Buy(lots, _Symbol, price, sl, tp, InpTradeComment);
     }
   else
     {
      price = tick.bid;
      sl    = NormalizeDouble(price + slDist, digits);
      tp    = (InpTakeProfit > 0) ? NormalizeDouble(price - tpDist, digits) : 0.0;
      sent  = g_trade.Sell(lots, _Symbol, price, sl, tp, InpTradeComment);
     }

   uint rc = g_trade.ResultRetcode();
   if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
     {
      g_lastTradeTime = TimeCurrent();
      int k = ArraySize(g_openTimes);
      ArrayResize(g_openTimes, k + 1, 64);
      g_openTimes[k] = TimeCurrent();
      JournalWrite("OPEN", (long)g_trade.ResultOrder(), (dir > 0 ? "BUY" : "SELL"), tag, lots,
                   g_trade.ResultPrice(), tick.ask - tick.bid, 0.0, 0.0, "");
      Msg(StringFormat("%s %s %s lots @ %s", tag, (dir > 0 ? "BUY" : "SELL"),
                       DoubleToString(lots, 2), DoubleToString(g_trade.ResultPrice(), digits)), CLR_GREEN);
      return true;
     }

   Msg(StringFormat("Order failed (%u): %s", rc, g_trade.ResultRetcodeDescription()), CLR_RED);
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
         if(g_trade.PositionClose(ticket, InpSlippagePoints))
            closed++;
         else
            failed++;
        }
      if(CountOurPositions() == 0)
         break;
     }
   PrintFormat("CloseAll (%s): closed %d, failed %d", why, closed, failed);
   if(CountOurPositions() > 0)
      Msg(StringFormat("Close all (%s): some positions could not be closed.", why), CLR_RED);
   else
      Msg(StringFormat("Close all (%s): %d position(s) closed.", why, closed), CLR_MUTED);
   return closed;
  }

//==================================================================
//  STATS
//==================================================================
void RefreshStats()
  {
   // Floating P/L of our open positions
   g_floating = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0 || !IsOurs())
         continue;
      g_floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }

   // Closed P/L today (broker server day) for positions opened by this EA
   g_todayClosed = 0.0;
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(dayStart == 0)
     {
      long now = (long)TimeCurrent();
      dayStart = (datetime)(now - now % 86400);
     }
   if(!HistorySelect(dayStart, TimeCurrent() + 3600))
      return;

   int total = HistoryDealsTotal();
   long ourIds[];
   int  idCount = 0;
   ArrayResize(ourIds, 0, 64);

   for(int i = 0; i < total; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN
         && HistoryDealGetInteger(deal, DEAL_MAGIC) == InpMagic)
        {
         ArrayResize(ourIds, idCount + 1, 64);
         ourIds[idCount++] = HistoryDealGetInteger(deal, DEAL_POSITION_ID);
        }
     }

   double posNet[];
   bool   posClosed[];
   ArrayResize(posNet, idCount);
   ArrayResize(posClosed, idCount);
   if(idCount > 0)
     {
      ArrayInitialize(posNet, 0.0);
      ArrayInitialize(posClosed, false);
     }

   for(int i = 0; i < total; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      long posId = HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      int  idx   = -1;
      for(int k = 0; k < idCount; k++)
         if(ourIds[k] == posId)
           {
            idx = k;
            break;
           }
      if(idx < 0)
         continue;

      double cost = HistoryDealGetDouble(deal, DEAL_COMMISSION) + HistoryDealGetDouble(deal, DEAL_FEE);
      double amount;
      if(HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
         amount = cost;
      else
        {
         amount = HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP) + cost;
         posClosed[idx] = true;
        }
      g_todayClosed += amount;
      posNet[idx]   += amount;
     }

   g_tradesToday = 0;
   g_winsToday   = 0;
   for(int k = 0; k < idCount; k++)
     {
      if(!posClosed[k])
         continue;
      g_tradesToday++;
      if(posNet[k] > 0)
         g_winsToday++;
     }
  }

//==================================================================
//  TRADE JOURNAL  (MQL5/Files/XAUScalper_journal.csv)
//==================================================================
// One row per entry (with the burst that triggered it) and one per exit,
// so the profile values can be tuned from real results.
void JournalWrite(const string event, const long position, const string side, const string tag,
                  const double lots, const double price, const double spread,
                  const double profit, const double holdSec, const string reason)
  {
   if(!InpJournal || MQLInfoInteger(MQL_OPTIMIZATION))
      return;
   string name = "XAUScalper_journal.csv";
   int h = FileOpen(name, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE)
      return;
   if(FileSize(h) == 0)
      FileWrite(h, "event", "time", "account", "position", "side", "tag", "profile", "lots", "price",
                "spread", "move", "need", "dir_ratio", "ticks", "profit", "hold_s", "reason");
   FileSeek(h, 0, SEEK_END);
   bool isOpen = (event == "OPEN");
   FileWrite(h, event, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
             IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)), IntegerToString(position), side, tag,
             ProfileName(g_profile), DoubleToString(lots, 2), DoubleToString(price, _Digits),
             DoubleToString(spread, _Digits),
             isOpen ? DoubleToString(g_lastMove, 2) : "", isOpen ? DoubleToString(g_lastNeed, 2) : "",
             isOpen ? DoubleToString(g_lastRatio, 2) : "", isOpen ? IntegerToString(g_lastTicks) : "",
             isOpen ? "" : DoubleToString(profit, 2), isOpen ? "" : DoubleToString(holdSec, 1), reason);
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

   // Confirm the position was opened by this EA and find its entry time
   if(!HistorySelectByPosition(posId))
      return;
   bool   ours  = false;
   long   inMsc = 0;
   string tag   = "";
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
        }
     }
   if(!ours)
      return;

   // A closing SELL deal closes a BUY position and vice versa
   string side = (dealType == DEAL_TYPE_SELL) ? "BUY" : "SELL";
   double hold = (inMsc > 0 && outMsc >= inMsc) ? (outMsc - inMsc) / 1000.0 : 0.0;
   JournalWrite("CLOSE", posId, side, tag, lots, price, CurrentSpread(), profit, hold, DealReasonText(reason));
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

// MT5 chart labels show at most 63 characters.
string Fit(const string text)
  {
   if(text == "")
      return " ";
   if(StringLen(text) > 63)
      return StringSubstr(text, 0, 60) + "...";
   return text;
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
          || name == P("pill") || name == P("pill_t") || name == P("b_min") || name == P("b_mode");
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
   MkRect("pill", PANEL_W - 118, 8, 106, 20, CLR_GREY, CLR_GREY);
   MkLabel("pill_t", PANEL_W - 65, 18, "STOPPED", clrWhite, 8, "Arial Bold", ANCHOR_CENTER);
   MkButton("b_min", PANEL_W - 146, 8, 22, 20, "-", CLR_GREY, clrWhite, 10);
   MkButton("b_mode", 150, 8, 150, 20, "MODE: BALANCED", CLR_GREY, clrWhite, 8);
   MkLabel("info", 14, 44, " ", CLR_MUTED, 8);

   // Stats grid (2 rows x 3 columns)
   string titles[6] = {"BALANCE", "EQUITY", "TODAY P/L", "FLOATING P/L", "SPREAD", "TRADES TODAY"};
   for(int i = 0; i < 6; i++)
     {
      int x = 14 + (i % 3) * 178;
      int y = 66 + (i / 3) * 40;
      MkLabel("s_t" + IntegerToString(i), x, y, titles[i], CLR_MUTED, 7);
      MkLabel("s_v" + IntegerToString(i), x, y + 13, "-", CLR_TEXT, 11, "Arial Bold");
     }

   // Buttons
   MkRect("sep1", 12, 148, PANEL_W - 24, 1, CLR_BORDER, CLR_BORDER);
   MkButton("b_start", 12,  158, 110, 32, "START",     CLR_GREEN, clrWhite, 10);
   MkButton("b_stop",  130, 158, 110, 32, "STOP",      CLR_RED,   clrWhite, 10);
   MkButton("b_close", 248, 158, 110, 32, "CLOSE ALL", CLR_GREY,  clrWhite, 9);
   if(InpShowManualButtons)
     {
      MkButton("b_buy",  382, 158, 70, 32, "BUY",  CLR_BLUE, clrWhite, 9);
      MkButton("b_sell", 458, 158, 70, 32, "SELL", CLR_BLUE, clrWhite, 9);
     }

   // Positions table
   MkLabel("t_title", 14, 200, "OPEN POSITIONS (0)", CLR_MUTED, 7, "Arial Bold");
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
   if(!connected)               { status = "OFFLINE"; pill = CLR_RED;   }
   else if(g_dailyLimitHit)     { status = "LOCKED";  pill = CLR_RED;   }
   else if(g_state == BOT_RUNNING) { status = "RUNNING"; pill = CLR_GREEN; }
   else if(g_state == BOT_PAUSED)  { status = "PAUSED";  pill = CLR_AMBER; }
   ObjectSetInteger(0, P("pill"), OBJPROP_BGCOLOR, pill);
   ObjectSetInteger(0, P("pill"), OBJPROP_COLOR, pill);
   SetText("pill_t", status, clrWhite);

   SetText("info", "Account " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "   |   "
           + AccountInfoString(ACCOUNT_SERVER) + "   |   " + _Symbol, CLR_MUTED);

   // Stats
   double spread = CurrentSpread();
   SetText("s_v0", Money(AccountInfoDouble(ACCOUNT_BALANCE)) + " " + currency, CLR_TEXT);
   SetText("s_v1", Money(AccountInfoDouble(ACCOUNT_EQUITY)) + " " + currency, CLR_TEXT);
   SetText("s_v2", Signed(g_todayClosed + g_floating), PLColor(g_todayClosed + g_floating));
   SetText("s_v3", Signed(g_floating), PLColor(g_floating));
   SetText("s_v4", DoubleToString(spread, _Digits),
           (InpMaxSpread > 0 && spread > InpMaxSpread) ? CLR_RED : CLR_TEXT);
   if(g_tradesToday > 0)
      SetText("s_v5", StringFormat("%d  (%d%% win)", g_tradesToday, (int)MathRound(100.0 * g_winsToday / g_tradesToday)),
              g_winsToday * 2 >= g_tradesToday ? CLR_GREEN : CLR_RED);
   else
      SetText("s_v5", "0", CLR_TEXT);

   // Profile button
   color modeClr = CLR_GREY;
   if(g_profile == PROFILE_SAFE)            modeClr = CLR_BLUE;
   else if(g_profile == PROFILE_AGGRESSIVE) modeClr = CLR_RED;
   ObjectSetString(0, P("b_mode"), OBJPROP_TEXT, "MODE: " + ProfileName(g_profile));
   ObjectSetInteger(0, P("b_mode"), OBJPROP_BGCOLOR, modeClr);
   ObjectSetInteger(0, P("b_mode"), OBJPROP_BORDER_COLOR, modeClr);

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

   // Footer
   SetText("f_msg", g_lastMsg, g_lastMsgColor);
   string cond;
   if(g_state == BOT_RUNNING)
     {
      string why = BlockReason();
      if(why == "" || why == "max open positions reached" || why == "cooldown after last trade")
         cond = StringFormat("Scanning: %ss move %s%s (need %s)", DoubleToString(g_p.windowMs / 1000.0, 1),
                             g_lastMove >= 0 ? "+" : "", DoubleToString(g_lastMove, 2), DoubleToString(g_lastNeed, 2));
      else
         cond = "Waiting: " + why;
     }
   else if(g_state == BOT_PAUSED)
      cond = "Paused after reconnect. Press START to resume.";
   else
      cond = "Bot is stopped. No new trades will be opened.";
   SetText("f_cond", cond, CLR_MUTED);

   ChartRedraw();
  }
//+------------------------------------------------------------------+
