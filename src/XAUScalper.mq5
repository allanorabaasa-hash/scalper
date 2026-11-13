//+------------------------------------------------------------------+
//|                                                 XAUScalper.mq5   |
//|        XAUUSD grid / hedge wave EA with on-chart control panel    |
//+------------------------------------------------------------------+
#property copyright "Allan"
#property link      "https://github.com/allanorabaasa-hash/scalper"
#property version   "7.10"
#property description "Grid waves: fixed-lot buys and sells together, each closed at a small profit."
#property description "No stop losses. Runs on DEMO accounts and in the Strategy Tester only."

#include <XAUScalper\RiskManager.mqh>
#include <XAUScalper\Execution.mqh>
#include <XAUScalper\Journal.mqh>

//==================================================================
//  INPUTS
//==================================================================
input group "Grid waves"
input double        InpLot                  = 0.01;          // Lot per position (fixed)
input string        InpWaves                = "10,15,20";    // Positions per wave (half buys, half sells); the last size repeats
input double        InpTakeProfit           = 0.50;          // Close a position when its profit reaches this (account currency)
input double        InpNextWavePct          = 50;            // Open the next wave when this % of the current wave has closed in profit
                                                             // The wave size steps up (10 -> 15 -> 20) only when the previous wave was in profit
input int           InpMaxOpen              = 60;            // Max positions open at once
input double        InpMinMarginLevel       = 300;           // No new positions below this margin level % (0 = off)
input int           InpMaxHoldMin           = 0;             // Close any position older than N minutes (0 = off: losers wait)
input double        InpBasketStopPct        = 0;             // Close ALL positions if equity is this % below balance (0 = off)
input double        InpMaxSpreadCostPct     = 60;            // No new positions when the spread costs more than this % of the take profit (0 = off)

input group "Account safety"
input double        InpEmergencyMarginLevel = 100;           // Emergency: close all if margin level falls below this % (0 = off)
input bool          InpAutoStart            = true;          // Start/resume automatically whenever connected (STOP is remembered)

input group "General"
input long          InpMagic                = 20261112;      // Magic number (unique per EA)
input string        InpTradeComment         = "XAUScalper";  // Order comment prefix
input int           InpSlippagePoints       = 30;            // Max slippage (points)
input bool          InpJournal              = true;          // Trade journal (Common/Files/XAUScalper_trades.csv)
input int           InpPanelX               = 10;            // Panel X offset
input int           InpPanelY               = 30;            // Panel Y offset

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

int            g_sizes[];             // wave sizes from InpWaves
int            g_waveIdx      = -1;   // index into g_sizes
int            g_wave         = 0;    // wave number (order comment tag)
int            g_opened       = 0;    // positions opened in the current wave
int            g_wins         = 0;    // positions closed in profit (this session)
datetime       g_lastOpen     = 0;
string         g_status       = "not started";
string         g_block        = "";   // why no new positions right now ("" = none)
bool           g_started      = false;// first wave of this session opened
double         g_waveRealized = 0;    // closed P/L of the current wave
double         g_lastWaveResult = 0;

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

//--- Panel geometry
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
string WaveKey()       { return "XS_wave_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + IntegerToString(InpMagic) + "_" + _Symbol; }

bool IsRealAccount()
  {
   return !MQLInfoInteger(MQL_TESTER) && AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL;
  }

// Call after PositionGetTicket / PositionSelect.
bool IsOurs()
  {
   return PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic;
  }

// Open positions of this EA; wave > 0 counts only that wave.
int CountPositions(const int wave, int &buys, int &sells)
  {
   buys = 0;
   sells = 0;
   string tag = ":GRID:" + IntegerToString(wave);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0 || !IsOurs())
         continue;
      if(wave > 0)
        {
         string c = PositionGetString(POSITION_COMMENT);
         int p = StringFind(c, tag);
         // exact wave match: the tag must end the comment
         if(p < 0 || p + StringLen(tag) != StringLen(c))
            continue;
        }
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         buys++;
      else
         sells++;
     }
   return buys + sells;
  }

void NoteCloseReason(const ulong ticket, const string why)
  {
   int n = ArraySize(g_reasonPos);
   if(n >= 500)
     {
      ArrayRemove(g_reasonPos, 0, 250);
      ArrayRemove(g_reasonText, 0, 250);
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

void ParseWaves()
  {
   string parts[];
   int n = StringSplit(InpWaves, ',', parts);
   ArrayResize(g_sizes, 0);
   for(int i = 0; i < n; i++)
     {
      string t = parts[i];
      StringTrimLeft(t);
      StringTrimRight(t);
      int v = (int)StringToInteger(t);
      if(v > 0)
        {
         int k = ArraySize(g_sizes);
         ArrayResize(g_sizes, k + 1);
         g_sizes[k] = v;
        }
     }
   if(ArraySize(g_sizes) == 0)
     {
      ArrayResize(g_sizes, 1);
      g_sizes[0] = 10;
     }
  }

//==================================================================
//  LIFECYCLE
//==================================================================
int OnInit()
  {
   ArrayInitialize(g_rowTicket, 0);
   ChartSetInteger(0, CHART_FOREGROUND, false);
   ChartSetInteger(0, CHART_SHOW_ONE_CLICK, false);   // MT5 one-click box would cover the panel

   if(InpLot <= 0 || InpTakeProfit <= 0 || InpMaxOpen < 1)
     {
      Print("XAUScalper: lot, take profit and max open must be above 0");
      return INIT_PARAMETERS_INCORRECT;
     }
   ParseWaves();
   g_exec.Init(_Symbol, InpMagic, InpSlippagePoints);
   JournalInit(InpJournal);

   // Risk manager: day statistics and the margin-level emergency only.
   RiskConfig cfg;
   cfg.magic = InpMagic;  cfg.riskPct = 1.0;  cfg.minLotMaxRiskPct = 0;  cfg.maxDailyLossPct = 0;
   cfg.dailyTargetPct = 0;  cfg.maxConsecLosses = 0;  cfg.maxPositions = InpMaxOpen;  cfg.maxDailyTrades = 0;
   cfg.minSecBetweenTrades = 0;  cfg.cooldownAfterLossMin = 0;  cfg.emergencyDDPct = 0;
   cfg.emergencyMarginLevel = InpEmergencyMarginLevel;  cfg.marginBufferPct = 0;
   cfg.emergencyPolicy = EMERGENCY_CLOSE_ALL;
   g_risk.Init(_Symbol, cfg);

   g_state = BOT_STOPPED;
   string key = StateKey();
   if(GlobalVariableCheck(key))            // timeframe switch / input change: keep the state
     {
      g_state = (ENUM_BOT_STATE)(int)GlobalVariableGet(key);
      GlobalVariableDel(key);
     }
   if(MQLInfoInteger(MQL_TESTER))
      g_state = BOT_RUNNING;
   // continue the wave numbering and size after a restart (new wave numbers never mix with old positions)
   if(!MQLInfoInteger(MQL_TESTER) && GlobalVariableCheck(WaveKey()))
     {
      g_wave    = (int)GlobalVariableGet(WaveKey());
      g_waveIdx = (int)MathMin(GlobalVariableGet(WaveKey() + "_idx"), ArraySize(g_sizes) - 1);
     }
   g_wasConnected = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);

   if(IsRealAccount())
      Msg("REAL account: grid mode is disabled (no stop losses). Use a demo account.", CLR_RED);

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
   Grid(g_state == BOT_RUNNING);
  }

void OnTimer()
  {
   CheckConnection();
   CheckAutoStart();
   Grid(g_state == BOT_RUNNING);
   if(g_risk.Update())
      ApplyEmergency();
   if(!MQLInfoInteger(MQL_TESTER))
      UpdatePanel();
  }

//==================================================================
//  GRID ENGINE
//==================================================================
// 1. close every position whose profit reached InpTakeProfit (always, even when stopped)
// 2. optional max holding time and basket stop
// 3. when running: start the next wave once InpNextWavePct of the current wave
//    has closed in profit, and fill the wave with alternating buys and sells
void Grid(const bool allowNew)
  {
   datetime now = TimeCurrent();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !IsOurs())
         continue;
      double net = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double ageMin = (double)(now - (datetime)PositionGetInteger(POSITION_TIME)) / 60.0;
      string why = "";
      if(net >= InpTakeProfit)
         why = "take profit";
      else if(InpMaxHoldMin > 0 && ageMin >= InpMaxHoldMin)
         why = "max hold";
      if(why == "")
         continue;
      string err;
      NoteCloseReason(t, why);
      if(g_exec.Close(t, err))
        {
         if(why == "take profit")
            g_wins++;
        }
      else
         Print(err);
     }

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(InpBasketStopPct > 0 && bal > 0 && (bal - eq) / bal * 100.0 >= InpBasketStopPct)
     {
      CloseAll("basket stop");
      g_state = BOT_STOPPED;
      GlobalVariableSet(ManualStopKey(), 1);
      Msg(StringFormat("BASKET STOP: equity %.1f%% below balance. All closed, bot stopped.",
                       (bal - eq) / bal * 100.0), CLR_RED);
      return;
     }

   int b, s;
   int waveSize = (g_waveIdx >= 0) ? g_sizes[g_waveIdx] : 0;
   int inWave   = (g_started && g_wave > 0) ? CountPositions(g_wave, b, s) : 0;
   int closed   = g_opened - inWave;
   int nOpen    = CountPositions(0, b, s);
   g_status = StringFormat("Wave %d: %d/%d open   Total %d (B%d / S%d)   Wins %d", g_wave, inWave, waveSize,
                           nOpen, b, s, g_wins);

   if(!allowNew)
     {
      g_block = "";
      return;
     }
   if(now == g_lastOpen)
      return;
   g_lastOpen = now;

   g_block = PlatformBlockReason();
   if(g_block != "")
      return;
   if(g_risk.Locked())
     {
      g_block = g_risk.LockText();
      return;
     }
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
     {
      g_block = "no price for " + _Symbol;
      return;
     }
   double cost = SpreadCost();
   if(InpMaxSpreadCostPct > 0 && cost > InpTakeProfit * InpMaxSpreadCostPct / 100.0)
     {
      g_block = StringFormat("spread cost %.2f above limit %.2f", cost,
                             InpTakeProfit * InpMaxSpreadCostPct / 100.0);
      return;
     }

   bool nextWave = !g_started || (g_opened >= waveSize && closed * 100.0 >= InpNextWavePct * waveSize);
   if(nextWave)
     {
      string why;
      if(!g_started)
        {
         g_waveIdx = MathMax(g_waveIdx, 0);
         why = (g_wave == 0) ? "first wave" : "restart: same size as before";
        }
      else
        {
         double result = g_waveRealized + WaveFloating(g_wave);
         g_lastWaveResult = result;
         if(result > 0)
           {
            g_waveIdx = MathMin(g_waveIdx + 1, ArraySize(g_sizes) - 1);
            why = StringFormat("wave %d made %+.2f: size up", g_wave, result);
           }
         else
            why = StringFormat("wave %d made %+.2f: same size", g_wave, result);
        }
      g_started = true;
      g_wave++;
      g_opened = 0;
      g_waveRealized = 0;
      waveSize = g_sizes[g_waveIdx];
      GlobalVariableSet(WaveKey(), g_wave);
      GlobalVariableSet(WaveKey() + "_idx", g_waveIdx);
      Msg(StringFormat("Wave %d: %d positions (%s)", g_wave, waveSize, why), CLR_BLUE);
     }

   while(g_opened < waveSize)
     {
      if(CountPositions(0, b, s) >= InpMaxOpen)
        {
         g_block = StringFormat("max %d open positions: waiting for closes", InpMaxOpen);
         return;
        }
      if(InpMinMarginLevel > 0 && AccountInfoDouble(ACCOUNT_MARGIN) > 0
         && AccountInfoDouble(ACCOUNT_MARGIN_LEVEL) < InpMinMarginLevel)
        {
         g_block = StringFormat("margin level below %.0f%%: no new positions", InpMinMarginLevel);
         return;
        }
      int dir = (g_opened % 2 == 0) ? 1 : -1;
      string err;
      MqlTick tk;
      SymbolInfoTick(_Symbol, tk);
      ulong pos = g_exec.OpenNoStop(dir, InpLot, InpTradeComment + ":GRID:" + IntegerToString(g_wave), err);
      if(pos == 0)
        {
         g_block = "order rejected: " + err;
         Msg("Order failed: " + err, CLR_RED);
         return;   // retry next second
        }
      JournalOpen((long)pos, dir, "GRID", "wave " + IntegerToString(g_wave), InpLot,
                  dir > 0 ? tk.ask : tk.bid, tk.ask - tk.bid, 0, 0, 0, 0, 0, 0, "");
      g_opened++;
     }
  }

// Money lost to the spread when one position of InpLot opens (account currency).
double SpreadCost()
  {
   MqlTick tick;
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(!SymbolInfoTick(_Symbol, tick) || ts <= 0)
      return 0;
   return (tick.ask - tick.bid) / ts * tv * InpLot;
  }

// Open profit of the positions of one wave.
double WaveFloating(const int wave)
  {
   double sum = 0;
   string tag = ":GRID:" + IntegerToString(wave);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0 || !IsOurs())
         continue;
      string c = PositionGetString(POSITION_COMMENT);
      int p = StringFind(c, tag);
      if(p < 0 || p + StringLen(tag) != StringLen(c))
         continue;
      sum += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   return sum;
  }

//==================================================================
//  CONTROLS
//==================================================================
// Platform permissions and the real-account block. "" = OK.
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
   if(IsRealAccount())
      return "REAL account: grid mode is demo-only";
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
      Msg("Connection lost. No new positions until it returns.", CLR_RED);
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
   Msg("STOPPED: no new positions. Open positions still close at the profit target.", CLR_AMBER);
  }

void DoCloseAll()
  {
   int b, s;
   int n = CountPositions(0, b, s);
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
   if(MessageBox("Emergency: close ALL positions, stop the bot and block new positions until the next trading day.\n\nContinue?",
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
   int closed = 0, b, s;
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
      if(CountPositions(0, b, s) == 0)
         break;
     }
   if(CountPositions(0, b, s) > 0)
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
   string inComment = "";
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0 || HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;
      if(HistoryDealGetInteger(d, DEAL_MAGIC) == InpMagic)
        {
         ours  = true;
         inMsc = HistoryDealGetInteger(d, DEAL_TIME_MSC);
         inComment = HistoryDealGetString(d, DEAL_COMMENT);
         double c = HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
         comm   += c;
         profit += c;
        }
     }
   if(!ours)
      return;
   string tag = ":GRID:" + IntegerToString(g_wave);
   int tp = StringFind(inComment, tag);
   if(g_wave > 0 && tp >= 0 && tp + StringLen(tag) == StringLen(inComment))
      g_waveRealized += profit;
   string why = TakeCloseReason(posId);
   if(why == "")
      why = (reason == DEAL_REASON_SO) ? "stop out" : "other";
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
   MkLabel("mode", 150, 12, "GRID WAVES (demo only)", CLR_BLUE, 8, "Arial Bold");
   MkRect("pill", PANEL_W - 118, 8, 106, 20, CLR_GREY, CLR_GREY);
   MkLabel("pill_t", PANEL_W - 65, 18, "STOPPED", clrWhite, 8, "Arial Bold", ANCHOR_CENTER);
   MkButton("b_min", PANEL_W - 146, 8, 22, 20, "-", CLR_GREY, clrWhite, 10);
   MkLabel("info", 14, 44, " ", CLR_MUTED, 8);

   string titles[6] = {"BALANCE", "EQUITY", "DAY P/L (CLOSED + OPEN)", "FLOATING P/L", "SPREAD (COST / POSITION)", "MARGIN LEVEL"};
   for(int i = 0; i < 6; i++)
     {
      int x = 14 + (i % 3) * 178;
      int y = 66 + (i / 3) * 40;
      MkLabel("s_t" + IntegerToString(i), x, y, titles[i], CLR_MUTED, 7);
      MkLabel("s_v" + IntegerToString(i), x, y + 13, "-", CLR_TEXT, 11, "Arial Bold");
     }
   MkLabel("grid1", 14, 146, " ", CLR_TEXT, 8, "Arial Bold");
   MkLabel("grid2", 14, 162, " ", CLR_MUTED, 8);

   MkRect("sep1", 12, 180, PANEL_W - 24, 1, CLR_BORDER, CLR_BORDER);
   MkButton("b_start", 12,  188, 110, 32, "START",     CLR_GREEN,   clrWhite, 10);
   MkButton("b_stop",  130, 188, 110, 32, "STOP",      CLR_RED,     clrWhite, 10);
   MkButton("b_close", 248, 188, 120, 32, "CLOSE ALL", CLR_GREY,    clrWhite, 9);
   MkButton("b_emerg", 376, 188, 152, 32, "EMERGENCY", CLR_DARKRED, clrWhite, 9);

   MkLabel("t_title", 14, 226, "OPEN POSITIONS (0)", CLR_MUTED, 7, "Arial Bold");
   string heads[6] = {"TICKET", "TYPE", "LOTS", "OPEN", "AGE", "P/L"};
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
   double ml = AccountInfoDouble(ACCOUNT_MARGIN) > 0 ? AccountInfoDouble(ACCOUNT_MARGIN_LEVEL) : 0.0;
   SetText("s_v0", DoubleToString(bal, 2) + " " + cur, CLR_TEXT);
   SetText("s_v1", DoubleToString(eq, 2) + " " + cur, CLR_TEXT);
   SetText("s_v2", Signed(g_risk.DayPL()), PLColor(g_risk.DayPL()));
   SetText("s_v3", Signed(eq - bal), PLColor(eq - bal));
   double cost = SpreadCost();
   SetText("s_v4", DoubleToString(spread, _Digits) + "  (" + DoubleToString(cost, 2) + ")",
           (InpMaxSpreadCostPct > 0 && cost > InpTakeProfit * InpMaxSpreadCostPct / 100.0) ? CLR_RED : CLR_TEXT);
   SetText("s_v5", ml > 0 ? DoubleToString(ml, 0) + "%" : "-", (ml > 0 && ml < InpMinMarginLevel) ? CLR_RED : CLR_TEXT);

   SetText("grid1", g_status, CLR_TEXT);
   if(g_started && g_wave > 1)
      SetText("grid2", StringFormat("This wave so far %+.2f    Previous wave %+.2f",
                                    g_waveRealized + WaveFloating(g_wave), g_lastWaveResult), CLR_MUTED);
   else
      SetText("grid2", StringFormat("Lot %.2f   Close at +%.2f   Waves %s   Max open %d", InpLot, InpTakeProfit,
                                    InpWaves, InpMaxOpen), CLR_MUTED);

   int row = 0, total = 0;
   datetime now = TimeCurrent();
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
      int    age   = (int)((now - (datetime)PositionGetInteger(POSITION_TIME)) / 60);
      SetText(RowCell(row, 0), IntegerToString((long)ticket), CLR_TEXT);
      SetText(RowCell(row, 1), isBuy ? "BUY" : "SELL", isBuy ? CLR_GREEN : CLR_RED);
      SetText(RowCell(row, 2), DoubleToString(PositionGetDouble(POSITION_VOLUME), 2), CLR_TEXT);
      SetText(RowCell(row, 3), DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), _Digits), CLR_TEXT);
      SetText(RowCell(row, 4), IntegerToString(age) + " min", CLR_MUTED);
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
   string tt = "OPEN POSITIONS (" + IntegerToString(total) + ")";
   if(total > MAX_ROWS)
      tt += "   showing first " + IntegerToString(MAX_ROWS);
   SetText("t_title", tt, CLR_MUTED);
   ShowObj("t_empty", total == 0);

   SetText("f_msg", g_lastMsg, g_lastMsgColor);
   string cond;
   if(g_risk.Locked())
      cond = "Locked: " + g_risk.LockText();
   else if(g_state == BOT_RUNNING && g_block != "")
      cond = "Not opening: " + g_block;
   else if(g_state == BOT_RUNNING)
      cond = "Running: opening waves, closing each position at +" + DoubleToString(InpTakeProfit, 2);
   else if(InpAutoStart && ManualStop())
      cond = "Stopped by you: press START to resume.";
   else
      cond = "Stopped.";
   SetText("f_cond", cond, (g_risk.Locked() || (g_state == BOT_RUNNING && g_block != "")) ? CLR_AMBER : CLR_MUTED);
   ChartRedraw();
  }
//+------------------------------------------------------------------+
