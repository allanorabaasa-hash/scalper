//+------------------------------------------------------------------+
//|                                                StrategyMath.mqh  |
//|  Pure pattern calculations used by the strategies and the regime  |
//|  detector. No MT5 state, so they are unit-tested                  |
//|  (tests/StrategyTests.mq5).                                       |
//|                                                                   |
//|  Arrays are "series" arrays: index 0 = newest bar.                |
//+------------------------------------------------------------------+
#ifndef XAUSCALPER_STRATEGYMATH_MQH
#define XAUSCALPER_STRATEGYMATH_MQH

// Swing high at index i: the `strength` newer bars are strictly lower and the
// `strength` older bars are lower or equal.
bool SM_IsSwingHigh(const double &high[], const int i, const int strength)
  {
   int n = ArraySize(high);
   if(strength < 1 || i - strength < 0 || i + strength >= n)
      return false;
   for(int k = 1; k <= strength; k++)
     {
      if(high[i - k] >= high[i] || high[i + k] > high[i])
         return false;
     }
   return true;
  }

bool SM_IsSwingLow(const double &low[], const int i, const int strength)
  {
   int n = ArraySize(low);
   if(strength < 1 || i - strength < 0 || i + strength >= n)
      return false;
   for(int k = 1; k <= strength; k++)
     {
      if(low[i - k] <= low[i] || low[i + k] < low[i])
         return false;
     }
   return true;
  }

// Newest swing high with index in [from, to]; -1 if none.
int SM_LastSwingHigh(const double &high[], const int from, const int to, const int strength)
  {
   for(int i = from; i <= to; i++)
      if(SM_IsSwingHigh(high, i, strength))
         return i;
   return -1;
  }

int SM_LastSwingLow(const double &low[], const int from, const int to, const int strength)
  {
   for(int i = from; i <= to; i++)
      if(SM_IsSwingLow(low, i, strength))
         return i;
   return -1;
  }

bool SM_CrossUp(const double fastNow, const double slowNow, const double fastPrev, const double slowPrev)
  {
   return fastNow > slowNow && fastPrev <= slowPrev;
  }

bool SM_CrossDown(const double fastNow, const double slowNow, const double fastPrev, const double slowPrev)
  {
   return fastNow < slowNow && fastPrev >= slowPrev;
  }

// A strong candle in direction dir (+1 bullish, -1 bearish): body is at least
// minBodyRatio of the range and the range is at least minRangeATR x ATR.
bool SM_StrongCandle(const double o, const double h, const double l, const double c, const int dir,
                     const double atr, const double minBodyRatio, const double minRangeATR)
  {
   double range = h - l;
   if(range <= 0 || atr <= 0)
      return false;
   double body = (dir > 0) ? c - o : o - c;
   if(body <= 0)
      return false;
   return (body / range >= minBodyRatio) && (range >= minRangeATR * atr);
  }

// Liquidity sweep below a level: the wick goes beyond it by a meaningful depth
// (between minDepthATR and maxDepthATR x ATR) and the bar closes back above it.
bool SM_SweepBelow(const double low, const double close, const double level, const double atr,
                   const double minDepthATR, const double maxDepthATR)
  {
   if(atr <= 0)
      return false;
   double depth = level - low;
   return close > level && depth >= minDepthATR * atr && depth <= maxDepthATR * atr;
  }

bool SM_SweepAbove(const double high, const double close, const double level, const double atr,
                   const double minDepthATR, const double maxDepthATR)
  {
   if(atr <= 0)
      return false;
   double depth = high - level;
   return close < level && depth >= minDepthATR * atr && depth <= maxDepthATR * atr;
  }

// Highest / lowest value of a[from .. from+count-1]
double SM_Highest(const double &a[], const int from, const int count)
  {
   double v = -DBL_MAX;
   int n = ArraySize(a);
   for(int i = from; i < from + count && i < n; i++)
      if(a[i] > v)
         v = a[i];
   return v;
  }

double SM_Lowest(const double &a[], const int from, const int count)
  {
   double v = DBL_MAX;
   int n = ArraySize(a);
   for(int i = from; i < from + count && i < n; i++)
      if(a[i] < v)
         v = a[i];
   return v;
  }

double SM_Average(const double &a[], const int from, const int count)
  {
   int n = ArraySize(a), used = 0;
   double sum = 0;
   for(int i = from; i < from + count && i < n; i++)
     {
      sum += a[i];
      used++;
     }
   return (used > 0) ? sum / used : 0.0;
  }

double SM_AverageLong(const long &a[], const int from, const int count)
  {
   int n = ArraySize(a), used = 0;
   double sum = 0;
   for(int i = from; i < from + count && i < n; i++)
     {
      sum += (double)a[i];
      used++;
     }
   return (used > 0) ? sum / used : 0.0;
  }

// Share (0..1) of a[from .. from+count-1] that are <= value.
double SM_PercentRank(const double &a[], const int from, const int count, const double value)
  {
   int n = ArraySize(a), used = 0, below = 0;
   for(int i = from; i < from + count && i < n; i++)
     {
      used++;
      if(a[i] <= value)
         below++;
     }
   return (used > 0) ? (double)below / used : 0.0;
  }

// High and low of the bars whose open time is in [from, to). False if no bar.
bool SM_RangeInWindow(const MqlRates &r[], const datetime from, const datetime to, double &hi, double &lo)
  {
   hi = -DBL_MAX;
   lo = DBL_MAX;
   bool found = false;
   for(int i = 0; i < ArraySize(r); i++)
     {
      if(r[i].time < from || r[i].time >= to)
         continue;
      found = true;
      if(r[i].high > hi)
         hi = r[i].high;
      if(r[i].low < lo)
         lo = r[i].low;
     }
   return found;
  }

#endif
