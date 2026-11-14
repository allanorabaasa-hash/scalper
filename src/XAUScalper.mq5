//+------------------------------------------------------------------+
//|                                                 XAUScalper.mq5   |
//|   Market-structure trader for gold and bitcoin (no indicators)    |
//+------------------------------------------------------------------+
#property copyright "Allan"
#property link      "https://github.com/allanorabaasa-hash/scalper"
#property version   "15.00"
#property description "Market structure only (no indicators): M5 swing structure gives the side; an M1 pullback broken"
#property description "on the live tick, confirmed by real tick flow, gives the entry. Batches of 5 x 0.01 (+5 after a win, 5 after a loss)."

#include <XAUScalper\RiskManager.mqh>
#include <XAUScalper\Execution.mqh>
#include <XAUScalper\Journal.mqh>

//==================================================================
//  INPUTS
//==================================================================
input group "Market structure"
input ENUM_TIMEFRAMES InpBiasTF             = PERIOD_M5;     // Structure timeframe (side: HH/HL = buy, LH/LL = sell)
input ENUM_TIMEFRAMES InpEntryTF            = PERIOD_M1;     // Entry timeframe (pullback, broken on the live tick)
input int             InpSwingBars          = 3;             // Swing point = higher/lower than this many candles each side
input double          InpRewardR            = 2.0;           // Take profit at this many times the stop distance
input double          InpBreakevenR         = 1.0;           // Move the stop to entry after this many R in profit (0 = off)
input double          InpMinStopPct         = 0.03;          // Skip if the stop is closer than this % of price (gold ~$1.2)
input double          InpMaxStopPct         = 0.40;          // Gold: skip if the stop is further than this % of price (~$16)
input double          InpMaxStopPctBtc      = 0.80;          // Bitcoin: skip if the stop is further than this % of price (~$540)
input double          InpMaxSpreadOfStop    = 25;            // Skip if the spread is more than this % of the stop distance

input group "Real tick confirmation"
input bool            InpTickConfirm        = true;          // Enter only when the real ticks push in the trade's direction
input int             InpTickWindowSec      = 15;            // Look at the ticks of the last N seconds
input double          InpTickMinRatio       = 60;            // At least this % of price-changing ticks in the trade's direction

input group "Batches"
input double          InpLot                = 0.01;          // Lot per position (fixed)
input int             InpBatchStart         = 5;             // Positions in the first batch (and after a losing batch)
input int             InpBatchStep          = 5;             // Add this many positions after a winning batch
input int             InpBatchMax           = 20;            // Never more than this many positions in one batch
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
double         g_eSH = 0, g_eSL = 0;    // latest M15 swing high / low (panel)
string         g_block        = "";     // why no entry right now
string         g_lastSignal   = "none yet";
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
string ManualStopKey() { return StateKey() + "_manualstop_" + _Symbol; }
bool   ManualStop()    { return GlobalVariableCheck(ManualStopKey()); }
string BatchKey()      { return StateKey() + "_batch_" + _Symbol; }
string TFName(const ENUM_TIMEFRAMES tf) { return StringSubstr(EnumToString(tf), 7); }
bool   IsBtc()         { return StringFind(_Symbol, "BTC") >= 0; }
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
// Latest two swing highs and lows. A swing high is a candle whose high is above the highs of
// InpSwingBars candles on each side (lows mirrored). Shifts count back from the last candle.
struct Swings
  {
   int    nh, nl;
   double h1, h2, l1, l2;   // h1 / l1 = most recent
   int    sh1, sh2, sl1, sl2;
  };

bool FindSwings(const ENUM_TIMEFRAMES tf, Swings &w, MqlRates &r[])
  {
   w.nh = 0;  w.nl = 0;  w.h1 = 0;  w.h2 = 0;  w.l1 = 0;  w.l2 = 0;  w.sh1 = 0;  w.sh2 = 0;  w.sl1 = 0;  w.sl2 = 0;
   ArraySetAsSeries(r, true);
   int n = CopyRates(_Symbol, tf, 0, LOOKBACK, r);
   int k = InpSwingBars;
   if(n < 2 * k + 10)
      return false;
   for(int s = k + 1; s < n - k && (w.nh < 2 || w.nl < 2); s++)
     {
      bool hi = true, lo = true;
      for(int j = 1; j <= k && (hi || lo); j++)
        {
         if(r[s].high <= r[s - j].high || r[s].high <= r[s + j].high)
            hi = false;
         if(r[s].low >= r[s - j].low || r[s].low >= r[s + j].low)
            lo = false;
        }
      if(hi && w.nh < 2)
        {
         if(w.nh == 0) { w.h1 = r[s].high;  w.sh1 = s; }
         else          { w.h2 = r[s].high;  w.sh2 = s; }
         w.nh++;
        }
      if(lo && w.nl < 2)
        {
         if(w.nl == 0) { w.l1 = r[s].low;  w.sl1 = s; }
         else          { w.l2 = r[s].low;  w.sl2 = s; }
         w.nl++;
        }
     }
   return w.nh == 2 && w.nl == 2;
  }

// H1 side: higher highs + higher lows and price above the last higher low = up (mirror = down).
void UpdateBias()
  {
   Swings w;
   MqlRates r[];
   g_bias = 0;
   if(!FindSwings(InpBiasTF, w, r))
     {
      g_biasText = "waiting for " + TFName(InpBiasTF) + " data";
      return;
     }
   double c = r[1].close;
   if(w.h1 > w.h2 && w.l1 > w.l2 && c > w.l1)
     {
      g_bias = 1;
      g_biasText = "UP (higher highs, higher lows)";
     }
   else if(w.h1 < w.h2 && w.l1 < w.l2 && c < w.h1)
     {
      g_bias = -1;
      g_biasText = "DOWN (lower highs, lower lows)";
     }
   else
      g_biasText = "RANGE / unclear: no trade";
  }

// Setup (closed candles): in an up structure, the entry-timeframe pullback makes a lower high
// that has not been broken yet; the bot arms a buy at that level, stop beyond the pullback's
// lowest low. Mirrored for sells. Returns the armed direction (0 = none).
int Setup(double &level, double &stopRef, string &why)
  {
   Swings w;
   MqlRates r[];
   level = 0;  stopRef = 0;  why = "";
   if(!FindSwings(InpEntryTF, w, r))
     {
      why = "waiting for " + TFName(InpEntryTF) + " data";
      return 0;
     }
   g_eSH = w.h1;  g_eSL = w.l1;
   if(g_bias > 0)
     {
      if(!(w.h1 < w.h2))
        {
         why = "up structure: waiting for a pullback (lower high on " + TFName(InpEntryTF) + ")";
         return 0;
        }
      if(r[1].close > w.h1)
        {
         why = "pullback level already broken: waiting for a new pullback";
         return 0;
        }
      double low = r[1].low;
      for(int s = 2; s <= w.sh1; s++)
         low = MathMin(low, r[s].low);
      level = w.h1;  stopRef = low;
      return 1;
     }
   if(g_bias < 0)
     {
      if(!(w.l1 > w.l2))
        {
         why = "down structure: waiting for a pullback (higher low on " + TFName(InpEntryTF) + ")";
         return 0;
        }
      if(r[1].close < w.l1)
        {
         why = "pullback level already broken: waiting for a new pullback";
         return 0;
        }
      double high = r[1].high;
      for(int s = 2; s <= w.sl1; s++)
         high = MathMax(high, r[s].high);
      level = w.l1;  stopRef = high;
      return -1;
     }
   why = g_biasText;
   return 0;
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
      text = "too few ticks";
      return false;
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
  }

void LoadBatch()
  {
   g_batchSize = InpBatchStart;
   if(MQLInfoInteger(MQL_TESTER) || !GlobalVariableCheck(BatchKey() + "_size"))
      return;
   g_batchSize   = (int)GlobalVariableGet(BatchKey() + "_size");
   g_batchId     = (int)GlobalVariableGet(BatchKey() + "_id");
   g_batchOpen   = GlobalVariableGet(BatchKey() + "_open") > 0;
   g_batchStart  = (datetime)(long)GlobalVariableGet(BatchKey() + "_start");
   g_lastBatchPL = GlobalVariableGet(BatchKey() + "_last");
   g_batchSize   = MathMax(InpBatchStart, MathMin(g_batchSize, InpBatchMax));
  }

// Net result of the batch: every closing deal of this EA on this symbol since the batch opened.
double BatchResult()
  {
   if(!HistorySelect(g_batchStart - 1, TimeCurrent() + 60))
      return 0;
   double pl = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0 || HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol || HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic)
         continue;
      pl += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP)
            + HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
     }
   return pl;
  }

// A batch is finished when none of its positions is open: size up after a win, back to start after a loss.
void CheckBatchEnd()
  {
   if(!g_batchOpen || CountOurs() > 0)
      return;
   g_lastBatchPL = BatchResult();
   g_batchOpen = false;
   if(g_lastBatchPL > 0)
      g_batchSize = MathMin(g_batchSize + InpBatchStep, InpBatchMax);
   else
      g_batchSize = InpBatchStart;
   SaveBatch();
   Msg(StringFormat("Batch %d closed %+.2f: next batch %d positions", g_batchId, g_lastBatchPL, g_batchSize),
       g_lastBatchPL > 0 ? CLR_GREEN : CLR_RED);
  }

// Opens the batch: all positions share the structure stop and the R-multiple target.
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
   double tpPrice = entry + dir * InpRewardR * dist;

   // batch size, trimmed so the whole batch never risks more than InpMaxBatchRiskPct of the balance
   int n = MathMin(g_batchSize, InpBatchMax);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double riskPerPos = (ts > 0) ? dist / ts * tv * InpLot : 0;
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
   int opened = 0;
   for(int i = 0; i < n; i++)
     {
      SymbolInfoTick(_Symbol, tk);
      double px = dir > 0 ? tk.ask : tk.bid;
      double sl = dir * (px - stopPrice), tp = dir * (tpPrice - px);
      if(sl <= 0 || tp <= 0)
         break;
      string err;
      double fill = 0;
      ulong pos = g_exec.Open(dir, InpLot, sl, tp, InpTradeComment + ":B" + IntegerToString(g_batchId), err, fill);
      if(pos == 0)
        {
         Msg("Order failed: " + err, CLR_RED);
         break;
        }
      string e2;
      if(PositionSelectByTicket(pos))
         if(MathAbs(PositionGetDouble(POSITION_SL) - stopPrice) > _Point || MathAbs(PositionGetDouble(POSITION_TP) - tpPrice) > _Point)
            g_exec.SetSLTP(pos, stopPrice, tpPrice, e2);
      JournalOpen((long)pos, dir, "STRUCTURE", why, InpLot, fill, tk.ask - tk.bid, dist, InpRewardR * dist, 0,
                  riskPerPos, 0, 0, "batch " + IntegerToString(g_batchId));
      opened++;
     }
   if(opened == 0)
     {
      g_batchId--;
      return false;
     }
   g_batchOpen = true;
   SaveBatch();
   g_lastSignal = StringFormat("%s: %s %d x %.2f, stop %s, target %s", why, dir > 0 ? "BUY" : "SELL", opened, InpLot,
                               DoubleToString(stopPrice, _Digits), DoubleToString(tpPrice, _Digits));
   Msg(g_lastSignal, CLR_BLUE);
   return true;
  }

// Stop to entry once a position is InpBreakevenR in profit (only ever in the position's favour).
void ManageBreakeven()
  {
   if(InpBreakevenR <= 0)
      return;
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !IsOurs())
         continue;
      int    d    = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      if(sl == 0 || d * (open - sl) <= 0)
         continue;                                  // already at breakeven or better
      double risk = d * (open - sl);
      double px   = d > 0 ? tk.bid : tk.ask;
      if(d * (px - open) >= InpBreakevenR * risk)
        {
         string err;
         if(g_exec.MoveStop(t, open, err))
            Msg(StringFormat("+%.1fR: stop to breakeven on #%I64u", InpBreakevenR, t), CLR_MUTED);
        }
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
   if(InpLot <= 0 || InpBatchStart < 1 || InpBatchMax < InpBatchStart || InpRewardR <= 0 || InpSwingBars < 1)
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
   ManageBreakeven();
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
   if(CountOurs() > 0)
     {
      g_block = "";
      return;                                     // one batch at a time
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

   // 1. arm the setup once per closed entry-timeframe candle (structure on closed candles only)
   datetime bar = iTime(_Symbol, InpEntryTF, 0);
   if(bar != 0 && bar != g_lastEntryBar)
     {
      UpdateBias();
      g_setupDir = Setup(g_level, g_stopRef, g_setupWhy);
      g_lastEntryBar = bar;
     }
   if(g_setupDir == 0)
     {
      g_block = g_setupWhy;
      return;
     }
   if(g_level == g_lastTraded)
     {
      g_block = "this break was already traded: waiting for a new pullback";
      return;
     }

   // 2. trigger on the live tick: price breaks the level ...
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return;
   double px = tk.bid;
   if(g_setupDir * (px - g_level) <= 0)
     {
      g_block = StringFormat("%s armed: waiting for price to break %s", g_setupDir > 0 ? "BUY" : "SELL",
                             DoubleToString(g_level, _Digits));
      return;
     }
   // ... and the real ticks push the same way
   if(!TickFlowConfirms(g_setupDir, g_tickText))
     {
      g_block = "level broken, ticks not confirming (" + g_tickText + ")";
      return;
     }
   // stop beyond the pullback's extreme, including the current candle
   double buffer = (tk.ask - tk.bid) + px * 0.0002;
   double stop = (g_setupDir > 0) ? MathMin(g_stopRef, iLow(_Symbol, InpEntryTF, 0)) - buffer
                                  : MathMax(g_stopRef, iHigh(_Symbol, InpEntryTF, 0)) + buffer;
   g_block = "";
   g_lastTraded = g_level;
   OpenBatch(g_setupDir, stop, TFName(InpEntryTF) + " break + ticks");
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
   MkLabel("mode", 150, 12, "MARKET STRUCTURE (" + TFName(InpBiasTF) + " / " + TFName(InpEntryTF) + ")", CLR_BLUE, 8,
           "Arial Bold");
   MkRect("pill", PANEL_W - 118, 8, 106, 20, CLR_GREY, CLR_GREY);
   MkLabel("pill_t", PANEL_W - 65, 18, "STOPPED", clrWhite, 8, "Arial Bold", ANCHOR_CENTER);
   MkButton("b_min", PANEL_W - 146, 8, 22, 20, "-", CLR_GREY, clrWhite, 10);
   MkLabel("info", 14, 44, " ", CLR_MUTED, 8);

   string titles[6] = {"BALANCE", "EQUITY", "DAY P/L", "OPEN P/L", "NEXT BATCH", "NEXT HIGH-IMPACT NEWS"};
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

   MkLabel("t_title", 14, 226, "BATCH POSITIONS (0)", CLR_MUTED, 7, "Arial Bold");
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
color  PLColor(const double v){ return v > 0 ? CLR_GREEN : (v < 0 ? CLR_RED : CLR_TEXT); }

void UpdatePanel()
  {
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE))
      return;
   UpdateBias();
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
   SetText("s_v2", Signed(g_risk.DayPL()), PLColor(g_risk.DayPL()));
   SetText("s_v3", Signed(openPL), PLColor(openPL));
   SetText("s_v4", IntegerToString(g_batchSize) + " x " + DoubleToString(InpLot, 2), CLR_TEXT);
   string news = g_newsStatus;
   if(news == "" && g_newsTime > 0)
     {
      int mins = (int)((g_newsTime - TimeTradeServer()) / 60);
      news = TimeToString(g_newsTime, TIME_MINUTES) + (mins >= 0 ? " (in " + IntegerToString(mins) + " min)" : " (live)");
     }
   int phase = NewsPhase();
   SetText("s_v5", news, phase > 0 ? CLR_AMBER : CLR_TEXT);

   SetText("sig1", TFName(InpBiasTF) + " structure: " + g_biasText,
           g_bias > 0 ? CLR_GREEN : (g_bias < 0 ? CLR_RED : CLR_AMBER));
   if(phase > 0 && g_newsName != "")
      SetText("sig2", "News: " + g_newsName, CLR_AMBER);
   else if(g_tickText != "-" && CountOurs() == 0 && g_setupDir != 0)
      SetText("sig2", "Real ticks: " + g_tickText, CLR_MUTED);
   else
      SetText("sig2", StringFormat("Last batch %s   won %d / lost %d positions   %s swing H %s  L %s",
                                   Signed(g_lastBatchPL), g_wins, g_losses, TFName(InpEntryTF),
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
      cond = "Batch open: closes at its stop loss / take profit (breakeven at +" + DoubleToString(InpBreakevenR, 1) + "R).";
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
