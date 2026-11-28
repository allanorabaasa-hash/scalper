//+------------------------------------------------------------------+
//|                                                 XAUScalper.mq5   |
//|   Market-structure trader for gold and bitcoin (no indicators)    |
//+------------------------------------------------------------------+
#property copyright "Allan"
#property link      "https://github.com/allanorabaasa-hash/scalper"
#property version   "19.31"
#property description "Market structure only (no indicators), all on M1: break of structure / shift detection, live-tick"
#property description "triggers confirmed by real tick flow when available. Modes: Slow (1 +/-1), Regular (2 +/-2), Beast (5, +5 / back to 5). R:R 1:3, partials at TP1/TP2."

#include <XAUScalper\RiskManager.mqh>
#include <XAUScalper\Execution.mqh>
#include <XAUScalper\Journal.mqh>

//==================================================================
//  INPUTS
//==================================================================
enum ENUM_BOT_MODE
  {
   BOTMODE_SLOW    = 0,   // Slow: 1 position, +1 after a win, -1 after a loss
   BOTMODE_REGULAR = 1,   // Regular: 2 positions, +2 after a win, -2 after a loss
   BOTMODE_BEAST   = 2,   // Beast: 5 positions, +5 after a win, back to 5 after a loss
   BOTMODE_AUTO    = 3    // Auto: every symbol starts in Slow
  };

#define REWARD_R 3.0   // risk : reward is strictly 1 : 3 (TP1 = 0.7R, TP2 = 2R, TP3 = 3R)

input group "Market structure"
input ENUM_TIMEFRAMES InpStructureTF        = PERIOD_M1;     // Structure timeframe (everything is read on this chart)
input int             InpSwingBars          = 3;             // Swing point = higher/lower than this many candles each side
input double          InpPullbackPct        = 38;            // Pullback entry: price must give back at least this % of the move after the break
input int             InpEntryWindow        = 3;             // A confirmed pullback setup stays valid for this many candles
input double          InpMaxChaseR          = 0.5;           // ...unless price has already run more than this x the stop past the turn candle
input double          InpMinMoveCandles     = 4;             // Real move only: the move must be at least this many average candles long
input double          InpSpikeMult          = 4;             // Spike filter: no trades on a move with a candle this many times the normal size (0 = off)
input int             InpSpikeCooldown      = 30;            // ...and none for this many candles after such a candle
input double          InpStopBufferCandles  = 0.5;           // Stop this many average candles beyond the pullback's extreme
input int             InpRangeLookback      = 60;            // No buys within one average candle of the highest high of this many candles (sells mirrored)
input double          InpTP1R               = 0.7;           // TP1 at this many times the stop distance
input double          InpTP2R               = 2.0;           // TP2 at this many times the stop distance (TP3 = 3x)
input bool            InpSmartExit          = true;          // Smart exit: target split in 3 parts (L1, L2, TP), see README
input double          InpMinStopPct         = 0.03;          // Skip if the stop is closer than this % of price (gold ~$1.2)
input double          InpMaxStopPct         = 0.40;          // Gold: skip if the stop is further than this % of price (~$16)
input double          InpMaxStopPctBtc      = 0.80;          // Bitcoin: skip if the stop is further than this % of price (~$540)
input double          InpMaxSpreadOfStop    = 25;            // Skip if the spread is more than this % of the stop distance

input group "Real tick confirmation"
input bool            InpTickConfirm        = true;          // Enter only when the real ticks push in the trade's direction
input int             InpTickWindowSec      = 15;            // Look at the ticks of the last N seconds
input double          InpTickMinRatio       = 60;            // At least this % of price-changing ticks in the trade's direction

input group "Batches"
input ENUM_BOT_MODE   InpMode               = BOTMODE_AUTO;     // Mode: Slow / Regular / Beast (also switchable on the panel)
input double          InpLot                = 0.01;          // Lot size per position (also changeable on the panel)
input int             InpBatchMax           = 20;            // Never more than this many positions in one batch
input double          InpTargetSlow         = 5;             // Daily target, Slow mode: stop new batches at +this % of the day's start (0 = off)
input double          InpTargetRegular      = 7;             // Daily target, Regular mode (%)
input double          InpTargetBeast        = 10;            // Daily target, Beast mode (%)
input double          InpMaxBatchRiskPct    = 15;            // Batch stop-loss risk at most this % of balance (fewer positions if needed; 0 = off)

input group "News (MT5 economic calendar, live only)"
input bool            InpNews               = true;          // React to high-impact USD news
input int             InpNewsBeforeMin      = 15;            // Before the release: no new entries, winners to breakeven
input int             InpNewsRangeMin       = 15;            // Breakout range = high/low of the last N minutes before release
input int             InpNewsAfterMin       = 30;            // After the release: trade a breakout of that range for N minutes

input group "Account safety"
input double          InpEmergencyMarginLevel = 100;         // Emergency: close all below this margin level % (0 = off)
input bool            InpAllowReal          = false;         // Allow trading on a REAL account
input bool            InpAutoStart          = true;          // Start/resume automatically whenever connected (STOP is remembered)

input group "General"
input long            InpMagic              = 20261114;      // Magic number (unique per EA)
input string          InpTradeComment       = "Scalper";     // Order comment
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
#define LOOKBACK 300

CRiskManager   g_risk;
CExecution     g_exec;

ENUM_BOT_STATE g_state        = BOT_STOPPED;
bool           g_wasConnected = true;
string         g_lastMsg      = "Ready.";
color          g_lastMsgColor = clrSilver;
ulong          g_rowTicket[MAX_ROWS];
bool           g_collapsed    = false;

int            g_bias         = 0;      // +1 H1 up structure, -1 down, 0 range / unclear
string         g_biasText     = "-";
double         g_eSH = 0, g_eSL = 0;    // latest swing high / low (panel)
datetime       g_lastBatchEnd = 0;      // after a batch closes, only a NEW break of structure can be traded
double         g_zoneLevel    = 0;      // pullback zone edge (panel)
double         g_avgRange     = 0;
int            g_armBars      = 0;      // candles since the current setup was confirmed
double         g_armClose     = 0;      // close of the turn candle (chase check)      // average candle size (high - low) of the last 20 closed candles
string         g_block        = "";     // why no entry right now
string         g_lastSignal   = "none yet";
int            g_mode         = BOTMODE_BEAST;   // current mode and lot (panel or inputs)
double         g_lot          = 0.01;
datetime       g_lastEntryBar = 0;
int            g_setupDir     = 0;      // armed setup: +1 buy / -1 sell when price breaks g_level
double         g_level        = 0;      // the pullback's lower high (buy) / higher low (sell)
double         g_stopRef      = 0;      // the pullback's extreme (stop goes beyond it)
string         g_setupWhy     = "";
double         g_lastTraded   = 0;      // level already traded (one batch per break)
string         g_tickText     = "-";
int            g_wins = 0, g_losses = 0;

// batch state (persisted in global variables)
int            g_batchSize    = 5;      // size of the NEXT batch
int            g_batchId      = 0;
bool           g_batchOpen    = false;
datetime       g_batchStart   = 0;
double         g_lastBatchPL  = 0;
double         g_batchSL = 0, g_batchTP = 0;   // shared stop / target of the open batch
double         g_batchDist = 0, g_batchRiskPos = 0;
string         g_batchWhy = "";
#define BATCH_GRACE_SEC 15
double         g_batchRisk = 0;                 // money lost if the whole batch hits its stop
int            g_smStage = 0;                   // smart exit: 0 before L2, 1 L2 touched (stops at entry),
                                                //   2 half closed at L1, 3 half of the rest closed at L2
double         g_smEntry = 0;                   // the batch's average entry price                      // fills of an async batch may take a few seconds

// news state
datetime       g_newsTime     = 0;
string         g_newsName     = "";
string         g_newsStatus   = "off";
datetime       g_newsChecked  = 0;
datetime       g_newsTraded   = 0;      // release already traded
double         g_newsHi = 0, g_newsLo = 0;

long           g_reasonPos[];
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
#define PANEL_H  506
#define ROW_Y0   270
#define ROW_H    22

//==================================================================
//  HELPERS
//==================================================================
string StateKey()
  {
   return "XS_state_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + IntegerToString(InpMagic);
  }
string ManualStopKey() { return StateKey() + "_manualstop_" + _Symbol; }
bool   ManualStop()    { return GlobalVariableCheck(ManualStopKey()); }
string BatchKey()      { return StateKey() + "_batch_" + _Symbol; }
string PrefKey()       { return StateKey() + "_pref_" + _Symbol; }

// Mode and lot: the panel's choice is kept across restarts; a value changed in the inputs
// dialog wins over it (the inputs it was chosen against are remembered).
int DefaultMode()
  {
   // Auto starts every symbol in Slow; Regular and Beast are chosen on the panel or the inputs.
   if(InpMode != BOTMODE_AUTO)
      return InpMode;
   return BOTMODE_SLOW;
  }

void LoadPrefs()
  {
   g_mode = DefaultMode();
   g_lot  = InpLot;
   if(MQLInfoInteger(MQL_TESTER))
      return;
   // Saved modes from before v19.30 are ignored once (they could be Beast): the default applies again.
   if(GlobalVariableCheck(PrefKey() + "_v2") && GlobalVariableCheck(PrefKey() + "_inMode")
      && (int)GlobalVariableGet(PrefKey() + "_inMode") == (int)InpMode && GlobalVariableCheck(PrefKey() + "_mode"))
      g_mode = (int)GlobalVariableGet(PrefKey() + "_mode");
   if(GlobalVariableCheck(PrefKey() + "_inLot") && MathAbs(GlobalVariableGet(PrefKey() + "_inLot") - InpLot) < 1e-9
      && GlobalVariableCheck(PrefKey() + "_lot"))
      g_lot = GlobalVariableGet(PrefKey() + "_lot");
   SavePrefs();
  }

void SavePrefs()
  {
   if(MQLInfoInteger(MQL_TESTER))
      return;
   GlobalVariableSet(PrefKey() + "_v2", 1.0);
   GlobalVariableSet(PrefKey() + "_inMode", (double)InpMode);
   GlobalVariableSet(PrefKey() + "_inLot", InpLot);
   GlobalVariableSet(PrefKey() + "_mode", (double)g_mode);
   GlobalVariableSet(PrefKey() + "_lot", g_lot);
  }

double NormLot(double v)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   v = MathRound(v / step) * step;
   if(vmin > 0) v = MathMax(v, vmin);
   if(vmax > 0) v = MathMin(v, vmax);
   return NormalizeDouble(v, 2);
  }

void SetMode(const int m)
  {
   if(m == g_mode)
      return;
   g_mode = m;
   g_batchSize = ModeStart();
   SaveBatch();
   SavePrefs();
   Msg(StringFormat("%s mode: next batch %d position%s", ModeName(), g_batchSize, g_batchSize == 1 ? "" : "s"), CLR_BLUE);
  }

void SetLot(const double v)
  {
   double n = NormLot(v);
   if(n <= 0)
      return;
   g_lot = n;
   SavePrefs();
   Msg(StringFormat("Lot size %.2f from the next batch", g_lot), CLR_BLUE);
  }
string TFName(const ENUM_TIMEFRAMES tf) { return StringSubstr(EnumToString(tf), 7); }
bool   IsBtc()         { return StringFind(_Symbol, "BTC") >= 0; }
int    ModeStart()     { return g_mode == BOTMODE_SLOW ? 1 : (g_mode == BOTMODE_REGULAR ? 2 : 5); }
int    ModeStep()      { return ModeStart(); }
string ModeName()      { return g_mode == BOTMODE_SLOW ? "SLOW" : (g_mode == BOTMODE_REGULAR ? "REGULAR" : "BEAST"); }
double TargetPct()     { return g_mode == BOTMODE_SLOW ? InpTargetSlow : (g_mode == BOTMODE_REGULAR ? InpTargetRegular : InpTargetBeast); }
// This bot's result today (closed + open trades only). Equity minus balance would also count deposits and top-ups.
double DayResult()     { return g_risk.DayPL(); }
double TargetMoney()   { return g_risk.DayStartBalance() * TargetPct() / 100.0; }
bool   TargetReached() { return TargetPct() > 0 && g_risk.DayStartBalance() > 0 && DayResult() >= TargetMoney(); }
// Bitcoin swings are about twice as wide as gold's in % terms
double MaxStopPct()    { return IsBtc() ? InpMaxStopPctBtc : InpMaxStopPct; }

bool IsRealAccount()
  {
   return !MQLInfoInteger(MQL_TESTER) && AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL;
  }

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

double OpenPL()
  {
   double pl = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetTicket(i) != 0 && IsOurs())
         pl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   return pl;
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

//==================================================================
//  MARKET STRUCTURE (closed candles only, no indicators)
//==================================================================
// MAJOR structure, read left to right over the last LOOKBACK closed candles like a trader:
//   - swing point: a candle higher (lower) than InpSwingBars candles on each side; older candles
//     must be strictly beyond it, newer ones may equal it (M1 candles often open at the extreme)
//   - the first close beyond a swing sets the first structure
//   - in an UP structure the impulse runs to its high X; once a swing high forms there the
//     pullback has started. A close above X = continuation (break of structure); the pullback's
//     low becomes the PROTECTED low. Only a close below the protected low shifts the structure
//     DOWN. Pullbacks, however deep and however many small swings they break, do not.
//   - DOWN mirrored.
struct Structure
  {
   int    trend;        // +1 up, -1 down, 0 not known yet
   int    breakAge;     // candles since the last break (1 = the last closed candle)
   int    breakDir;
   bool   breakShift;   // the last break changed the structure
   double breakLevel;   // the level that was broken
   double protect;      // protected swing: the structure only changes if price closes beyond it
   double sh, sl;       // panel: latest swing high / low
   double x;            // impulse extreme since the last break
   int    xIdx;
   bool   locked;       // a swing formed at the impulse extreme: the pullback has started
  };

bool IsSwingHigh(MqlRates &r[], const int s, const int k)
  {
   for(int j = 1; j <= k; j++)
      if(r[s].high < r[s - j].high || r[s].high <= r[s + j].high)
         return false;
   return true;
  }

bool IsSwingLow(MqlRates &r[], const int s, const int k)
  {
   for(int j = 1; j <= k; j++)
      if(r[s].low > r[s - j].low || r[s].low >= r[s + j].low)
         return false;
   return true;
  }

double LowestLow(MqlRates &r[], const int from, const int to)
  {
   double v = r[from].low;
   for(int j = from; j <= to; j++)
      v = MathMin(v, r[j].low);
   return v;
  }

double HighestHigh(MqlRates &r[], const int from, const int to)
  {
   double v = r[from].high;
   for(int j = from; j <= to; j++)
      v = MathMax(v, r[j].high);
   return v;
  }

bool ScanStructure(Structure &st, MqlRates &r[])
  {
   st.trend = 0;  st.breakAge = 0;  st.breakDir = 0;  st.breakShift = false;  st.breakLevel = 0;  st.protect = 0;
   st.sh = 0;  st.sl = 0;  st.x = 0;  st.xIdx = 0;  st.locked = false;
   ArraySetAsSeries(r, true);
   int n = CopyRates(_Symbol, InpStructureTF, 0, LOOKBACK, r);
   int k = InpSwingBars;
   if(n < 4 * k + 20)
      return false;
   double sh = 0, sl = 0;
   int    shI = 0, slI = 0;
   bool   shB = true, slB = true;
   for(int i = n - k - 2; i >= 1; i--)               // chronological: old -> new, closed candles only
     {
      int  s   = i + k;                               // candle confirmed as a swing at i
      bool swH = (s + k < n) && IsSwingHigh(r, s, k);
      bool swL = (s + k < n) && IsSwingLow(r, s, k);
      if(swH) { st.sh = r[s].high; }
      if(swL) { st.sl = r[s].low; }

      if(st.trend == 0)                               // first structure: first close beyond a swing
        {
         if(swH) { sh = r[s].high;  shI = s;  shB = false; }
         if(swL) { sl = r[s].low;   slI = s;  slB = false; }
         if(!shB && r[i].close > sh)
           {
            st.trend = 1;  st.breakShift = true;  st.breakLevel = sh;  st.protect = LowestLow(r, i, shI);
            st.breakAge = i;  st.breakDir = 1;  st.x = r[i].high;  st.xIdx = i;  st.locked = false;
           }
         else if(!slB && r[i].close < sl)
           {
            st.trend = -1;  st.breakShift = true;  st.breakLevel = sl;  st.protect = HighestHigh(r, i, slI);
            st.breakAge = i;  st.breakDir = -1;  st.x = r[i].low;  st.xIdx = i;  st.locked = false;
           }
         continue;
        }

      if(st.trend > 0)
        {
         if(!st.locked && r[i].high >= st.x) { st.x = r[i].high;  st.xIdx = i; }
         if(!st.locked && swH && s == st.xIdx)
            st.locked = true;                         // swing high at the impulse top: pullback started
         if(st.locked && r[i].close > st.x)
           {                                          // continuation: pullback's low becomes protected
            st.protect = LowestLow(r, i, st.xIdx);  st.breakLevel = st.x;  st.breakShift = false;
            st.breakAge = i;  st.breakDir = 1;  st.x = r[i].high;  st.xIdx = i;  st.locked = false;
           }
         else if(r[i].close < st.protect)
           {                                          // shift DOWN: the up-move's high is protected
            st.breakLevel = st.protect;  st.protect = HighestHigh(r, i, st.xIdx);  st.trend = -1;
            st.breakShift = true;  st.breakAge = i;  st.breakDir = -1;  st.x = r[i].low;  st.xIdx = i;
            st.locked = false;
           }
        }
      else
        {
         if(!st.locked && r[i].low <= st.x) { st.x = r[i].low;  st.xIdx = i; }
         if(!st.locked && swL && s == st.xIdx)
            st.locked = true;
         if(st.locked && r[i].close < st.x)
           {
            st.protect = HighestHigh(r, i, st.xIdx);  st.breakLevel = st.x;  st.breakShift = false;
            st.breakAge = i;  st.breakDir = -1;  st.x = r[i].low;  st.xIdx = i;  st.locked = false;
           }
         else if(r[i].close > st.protect)
           {
            st.breakLevel = st.protect;  st.protect = LowestLow(r, i, st.xIdx);  st.trend = 1;
            st.breakShift = true;  st.breakAge = i;  st.breakDir = 1;  st.x = r[i].high;  st.xIdx = i;
            st.locked = false;
           }
        }
     }
   return true;
  }

// Reads the chart (once per closed candle) and decides what the bot is waiting for.
// Pullback entries only; the bot never chases a break:
//   1. a break of structure (or a shift) sets the side; the move after it is the impulse
//   2. after the last batch closed, only a break that happened AFTER that close counts
//      (no re-entry on the same move: wait for a clear new setup)
//   3. wait for the pullback: price gives back at least InpPullbackPct of the impulse
//      (measured from the protective swing behind the break to the impulse extreme) without
//      breaking that swing
//   4. wait for the turn: a closed candle in the trend's direction that closes beyond the
//      previous candle's high (buys) / low (sells), starting from the pullback zone
//   5. enter on the next tick if the real ticks agree; stop beyond the pullback's extreme
void ReadChart()
  {
   Structure st;
   MqlRates r[];
   g_bias = 0;  g_setupDir = 0;  g_zoneLevel = 0;
   if(!ScanStructure(st, r))
     {
      g_biasText = "waiting for " + TFName(InpStructureTF) + " data";
      g_setupWhy = g_biasText;
      return;
     }
   g_bias = st.trend;
   g_eSH = st.sh;  g_eSL = st.sl;
   if(st.trend == 0)
     {
      g_biasText = "no break of structure yet";
      g_setupWhy = g_biasText;
      return;
     }
   g_biasText = StringFormat("%s (%s %d candle%s ago at %s)", st.trend > 0 ? "UP" : "DOWN",
                             st.breakShift ? "shifted" : "broke", st.breakAge, st.breakAge == 1 ? "" : "s",
                             DoubleToString(st.breakLevel, _Digits));
   // average candle size: the market's own measure of noise (price action, no indicator)
   g_avgRange = 0;
   for(int j = 1; j <= 20; j++)
      g_avgRange += r[j].high - r[j].low;
   g_avgRange /= 20.0;
   int d  = st.trend;
   int ba = st.breakAge;
   string side = d > 0 ? "UP" : "DOWN";
   if(g_lastBatchEnd > 0 && r[ba].time <= g_lastBatchEnd)
     {
      g_setupWhy = side + ": batch closed on this move, waiting for a new break of structure";
      return;
     }
   // spike filter: a move made of abnormal candles (news, liquidations) is not a trend; its
   // pullbacks tend to keep going. Normal size = average candle of the 50 candles before the move.
   if(InpSpikeMult > 0)
     {
      int    nr = ArraySize(r);
      double base = 0;
      int    cnt = 0;
      for(int j = ba + 1; j <= ba + 50 && j < nr; j++)
        {
         base += r[j].high - r[j].low;
         cnt++;
        }
      if(cnt > 10)
        {
         base /= cnt;
         int upto = MathMin(MathMax(ba, InpSpikeCooldown), nr - 1);
         for(int j = 1; j <= upto; j++)
            if(r[j].high - r[j].low > InpSpikeMult * base)
              {
               g_setupWhy = StringFormat("%s: spike %d candles ago (%.0fx normal size): waiting for normal structure",
                                         side, j, (r[j].high - r[j].low) / base);
               return;
              }
        }
     }
   if(ba < 2)
     {
      g_setupWhy = side + ": structure just broke, waiting for the pullback";
      return;
     }
   // impulse extreme after the break
   int    xi = ba;
   double X  = d > 0 ? r[ba].high : r[ba].low;
   for(int j = ba - 1; j >= 1; j--)
      if(d > 0 ? r[j].high > X : r[j].low < X)
        {
         X = d > 0 ? r[j].high : r[j].low;
         xi = j;
        }
   if(xi <= 1)
     {
      g_setupWhy = side + ": the move is still running, waiting for the pullback";
      return;
     }
   // deepest point of the pullback after the impulse extreme
   int    pi = xi - 1;
   double PB = d > 0 ? r[pi].low : r[pi].high;
   for(int j = xi - 1; j >= 1; j--)
      if(d > 0 ? r[j].low < PB : r[j].high > PB)
        {
         PB = d > 0 ? r[j].low : r[j].high;
         pi = j;
        }
   double P    = st.protect;
   // only real moves: a tiny break inside a range is ignored
   if(g_avgRange > 0 && d * (X - P) < InpMinMoveCandles * g_avgRange)
     {
      g_setupWhy = StringFormat("%s: move too small (%.2f < %.0f candles): looks like a range", side, d * (X - P),
                                InpMinMoveCandles);
      return;
     }
   double zone = X - (X - P) * InpPullbackPct / 100.0;     // price must reach this (both directions)
   g_zoneLevel = zone;
   if(d * (PB - zone) > 0)
     {
      g_setupWhy = StringFormat("%s: waiting for a pullback to %s", side, DoubleToString(zone, _Digits));
      return;
     }
   if(d * (PB - P) <= 0)
     {
      g_setupWhy = side + ": pullback went through the protective swing, waiting";
      return;
     }
   // the turn: a candle in the trend's direction closing beyond the previous candle, from the zone
   bool turn = d > 0 ? (r[1].close > r[1].open && r[1].close > r[2].high && MathMin(r[1].low, r[2].low) <= zone)
                     : (r[1].close < r[1].open && r[1].close < r[2].low && MathMax(r[1].high, r[2].high) >= zone);
   if(!turn)
     {
      g_setupWhy = StringFormat("%s: in the pullback zone, waiting for a %s reversal candle", side, d > 0 ? "bullish" : "bearish");
      return;
     }
   if(PB == g_lastTraded)
     {
      g_setupWhy = side + ": this pullback was already traded";
      return;
     }
   // no buying at the top of the recent range, no selling at its bottom
   int lb = MathMin(InpRangeLookback, ArraySize(r) - 1);
   double hh = r[1].high, ll = r[1].low;
   for(int j = 2; j <= lb; j++)
     {
      hh = MathMax(hh, r[j].high);
      ll = MathMin(ll, r[j].low);
     }
   // ... but in a trend the recent high IS the impulse's own high: that is not a range top
   if(d > 0 && hh > X + g_avgRange * 0.01 && r[1].close >= hh - g_avgRange)
     {
      g_setupWhy = StringFormat("UP: too close to the %d-candle high %s, not buying the top", lb, DoubleToString(hh, _Digits));
      return;
     }
   if(d < 0 && ll < X - g_avgRange * 0.01 && r[1].close <= ll + g_avgRange)
     {
      g_setupWhy = StringFormat("DOWN: too close to the %d-candle low %s, not selling the bottom", lb, DoubleToString(ll, _Digits));
      return;
     }
   g_setupDir = d;
   g_level    = PB;                                         // identifies this pullback
   g_stopRef  = PB;
   g_armClose = r[1].close;
   g_armBars  = 0;
   g_setupWhy = "";
  }

// After ReadChart: keep the previous setup armed if no new one was found and it is still fresh.
void KeepArmed(const int prevDir, const double prevLevel, const double prevStop, const double prevClose, const int prevBars)
  {
   if(g_setupDir != 0 || prevDir == 0 || prevLevel == g_lastTraded || prevBars + 1 >= InpEntryWindow)
      return;
   if(g_bias != prevDir)
      return;                                                // structure changed: setup is void
   double px = iClose(_Symbol, InpStructureTF, 1);
   if(prevDir * (px - prevStop) <= 0)
      return;                                                // pullback extreme broken
   g_setupDir = prevDir;  g_level = prevLevel;  g_stopRef = prevStop;  g_armClose = prevClose;
   g_armBars  = prevBars + 1;
  }

// Real tick flow over the last InpTickWindowSec seconds: share of price-changing ticks (bid)
// that moved in direction dir, and the net move. true when both agree with dir.
bool TickFlowConfirms(const int dir, string &text)
  {
   if(!InpTickConfirm)
     {
      text = "tick check off";
      return true;
     }
   MqlTick t[];
   long now = (long)TimeCurrent() * 1000;
   MqlTick last;
   if(SymbolInfoTick(_Symbol, last))
      now = last.time_msc;
   int n = CopyTicks(_Symbol, t, COPY_TICKS_INFO, (ulong)(now - InpTickWindowSec * 1000), 0);
   if(n < 3)
     {
      text = "no tick data: check skipped";
      return true;                                    // ticks are used only when available
     }
   int with = 0, against = 0;
   for(int i = 1; i < n; i++)
     {
      double d = t[i].bid - t[i - 1].bid;
      if(d == 0)
         continue;
      if(dir * d > 0)
         with++;
      else
         against++;
     }
   double ratio = (with + against) > 0 ? 100.0 * with / (with + against) : 0;
   double move  = dir * (t[n - 1].bid - t[0].bid);
   text = StringFormat("ticks %.0f%% %s, move %+.2f in %ds", ratio, dir > 0 ? "up" : "down", move, InpTickWindowSec);
   return ratio >= InpTickMinRatio && move > 0;
  }

//==================================================================
//  NEWS (high-impact USD events from the MT5 calendar)
//==================================================================
void UpdateNews()
  {
   if(!InpNews)
     {
      g_newsStatus = "off";
      return;
     }
   if(MQLInfoInteger(MQL_TESTER))
     {
      g_newsStatus = "not available in the Strategy Tester";
      return;
     }
   datetime now = TimeTradeServer();
   if(now - g_newsChecked < 60)
      return;
   g_newsChecked = now;
   MqlCalendarValue v[];
   g_newsTime = 0;
   g_newsName = "";
   if(!CalendarValueHistory(v, now - InpNewsAfterMin * 60, now + 24 * 3600, NULL, "USD"))
     {
      g_newsStatus = "calendar unavailable";
      return;
     }
   for(int i = 0; i < ArraySize(v); i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(v[i].event_id, ev) || ev.importance != CALENDAR_IMPORTANCE_HIGH)
         continue;
      if(g_newsTime == 0 || v[i].time < g_newsTime)
        {
         g_newsTime = v[i].time;
         g_newsName = ev.name;
        }
     }
   g_newsStatus = (g_newsTime == 0) ? "no high-impact USD news in 24 h" : "";
  }

// 0 = normal, 1 = before the release, 2 = breakout window after the release
int NewsPhase()
  {
   if(!InpNews || g_newsTime == 0)
      return 0;
   datetime now = TimeTradeServer();
   if(now >= g_newsTime - InpNewsBeforeMin * 60 && now < g_newsTime)
      return 1;
   if(now >= g_newsTime && now < g_newsTime + InpNewsAfterMin * 60)
      return 2;
   return 0;
  }

// Before a release: move every position that is in profit to breakeven.
void ProtectForNews()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !IsOurs())
         continue;
      int    d    = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      MqlTick tk;
      SymbolInfoTick(_Symbol, tk);
      double px = d > 0 ? tk.bid : tk.ask;
      if(d * (px - open) > 0 && (sl == 0 || d * (open - sl) > 0))
        {
         string err;
         if(g_exec.MoveStop(t, open, err))
            Msg("News ahead: stop moved to breakeven on #" + IntegerToString((long)t), CLR_AMBER);
        }
     }
  }

// After a release: break of the pre-news range. Returns direction and stop.
int NewsSignal(double &stop)
  {
   stop = 0;
   if(g_newsTraded == g_newsTime)
      return 0;
   if(g_newsHi <= 0)
     {
      MqlRates m[];
      int n = CopyRates(_Symbol, PERIOD_M1, g_newsTime - InpNewsRangeMin * 60, g_newsTime - 1, m);
      if(n <= 0)
         return 0;
      g_newsHi = m[0].high;  g_newsLo = m[0].low;
      for(int i = 1; i < n; i++)
        {
         g_newsHi = MathMax(g_newsHi, m[i].high);
         g_newsLo = MathMin(g_newsLo, m[i].low);
        }
     }
   double c = iClose(_Symbol, PERIOD_M1, 1);
   datetime t1 = iTime(_Symbol, PERIOD_M1, 1);
   if(t1 < g_newsTime)
      return 0;
   MqlTick tk;
   SymbolInfoTick(_Symbol, tk);
   double buffer = (tk.ask - tk.bid) + c * 0.0002;
   if(c > g_newsHi)
     {
      stop = g_newsLo - buffer;
      return 1;
     }
   if(c < g_newsLo)
     {
      stop = g_newsHi + buffer;
      return -1;
     }
   return 0;
  }

//==================================================================
//  BATCHES
//==================================================================
void SaveBatch()
  {
   GlobalVariableSet(BatchKey() + "_size", g_batchSize);
   GlobalVariableSet(BatchKey() + "_id", g_batchId);
   GlobalVariableSet(BatchKey() + "_open", g_batchOpen ? 1 : 0);
   GlobalVariableSet(BatchKey() + "_start", (double)g_batchStart);
   GlobalVariableSet(BatchKey() + "_last", g_lastBatchPL);
   GlobalVariableSet(BatchKey() + "_risk", g_batchRisk);
   GlobalVariableSet(BatchKey() + "_mode", (double)g_mode);
   GlobalVariableSet(BatchKey() + "_sl", g_batchSL);
   GlobalVariableSet(BatchKey() + "_tp", g_batchTP);
   GlobalVariableSet(BatchKey() + "_smst", g_smStage);
   GlobalVariableSet(BatchKey() + "_sment", g_smEntry);
   GlobalVariableSet(BatchKey() + "_end", (double)g_lastBatchEnd);
  }

void LoadBatch()
  {
   g_batchSize = ModeStart();
   if(MQLInfoInteger(MQL_TESTER) || !GlobalVariableCheck(BatchKey() + "_size"))
      return;
   g_batchSize   = (int)GlobalVariableGet(BatchKey() + "_size");
   g_batchId     = (int)GlobalVariableGet(BatchKey() + "_id");
   g_batchOpen   = GlobalVariableGet(BatchKey() + "_open") > 0;
   g_batchStart  = (datetime)(long)GlobalVariableGet(BatchKey() + "_start");
   g_lastBatchPL = GlobalVariableGet(BatchKey() + "_last");
   g_batchRisk   = GlobalVariableCheck(BatchKey() + "_risk") ? GlobalVariableGet(BatchKey() + "_risk") : 0;
   g_batchSL     = GlobalVariableCheck(BatchKey() + "_sl") ? GlobalVariableGet(BatchKey() + "_sl") : 0;
   g_batchTP     = GlobalVariableCheck(BatchKey() + "_tp") ? GlobalVariableGet(BatchKey() + "_tp") : 0;
   g_smStage     = GlobalVariableCheck(BatchKey() + "_smst") ? (int)GlobalVariableGet(BatchKey() + "_smst") : 0;
   g_smEntry     = GlobalVariableCheck(BatchKey() + "_sment") ? GlobalVariableGet(BatchKey() + "_sment") : 0;
   g_lastBatchEnd = GlobalVariableCheck(BatchKey() + "_end") ? (datetime)(long)GlobalVariableGet(BatchKey() + "_end") : 0;
   // a different mode than last time starts again from that mode's first size
   if(!GlobalVariableCheck(BatchKey() + "_mode") || (int)GlobalVariableGet(BatchKey() + "_mode") != (int)g_mode)
      g_batchSize = ModeStart();
   g_batchSize   = MathMax(ModeStart(), MathMin(g_batchSize, InpBatchMax));
  }

// Net result of the batch: all deals of the positions this EA opened on this symbol since the
// batch opened (found by their opening deal, so stop / target closes count whatever their magic).
double BatchResult()
  {
   if(!HistorySelect(g_batchStart - 60, TimeCurrent() + 60))
      return 0;
   long ids[];
   int  m = 0;
   int  total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0 || HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol || HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN
         || HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic || (datetime)HistoryDealGetInteger(d, DEAL_TIME) < g_batchStart - 5)
         continue;
      ArrayResize(ids, m + 1);
      ids[m++] = HistoryDealGetInteger(d, DEAL_POSITION_ID);
     }
   double pl = 0;
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      long pid = HistoryDealGetInteger(d, DEAL_POSITION_ID);
      bool mine = false;
      for(int j = 0; j < m && !mine; j++)
         mine = (ids[j] == pid);
      if(!mine)
         continue;
      pl += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP)
            + HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
     }
   return pl;
  }

// A batch is finished when none of its positions is open. Its result decides the next size:
//   win  (profit above 20% of the batch's risk)  -> Slow +1, Regular +2, Beast +5
//   loss (loss beyond 20% of the batch's risk)   -> Slow -1, Regular -2, Beast back to 5
//   about zero (breakeven exits, spread)         -> size unchanged: no increase on a 0 result
void CheckBatchEnd()
  {
   if(!g_batchOpen || CountOurs() > 0 || TimeCurrent() - g_batchStart < BATCH_GRACE_SEC)
      return;
   g_lastBatchPL = BatchResult();
   g_batchOpen = false;
   g_lastBatchEnd = TimeCurrent();
   g_lastEntryBar = 0;                               // re-read the chart now
   double neutral = MathMax(0.2 * g_batchRisk, 0.01);
   string verdict;
   if(g_lastBatchPL > neutral)
     {
      g_batchSize = MathMin(g_batchSize + ModeStep(), InpBatchMax);
      verdict = "win";
     }
   else if(g_lastBatchPL < -neutral)
     {
      g_batchSize = (g_mode == BOTMODE_BEAST) ? ModeStart() : MathMax(ModeStart(), g_batchSize - ModeStep());
      verdict = "loss";
     }
   else
      verdict = "about zero, size kept";
   SaveBatch();
   Msg(StringFormat("Batch %d %+.2f (%s): next batch %d", g_batchId, g_lastBatchPL, verdict, g_batchSize),
       verdict == "win" ? CLR_GREEN : (verdict == "loss" ? CLR_RED : CLR_MUTED));
  }

// Which take-profit level position i of n gets: about 40% at TP1, 40% at TP2, the rest at TP3.
//   1 position: TP2.  2 positions: TP1 + TP3.  5: 2 x TP1, 2 x TP2, 1 x TP3.  10: 4 / 4 / 2.
int TierFor(const int i, const int n)
  {
   if(n == 1)
      return 2;
   if(n == 2)
      return i == 0 ? 1 : 3;
   int k1 = (int)MathRound(n * 0.4), k2 = (int)MathRound(n * 0.4);
   if(k1 + k2 >= n)
      k2 = n - k1 - 1;
   return i < k1 ? 1 : (i < k1 + k2 ? 2 : 3);
  }

double TierR(const int tier) { return tier == 1 ? InpTP1R : (tier == 2 ? InpTP2R : REWARD_R); }

// Opens the batch: all positions share the structure stop; targets are staggered TP1 / TP2 / TP3.
bool OpenBatch(const int dir, const double stopPrice, const string why)
  {
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return false;
   double entry = dir > 0 ? tk.ask : tk.bid;
   double dist  = dir * (entry - stopPrice);
   double spread = tk.ask - tk.bid;
   if(dist <= 0)
     {
      g_block = "price already beyond the stop";
      return false;
     }
   if(dist < entry * InpMinStopPct / 100.0 || dist < g_exec.MinStopDistance())
     {
      g_lastSignal = StringFormat("%s skipped: stop too close (%.2f)", why, dist);
      return false;
     }
   if(dist > entry * MaxStopPct() / 100.0)
     {
      g_lastSignal = StringFormat("%s skipped: stop too far (%.2f)", why, dist);
      return false;
     }
   if(InpMaxSpreadOfStop > 0 && spread > dist * InpMaxSpreadOfStop / 100.0)
     {
      g_lastSignal = StringFormat("%s skipped: spread %.2f too wide", why, spread);
      return false;
     }
   double tpPrice = entry + dir * REWARD_R * dist;

   // batch size, trimmed so the whole batch never risks more than InpMaxBatchRiskPct of the balance
   int n = MathMin(g_batchSize, InpBatchMax);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double riskPerPos = (ts > 0) ? dist / ts * tv * g_lot : 0;
   if(InpMaxBatchRiskPct > 0 && riskPerPos > 0)
     {
      int cap = (int)MathFloor(AccountInfoDouble(ACCOUNT_BALANCE) * InpMaxBatchRiskPct / 100.0 / riskPerPos);
      if(cap < 1)
        {
         g_lastSignal = StringFormat("%s skipped: one position risks %.2f, above %.0f%% of balance", why, riskPerPos,
                                     InpMaxBatchRiskPct);
         return false;
        }
      n = MathMin(n, cap);
     }

   g_batchId++;
   g_batchStart = TimeCurrent();
   g_batchSL = stopPrice;  g_batchTP = tpPrice;  g_batchDist = dist;  g_batchRiskPos = riskPerPos;  g_batchWhy = why;
   g_smStage = 0;  g_smEntry = 0;
   g_batchRisk = riskPerPos * n;
   // fire every order of the batch at once (no waiting for each confirmation), so all positions
   // fill within about a second at nearly the same price
   // every position gets its own take profit ON THE BROKER'S SERVER (TP1 / TP2 / TP3), so the
   // partial profits are taken even when MT5, the PC or the internet is off
   int opened = 0;
   string comment = InpTradeComment + ":B" + IntegerToString(g_batchId);
   for(int i = 0; i < n; i++)
     {
      string err;
      int    tier = TierFor(i, n);
      double tpI  = entry + dir * TierR(tier) * dist;
      if(!g_exec.OpenAsync(dir, g_lot, stopPrice, tpI, comment + ":T" + IntegerToString(tier), err))
        {
         Msg("Order failed: " + err, CLR_RED);
         break;
        }
      opened++;
     }
   if(opened == 0)
     {
      g_batchId--;
      return false;
     }
   g_batchOpen = true;
   g_batchRisk = riskPerPos * opened;
   SaveBatch();
   g_lastSignal = StringFormat("%s: %s %d x %.2f, stop %s, target %s", why, dir > 0 ? "BUY" : "SELL", opened, g_lot,
                               DoubleToString(stopPrice, _Digits), DoubleToString(tpPrice, _Digits));
   Msg(g_lastSignal, CLR_BLUE);
   return true;
  }

// A position that filled without its stop or target (the broker dropped them) gets the batch's.
void FixBatchStops()
  {
   if(g_batchSL <= 0)
      return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !IsOurs())
         continue;
      if(PositionGetDouble(POSITION_SL) == 0 || PositionGetDouble(POSITION_TP) == 0)
        {
         string err;
         double sl = PositionGetDouble(POSITION_SL) > 0 ? PositionGetDouble(POSITION_SL) : g_batchSL;
         double tp = PositionGetDouble(POSITION_TP) > 0 ? PositionGetDouble(POSITION_TP) : g_batchTP;
         if(!g_exec.SetSLTP(t, sl, tp, err))
            Print(err);
        }
     }
  }

// Partial profits. Each position carries its own take profit ON THE SERVER: about 40% of the
// batch at TP1 (0.7R), 40% at TP2 (2R), the rest at TP3 (3R): they close there even if MT5 is off.
// While MT5 is online the EA also protects what is left:
//   stage 0  TP1 touched -> every remaining stop moves to its entry (breakeven)             -> 1
//   stage 1  TP2 touched -> every remaining stop moves to TP1                               -> 3
// Touches are judged on the best price since the batch opened (M1 candles + live ticks), so a
// spike missed while offline still counts; if price is already back past the new stop level,
// the remaining positions are closed at market.
void ManageSmartExit()
  {
   if(!InpSmartExit || !g_batchOpen)
      return;
   ulong  tk[];
   int    n = 0, dir = 0;
   double sumOpen = 0, sl0 = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !IsOurs())
         continue;
      ArrayResize(tk, n + 1);
      tk[n++] = t;
      dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      sumOpen += PositionGetDouble(POSITION_PRICE_OPEN);
      if(sl0 == 0)
         sl0 = PositionGetDouble(POSITION_SL);
     }
   if(n == 0)
      return;
   if(g_smEntry <= 0)
     {
      if(TimeCurrent() - g_batchStart < 3)
         return;                                     // let all async fills arrive first
      g_smEntry = sumOpen / n;                       // first time the batch is seen filled
      if(g_batchSL <= 0)
         g_batchSL = sl0;                            // e.g. after a restart without saved state
      SaveBatch();
     }
   double risk = dir * (g_smEntry - g_batchSL);
   if(risk <= 0)
      return;
   double T  = REWARD_R * risk;
   double L1 = g_smEntry + dir * InpTP1R * risk;
   double L2 = g_smEntry + dir * InpTP2R * risk;
   MqlTick q;
   if(!SymbolInfoTick(_Symbol, q))
      return;
   double px = dir > 0 ? q.bid : q.ask;
   string err;

   double TP1 = L1, TP2 = L2;
   // best price since the batch opened, from the M1 candles + the live price: a TP1 / TP2 touch
   // that happened while MT5 was offline or between ticks still counts
   // (from the candle after the entry: the entry candle's extreme may come from before the entry)
   static double seen = 0;                            // best live price seen during this batch
   static int    seenBatch = -1;
   if(seenBatch != g_batchId) { seen = px; seenBatch = g_batchId; }
   if(dir * (px - seen) > 0) seen = px;
   double best = seen;
   double hl[];
   datetime from = (datetime)(g_batchStart - g_batchStart % 60 + 60);
   if(TimeCurrent() >= from)
     {
      if(dir > 0 && CopyHigh(_Symbol, PERIOD_M1, from, TimeCurrent(), hl) > 0)
         best = MathMax(best, hl[ArrayMaximum(hl)]);
      if(dir < 0 && CopyLow(_Symbol, PERIOD_M1, from, TimeCurrent(), hl) > 0)
         best = MathMin(best, hl[ArrayMinimum(hl)] + (q.ask - q.bid));
     }

   // stage 0 -> 1: TP1 touched, stops to entry. If the touch was missed and price is already
   // back at or below the entry, the breakeven stop cannot be placed: close at market instead.
   if(g_smStage == 0 && dir * (best - TP1) >= 0)
     {
      int moved = 0;
      for(int i = 0; i < n; i++)
         if(PositionSelectByTicket(tk[i]))
           {
            double open = PositionGetDouble(POSITION_PRICE_OPEN);
            if(dir * (px - open) > 0 && g_exec.MoveStop(tk[i], open, err))
               moved++;
            else if(PositionSelectByTicket(tk[i]) && dir * (open - PositionGetDouble(POSITION_SL)) > 0)
              {
               NoteCloseReason(tk[i], "TP1 touched, breakeven missed");
               if(!g_exec.CloseAsync(tk[i], err))
                  Print(err);
              }
           }
      g_smStage = 1;
      SaveBatch();
      Msg(moved == n ? "TP1 reached: all stops moved to entry (breakeven)"
                     : "TP1 was touched while offline: breakeven missed, closed at market", moved == n ? CLR_GREEN : CLR_AMBER);
      return;
     }
   // TP2 reached: the TP1 / TP2 positions have closed on the server; the rest's stop moves to TP1
   if(g_smStage == 1 && dir * (best - TP2) >= 0)
     {
      int moved = 0;
      for(int i = 0; i < n; i++)
         if(dir * (px - TP1) > 0)
           {
            if(g_exec.MoveStop(tk[i], TP1, err))
               moved++;
           }
         else
           {                                          // TP2 touch missed, price already back below TP1
            NoteCloseReason(tk[i], "TP2 touched, back below TP1");
            if(!g_exec.CloseAsync(tk[i], err))
               Print(err);
           }
      g_smStage = 3;
      SaveBatch();
      Msg(StringFormat("TP2 reached: stop of the last %d position(s) moved to TP1", n), CLR_GREEN);
      return;
     }
  }

//==================================================================
//  LIFECYCLE
//==================================================================
int OnInit()
  {
   ArrayInitialize(g_rowTicket, 0);
   ChartSetInteger(0, CHART_FOREGROUND, false);
   ChartSetInteger(0, CHART_SHOW_ONE_CLICK, false);
   LoadPrefs();
   if(g_lot <= 0 || InpBatchMax < ModeStart() || InpSwingBars < 1)
     {
      Print("XAUScalper: check the inputs");
      return INIT_PARAMETERS_INCORRECT;
     }
   g_exec.Init(_Symbol, InpMagic, InpSlippagePoints);
   JournalInit(InpJournal);

   RiskConfig cfg;
   cfg.magic = InpMagic;  cfg.riskPct = 1.0;  cfg.minLotMaxRiskPct = 0;  cfg.maxDailyLossPct = 0;
   cfg.dailyTargetPct = 0;  cfg.maxConsecLosses = 0;  cfg.maxPositions = InpBatchMax;  cfg.maxDailyTrades = 0;
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
   LoadBatch();
   if(!g_batchOpen && CountOurs() > 0)          // positions without saved batch state
     {
      g_batchOpen = true;
      g_batchStart = TimeCurrent() - 7 * 86400;
     }
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
   Engine();
  }

void OnTimer()
  {
   CheckConnection();
   CheckAutoStart();
   Engine();
   if(g_risk.Update())
      ApplyEmergency();
   if(!MQLInfoInteger(MQL_TESTER))
      UpdatePanel();
  }

//==================================================================
//  ENGINE
//==================================================================
void Engine()
  {
   CheckBatchEnd();
   ManageSmartExit();
   UpdateNews();
   int phase = NewsPhase();
   if(phase == 1)
      ProtectForNews();
   if(phase != 2)
     {
      g_newsHi = 0;
      g_newsLo = 0;
     }

   if(g_state != BOT_RUNNING)
     {
      g_block = "";
      return;
     }
   g_block = PlatformBlockReason();
   if(g_block != "")
      return;
   if(g_risk.Locked())
     {
      g_block = g_risk.LockText();
      return;
     }
   if(CountOurs() > 0 || g_batchOpen)
     {
      g_block = "";
      FixBatchStops();
      return;                                     // one batch at a time
     }
   // daily target of the mode (Slow 5%, Regular 10%, Beast 15%): done for the day once reached
   if(TargetReached())
     {
      g_block = StringFormat("daily target %.0f%% reached (%s): no new batches until tomorrow", TargetPct(),
                             Signed(DayResult()));
      return;
     }

   if(phase == 1)
     {
      g_block = "news in " + IntegerToString((int)((g_newsTime - TimeTradeServer()) / 60) + 1) + " min: no new entries";
      return;
     }
   if(phase == 2)
     {
      double stop;
      int d = NewsSignal(stop);
      g_block = StringFormat("news breakout: waiting for a close outside %s - %s", DoubleToString(g_newsLo, _Digits),
                             DoubleToString(g_newsHi, _Digits));
      if(d != 0)
        {
         g_newsTraded = g_newsTime;
         OpenBatch(d, stop, "news breakout");
        }
      return;
     }

   // 1. read the chart once per closed candle (also right after the bot is attached)
   datetime bar = iTime(_Symbol, InpStructureTF, 0);
   if(bar != 0 && bar != g_lastEntryBar)
     {
      int    pd = g_setupDir, pb = g_armBars;
      double pl = g_level, ps = g_stopRef, pc = g_armClose;
      ReadChart();
      KeepArmed(pd, pl, ps, pc, pb);
      g_lastEntryBar = bar;
     }
   // 2. pullback setup confirmed on the last closed candle: enter if the real ticks agree
   if(g_setupDir == 0)
     {
      g_block = g_setupWhy;
      return;
     }
   if(g_level == g_lastTraded)
     {
      g_block = "this pullback was already traded";
      return;
     }
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return;
   double runAway = g_setupDir * (tk.bid - g_armClose);
   if(runAway > InpMaxChaseR * MathAbs(g_armClose - g_stopRef))
     {
      g_block = "price already ran away from the setup: not chasing";
      return;
     }
   if(!TickFlowConfirms(g_setupDir, g_tickText))
     {
      g_block = "pullback setup ready, ticks not confirming (" + g_tickText + ")";
      return;
     }
   // stop beyond the pullback's extreme by spread + half an average candle (room for normal wicks)
   double buffer = (tk.ask - tk.bid) + MathMax(InpStopBufferCandles * g_avgRange, tk.bid * 0.0002);
   double stop   = g_stopRef - g_setupDir * buffer;
   g_block = "";
   g_lastTraded = g_level;
   OpenBatch(g_setupDir, stop, TFName(InpStructureTF) + " pullback entry");
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
      Msg("Connection lost. Stop loss and take profit stay on the broker's server.", CLR_RED);
     }
   else if(connected && !g_wasConnected)
     {
      g_wasConnected = true;
      Msg("Reconnected.", CLR_GREEN);
     }
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_OBJECT_ENDEDIT && sparam == P("e_lot"))
     {
      double v = StringToDouble(ObjectGetString(0, sparam, OBJPROP_TEXT));
      if(v > 0)
         SetLot(v);
      ObjectSetString(0, sparam, OBJPROP_TEXT, DoubleToString(g_lot, 2));
      UpdatePanel();
      return;
     }
   if(id != CHARTEVENT_OBJECT_CLICK || StringFind(sparam, PREFIX) != 0)
      return;
   ObjectSetInteger(0, sparam, OBJPROP_STATE, false);

   if(sparam == P("b_m0") || sparam == P("b_m1") || sparam == P("b_m2"))
     {
      SetMode((int)StringToInteger(StringSubstr(sparam, StringLen(P("b_m")))));
      UpdatePanel();
      return;
     }
   if(sparam == P("b_lm") || sparam == P("b_lp"))
     {
      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      if(step <= 0) step = 0.01;
      SetLot(g_lot + (sparam == P("b_lp") ? step : -step));
      UpdatePanel();
      return;
     }

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
   Msg("STOPPED: no new batches. Open positions keep their SL / TP.", CLR_AMBER);
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
   if(entry == DEAL_ENTRY_IN && HistoryDealGetInteger(trans.deal, DEAL_MAGIC) == InpMagic)
     {
      MqlTick tk;
      SymbolInfoTick(_Symbol, tk);
      int d = (HistoryDealGetInteger(trans.deal, DEAL_TYPE) == DEAL_TYPE_BUY) ? 1 : -1;
      // target from the REAL fill: TP1 / TP2 / TP3 x the distance from the fill to the stop
      long pid = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
      if(PositionSelectByTicket((ulong)pid))
        {
         double fill = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl   = PositionGetDouble(POSITION_SL) > 0 ? PositionGetDouble(POSITION_SL) : g_batchSL;
         string cm   = PositionGetString(POSITION_COMMENT);
         if(StringFind(cm, ":T") < 0)
            cm = HistoryDealGetString(trans.deal, DEAL_COMMENT);
         double mult = StringFind(cm, ":T1") >= 0 ? InpTP1R : (StringFind(cm, ":T2") >= 0 ? InpTP2R : REWARD_R);
         if(sl > 0 && d * (fill - sl) > 0)
           {
            double tp = fill + d * mult * (d * (fill - sl));
            if(MathAbs(PositionGetDouble(POSITION_TP) - tp) > _Point || PositionGetDouble(POSITION_SL) == 0)
              {
               string err;
               if(!g_exec.SetSLTP((ulong)pid, sl, tp, err))
                  Print(err);
              }
           }
        }
      JournalOpen(HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID), d, "STRUCTURE", g_batchWhy,
                  HistoryDealGetDouble(trans.deal, DEAL_VOLUME), HistoryDealGetDouble(trans.deal, DEAL_PRICE),
                  tk.ask - tk.bid, g_batchDist, REWARD_R * g_batchDist, 0, g_batchRiskPos, 0, 0,
                  "batch " + IntegerToString(g_batchId));
      return;
     }
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
   JournalClose(posId, type == DEAL_TYPE_SELL ? "BUY" : "SELL", "STRUCTURE", lots, price, profit, comm, hold, 0, false, why);
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

void MkEdit(const string name, int x, int y, int w, int h, const string text)
  {
   string o = P(name);
   if(ObjectFind(0, o) < 0)
      ObjectCreate(0, o, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, o, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, o, OBJPROP_XDISTANCE, InpPanelX + x);
   ObjectSetInteger(0, o, OBJPROP_YDISTANCE, InpPanelY + y);
   ObjectSetInteger(0, o, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, o, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, o, OBJPROP_BGCOLOR, CLR_HEADER);
   ObjectSetInteger(0, o, OBJPROP_BORDER_COLOR, CLR_BORDER);
   ObjectSetInteger(0, o, OBJPROP_COLOR, CLR_TEXT);
   ObjectSetInteger(0, o, OBJPROP_ALIGN, ALIGN_CENTER);
   ObjectSetString(0, o, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, o, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, o, OBJPROP_TEXT, text);
   ObjectSetInteger(0, o, OBJPROP_READONLY, false);
   ObjectSetInteger(0, o, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, o, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, o, OBJPROP_ZORDER, 10);
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
   MkLabel("title", 14, 9, IsBtc() ? "BTC SCALPER" : "XAU SCALPER", CLR_TEXT, 12, "Arial Bold");
   MkLabel("mode", 150, 12, ModeName() + " MODE | " + TFName(InpStructureTF) + " STRUCTURE + TICKS", CLR_BLUE, 8, "Arial Bold");
   MkRect("pill", PANEL_W - 118, 8, 106, 20, CLR_GREY, CLR_GREY);
   MkLabel("pill_t", PANEL_W - 65, 18, "STOPPED", clrWhite, 8, "Arial Bold", ANCHOR_CENTER);
   MkButton("b_min", PANEL_W - 146, 8, 22, 20, "-", CLR_GREY, clrWhite, 10);
   MkLabel("info", 14, 44, " ", CLR_MUTED, 8);

   string titles[6] = {"BALANCE", "EQUITY", "DAY P/L / TARGET", "OPEN P/L", "NEXT BATCH", "NEXT HIGH-IMPACT NEWS"};
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

   // mode and lot size, changeable while running (apply from the next batch)
   MkLabel("l_mode", 14, 234, "MODE", CLR_MUTED, 7, "Arial Bold");
   MkButton("b_m0", 52,  228, 70, 24, "SLOW",    CLR_GREY, clrWhite, 8);
   MkButton("b_m1", 126, 228, 80, 24, "REGULAR", CLR_GREY, clrWhite, 8);
   MkButton("b_m2", 210, 228, 70, 24, "BEAST",   CLR_GREY, clrWhite, 8);
   MkLabel("l_lot", 312, 234, "LOT", CLR_MUTED, 7, "Arial Bold");
   MkButton("b_lm", 340, 228, 26, 24, "-", CLR_GREY, clrWhite, 10);
   MkEdit("e_lot", 370, 228, 70, 24, DoubleToString(g_lot, 2));
   MkButton("b_lp", 444, 228, 26, 24, "+", CLR_GREY, clrWhite, 10);

   MkLabel("t_title", 14, 262, "BATCH POSITIONS (0)", CLR_MUTED, 7, "Arial Bold");
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
   MkLabel("t_empty", PANEL_W / 2, ROW_Y0 + 60, "No open batch", CLR_MUTED, 9, "Arial", ANCHOR_UPPER);

   MkRect("sep3", 12, PANEL_H - 52, PANEL_W - 24, 1, CLR_BORDER, CLR_BORDER);
   MkLabel("f_msg",  14, PANEL_H - 44, g_lastMsg, g_lastMsgColor, 8);
   MkLabel("f_cond", 14, PANEL_H - 24, " ", CLR_MUTED, 8);
   ChartRedraw();
  }

string Signed(const double v) { return (v >= 0 ? "+" : "") + DoubleToString(v, 2); }

string SmartExitText()
  {
   if(!InpSmartExit)
      return "Batch open: closes at its stop loss / take profit.";
   if(g_smEntry <= 0 || g_batchSL <= 0)
      return "Batch open: waiting for the fills.";
   double risk = MathAbs(g_smEntry - g_batchSL);
   int    dir  = (g_batchSL < g_smEntry) ? 1 : -1;
   double L1 = g_smEntry + dir * InpTP1R * risk, L2 = g_smEntry + dir * InpTP2R * risk;
   string lv = "TP1 " + DoubleToString(L1, 2) + "  TP2 " + DoubleToString(L2, 2) + ": ";
   switch(g_smStage)
     {
      case 0: return lv + "TP1 / TP2 / TP3 on the server; at TP1 stops go to entry";
      case 1: return lv + "stops at entry; next: TP2 (stops to TP1)";
      case 2: return lv + "stops at entry; next: TP2 (stops to TP1)";
      case 3: return lv + "stops at TP1; last ones target TP3";
     }
   return lv + "closing";
  }
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

   double openPL = OpenPL();
   SetText("s_v0", DoubleToString(bal, 2) + " " + cur, CLR_TEXT);
   SetText("s_v1", DoubleToString(eq, 2) + " " + cur, CLR_TEXT);
   if(TargetPct() > 0)
      SetText("s_v2", Signed(DayResult()) + " / +" + DoubleToString(TargetMoney(), 2), TargetReached() ? CLR_GREEN : PLColor(DayResult()));
   else
      SetText("s_v2", Signed(DayResult()), PLColor(DayResult()));
   SetText("s_v3", Signed(openPL), PLColor(openPL));
   SetText("s_v4", ModeName() + ": " + IntegerToString(g_batchSize) + " x " + DoubleToString(g_lot, 2), CLR_TEXT);
   for(int m = 0; m < 3; m++)
     {
      color mc = (m == g_mode) ? CLR_BLUE : CLR_GREY;
      ObjectSetInteger(0, P("b_m" + IntegerToString(m)), OBJPROP_BGCOLOR, mc);
      ObjectSetInteger(0, P("b_m" + IntegerToString(m)), OBJPROP_BORDER_COLOR, mc);
     }
   static double shownLot = -1;                    // only rewrite the box when the lot changed,
   if(shownLot != g_lot)                           // so typing in it is not overwritten
     {
      ObjectSetString(0, P("e_lot"), OBJPROP_TEXT, DoubleToString(g_lot, 2));
      shownLot = g_lot;
     }
   ObjectSetString(0, P("mode"), OBJPROP_TEXT, ModeName() + " MODE | " + TFName(InpStructureTF) + " STRUCTURE + TICKS");
   string news = g_newsStatus;
   if(news == "" && g_newsTime > 0)
     {
      int mins = (int)((g_newsTime - TimeTradeServer()) / 60);
      news = TimeToString(g_newsTime, TIME_MINUTES) + (mins >= 0 ? " (in " + IntegerToString(mins) + " min)" : " (live)");
     }
   int phase = NewsPhase();
   SetText("s_v5", news, phase > 0 ? CLR_AMBER : CLR_TEXT);

   SetText("sig1", TFName(InpStructureTF) + " structure: " + g_biasText,
           g_bias > 0 ? CLR_GREEN : (g_bias < 0 ? CLR_RED : CLR_AMBER));
   if(phase > 0 && g_newsName != "")
      SetText("sig2", "News: " + g_newsName, CLR_AMBER);
   else if(g_tickText != "-" && CountOurs() == 0 && g_setupDir != 0)
      SetText("sig2", "Real ticks: " + g_tickText, CLR_MUTED);
   else
      SetText("sig2", StringFormat("Last batch %s   won %d / lost %d positions   %s swing H %s  L %s",
                                   Signed(g_lastBatchPL), g_wins, g_losses, TFName(InpStructureTF),
                                   DoubleToString(g_eSH, 2), DoubleToString(g_eSL, 2)), CLR_MUTED);

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
   string tt = "BATCH POSITIONS (" + IntegerToString(total) + ")";
   if(total > MAX_ROWS)
      tt += "   showing first " + IntegerToString(MAX_ROWS);
   SetText("t_title", tt, CLR_MUTED);
   ShowObj("t_empty", total == 0);

   SetText("f_msg", g_lastMsg, g_lastMsgColor);
   string cond;
   color  cc = CLR_MUTED;
   if(g_risk.Locked())
     {
      cond = "Locked: " + g_risk.LockText();
      cc = CLR_RED;
     }
   else if(g_state == BOT_RUNNING && total > 0)
      cond = SmartExitText();
   else if(g_state == BOT_RUNNING && g_block != "")
     {
      cond = "Waiting: " + g_block;
      cc = CLR_AMBER;
     }
   else if(g_state == BOT_RUNNING)
      cond = "Running: watching the structure.";
   else if(InpAutoStart && ManualStop())
      cond = "Stopped by you: press START to resume.";
   else
      cond = "Stopped.";
   SetText("f_cond", cond, cc);
   ChartRedraw();
  }
//+------------------------------------------------------------------+
