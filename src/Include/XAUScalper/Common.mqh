//+------------------------------------------------------------------+
//|                                                      Common.mqh  |
//|  Shared types and market-data helpers.                            |
//+------------------------------------------------------------------+
#ifndef XAUSCALPER_COMMON_MQH
#define XAUSCALPER_COMMON_MQH

#include <XAUScalper\StrategyMath.mqh>

enum ENUM_REGIME
  {
   REGIME_UNCLEAR  = 0,
   REGIME_TREND    = 1,
   REGIME_RANGE    = 2,
   REGIME_BREAKOUT = 3,
   REGIME_REVERSAL = 4,
   REGIME_MOMENTUM = 5,
   REGIME_DANGER   = 6
  };

#define STRAT_COUNT    5
#define STRAT_NONE     -1
#define STRAT_PULLBACK 0
#define STRAT_BREAKOUT 1
#define STRAT_MEANREV  2
#define STRAT_SWEEP    3
#define STRAT_MOMENTUM 4
#define STRAT_ALL      100   // pseudo-id: every enabled strategy

enum ENUM_STRATEGY_MODE
  {
   MODE_AUTO     = 0,   // Auto: market regime chooses the strategy
   MODE_PULLBACK = 1,   // Only Strategy 1: EMA trend pullback
   MODE_BREAKOUT = 2,   // Only Strategy 2: breakout + retest
   MODE_MEANREV  = 3,   // Only Strategy 3: RSI + Bollinger mean reversion
   MODE_SWEEP    = 4,   // Only Strategy 4: liquidity sweep + structure shift
   MODE_MOMENTUM = 5,   // Only Strategy 5: momentum scalping
   MODE_ALL      = 6    // All strategies scan, first valid signal trades (testing)
  };

// A trade proposal from a strategy. Numbers only, so it can be copied safely.
struct TradeSignal
  {
   int               dir;          // +1 buy, -1 sell
   int               strat;        // STRAT_*
   double            slDist;       // stop distance from the entry price
   double            tpDist;       // take-profit distance (0 = none)
   double            atr;          // ATR of the strategy timeframe at the signal
   double            level;        // key level involved (0 if none)
  };

void ClearSignal(TradeSignal &s)
  {
   s.dir = 0;  s.strat = STRAT_NONE;  s.slDist = 0;  s.tpDist = 0;  s.atr = 0;  s.level = 0;
  }

string StrategyCode(const int id)
  {
   switch(id)
     {
      case STRAT_PULLBACK: return "PULLBACK";
      case STRAT_BREAKOUT: return "BREAKOUT";
      case STRAT_MEANREV:  return "MEANREV";
      case STRAT_SWEEP:    return "SWEEP";
      case STRAT_MOMENTUM: return "MOMENTUM";
     }
   return "NONE";
  }

int StrategyFromCode(const string code)
  {
   for(int i = 0; i < STRAT_COUNT; i++)
      if(StrategyCode(i) == code)
         return i;
   return STRAT_NONE;
  }

string RegimeName(const ENUM_REGIME r)
  {
   switch(r)
     {
      case REGIME_TREND:    return "TRENDING";
      case REGIME_RANGE:    return "RANGING";
      case REGIME_BREAKOUT: return "BREAKOUT";
      case REGIME_REVERSAL: return "REVERSAL";
      case REGIME_MOMENTUM: return "MOMENTUM";
      case REGIME_DANGER:   return "DANGEROUS";
     }
   return "UNCLEAR";
  }

// Strategy chosen for each regime (spec section 4)
int StrategyForRegime(const ENUM_REGIME r)
  {
   switch(r)
     {
      case REGIME_TREND:    return STRAT_PULLBACK;
      case REGIME_BREAKOUT: return STRAT_BREAKOUT;
      case REGIME_RANGE:    return STRAT_MEANREV;
      case REGIME_REVERSAL: return STRAT_SWEEP;
      case REGIME_MOMENTUM: return STRAT_MOMENTUM;
     }
   return STRAT_NONE;
  }

//--- data helpers (series arrays: index 0 = start shift) ------------
bool GetBuf(const int handle, const int buffer, const int start, const int count, double &out[])
  {
   ArraySetAsSeries(out, true);
   if(handle == INVALID_HANDLE)
      return false;
   return CopyBuffer(handle, buffer, start, count, out) == count;
  }

bool GetRates(const string sym, const ENUM_TIMEFRAMES tf, const int start, const int count, MqlRates &out[])
  {
   ArraySetAsSeries(out, true);
   return CopyRates(sym, tf, start, count, out) == count;
  }

void RatesToArrays(const MqlRates &r[], double &o[], double &h[], double &l[], double &c[])
  {
   int n = ArraySize(r);
   ArrayResize(o, n);  ArrayResize(h, n);  ArrayResize(l, n);  ArrayResize(c, n);
   for(int i = 0; i < n; i++)
     {
      o[i] = r[i].open;  h[i] = r[i].high;  l[i] = r[i].low;  c[i] = r[i].close;
     }
  }

#endif
