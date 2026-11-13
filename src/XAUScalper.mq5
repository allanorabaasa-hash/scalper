//+------------------------------------------------------------------+
//|                                                 XAUScalper.mq5   |
//|   EMA 21/55 trend strategy (M5 by default) with on-chart panel    |
//+------------------------------------------------------------------+
#property copyright "Allan"
#property link      "https://github.com/allanorabaasa-hash/scalper"
#property version   "9.00"
#property description "Basket mode (default): baskets of same-direction positions in the EMA 21/55 direction, closed together; lot grows with the balance."
#property description "EMA trend mode: EMA 21/55 crossover with a daily trend filter, ATR stop and trailing stop, 1% risk."
#property description "Same rules as tools/backtest_ema_trend.py."

#include <XAUScalper\RiskManager.mqh>
#include <XAUScalper\Execution.mqh>
#include <XAUScalper\Journal.mqh>

//==================================================================
//  INPUTS
//==================================================================
enum ENUM_MODE
  {
   MODE_BASKET    = 0,   // Basket (compounding, closes together)
   MODE_EMA_TREND = 1    // EMA 21/55 trend (one trade, ATR stops)
  };

input group "Mode"
input ENUM_MODE       InpMode               = MODE_BASKET;   // Strategy

input group "Basket mode"
input int             InpBasketSize         = 10;            // Positions per basket (all the same direction)
input double          InpBalancePer001      = 200;           // Lot per position: 0.01 for every this much balance (compounds)
input double          InpMaxLotPerPos       = 5.0;           // Max lot per position
input double          InpBasketTPPct        = 4.0;           // Close the whole basket at this profit (% of balance)
input double          InpBasketSLPct        = 8.0;           // Close the whole basket at this loss (% of balance, 0 = off)
input double          InpMinMarginLevel     = 300;           // Do not add positions below this margin level %

input group "EMA trend mode (also gives the basket direction)"
input ENUM_TIMEFRAMES InpTF                 = PERIOD_M5;     // Trading timeframe (M5 or M1; H4 = original)
input int             InpEmaFast            = 21;            // Fast EMA
input int             InpEmaSlow            = 55;            // Slow EMA
input int             InpAtrPeriod          = 14;            // ATR period
input double          InpSlAtr              = 1.5;           // Initial stop (x ATR)
input double          InpTrailStartAtr      = 1.0;           // Start trailing after this profit (x ATR)
input double          InpTrailAtr           = 2.0;           // Trailing distance (x ATR)
input bool            InpDailyFilter        = true;          // Trade only with the daily trend (D1 EMA fast vs slow)
input double          InpMinAtrRatio        = 0.5;           // Skip if ATR < this x its 100-bar average (0 = off)

input group "Risk"
input double          InpRiskPct            = 1.0;           // Risk per trade (% of equity); skip if the min lot risks more
input double          InpEmergencyMarginLevel = 100;         // Emergency: close all below this margin level % (0 = off)
input bool            InpAllowReal          = false;         // Allow trading on a REAL account
input bool            InpAutoStart          = true;          // Start/resume automatically whenever connected (STOP is remembered)

input group "General"
input long            InpMagic              = 20261113;      // Magic number (unique per EA)
input string          InpTradeComment       = "XAUScalper";  // Order comment
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
#define ATR_AVG  100

CRiskManager   g_risk;
CExecution     g_exec;

ENUM_BOT_STATE g_state        = BOT_STOPPED;
bool           g_wasConnected = true;
string         g_lastMsg      = "Ready.";
color          g_lastMsgColor = clrSilver;
ulong          g_rowTicket[MAX_ROWS];
bool           g_collapsed    = false;

int            g_hFast = INVALID_HANDLE, g_hSlow = INVALID_HANDLE, g_hAtr = INVALID_HANDLE;
int            g_hDFast = INVALID_HANDLE, g_hDSlow = INVALID_HANDLE;
datetime       g_lastBar      = 0;
string         g_block        = "";   // why the bot cannot trade right now
string         g_lastSignal   = "none yet";
int            g_dir          = 0;    // basket direction from the last closed bar (+1 buy, -1 sell, 0 wait)
double         g_basketBase   = 0;    // balance when the current basket opened
int            g_basketDir    = 0;
int            g_basketOpened = 0;
int            g_baskets = 0, g_basketWins = 0;
bool           g_newBarForBasket = false;  // a new basket may start only on a fresh bar

// latest closed-bar values (panel)
double         g_fast = 0, g_slow = 0, g_atr = 0, g_atrAvg = 0;
int            g_dayTrend = 0;

long           g_reasonPos[];         // positions closed by the bot, and why (journal)
string         g_reasonText[];
long           g_riskPos[];           // risk money per position (journal R multiple)
double         g_riskMoney[];

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
string TFName(const ENUM_TIMEFRAMES tf) { return StringSubstr(EnumToString(tf), 7); }

bool IsRealAccount()
  {
   return !MQLInfoInteger(MQL_TESTER) && AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL;
  }

// Call after PositionGetTicket / PositionSelect.
bool IsOurs()
  {
   return PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic;
  }

// Our open position on this symbol (0 = none). Selects it.
ulong OurPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t != 0 && IsOurs())
         return t;
     }
   return 0;
  }

int CountOurs()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetTicket(i) != 0 && IsOurs())
         n++;
   return n;
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

double TakeRiskMoney(const long position)
  {
   for(int i = ArraySize(g_riskPos) - 1; i >= 0; i--)
      if(g_riskPos[i] == position)
        {
         double r = g_riskMoney[i];
         ArrayRemove(g_riskPos, i, 1);
         ArrayRemove(g_riskMoney, i, 1);
         return r;
        }
   return 0;
  }

// One value of an indicator buffer at a bar shift. false when not ready.
bool Value(const int handle, const int shift, double &v)
  {
   double b[];
   if(CopyBuffer(handle, 0, shift, 1, b) != 1)
      return false;
   v = b[0];
   return v != EMPTY_VALUE;
  }

//==================================================================
//  LIFECYCLE
//==================================================================
int OnInit()
  {
   ArrayInitialize(g_rowTicket, 0);
   ChartSetInteger(0, CHART_FOREGROUND, false);
   ChartSetInteger(0, CHART_SHOW_ONE_CLICK, false);

   if(InpEmaFast < 1 || InpEmaSlow <= InpEmaFast || InpAtrPeriod < 1 || InpSlAtr <= 0 || InpRiskPct <= 0)
     {
      Print("XAUScalper: check the strategy inputs (EMA slow must be above EMA fast, stop and risk above 0)");
      return INIT_PARAMETERS_INCORRECT;
     }
   g_hFast  = iMA(_Symbol, InpTF, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hSlow  = iMA(_Symbol, InpTF, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hAtr   = iATR(_Symbol, InpTF, InpAtrPeriod);
   g_hDFast = iMA(_Symbol, PERIOD_D1, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hDSlow = iMA(_Symbol, PERIOD_D1, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hFast == INVALID_HANDLE || g_hSlow == INVALID_HANDLE || g_hAtr == INVALID_HANDLE
      || g_hDFast == INVALID_HANDLE || g_hDSlow == INVALID_HANDLE)
     {
      Print("XAUScalper: could not create the indicators");
      return INIT_FAILED;
     }

   g_exec.Init(_Symbol, InpMagic, InpSlippagePoints);
   JournalInit(InpJournal);

   RiskConfig cfg;
   cfg.magic = InpMagic;  cfg.riskPct = InpRiskPct;  cfg.minLotMaxRiskPct = 0;  cfg.maxDailyLossPct = 0;
   cfg.dailyTargetPct = 0;  cfg.maxConsecLosses = 0;  cfg.maxPositions = (InpMode == MODE_BASKET) ? MathMax(1, InpBasketSize) : 1;  cfg.maxDailyTrades = 0;
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
   IndicatorRelease(g_hFast);  IndicatorRelease(g_hSlow);  IndicatorRelease(g_hAtr);
   IndicatorRelease(g_hDFast); IndicatorRelease(g_hDSlow);
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
   OnNewBar();
   if(InpMode == MODE_BASKET)
      Basket();
  }

void OnTimer()
  {
   CheckConnection();
   CheckAutoStart();
   OnNewBar();
   if(InpMode == MODE_BASKET)
      Basket();
   if(g_risk.Update())
      ApplyEmergency();
   if(!MQLInfoInteger(MQL_TESTER))
      UpdatePanel();
  }

//==================================================================
//  STRATEGY
//==================================================================
// Runs once per new bar of InpTF, on the bar that just closed (shift 1).
void OnNewBar()
  {
   datetime bar = iTime(_Symbol, InpTF, 0);
   if(bar == 0 || bar == g_lastBar)
      return;

   // closed-bar values; retry on the next tick until the indicators are ready
   double f1, f2, s1, s2, a1;
   if(!Value(g_hFast, 1, f1) || !Value(g_hFast, 2, f2) || !Value(g_hSlow, 1, s1) || !Value(g_hSlow, 2, s2)
      || !Value(g_hAtr, 1, a1))
      return;
   double atrs[];
   if(CopyBuffer(g_hAtr, 0, 1, ATR_AVG, atrs) != ATR_AVG)
      return;
   double sum = 0;
   for(int i = 0; i < ATR_AVG; i++)
      sum += atrs[i];
   g_lastBar = bar;

   double c1 = iClose(_Symbol, InpTF, 1);
   g_fast = f1;  g_slow = s1;  g_atr = a1;  g_atrAvg = sum / ATR_AVG;

   // daily trend from the last COMPLETED daily candle
   g_dayTrend = 0;
   double df, ds;
   if(iBars(_Symbol, PERIOD_D1) > InpEmaSlow + 1 && Value(g_hDFast, 1, df) && Value(g_hDSlow, 1, ds))
      g_dayTrend = (df > ds) ? 1 : (df < ds ? -1 : 0);

   // basket direction: EMA fast above slow and the close above fast = buy (mirror for sell)
   g_dir = (f1 > s1 && c1 > f1) ? 1 : ((f1 < s1 && c1 < f1) ? -1 : 0);
   if(InpMode == MODE_BASKET)
     {
      g_newBarForBasket = true;
      return;
     }

   bool longSig  = f1 > s1 && f2 <= s2 && c1 > f1 && c1 > s1;
   bool shortSig = f1 < s1 && f2 >= s2 && c1 < f1 && c1 < s1;
   int  sig = longSig ? 1 : (shortSig ? -1 : 0);

   // 1. trailing stop of the open position (works also when STOPPED)
   ulong pos = OurPosition();
   if(pos != 0)
      Trail(pos);

   // 2. opposite signal closes the open position (also when STOPPED: it is an exit rule)
   if(sig != 0 && pos != 0 && PositionSelectByTicket(pos))
     {
      int dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      if(dir == -sig)
        {
         string err;
         NoteCloseReason(pos, "opposite signal");
         if(g_exec.Close(pos, err))
           {
            Msg("Closed on the opposite signal.", CLR_MUTED);
            pos = 0;
           }
         else
            Msg(err, CLR_RED);
        }
     }

   if(sig == 0)
      return;
   string side = sig > 0 ? "BUY" : "SELL";
   string when = TimeToString(iTime(_Symbol, InpTF, 1) + PeriodSeconds(InpTF), TIME_MINUTES);

   // 3. new entry
   string skip = "";
   if(g_state != BOT_RUNNING)
      skip = "bot stopped";
   else if(pos != 0)
      skip = "position already open";
   else if(InpDailyFilter && g_dayTrend != sig)
      skip = g_dayTrend == 0 ? "no daily trend" : "against the daily trend";
   else if(InpMinAtrRatio > 0 && a1 < InpMinAtrRatio * g_atrAvg)
      skip = StringFormat("ATR extremely low (%.2f < %.2f)", a1, InpMinAtrRatio * g_atrAvg);
   else
     {
      string block = PlatformBlockReason();
      string risk  = g_risk.CanOpen();
      if(block != "")
         skip = block;
      else if(risk != "")
         skip = risk;
     }
   if(skip != "")
     {
      g_lastSignal = StringFormat("%s %s skipped: %s", side, when, skip);
      Msg("Signal " + g_lastSignal, CLR_AMBER);
      return;
     }

   double slDist = InpSlAtr * a1;
   string reason;
   double riskPct = 0;
   double lots = g_risk.SizeTrade(sig, slDist, reason, riskPct);
   if(lots <= 0)
     {
      g_lastSignal = StringFormat("%s %s skipped: %s", side, when, reason);
      Msg("Signal " + g_lastSignal, CLR_AMBER);
      return;
     }
   string err;
   double fill = 0;
   MqlTick tk;
   SymbolInfoTick(_Symbol, tk);
   ulong ticket = g_exec.Open(sig, lots, slDist, 0, InpTradeComment, err, fill);
   if(ticket == 0)
     {
      g_lastSignal = StringFormat("%s %s failed: %s", side, when, err);
      Msg("Signal " + g_lastSignal, CLR_RED);
      return;
     }
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * riskPct / 100.0;
   int n = ArraySize(g_riskPos);
   ArrayResize(g_riskPos, n + 1);
   ArrayResize(g_riskMoney, n + 1);
   g_riskPos[n] = (long)ticket;
   g_riskMoney[n] = riskMoney;
   g_lastSignal = StringFormat("%s %s taken: %.2f lot, stop %.2f away", side, when, lots, slDist);
   Msg(StringFormat("%s %.2f lot at %s, stop %.2f (%.2f%% risk)", side, lots, DoubleToString(fill, _Digits),
                    slDist, riskPct), CLR_GREEN);
   JournalOpen((long)ticket, sig, "EMA21_55", g_dayTrend > 0 ? "D1 up" : "D1 down", lots, fill, tk.ask - tk.bid,
               slDist, 0, a1, riskMoney, riskPct, (tk.ask - tk.bid) * lots * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE), "");
  }

// Once the best price since entry is 1 ATR in profit, the stop follows it at 2 ATR.
// ATR = the ATR of the signal candle. Uses closed bars only; the stop never moves back.
void Trail(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return;
   int      dir      = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
   double   entry    = PositionGetDouble(POSITION_PRICE_OPEN);
   datetime opened   = (datetime)PositionGetInteger(POSITION_TIME);
   int      shift    = iBarShift(_Symbol, InpTF, opened, false);   // entry bar
   if(shift < 1)
      return;                                                       // entry bar not closed yet
   double atr;
   if(!Value(g_hAtr, shift + 1, atr) || atr <= 0)                  // signal candle
      return;
   double best;
   if(dir > 0)
      best = iHigh(_Symbol, InpTF, iHighest(_Symbol, InpTF, MODE_HIGH, shift, 1));
   else
     {
      MqlTick tk;
      double spread = SymbolInfoTick(_Symbol, tk) ? tk.ask - tk.bid : 0.0;
      best = iLow(_Symbol, InpTF, iLowest(_Symbol, InpTF, MODE_LOW, shift, 1)) + spread;
     }
   if(dir * (best - entry) < InpTrailStartAtr * atr)
      return;
   double newSL = best - dir * InpTrailAtr * atr;
   string err;
   if(g_exec.MoveStop(ticket, newSL, err))
      Msg(StringFormat("Trailing stop moved to %s", DoubleToString(newSL, _Digits)), CLR_MUTED);
   else if(err != "")
      Msg(err, CLR_RED);
  }

//==================================================================
//  BASKET MODE
//==================================================================
double BasketLot()
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), InpMaxLotPerPos);
   double lots = 0.01 * MathFloor(AccountInfoDouble(ACCOUNT_BALANCE) / MathMax(InpBalancePer001, 1));
   if(step > 0)
      lots = MathFloor(lots / step + 1e-9) * step;
   return NormalizeDouble(MathMax(vmin, MathMin(lots, vmax)), 2);
  }

// Net P/L (profit + swap) of all our open positions.
double BasketPL(int &count)
  {
   double pl = 0;
   count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0 || !IsOurs())
         continue;
      pl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      count++;
     }
   return pl;
  }

// 1. close the whole basket at the profit target or the loss limit (also when STOPPED)
// 2. when running, flat and on a fresh bar with a direction: open a new basket
void Basket()
  {
   int n;
   double pl = BasketPL(n);
   if(n > 0)
     {
      if(g_basketBase <= 0)
         g_basketBase = AccountInfoDouble(ACCOUNT_BALANCE);   // after a restart
      double tp = g_basketBase * InpBasketTPPct / 100.0;
      double sl = g_basketBase * InpBasketSLPct / 100.0;
      if(InpBasketTPPct > 0 && pl >= tp)
        {
         CloseAll("basket take profit");
         g_basketWins++;
         Msg(StringFormat("Basket closed in profit: %+.2f", pl), CLR_GREEN);
         g_basketBase = 0;
         return;
        }
      if(InpBasketSLPct > 0 && pl <= -sl)
        {
         CloseAll("basket stop");
         Msg(StringFormat("Basket closed at the loss limit: %+.2f", pl), CLR_RED);
         g_basketBase = 0;
         return;
        }
     }

   // keep filling a basket that is not complete (e.g. an order was rejected)
   bool filling = (n > 0 && g_basketOpened > 0 && g_basketOpened < InpBasketSize);
   if(g_state != BOT_RUNNING || g_risk.Locked())
      return;
   if(n > 0 && !filling)
      return;
   if(n == 0)
     {
      g_basketOpened = 0;
      if(!g_newBarForBasket || g_dir == 0)
         return;
     }
   string block = PlatformBlockReason();
   if(block != "")
      return;

   if(n == 0)
     {
      g_newBarForBasket = false;
      g_basketDir  = g_dir;
      g_basketBase = AccountInfoDouble(ACCOUNT_BALANCE);
      g_baskets++;
     }
   double lots = BasketLot();
   while(g_basketOpened < InpBasketSize)
     {
      if(AccountInfoDouble(ACCOUNT_MARGIN) > 0 && AccountInfoDouble(ACCOUNT_MARGIN_LEVEL) < InpMinMarginLevel)
        {
         g_basketOpened = InpBasketSize;    // basket stays smaller: margin guard
         Msg(StringFormat("Margin level below %.0f%%: basket kept at %d positions", InpMinMarginLevel, CountOurs()),
             CLR_AMBER);
         break;
        }
      double margin = 0;
      MqlTick tk;
      SymbolInfoTick(_Symbol, tk);
      if(OrderCalcMargin(g_basketDir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots,
                         g_basketDir > 0 ? tk.ask : tk.bid, margin)
         && margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
        {
         g_basketOpened = InpBasketSize;
         Msg("Not enough free margin: basket kept smaller.", CLR_AMBER);
         break;
        }
      string err;
      ulong pos = g_exec.OpenNoStop(g_basketDir, lots, InpTradeComment + ":B" + IntegerToString(g_baskets), err);
      if(pos == 0)
        {
         Msg("Order failed: " + err, CLR_RED);
         return;     // retry on the next timer tick
        }
      JournalOpen((long)pos, g_basketDir, "BASKET", "basket " + IntegerToString(g_baskets), lots,
                  g_basketDir > 0 ? tk.ask : tk.bid, tk.ask - tk.bid, 0, 0, g_atr, 0, 0, 0, "");
      g_basketOpened++;
     }
   g_lastSignal = StringFormat("basket %d: %s %d x %.2f lot", g_baskets, g_basketDir > 0 ? "BUY" : "SELL",
                               CountOurs(), lots);
   Msg("Opened " + g_lastSignal, CLR_BLUE);
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
      Msg("Connection lost. Stops stay on the broker's server.", CLR_RED);
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
      Msg("Bot STARTED: waiting for the next EMA crossover.", CLR_GREEN);
   else
      Msg("STARTED, but Algo Trading is OFF in MT5.", CLR_AMBER);
  }

void DoStop()
  {
   g_state = BOT_STOPPED;
   GlobalVariableSet(ManualStopKey(), 1);
   Msg("STOPPED: no new trades. The open trade keeps its stop and trailing.", CLR_AMBER);
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
      why = (reason == DEAL_REASON_SL) ? "stop loss / trailing stop" : (reason == DEAL_REASON_SO ? "stop out" : "other");
   double risk = TakeRiskMoney(posId);
   double hold = (inMsc > 0 && outMsc >= inMsc) ? (outMsc - inMsc) / 1000.0 : 0.0;
   JournalClose(posId, type == DEAL_TYPE_SELL ? "BUY" : "SELL", InpMode == MODE_BASKET ? "BASKET" : "EMA21_55", lots, price, profit, comm, hold,
                risk > 0 ? profit / risk : 0, risk > 0, why);
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
      case 3: return 200;
      case 4: return 290;
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
   MkLabel("mode", 150, 12, InpMode == MODE_BASKET ? "BASKET MODE (" + TFName(InpTF) + " EMA direction)"
           : "EMA 21/55 TREND (" + TFName(InpTF) + ")", CLR_BLUE, 8, "Arial Bold");
   MkRect("pill", PANEL_W - 118, 8, 106, 20, CLR_GREY, CLR_GREY);
   MkLabel("pill_t", PANEL_W - 65, 18, "STOPPED", clrWhite, 8, "Arial Bold", ANCHOR_CENTER);
   MkButton("b_min", PANEL_W - 146, 8, 22, 20, "-", CLR_GREY, clrWhite, 10);
   MkLabel("info", 14, 44, " ", CLR_MUTED, 8);

   string titles[6] = {"BALANCE", "EQUITY", "DAY P/L (CLOSED + OPEN)", "DAILY TREND (D1 EMA)", "ATR / 100-BAR AVG", "SPREAD"};
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

   MkLabel("t_title", 14, 226, "OPEN POSITIONS (0)", CLR_MUTED, 7, "Arial Bold");
   string heads[6] = {"TICKET", "TYPE", "LOTS", "OPEN", "STOP", "P/L"};
   for(int c = 0; c < 6; c++)
      MkLabel("h" + IntegerToString(c), ColX(c), ROW_Y0 + 6, heads[c], CLR_MUTED, 7, "Arial",
              c == 5 ? ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER);
   MkRect("sep2", 12, ROW_Y0 + 20, PANEL_W - 24, 1, CLR_BORDER, CLR_BORDER);
   for(int r = 0; r < MAX_ROWS; r++)
     {
      int y = ROW_Y0 + 24 + r * ROW_H;
      if(r % 2 == 1)
         MkRect("rbg" + IntegerToString(r), 12, y - 3, PANEL_W - 24, ROW_H, CLR_ROWALT, CLR_ROWALT);
      for(int c = 0; c < 6; c++)
         MkLabel(RowCell(r, c), ColX(c), y, " ", CLR_TEXT, 9, "Arial", c == 5 ? ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER);
      MkButton("rx" + IntegerToString(r), 500, y - 2, 26, 18, "X", CLR_RED, clrWhite, 8);
      ShowObj("rx" + IntegerToString(r), false);
     }
   MkLabel("t_empty", PANEL_W / 2, ROW_Y0 + 60, "No open positions", CLR_MUTED, 9, "Arial", ANCHOR_UPPER);

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
   SetText("s_v0", DoubleToString(bal, 2) + " " + cur, CLR_TEXT);
   SetText("s_v1", DoubleToString(eq, 2) + " " + cur, CLR_TEXT);
   SetText("s_v2", Signed(g_risk.DayPL()), PLColor(g_risk.DayPL()));
   if(!InpDailyFilter)
      SetText("s_v3", "filter off", CLR_MUTED);
   else
      SetText("s_v3", g_dayTrend > 0 ? "UP (buys only)" : (g_dayTrend < 0 ? "DOWN (sells only)" : "none"),
              g_dayTrend > 0 ? CLR_GREEN : (g_dayTrend < 0 ? CLR_RED : CLR_MUTED));
   bool atrLow = InpMinAtrRatio > 0 && g_atr < InpMinAtrRatio * g_atrAvg;
   SetText("s_v4", DoubleToString(g_atr, 2) + " / " + DoubleToString(g_atrAvg, 2), atrLow ? CLR_AMBER : CLR_TEXT);
   SetText("s_v5", DoubleToString(spread, _Digits), CLR_TEXT);

   if(InpMode == MODE_BASKET)
      SetText("sig1", StringFormat("Direction %s   Lot %.2f x %d   EMA%d %s  EMA%d %s",
                                   g_dir > 0 ? "BUY" : (g_dir < 0 ? "SELL" : "WAIT"), BasketLot(), InpBasketSize,
                                   InpEmaFast, DoubleToString(g_fast, 1), InpEmaSlow, DoubleToString(g_slow, 1)),
              g_dir > 0 ? CLR_GREEN : (g_dir < 0 ? CLR_RED : CLR_MUTED));
   else
   SetText("sig1", StringFormat("%s  EMA%d %s  EMA%d %s  (%s)", TFName(InpTF), InpEmaFast, DoubleToString(g_fast, _Digits),
                                InpEmaSlow, DoubleToString(g_slow, _Digits), g_fast > g_slow ? "fast above" : "fast below"),
           CLR_TEXT);
   if(InpMode == MODE_BASKET)
     {
      int n;
      double pl = BasketPL(n);
      double base = g_basketBase > 0 ? g_basketBase : bal;
      SetText("sig2", StringFormat("Basket %d (%d won): %d open, P/L %+.2f  TP +%.2f  SL -%.2f", g_baskets, g_basketWins,
                                   n, pl, base * InpBasketTPPct / 100.0, base * InpBasketSLPct / 100.0), PLColor(pl));
     }
   else
      SetText("sig2", "Last signal: " + g_lastSignal, CLR_MUTED);

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
      double sl    = PositionGetDouble(POSITION_SL);
      SetText(RowCell(row, 0), IntegerToString((long)ticket), CLR_TEXT);
      SetText(RowCell(row, 1), isBuy ? "BUY" : "SELL", isBuy ? CLR_GREEN : CLR_RED);
      SetText(RowCell(row, 2), DoubleToString(PositionGetDouble(POSITION_VOLUME), 2), CLR_TEXT);
      SetText(RowCell(row, 3), DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), _Digits), CLR_TEXT);
      SetText(RowCell(row, 4), sl > 0 ? DoubleToString(sl, _Digits) : "none", sl > 0 ? CLR_MUTED : CLR_RED);
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
   SetText("t_title", "OPEN POSITIONS (" + IntegerToString(total) + ")", CLR_MUTED);
   ShowObj("t_empty", total == 0);

   SetText("f_msg", g_lastMsg, g_lastMsgColor);
   string cond;
   color  cc = CLR_MUTED;
   string block = PlatformBlockReason();
   if(g_risk.Locked())
     {
      cond = "Locked: " + g_risk.LockText();
      cc = CLR_RED;
     }
   else if(g_state == BOT_RUNNING && block != "")
     {
      cond = "Cannot trade: " + block;
      cc = CLR_AMBER;
     }
   else if(InpMode == MODE_BASKET && g_state == BOT_RUNNING && total > 0)
      cond = "Basket open: closes together at the profit target or the loss limit.";
   else if(InpMode == MODE_BASKET && g_state == BOT_RUNNING)
      cond = "Running: next basket on the next " + TFName(InpTF) + " bar with a direction.";
   else if(g_state == BOT_RUNNING && total > 0)
      cond = "In a trade: exit by stop, trailing stop or opposite signal.";
   else if(g_state == BOT_RUNNING)
      cond = "Running: waiting for an EMA crossover on " + TFName(InpTF) + ".";
   else if(InpAutoStart && ManualStop())
      cond = "Stopped by you: press START to resume.";
   else
      cond = "Stopped.";
   SetText("f_cond", cond, cc);
   ChartRedraw();
  }
//+------------------------------------------------------------------+
