//+------------------------------------------------------------------+
//|                                                 XAUScalper.mq5   |
//|        XAUUSD Expert Advisor with on-chart control panel          |
//+------------------------------------------------------------------+
#property copyright "Allan"
#property link      "https://github.com/allanorabaasa-hash/scalper"
#property version   "5.60"
#property description "Five strategies selected by a market regime detector."
#property description "Every entry is approved and sized by an independent risk manager."

#include <XAUScalper\RiskManager.mqh>
#include <XAUScalper\Common.mqh>
#include <XAUScalper\Levels.mqh>
#include <XAUScalper\StrategyBase.mqh>
#include <XAUScalper\StratPullback.mqh>
#include <XAUScalper\StratBreakout.mqh>
#include <XAUScalper\StratMeanReversion.mqh>
#include <XAUScalper\StratSweep.mqh>
#include <XAUScalper\StratMomentum.mqh>
#include <XAUScalper\StratFVG.mqh>
#include <XAUScalper\StratSRBounce.mqh>
#include <XAUScalper\Regime.mqh>
#include <XAUScalper\Filters.mqh>
#include <XAUScalper\Execution.mqh>
#include <XAUScalper\Journal.mqh>

//==================================================================
//  INPUTS
//==================================================================
input group "General"
input long          InpMagic                = 20261112;      // Magic number (unique per EA)
input string        InpTradeComment         = "XAUScalper";  // Order comment prefix
input int           InpSlippagePoints       = 30;            // Max slippage (points)
input bool          InpJournal              = true;          // Trade journal (Common/Files/XAUScalper_trades.csv)
input bool          InpAllowLive            = false;         // Allow trading on a REAL account (only after demo validation)
input bool          InpAutoStart            = true;          // Start/resume automatically whenever connected (STOP is remembered)

input group "Strategy selection"
input ENUM_STRATEGY_MODE InpMode            = MODE_ALL;      // Mode (All = testing; Auto = regime selects; or one strategy)
input bool          InpTestingMode          = true;          // TESTING: daily loss limit, loss streak, trade cap, cooldown and emergency drawdown OFF
input bool          InpEnablePullback       = true;          // Enable Strategy 1: EMA trend pullback
input bool          InpEnableBreakout       = false;         // Enable Strategy 2: breakout + retest (off: PF 0.85 / 0.76 in tests 1-2)
input bool          InpEnableMeanRev        = false;         // Enable Strategy 3: mean reversion (off: 1 trade in 6 weeks)
input bool          InpEnableSweep          = false;         // Enable Strategy 4: liquidity sweep (off: PF 0.95 / 0.97 in tests 1-2)
input bool          InpEnableMomentum       = true;          // Enable Strategy 5: momentum scalping
input bool          InpEnableFVG            = true;          // Enable Strategy 6: fair value gap retracement
input bool          InpEnableSRBounce       = false;         // Enable Strategy 7: support/resistance bounce (off: PF 0.75 in test 2)

input group "Market regime detector (M15)"
input double        InpRegMinScore          = 0.75;          // Rule-agreement score needed (0-1; not a probability)
input double        InpRegDangerATR         = 2.5;           // Dangerous: ATR above this x its 50-bar average
input double        InpRegTrendADX          = 22;            // Trending: ADX at least
input double        InpRegMomentumADX       = 30;            // Strong momentum: ADX above
input double        InpRegRangeADX          = 18;            // Ranging: ADX below
input double        InpRegSqueezePct        = 0.20;          // Breakout: band-width percentile counted as squeeze

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
input double        InpMaxCostShare         = 0.25;          // Reject if spread > this share of the target distance

input group "Market filters (hours are broker server time)"
input double        InpMaxSpread            = 0.40;          // Max spread in price (0 = off)
input double        InpMaxSpreadATR         = 0.20;          // Max spread / ATR(M5) (0 = off)
input int           InpRolloverFrom         = 21;            // No entries from server hour (daily rollover)...
input int           InpRolloverTo           = 23;            // ...until server hour (equal = off)
input int           InpFridayLastHour       = 19;            // Friday: no new entries from this hour (0 = off)
input int           InpMondayFirstHour      = 1;             // Monday: no new entries before this hour (0 = off)
input bool          InpUseNews              = true;          // News filter (MT5 economic calendar, high-impact USD)
input int           InpNewsBeforeMin        = 30;            // Minutes before news: no entries
input int           InpNewsAfterMin         = 30;            // Minutes after news: no entries
input bool          InpBlockIfNoNewsData    = false;         // Block entries when calendar data is unavailable
input double        InpMaxM1RangeATR        = 4.0;           // Abnormal volatility: M1 range above this x ATR(M1) (0 = off)
input int           InpVolPauseMin          = 15;            // Pause after abnormal volatility (minutes)
input int           InpMaxTickAgeSec        = 60;            // Stale prices: no tick for this many seconds (0 = off)

input group "Sessions for key levels (server hours)"
input int           InpAsiaStart            = 0;             // Asian session start
input int           InpAsiaEnd              = 7;             // Asian session end
input int           InpLondonStart          = 7;             // London session start
input int           InpLondonEnd            = 12;            // London session end
input int           InpNYStart              = 12;            // New York session start
input int           InpNYEnd                = 21;            // New York session end

input group "Strategy 1: EMA trend pullback (M15 trend, M5 setup, M1 entry)"
input int           InpS1_Lookback          = 6;             // M5 bars searched for the pullback
input double        InpS1_RewardR           = 1.8;           // Take profit (x risk)
input double        InpS1_MaxSLATR          = 2.5;           // Max stop (x ATR M5), wider = skip
input double        InpS1_BE_R              = 1.0;           // Breakeven at (x risk, 0 = off)
input int           InpS1_MaxHoldMin        = 180;           // Max holding time (minutes)
input int           InpS1_StaleMin          = 0;             // Time exit if not at 0.3R after N minutes (0 = off)
input bool          InpS1_MomentumExit      = false;         // Exit when an M5 bar closes beyond EMA 50

input group "Strategy 2: breakout + retest (M5)"
input int           InpS2_MaxBars           = 12;            // Max bars between breakout and confirmation
input double        InpS2_MinRangeATR       = 1.0;           // Breakout candle range at least (x ATR)
input double        InpS2_RewardR           = 2.0;           // Take profit (x risk)
input double        InpS2_MaxSLATR          = 2.5;           // Max stop (x ATR), wider = skip
input double        InpS2_BE_R              = 1.0;           // Breakeven at (x risk, 0 = off)
input double        InpS2_TrailStartR       = 1.5;           // Trailing starts at (x risk, 0 = off)
input int           InpS2_MaxHoldMin        = 240;           // Max holding time (minutes)

input group "Strategy 3: RSI + Bollinger mean reversion (M5)"
input double        InpS3_RsiOversold       = 30;            // RSI oversold
input double        InpS3_RsiOverbought     = 70;            // RSI overbought
input double        InpS3_MaxADX            = 25;            // Only when ADX(M5) below
input double        InpS3_MinRewardR        = 1.0;           // Min distance to middle band (x risk)
input int           InpS3_MaxHoldMin        = 90;            // Max holding time (minutes)

input group "Strategy 4: liquidity sweep + structure shift (M5)"
input int           InpS4_SweepBars         = 8;             // Bars back in which the sweep may be
input double        InpS4_MinDepthATR       = 0.15;          // Min sweep depth beyond the level (x ATR)
input double        InpS4_RewardR           = 2.5;           // Take profit (x risk)
input double        InpS4_MaxSLATR          = 3.0;           // Max stop (x ATR), wider = skip
input double        InpS4_BE_R              = 1.0;           // Breakeven at (x risk, 0 = off)
input double        InpS4_TrailStartR       = 2.0;           // Trailing starts at (x risk, 0 = off)
input int           InpS4_MaxHoldMin        = 240;           // Max holding time (minutes)

input group "Strategy 5: momentum scalping"
input ENUM_TIMEFRAMES InpS5_TF              = PERIOD_M5;     // Timeframe
input double        InpS5_RewardR           = 1.8;           // Take profit (x risk)
input double        InpS5_MinADX            = 20;            // ADX above
input double        InpS5_BE_R              = 1.0;           // Breakeven at (x risk, 0 = off)
input double        InpS5_TrailStartR       = 1.0;           // Trailing starts at (x risk, 0 = off)
input int           InpS5_MaxHoldMin        = 60;            // Max holding time (minutes)

input group "Strategy 6: fair value gap retracement (M5, with M15 trend)"
input int           InpS6_MaxAge            = 20;            // Max bars since the gap formed
input double        InpS6_MinGapATR         = 0.30;          // Min gap size (x ATR)
input double        InpS6_DisplacementATR   = 1.00;          // Min body of the middle candle (x ATR)
input double        InpS6_RewardR           = 2.0;           // Take profit (x risk)
input double        InpS6_MaxSLATR          = 2.5;           // Max stop (x ATR), wider = skip
input double        InpS6_BE_R              = 1.0;           // Breakeven at (x risk, 0 = off)
input int           InpS6_MaxHoldMin        = 180;           // Max holding time (minutes)

input group "Strategy 7: support/resistance bounce (M5)"
input double        InpS7_TolATR            = 0.15;          // Touch tolerance above support / below resistance (x ATR)
input double        InpS7_MaxPierceATR      = 0.30;          // Max pierce through the level (x ATR)
input double        InpS7_WickRatio         = 0.50;          // Rejection wick at least this share of the candle
input double        InpS7_MaxADX            = 30;            // No bounce trades against an M15 trend with ADX above
input double        InpS7_RewardR           = 2.0;           // Take profit (x risk)
input double        InpS7_MaxSLATR          = 2.0;           // Max stop (x ATR), wider = skip
input double        InpS7_BE_R              = 1.0;           // Breakeven at (x risk, 0 = off)
input int           InpS7_MaxHoldMin        = 180;           // Max holding time (minutes)

input group "Connection safety"
input bool          InpPauseOnReconnect     = true;          // Pause bot after a connection drop
input bool          InpCloseOnReconnect     = false;         // Close all positions after a connection drop

input group "Panel"
input int           InpPanelX               = 10;            // Panel X offset
input int           InpPanelY               = 30;            // Panel Y offset
input int           InpPerfDays             = 30;            // Strategy performance: last N days

//==================================================================
//  STATE
//==================================================================
enum ENUM_BOT_STATE
  {
   BOT_STOPPED = 0,
   BOT_RUNNING = 1,
   BOT_PAUSED  = 2
  };

#define MAX_ROWS 3
#define PREFIX   "XS_"

CRiskManager   g_risk;
CExecution     g_exec;
CFilters       g_filters;
CRegime        g_regime;
CStrategy     *g_s[STRAT_COUNT];
bool           g_enabled[STRAT_COUNT];

ENUM_BOT_STATE g_state           = BOT_STOPPED;
bool           g_wasConnected    = true;
string         g_lastMsg         = "Ready. Press START to begin.";
color          g_lastMsgColor    = clrSilver;
string         g_engineStatus    = "stopped";
int            g_active          = STRAT_NONE;
ulong          g_rowTicket[MAX_ROWS];
bool           g_collapsed       = false;
datetime       g_lastManage      = 0;
datetime       g_manageBackoff   = 0;
datetime       g_lastExitBar     = 0;
datetime       g_lastPerf        = 0;

long           g_reasonPos[];          // positions closed by the bot, and why (journal)
string         g_reasonText[];

// Strategy performance (last InpPerfDays) and recent trades, for the panel
int            g_pfTrades[STRAT_COUNT];
int            g_pfWins[STRAT_COUNT];
double         g_pfWin[STRAT_COUNT];
double         g_pfLoss[STRAT_COUNT];
string         g_recent[3];

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
#define PANEL_H  640
#define ROW_Y0   272
#define ROW_H    22

//==================================================================
//  POSITION INFO (initial risk, for breakeven/trailing and R-multiples)
//==================================================================
string PosKey(const ulong pos, const string field) { return "XSI_" + IntegerToString((long)pos) + "_" + field; }

void SavePosInfo(const ulong pos, const double riskDist, const double riskMoney)
  {
   GlobalVariableSet(PosKey(pos, "r"), riskDist);
   GlobalVariableSet(PosKey(pos, "m"), riskMoney);
  }

double PosInfo(const ulong pos, const string field)
  {
   string k = PosKey(pos, field);
   return GlobalVariableCheck(k) ? GlobalVariableGet(k) : 0.0;
  }

void DeletePosInfo(const ulong pos)
  {
   GlobalVariableDel(PosKey(pos, "r"));
   GlobalVariableDel(PosKey(pos, "m"));
  }

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
//  INITIALISATION
//==================================================================
void MakePlan(ManagePlan &m, const double beR, const double trailStartR, const double trailATR,
              const int maxHoldMin, const int staleMin, const double staleR, const bool momentumExit = true)
  {
   m.momentumExit = momentumExit;
   m.beR = beR;  m.trailStartR = trailStartR;  m.trailATR = trailATR;
   m.maxHoldMin = maxHoldMin;  m.staleMin = staleMin;  m.staleR = staleR;
  }

bool InitStrategies(const SessionHours &sh)
  {
   for(int i = 0; i < STRAT_COUNT; i++)
      g_s[i] = NULL;

   PullbackParams p1;
   p1.lookback = InpS1_Lookback;  p1.touchATR = 0.10;  p1.minGapATR = 0.20;  p1.minSlopeATR = 0.10;
   p1.rsiLevel = 50;  p1.slBufferATR = 0.30;  p1.minSLATR = 0.80;  p1.maxSLATR = InpS1_MaxSLATR;
   p1.rewardR = InpS1_RewardR;
   MakePlan(p1.plan, InpS1_BE_R, 0.0, 0.0, InpS1_MaxHoldMin, InpS1_StaleMin, 0.3, InpS1_MomentumExit);
   CStratPullback *s1 = new CStratPullback();
   bool ok1 = s1.Init(_Symbol, p1);
   g_s[STRAT_PULLBACK] = s1;

   BreakoutParams p2;
   p2.maxBarsSinceBreak = InpS2_MaxBars;  p2.minBodyRatio = 0.60;  p2.minRangeATR = InpS2_MinRangeATR;
   p2.minBeyondATR = 0.20;  p2.retestTolATR = 0.15;  p2.failCloseATR = 0.10;  p2.slBufferATR = 0.20;
   p2.minSLATR = 0.50;  p2.maxSLATR = InpS2_MaxSLATR;  p2.rewardR = InpS2_RewardR;
   p2.swingBars = 60;  p2.swingStrength = 3;
   MakePlan(p2.plan, InpS2_BE_R, InpS2_TrailStartR, 1.0, InpS2_MaxHoldMin, 90, 0.3);
   CStratBreakout *s2 = new CStratBreakout();
   bool ok2 = s2.Init(_Symbol, p2, sh);
   g_s[STRAT_BREAKOUT] = s2;

   MeanRevParams p3;
   p3.rsiOversold = InpS3_RsiOversold;  p3.rsiOverbought = InpS3_RsiOverbought;  p3.maxADX = InpS3_MaxADX;
   p3.maxEmaSlopeATR = 0.50;  p3.slBufferATR = 0.30;  p3.minSLATR = 0.50;  p3.maxSLATR = 2.0;
   p3.minRewardR = InpS3_MinRewardR;
   MakePlan(p3.plan, 0.0, 0.0, 0.0, InpS3_MaxHoldMin, 45, 0.2);
   CStratMeanRev *s3 = new CStratMeanRev();
   bool ok3 = s3.Init(_Symbol, p3);
   g_s[STRAT_MEANREV] = s3;

   SweepParams p4;
   p4.sweepBars = InpS4_SweepBars;  p4.minDepthATR = InpS4_MinDepthATR;  p4.maxDepthATR = 2.0;
   p4.mssLookback = 20;  p4.mssStrength = 2;  p4.slBufferATR = 0.20;  p4.minSLATR = 0.50;
   p4.maxSLATR = InpS4_MaxSLATR;  p4.rewardR = InpS4_RewardR;  p4.swingBars = 60;  p4.swingStrength = 3;
   MakePlan(p4.plan, InpS4_BE_R, InpS4_TrailStartR, 1.5, InpS4_MaxHoldMin, 120, 0.3);
   CStratSweep *s4 = new CStratSweep();
   bool ok4 = s4.Init(_Symbol, p4, sh);
   g_s[STRAT_SWEEP] = s4;

   MomentumParams p5;
   p5.crossBars = 3;  p5.rsiBuy = 55;  p5.rsiSell = 45;  p5.minADX = InpS5_MinADX;  p5.volAvgBars = 20;
   p5.breakBars = 5;  p5.maxCandleATR = 2.0;  p5.maxExtensionATR = 1.5;  p5.slBufferATR = 0.20;
   p5.minSLATR = 0.80;  p5.maxSLATR = 2.0;  p5.rewardR = InpS5_RewardR;
   MakePlan(p5.plan, InpS5_BE_R, InpS5_TrailStartR, 1.0, InpS5_MaxHoldMin, 20, 0.3);
   CStratMomentum *s5 = new CStratMomentum();
   bool ok5 = s5.Init(_Symbol, InpS5_TF, p5);
   g_s[STRAT_MOMENTUM] = s5;

   FVGParams p6;
   p6.maxAge = InpS6_MaxAge;  p6.minGapATR = InpS6_MinGapATR;  p6.displacementATR = InpS6_DisplacementATR;
   p6.slBufferATR = 0.30;  p6.minSLATR = 0.60;  p6.maxSLATR = InpS6_MaxSLATR;  p6.rewardR = InpS6_RewardR;
   MakePlan(p6.plan, InpS6_BE_R, 0.0, 0.0, InpS6_MaxHoldMin, 60, 0.3);
   CStratFVG *s6 = new CStratFVG();
   bool ok6 = s6.Init(_Symbol, p6);
   g_s[STRAT_FVG] = s6;

   SRBounceParams p7;
   p7.tolATR = InpS7_TolATR;  p7.maxPierceATR = InpS7_MaxPierceATR;  p7.wickRatio = InpS7_WickRatio;
   p7.maxADX = InpS7_MaxADX;  p7.slBufferATR = 0.20;  p7.minSLATR = 0.50;  p7.maxSLATR = InpS7_MaxSLATR;
   p7.rewardR = InpS7_RewardR;  p7.swingBars = 60;  p7.swingStrength = 3;
   MakePlan(p7.plan, InpS7_BE_R, 0.0, 0.0, InpS7_MaxHoldMin, 60, 0.3);
   CStratSRBounce *s7 = new CStratSRBounce();
   bool ok7 = s7.Init(_Symbol, p7, sh);
   g_s[STRAT_SRBOUNCE] = s7;

   g_enabled[STRAT_PULLBACK] = InpEnablePullback;
   g_enabled[STRAT_BREAKOUT] = InpEnableBreakout;
   g_enabled[STRAT_MEANREV]  = InpEnableMeanRev;
   g_enabled[STRAT_SWEEP]    = InpEnableSweep;
   g_enabled[STRAT_MOMENTUM] = InpEnableMomentum;
   g_enabled[STRAT_FVG]      = InpEnableFVG;
   g_enabled[STRAT_SRBOUNCE] = InpEnableSRBounce;

   return ok1 && ok2 && ok3 && ok4 && ok5 && ok6 && ok7;
  }

string StateKey()
  {
   return "XS_state_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + IntegerToString(InpMagic);
  }

int OnInit()
  {
   ArrayInitialize(g_rowTicket, 0);
   ChartSetInteger(0, CHART_FOREGROUND, false);
   ChartSetInteger(0, CHART_SHOW_ONE_CLICK, false);   // MT5 one-click box would cover the panel

   if(InpRiskPercent <= 0 || InpMaxPositions < 1)
     {
      Print("XAUScalper: Risk % must be above 0 and Max positions at least 1");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_exec.Init(_Symbol, InpMagic, InpSlippagePoints);
   JournalInit(InpJournal);

   RiskConfig cfg;
   cfg.magic                = InpMagic;
   cfg.riskPct              = InpRiskPercent;
   cfg.minLotMaxRiskPct     = InpMinLotMaxRiskPct;
   cfg.maxDailyLossPct      = InpTestingMode ? 0.0 : InpMaxDailyLossPct;
   cfg.dailyTargetPct       = InpDailyTargetPct;
   cfg.maxConsecLosses      = InpTestingMode ? 0 : InpMaxConsecLosses;
   cfg.maxPositions         = InpMaxPositions;
   cfg.maxDailyTrades       = InpTestingMode ? 0 : InpMaxDailyTrades;
   cfg.minSecBetweenTrades  = InpMinSecBetweenTrades;
   cfg.cooldownAfterLossMin = InpTestingMode ? 0 : InpCooldownAfterLossMin;
   cfg.emergencyDDPct       = InpTestingMode ? 0.0 : InpEmergencyDDPct;
   cfg.emergencyMarginLevel = InpEmergencyMarginLevel;
   cfg.marginBufferPct      = InpMarginBufferPct;
   cfg.emergencyPolicy      = InpEmergencyPolicy;
   g_risk.Init(_Symbol, cfg);

   SessionHours sh;
   sh.asiaStart = InpAsiaStart;  sh.asiaEnd = InpAsiaEnd;  sh.londonStart = InpLondonStart;
   sh.londonEnd = InpLondonEnd;  sh.nyStart = InpNYStart;  sh.nyEnd = InpNYEnd;

   FilterParams fp;
   fp.maxSpread = InpMaxSpread;  fp.maxSpreadATR = InpMaxSpreadATR;
   fp.rolloverFromHour = InpRolloverFrom;  fp.rolloverToHour = InpRolloverTo;
   fp.fridayLastHour = InpFridayLastHour;  fp.mondayFirstHour = InpMondayFirstHour;
   fp.useNews = InpUseNews;  fp.newsBeforeMin = InpNewsBeforeMin;  fp.newsAfterMin = InpNewsAfterMin;
   fp.blockIfNewsUnknown = InpBlockIfNoNewsData;  fp.maxM1RangeATR = InpMaxM1RangeATR;
   fp.volPauseMin = InpVolPauseMin;  fp.maxTickAgeSec = InpMaxTickAgeSec;

   RegimeParams rp;
   rp.minScore = InpRegMinScore;  rp.dangerATRMult = InpRegDangerATR;  rp.trendADX = InpRegTrendADX;
   rp.momentumADX = InpRegMomentumADX;  rp.rangeADX = InpRegRangeADX;  rp.squeezePct = InpRegSqueezePct;

   bool ok = g_filters.Init(_Symbol, fp);
   ok = g_regime.Init(_Symbol, rp, sh) && ok;
   ok = InitStrategies(sh) && ok;
   if(!ok)
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

   g_wasConnected = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);

   if(StringFind(_Symbol, "XAU") < 0 && StringFind(_Symbol, "GOLD") < 0)
      Msg("Warning: attach this EA to a gold (XAUUSD) chart.", CLR_AMBER);

   if(!MQLInfoInteger(MQL_TESTER))
     {
      BuildPanel();
      RefreshPerformance();
      UpdatePanel();
     }
   EventSetMillisecondTimer(500);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(reason == REASON_CHARTCHANGE || reason == REASON_PARAMETERS)
      GlobalVariableSet(StateKey(), (double)g_state);

   for(int i = 0; i < STRAT_COUNT; i++)
      if(CheckPointer(g_s[i]) == POINTER_DYNAMIC)
        {
         delete g_s[i];
         g_s[i] = NULL;
        }
   EventKillTimer();
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

//==================================================================
//  MAIN LOOP
//==================================================================
void OnTick()
  {
   if(MQLInfoInteger(MQL_TESTER))
     {
      // The tester does not run the timer: update state once per second.
      static datetime last = 0;
      if(TimeCurrent() != last)
        {
         last = TimeCurrent();
         g_filters.Update();
         if(g_risk.Update())
            ApplyEmergency();
        }
     }
   g_regime.Update();
   ManagePositions();          // runs even when stopped: open trades stay managed
   if(g_state == BOT_RUNNING)
      Engine();
  }

void OnTimer()
  {
   CheckConnection();
   CheckAutoStart();
   g_filters.Update();
   g_regime.Update();
   ManagePositions();
   if(g_risk.Update())
      ApplyEmergency();
   if(!MQLInfoInteger(MQL_TESTER))
     {
      if(TimeCurrent() - g_lastPerf >= 15)
         RefreshPerformance();
      UpdatePanel();
     }
  }

// Which strategy may trade now ("" status explains when none).
int ActiveStrategy(string &why)
  {
   ENUM_REGIME rg = g_regime.Regime();
   if(rg == REGIME_DANGER)
     {
      why = "dangerous market (" + g_regime.Detail() + "): waiting";
      return STRAT_NONE;
     }
   int id;
   if(InpMode == MODE_ALL)
     {
      why = "";
      return STRAT_ALL;
     }
   if(InpMode != MODE_AUTO)
      id = StrategyForMode(InpMode);
   else
     {
      id = StrategyForRegime(rg);
      if(id == STRAT_NONE)
        {
         why = "market regime uncertain: waiting";
         return STRAT_NONE;
        }
     }
   if(!g_enabled[id])
     {
      why = StrategyCode(id) + " is disabled for regime " + RegimeName(rg) + ": waiting";
      return STRAT_NONE;
     }
   why = "";
   return id;
  }

// The engine: market + risk checks, regime -> strategy, signal, risk, execute.
void Engine()
  {
   string pre = PreEntryBlock();
   if(pre != "")
     {
      g_engineStatus = "not trading: " + pre;
      return;
     }
   string why;
   int id = ActiveStrategy(why);
   g_active = id;
   if(id == STRAT_NONE)
     {
      g_engineStatus = why;
      return;
     }
   g_engineStatus = "";

   TradeSignal s;
   ClearSignal(s);
   if(id == STRAT_ALL)
     {
      // Every enabled strategy evaluates its own new bar; the first valid signal trades.
      bool found = false;
      for(int i = 0; i < STRAT_COUNT && !found; i++)
        {
         if(!g_enabled[i] || CheckPointer(g_s[i]) == POINTER_INVALID)
            continue;
         if(g_s[i].Evaluate(s))
            found = true;
        }
      if(!found)
         return;
     }
   else if(!g_s[id].Evaluate(s))
      return;

   if(HasOppositePosition(s.dir))
     {
      Reject(StrategyCode(s.strat) + " signal rejected: conflicting open position");
      return;
     }
   OpenSignal(s);
  }

bool HasOppositePosition(const int dir)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0 || !IsOurs())
         continue;
      bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      if((dir > 0) != isBuy)
         return true;
     }
   return false;
  }

void OpenSignal(const TradeSignal &s)
  {
   string name = StrategyCode(s.strat);
   string side = (s.dir > 0) ? "BUY" : "SELL";

   // Broker minimum stop distance; keep the same reward multiple if the stop is widened.
   double minD   = g_exec.MinStopDistance();
   double slDist = MathMax(s.slDist, minD);
   double tpDist = s.tpDist;
   if(tpDist > 0 && slDist > s.slDist && s.slDist > 0 && s.strat != STRAT_MEANREV)
      tpDist = s.tpDist / s.slDist * slDist;
   if(tpDist > 0)
      tpDist = MathMax(tpDist, minD);

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;
   double spread = tick.ask - tick.bid;
   if(tpDist > 0 && InpMaxCostShare > 0 && spread > InpMaxCostShare * tpDist)
     {
      Reject(StringFormat("%s %s rejected: spread %.2f too large for a %.2f target", name, side, spread, tpDist));
      return;
     }

   string reason = "";
   double riskPct = 0;
   double lots = g_risk.SizeTrade(s.dir, slDist, reason, riskPct);
   if(lots <= 0)
     {
      Reject(name + " " + side + " rejected: " + reason);
      return;
     }

   string err;
   double fill;
   ulong pos = g_exec.Open(s.dir, lots, slDist, tpDist, InpTradeComment + ":" + name, err, fill);
   if(pos == 0)
     {
      Msg(name + " " + side + ": " + err, CLR_RED);
      return;
     }

   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0)
      tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double riskMoney  = lots * RM_LossPerLot(slDist, tickSize, tickValue);
   double spreadCost = (tickSize > 0) ? spread / tickSize * tickValue * lots : 0.0;
   SavePosInfo(pos, slDist, riskMoney);
   JournalOpen((long)pos, s.dir, name, RegimeName(g_regime.Regime()), lots, fill, spread, slDist, tpDist,
               s.atr, riskMoney, riskPct, spreadCost, reason);
   Msg(StringFormat("%s %s %.2f lots @ %s, risk %.1f%%", name, side, lots, DoubleToString(fill, _Digits), riskPct),
       CLR_GREEN);
   g_risk.Update();
  }

//==================================================================
//  POSITION MANAGEMENT
//==================================================================
// Max holding time, stale-trade exit, momentum-loss exit, breakeven, trailing.
// Stops only move in the position's favour (CExecution enforces it).
void ManagePositions()
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
      return;
   datetime now = TimeCurrent();
   if(now == g_lastManage || now < g_manageBackoff)
      return;
   g_lastManage = now;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;
   datetime m1 = iTime(_Symbol, PERIOD_M1, 0);
   bool newM1 = (m1 != 0 && m1 != g_lastExitBar);
   if(newM1)
      g_lastExitBar = m1;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurs())
         continue;
      string c = PositionGetString(POSITION_COMMENT);
      int sep = StringFind(c, ":");
      int id = StrategyFromCode(sep >= 0 ? StringSubstr(c, sep + 1) : "");
      if(id == STRAT_NONE || CheckPointer(g_s[id]) == POINTER_INVALID)
         continue;   // not opened by a strategy (or comment lost): keep its own SL/TP

      ManagePlan plan;
      g_s[id].GetPlan(plan);
      bool   isBuy  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      int    dir    = isBuy ? 1 : -1;
      double open   = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl     = PositionGetDouble(POSITION_SL);
      double profit = isBuy ? tick.bid - open : open - tick.ask;
      double ageMin = (double)(now - (datetime)PositionGetInteger(POSITION_TIME)) / 60.0;
      double R      = PosInfo(ticket, "r");
      if(R <= 0 && sl > 0 && ((isBuy && sl < open) || (!isBuy && sl > open)))
         R = MathAbs(open - sl);

      string why = "";
      if(plan.maxHoldMin > 0 && ageMin >= plan.maxHoldMin)
         why = "max holding time";
      else if(plan.staleMin > 0 && ageMin >= plan.staleMin && R > 0 && profit < plan.staleR * R)
         why = "time exit: no progress";
      else if(newM1 && plan.momentumExit && g_s[id].ExitSignal(dir))
         why = "momentum lost";
      if(why != "")
        {
         string err;
         NoteCloseReason(ticket, why);
         if(g_exec.Close(ticket, err))
            Msg(StringFormat("Closed #%I64u (%s)", ticket, why), CLR_MUTED);
         else
           {
            Msg(err, CLR_RED);
            g_manageBackoff = now + 10;
           }
         continue;
        }

      double spread = tick.ask - tick.bid;
      double newSL  = 0;
      if(plan.beR > 0 && R > 0 && profit >= plan.beR * R)
         newSL = isBuy ? open + spread : open - spread;
      double atr = g_s[id].CurrentATR();
      if(plan.trailStartR > 0 && R > 0 && atr > 0 && profit >= plan.trailStartR * R)
        {
         double trail = isBuy ? tick.bid - plan.trailATR * atr : tick.ask + plan.trailATR * atr;
         if(newSL == 0 || (isBuy && trail > newSL) || (!isBuy && trail < newSL))
            newSL = trail;
        }
      if(newSL > 0)
        {
         string err;
         if(g_exec.MoveStop(ticket, newSL, err))
            Msg(StringFormat("Stop moved on #%I64u to %s", ticket, DoubleToString(newSL, _Digits)), CLR_MUTED);
         else if(err != "")
           {
            Msg(err, CLR_RED);
            g_manageBackoff = now + 10;
           }
        }
     }
  }

//==================================================================
//  BUTTON ACTIONS
//==================================================================
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
         string err;
         NoteCloseReason(g_rowTicket[idx], "manual (panel)");
         if(!g_exec.Close(g_rowTicket[idx], err))
            Msg(err, CLR_RED);
        }
     }

   g_risk.Update();
   UpdatePanel();
  }

//--- Auto-start ----------------------------------------------------
// With Auto-start on, the bot runs whenever MT5 is connected: after MT5 opens,
// after the internet comes back, and on a new trading day after a risk lock.
// Pressing STOP (or EMERGENCY) is remembered, even across restarts, and
// auto-start stays off until START is pressed again.
string ManualStopKey() { return StateKey() + "_manualstop"; }
bool   ManualStop()    { return GlobalVariableCheck(ManualStopKey()); }

void CheckAutoStart()
  {
   if(!InpAutoStart || MQLInfoInteger(MQL_TESTER) || g_state == BOT_RUNNING)
      return;
   if(ManualStop() || g_risk.Locked() || !TerminalInfoInteger(TERMINAL_CONNECTED))
      return;
   g_state = BOT_RUNNING;
   for(int i = 0; i < STRAT_COUNT; i++)
      if(CheckPointer(g_s[i]) != POINTER_INVALID)
         g_s[i].ResetBar();
   Msg("AUTO-STARTED: connected to the broker.", CLR_GREEN);
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
   for(int i = 0; i < STRAT_COUNT; i++)
      if(CheckPointer(g_s[i]) != POINTER_INVALID)
         g_s[i].ResetBar();
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      Msg("STARTED, but Algo Trading is OFF in the MT5 toolbar.", CLR_AMBER);
   else
      Msg("Bot STARTED.", CLR_GREEN);
  }

void DoStop()
  {
   g_state = BOT_STOPPED;
   GlobalVariableSet(ManualStopKey(), 1);   // auto-start stays off until START
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
   GlobalVariableSet(ManualStopKey(), 1);   // manual emergency: no auto-start until START
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
//  ENTRY CHECKS
//==================================================================
// Platform permissions and live-account guard. "" = OK.
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
   if(!MQLInfoInteger(MQL_TESTER) && AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL && !InpAllowLive)
      return "REAL account: live trading not enabled (input 'Allow trading on a REAL account')";
   return "";
  }

// Everything that blocks entries before a strategy is even asked.
string PreEntryBlock()
  {
   string why = PlatformBlockReason();
   if(why != "")
      return why;
   why = g_filters.Check();
   if(why != "")
      return why;
   return g_risk.CanOpen();
  }

void Reject(const string why)
  {
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
      if(g_state == BOT_RUNNING && InpPauseOnReconnect && !InpAutoStart)
        {
         g_state = BOT_PAUSED;
         Msg("Reconnected. Bot PAUSED, press START to resume.", CLR_AMBER);
        }
      else
         Msg(g_state == BOT_RUNNING ? "Reconnected. Trading resumes." : "Reconnected.", CLR_GREEN);
      if(InpCloseOnReconnect && CountOurPositions() > 0)
         CloseAll("reconnect");
     }
  }

//==================================================================
//  POSITIONS
//==================================================================
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
         string err;
         if(g_exec.Close(ticket, err))
            closed++;
         else
           {
            failed++;
            Print(err);
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
//  JOURNAL: CLOSED POSITIONS
//==================================================================
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
     }
   return "other";
  }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
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
   double comm     = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION) + HistoryDealGetDouble(trans.deal, DEAL_FEE);
   double profit   = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP) + comm;

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
         double c = HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
         comm   += c;
         profit += c;
         string cm = HistoryDealGetString(d, DEAL_COMMENT);
         int sep = StringFind(cm, ":");
         strategy = (sep >= 0) ? StringSubstr(cm, sep + 1) : cm;
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
         why = "breakeven/trailing stop";
     }
   double riskMoney = PosInfo((ulong)posId, "m");
   bool   hasR = riskMoney > 0;
   bool   stillOpen = PositionSelectByTicket((ulong)posId);   // partial close keeps the position
   JournalClose(posId, side, strategy, lots, price, profit, comm, hold, hasR ? profit / riskMoney : 0.0, hasR, why);
   if(!stillOpen)
      DeletePosInfo((ulong)posId);
   if(!MQLInfoInteger(MQL_TESTER))
      g_lastPerf = 0;   // refresh panel statistics
  }

//==================================================================
//  STATISTICS (panel and tester)
//==================================================================
// Per-strategy results over `days` (0 = all history) and the three most recent trades.
void ComputePerformance(const int days)
  {
   ArrayInitialize(g_pfTrades, 0);
   ArrayInitialize(g_pfWins, 0);
   ArrayInitialize(g_pfWin, 0.0);
   ArrayInitialize(g_pfLoss, 0.0);
   for(int k = 0; k < 3; k++)
      g_recent[k] = "";

   datetime to   = TimeCurrent() + 86400;
   datetime from = (days > 0) ? TimeCurrent() - days * 86400 : 0;
   if(!HistorySelect(from, to))
      return;
   int total = HistoryDealsTotal();

   long   ids[];
   int    strat[];
   double net[];
   bool   closed[];
   int    n = 0;
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0 || HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol)
         continue;
      long posId = HistoryDealGetInteger(d, DEAL_POSITION_ID);
      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      int idx = -1;
      for(int k = 0; k < n; k++)
         if(ids[k] == posId) { idx = k; break; }
      if(entry == DEAL_ENTRY_IN)
        {
         if(HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic || idx >= 0)
            continue;
         string cm = HistoryDealGetString(d, DEAL_COMMENT);
         int sep = StringFind(cm, ":");
         ArrayResize(ids, n + 1, 32);  ArrayResize(strat, n + 1, 32);
         ArrayResize(net, n + 1, 32);  ArrayResize(closed, n + 1, 32);
         ids[n] = posId;  strat[n] = StrategyFromCode(sep >= 0 ? StringSubstr(cm, sep + 1) : "");
         net[n] = 0;  closed[n] = false;
         idx = n++;
        }
      if(idx < 0)
         continue;
      double amount = HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
      if(entry != DEAL_ENTRY_IN)
        {
         amount += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP);
         closed[idx] = true;
        }
      net[idx] += amount;
     }

   int shown = 0;
   for(int k = n - 1; k >= 0; k--)
     {
      if(!closed[k])
         continue;
      int s = strat[k];
      if(s >= 0 && s < STRAT_COUNT)
        {
         g_pfTrades[s]++;
         if(net[k] > 0)
           {
            g_pfWins[s]++;
            g_pfWin[s] += net[k];
           }
         else
            g_pfLoss[s] += -net[k];
        }
      if(shown < 3)
        {
         g_recent[shown] = StringFormat("#%I64d  %-9s %s", ids[k], (s >= 0 ? StrategyCode(s) : "OTHER"),
                                        (net[k] >= 0 ? "+" : "") + DoubleToString(net[k], 2));
         shown++;
        }
     }
  }

void RefreshPerformance()
  {
   g_lastPerf = TimeCurrent();
   ComputePerformance(InpPerfDays);
  }

// Strategy Tester: optimisation criterion and per-strategy summary in the log.
// Criterion = profit factor x (1 - relative drawdown) x sqrt(trades); 0 below 30 trades.
double OnTester()
  {
   ComputePerformance(0);
   Print("=== XAUScalper per-strategy results (this test) ===");
   for(int s = 0; s < STRAT_COUNT; s++)
     {
      double pf = (g_pfLoss[s] > 0) ? g_pfWin[s] / g_pfLoss[s] : (g_pfWin[s] > 0 ? 99.0 : 0.0);
      PrintFormat("%-9s trades %4d  win %5.1f%%  net %10.2f  PF %5.2f", StrategyCode(s), g_pfTrades[s],
                  g_pfTrades[s] > 0 ? 100.0 * g_pfWins[s] / g_pfTrades[s] : 0.0, g_pfWin[s] - g_pfLoss[s], pf);
     }
   double trades = TesterStatistics(STAT_TRADES);
   if(trades < 30)
      return 0.0;
   double pf = TesterStatistics(STAT_PROFIT_FACTOR);
   double dd = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   return pf * (1.0 - dd / 100.0) * MathSqrt(trades);
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
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE))
      return;
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
     }
   return 488;   // P/L, right-aligned
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
   MkLabel("mode", 150, 12, " ", CLR_BLUE, 8, "Arial Bold");
   MkRect("pill", PANEL_W - 118, 8, 106, 20, CLR_GREY, CLR_GREY);
   MkLabel("pill_t", PANEL_W - 65, 18, "STOPPED", clrWhite, 8, "Arial Bold", ANCHOR_CENTER);
   MkButton("b_min", PANEL_W - 146, 8, 22, 20, "-", CLR_GREY, clrWhite, 10);
   MkLabel("info", 14, 44, " ", CLR_MUTED, 8);

   // Account stats (2 rows x 3 columns)
   string titles[6] = {"BALANCE", "EQUITY", "DAY P/L (CLOSED + OPEN)", "FLOATING P/L", "SPREAD", "DRAWDOWN TODAY"};
   for(int i = 0; i < 6; i++)
     {
      int x = 14 + (i % 3) * 178;
      int y = 66 + (i / 3) * 40;
      MkLabel("s_t" + IntegerToString(i), x, y, titles[i], CLR_MUTED, 7);
      MkLabel("s_v" + IntegerToString(i), x, y + 13, "-", CLR_TEXT, 11, "Arial Bold");
     }

   // Risk status, market regime, news, heartbeat
   MkLabel("risk1", 14, 146, " ", CLR_MUTED, 8);
   MkLabel("risk2", 286, 146, " ", CLR_MUTED, 8);
   MkLabel("regime", 14, 164, " ", CLR_TEXT, 8, "Arial Bold");
   MkLabel("tick", PANEL_W - 14, 164, " ", CLR_MUTED, 8, "Arial", ANCHOR_RIGHT_UPPER);
   MkLabel("news", 14, 182, " ", CLR_MUTED, 8);

   // Buttons
   MkRect("sep1", 12, 200, PANEL_W - 24, 1, CLR_BORDER, CLR_BORDER);
   MkButton("b_start", 12,  208, 110, 32, "START",     CLR_GREEN,   clrWhite, 10);
   MkButton("b_stop",  130, 208, 110, 32, "STOP",      CLR_RED,     clrWhite, 10);
   MkButton("b_close", 248, 208, 120, 32, "CLOSE ALL", CLR_GREY,    clrWhite, 9);
   MkButton("b_emerg", 376, 208, 152, 32, "EMERGENCY", CLR_DARKRED, clrWhite, 9);

   // Open positions
   MkLabel("t_title", 14, 250, "OPEN POSITIONS (0)", CLR_MUTED, 7, "Arial Bold");
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
   MkLabel("t_empty", PANEL_W / 2, ROW_Y0 + 30, "No open positions", CLR_MUTED, 9, "Arial", ANCHOR_UPPER);

   // Recent trades
   MkRect("sep4", 12, 356, PANEL_W - 24, 1, CLR_BORDER, CLR_BORDER);
   MkLabel("rc_t", 14, 362, "RECENT TRADES", CLR_MUTED, 7, "Arial Bold");
   for(int k = 0; k < 3; k++)
      MkLabel("rc" + IntegerToString(k), 14, 378 + k * 16, " ", CLR_TEXT, 8);

   // Strategy performance
   MkLabel("pf_t", 14, 432, " ", CLR_MUTED, 7, "Arial Bold");
   for(int s = 0; s < STRAT_COUNT; s++)
      MkLabel("pf" + IntegerToString(s), 14, 448 + s * 16, " ", CLR_TEXT, 8);

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
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE))
      return;
   bool   connected = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);
   string currency  = AccountInfoString(ACCOUNT_CURRENCY);

   // Header
   string mode = (InpMode == MODE_AUTO) ? "AUTO (regime selects)"
                 : (InpMode == MODE_ALL) ? "ALL STRATEGIES (testing)" : "ONLY " + StrategyCode(StrategyForMode(InpMode));
   SetText("mode", mode, CLR_BLUE);
   string status = "STOPPED";
   color  pill   = CLR_GREY;
   if(!connected)                  { status = "OFFLINE"; pill = CLR_RED;   }
   else if(g_risk.Locked())        { status = "LOCKED";  pill = CLR_RED;   }
   else if(g_state == BOT_RUNNING) { status = "RUNNING"; pill = CLR_GREEN; }
   else if(g_state == BOT_PAUSED)  { status = "PAUSED";  pill = CLR_AMBER; }
   ObjectSetInteger(0, P("pill"), OBJPROP_BGCOLOR, pill);
   ObjectSetInteger(0, P("pill"), OBJPROP_COLOR, pill);
   SetText("pill_t", status, clrWhite);
   SetText("info", AccountInfoString(ACCOUNT_COMPANY) + " | " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
           + " (" + AccountMode() + ") | " + AccountInfoString(ACCOUNT_SERVER) + " | " + _Symbol, CLR_MUTED);

   // Account stats
   MqlTick tick;
   bool   haveTick = SymbolInfoTick(_Symbol, tick);
   double spread   = haveTick ? tick.ask - tick.bid : 0.0;
   double dd       = g_risk.DrawdownPct();
   SetText("s_v0", Money(AccountInfoDouble(ACCOUNT_BALANCE)) + " " + currency, CLR_TEXT);
   SetText("s_v1", Money(AccountInfoDouble(ACCOUNT_EQUITY)) + " " + currency, CLR_TEXT);
   SetText("s_v2", Signed(g_risk.DayPL()), PLColor(g_risk.DayPL()));
   SetText("s_v3", Signed(g_risk.Floating()), PLColor(g_risk.Floating()));
   SetText("s_v4", DoubleToString(spread, _Digits), (InpMaxSpread > 0 && spread > InpMaxSpread) ? CLR_RED : CLR_TEXT);
   SetText("s_v5", DoubleToString(dd, 2) + "%", dd > 0 ? CLR_RED : CLR_TEXT);

   // Risk status
   double used = g_risk.DayLossUsedPct();
   string r1 = InpTestingMode ? StringFormat("Risk %.1f%%/trade   TESTING MODE: daily limits OFF", g_risk.RiskPct())
               : (g_risk.MaxDailyLossPct() > 0)
               ? StringFormat("Risk %.1f%%/trade   Daily loss limit used: %.0f%%", g_risk.RiskPct(), used)
               : StringFormat("Risk %.1f%%/trade   Daily loss limit: OFF", g_risk.RiskPct());
   string r2 = StringFormat("Losses in a row %d/%d   Trades %d/%d   Wins %d/%d",
                            g_risk.ConsecLosses(), g_risk.MaxConsecLosses(),
                            g_risk.EntriesToday(), g_risk.MaxDailyTrades(),
                            g_risk.WinsToday(), g_risk.ClosedToday());
   SetText("risk1", r1, used >= 100 ? CLR_RED : (used >= 50 ? CLR_AMBER : CLR_MUTED));
   SetText("risk2", r2, (g_risk.MaxConsecLosses() > 0 && g_risk.ConsecLosses() >= g_risk.MaxConsecLosses()) ? CLR_RED : CLR_MUTED);

   // Regime, strategy, news, heartbeat
   ENUM_REGIME rg = g_regime.Regime();
   string why;
   int act = ActiveStrategy(why);
   string reg = StringFormat("Regime: %s (score %.2f)  ->  %s", RegimeName(rg), g_regime.ScoreValue(),
                             act == STRAT_NONE ? "WAIT" : (act == STRAT_ALL ? "ALL SCANNING" : StrategyCode(act)));
   SetText("regime", reg, rg == REGIME_DANGER ? CLR_RED : (act == STRAT_NONE ? CLR_AMBER : CLR_TEXT));
   long age = haveTick ? (long)(TimeTradeServer() - tick.time) : -1;
   SetText("tick", age >= 0 ? StringFormat("last tick %I64ds ago", age) : "no tick", age > 60 ? CLR_AMBER : CLR_MUTED);
   SetText("news", "News: " + g_filters.NewsStatus(),
           InpUseNews && !g_filters.NewsActive() ? CLR_AMBER : CLR_MUTED);

   // Open positions
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
   SetText("t_title", "OPEN POSITIONS (" + IntegerToString(total) + ")", CLR_MUTED);
   ShowObj("t_empty", total == 0);

   // Recent trades and strategy performance
   for(int k = 0; k < 3; k++)
      SetText("rc" + IntegerToString(k), g_recent[k] == "" ? (k == 0 ? "none yet" : " ") : g_recent[k],
              StringFind(g_recent[k], "+") > 0 ? CLR_GREEN : (g_recent[k] == "" ? CLR_MUTED : CLR_RED));
   SetText("pf_t", StringFormat("STRATEGY PERFORMANCE (LAST %d DAYS)", InpPerfDays), CLR_MUTED);
   for(int s = 0; s < STRAT_COUNT; s++)
     {
      string line;
      if(g_pfTrades[s] == 0)
         line = StringFormat("%-9s no trades%s", StrategyCode(s), g_enabled[s] ? "" : "  (disabled)");
      else
        {
         double pf = (g_pfLoss[s] > 0) ? g_pfWin[s] / g_pfLoss[s] : 99.0;
         line = StringFormat("%-9s %3d trades  win %3.0f%%  net %s  PF %.2f%s", StrategyCode(s), g_pfTrades[s],
                             100.0 * g_pfWins[s] / g_pfTrades[s], Signed(g_pfWin[s] - g_pfLoss[s]), pf,
                             g_enabled[s] ? "" : " (off)");
        }
      SetText("pf" + IntegerToString(s), line, s == act ? CLR_TEXT : CLR_MUTED);
     }

   // Footer: last action, and why the bot is or is not trading right now
   SetText("f_msg", g_lastMsg, g_lastMsgColor);
   string cond;
   color  condClr = CLR_MUTED;
   if(g_risk.Locked())
     {
      cond = "Locked: " + g_risk.LockText();
      condClr = CLR_RED;
     }
   else if(g_state == BOT_RUNNING)
     {
      string pre = PreEntryBlock();
      if(pre != "")
        {
         cond = "Not trading: " + pre;
         condClr = CLR_AMBER;
        }
      else if(act == STRAT_NONE)
         cond = why;
      else
        {
         int show = act;
         if(act == STRAT_ALL)
           {
            // rotate through the enabled strategies, one every 3 seconds
            int on[];
            for(int i = 0; i < STRAT_COUNT; i++)
               if(g_enabled[i])
                 {
                  int n = ArraySize(on);
                  ArrayResize(on, n + 1);
                  on[n] = i;
                 }
            show = (ArraySize(on) > 0) ? on[(int)((TimeLocal() / 3) % ArraySize(on))] : STRAT_PULLBACK;
           }
         cond = StrategyCode(show) + ": " + g_s[show].GetStatus();
        }
     }
   else if(g_state == BOT_PAUSED)
      cond = "Paused after reconnect. Press START to resume.";
   else if(InpAutoStart && ManualStop())
      cond = "Stopped by you: auto-start is off until you press START.";
   else if(InpAutoStart)
      cond = "Auto-start on: waiting for the broker connection.";
   else
      cond = "Stopped. No new trades will be opened.";
   SetText("f_cond", cond, condClr);

   ChartRedraw();
  }
//+------------------------------------------------------------------+
