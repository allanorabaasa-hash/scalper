//+------------------------------------------------------------------+
//|                                                 XAUScalper.mq5   |
//|        XAUUSD scalping Expert Advisor with on-chart control panel |
//+------------------------------------------------------------------+
#property copyright "Allan"
#property link      "https://github.com/allanorabaasa-hash/scalper"
#property version   "1.00"
#property description "XAUUSD scalper with an on-chart control panel."
#property description "Strategy logic lives in GetSignal() and is a placeholder for now."

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
input double        InpRiskPercent       = 0.5;           // Risk % per trade (if Lot mode = Risk %)

input group "Stops (price distance: 2.00 = a $2 move in gold)"
input double        InpStopLoss          = 2.00;          // Stop loss distance (required)
input double        InpTakeProfit        = 2.00;          // Take profit distance (0 = none)

input group "Filters and limits"
input double        InpMaxSpread         = 0.35;          // Max spread in price (0 = off)
input int           InpMaxPositions      = 1;             // Max open positions at once
input int           InpCooldownSec       = 60;            // Seconds between new trades
input int           InpSlippagePoints    = 30;            // Max slippage (points)
input double        InpMaxDailyLossPct   = 3.0;           // Daily loss limit % (0 = off)
input double        InpDailyTargetPct    = 0.0;           // Daily profit target % (0 = off)

input group "Session (PC local time)"
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
//  STRATEGY  (to be designed together)
//==================================================================
// Return +1 to BUY, -1 to SELL, 0 for no trade.
// Called on every tick while the bot is RUNNING and every safety check
// has passed (connection, session, spread, daily limit, max positions, cooldown).
int GetSignal()
  {
   return 0;   // placeholder: no automatic trades yet
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

   g_state = BOT_STOPPED;
   // Keep RUNNING state only across a timeframe switch or input change,
   // never across a terminal restart (power cut, reboot).
   string key = StateKey();
   if(GlobalVariableCheck(key))
     {
      g_state = (ENUM_BOT_STATE)(int)GlobalVariableGet(key);
      GlobalVariableDel(key);
     }

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
      GlobalVariableSet(StateKey(), (double)g_state);

   EventKillTimer();
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

void OnTick()
  {
   if(g_state != BOT_RUNNING)
      return;
   if(BlockReason() != "")
      return;

   int signal = GetSignal();
   if(signal != 0)
      OpenTrade(signal, "AUTO");
  }

void OnTimer()
  {
   CheckConnection();
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
      Msg("Bot STARTED, but the Algo Trading button in MT5 is OFF. Turn it on.", CLR_AMBER);
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
   if(CountOurPositions() >= InpMaxPositions)
      return "max open positions reached";
   if(TimeCurrent() - g_lastTradeTime < InpCooldownSec)
      return "cooldown after last trade";
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
      Msg(reason + ". Positions closed, trading locked until tomorrow.", reason == "Daily loss limit hit" ? CLR_RED : CLR_GREEN);
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
      return 0.0;   // never round UP past the risk limit
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
      Msg("Lot size would be below the broker minimum for this risk. Trade skipped.", CLR_AMBER);
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

   for(int i = 0; i < total; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      long posId = HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      bool ours  = false;
      for(int k = 0; k < idCount; k++)
         if(ourIds[k] == posId)
           {
            ours = true;
            break;
           }
      if(!ours)
         continue;

      double cost = HistoryDealGetDouble(deal, DEAL_COMMISSION) + HistoryDealGetDouble(deal, DEAL_FEE);
      if(HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
         g_todayClosed += cost;
      else
         g_todayClosed += HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP) + cost;
     }
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
   ObjectSetString(0, o, OBJPROP_TEXT, (text == "" ? " " : text));
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
   ObjectSetString(0, o, OBJPROP_TEXT, (text == "" ? " " : text));
   ObjectSetInteger(0, o, OBJPROP_COLOR, clr);
  }

void ShowObj(const string name, bool show)
  {
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

void BuildPanel()
  {
   // Frame and header
   MkRect("bg",     0, 0, PANEL_W, PANEL_H, CLR_BG, CLR_BORDER);
   MkRect("header", 0, 0, PANEL_W, 36, CLR_HEADER, CLR_BORDER);
   MkLabel("title", 14, 9, "XAU SCALPER", CLR_TEXT, 12, "Arial Bold");
   MkRect("pill", PANEL_W - 118, 8, 106, 20, CLR_GREY, CLR_GREY);
   MkLabel("pill_t", PANEL_W - 65, 18, "STOPPED", clrWhite, 8, "Arial Bold", ANCHOR_CENTER);
   MkLabel("info", 14, 44, " ", CLR_MUTED, 8);

   // Stats grid (2 rows x 3 columns)
   string titles[6] = {"BALANCE", "EQUITY", "TODAY P/L", "FLOATING P/L", "SPREAD", "SESSION"};
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
           + AccountInfoString(ACCOUNT_SERVER) + "   |   " + _Symbol + "   |   Magic "
           + IntegerToString(InpMagic), CLR_MUTED);

   // Stats
   double spread = CurrentSpread();
   bool   sOpen  = SessionOpen();
   string sess   = StringFormat("%02d:%02d-%02d:%02d", InpStartHour, InpStartMinute, InpEndHour, InpEndMinute);
   SetText("s_v0", Money(AccountInfoDouble(ACCOUNT_BALANCE)) + " " + currency, CLR_TEXT);
   SetText("s_v1", Money(AccountInfoDouble(ACCOUNT_EQUITY)) + " " + currency, CLR_TEXT);
   SetText("s_v2", Signed(g_todayClosed + g_floating), PLColor(g_todayClosed + g_floating));
   SetText("s_v3", Signed(g_floating), PLColor(g_floating));
   SetText("s_v4", DoubleToString(spread, _Digits),
           (InpMaxSpread > 0 && spread > InpMaxSpread) ? CLR_RED : CLR_TEXT);
   SetText("s_v5", (sOpen ? "OPEN " : "CLOSED ") + sess, sOpen ? CLR_GREEN : CLR_MUTED);

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
      cond = (why == "") ? "Scanning for signals..." : "Waiting: " + why;
     }
   else if(g_state == BOT_PAUSED)
      cond = "Paused after reconnect. Press START to resume.";
   else
      cond = "Bot is stopped. No new trades will be opened.";
   SetText("f_cond", cond, CLR_MUTED);

   ChartRedraw();
  }
//+------------------------------------------------------------------+
