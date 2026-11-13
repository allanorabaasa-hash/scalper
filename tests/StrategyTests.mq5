//+------------------------------------------------------------------+
//|                                              StrategyTests.mq5   |
//|  Unit tests for the pattern calculations in StrategyMath.mqh.     |
//|  Run: drag it from Navigator > Scripts > XAUScalper onto any      |
//|  chart. Results appear in the Experts tab and in an alert.        |
//+------------------------------------------------------------------+
#property script_show_inputs false
#include <XAUScalper\StrategyMath.mqh>

int g_pass = 0;
int g_fail = 0;

void Check(const string name, const bool ok, const string detail = "")
  {
   if(ok)
     {
      g_pass++;
      Print("PASS  ", name);
     }
   else
     {
      g_fail++;
      Print("FAIL  ", name, "  ", detail);
     }
  }

bool Near(const double a, const double b, const double eps = 1e-9) { return MathAbs(a - b) <= eps; }

void OnStart()
  {
   //--- swings (series arrays: index 0 = newest)
   double hi[] = {1, 2, 3, 6, 4, 3, 2};         // swing high at index 3
   Check("swing high found at index 3 (strength 2)", SM_IsSwingHigh(hi, 3, 2));
   Check("index 2 is not a swing high", !SM_IsSwingHigh(hi, 2, 2));
   Check("too close to the newest bar -> not a swing", !SM_IsSwingHigh(hi, 1, 2));
   Check("LastSwingHigh(1..4) = 3", SM_LastSwingHigh(hi, 1, 4, 2) == 3);
   double flat[] = {5, 5, 5, 5, 5};
   Check("flat highs are not a swing high", !SM_IsSwingHigh(flat, 2, 2));
   double lo[] = {5, 4, 3, 1, 2, 3, 4};          // swing low at index 3
   Check("swing low found at index 3", SM_IsSwingLow(lo, 3, 2));
   Check("LastSwingLow(1..4) = 3", SM_LastSwingLow(lo, 1, 4, 2) == 3);
   double none[] = {1, 2, 3, 4, 5, 6, 7};
   Check("steady rise: no swing low", SM_LastSwingLow(none, 1, 4, 2) == -1);

   //--- crosses
   Check("cross up: 10>9 now, 8<=9 before", SM_CrossUp(10, 9, 8, 9));
   Check("no cross up when already above", !SM_CrossUp(10, 9, 10, 9));
   Check("cross down: 8<9 now, 10>=9 before", SM_CrossDown(8, 9, 10, 9));

   //--- strong candle: range 2.0, body 1.6 (80%), ATR 1.5
   Check("strong bullish candle", SM_StrongCandle(100.0, 102.0, 100.0, 101.6, 1, 1.5, 0.6, 1.0));
   Check("bullish candle is not strong bearish", !SM_StrongCandle(100.0, 102.0, 100.0, 101.6, -1, 1.5, 0.6, 1.0));
   Check("small body (30%) is not strong", !SM_StrongCandle(100.0, 102.0, 100.0, 100.6, 1, 1.5, 0.6, 1.0));
   Check("range below 1 x ATR is not strong", !SM_StrongCandle(100.0, 101.0, 100.0, 100.9, 1, 1.5, 0.6, 1.0));

   //--- sweeps: level 100, ATR 2
   Check("sweep below: wick 99.5 (0.25 ATR), close 100.4", SM_SweepBelow(99.5, 100.4, 100.0, 2.0, 0.15, 2.0));
   Check("tiny wick 99.9 (0.05 ATR) is not a sweep", !SM_SweepBelow(99.9, 100.4, 100.0, 2.0, 0.15, 2.0));
   Check("close below the level is a breakdown, not a sweep", !SM_SweepBelow(99.5, 99.8, 100.0, 2.0, 0.15, 2.0));
   Check("wick of 3 ATR is too deep for a sweep", !SM_SweepBelow(94.0, 100.4, 100.0, 2.0, 0.15, 2.0));
   Check("sweep above: wick 100.6, close 99.7", SM_SweepAbove(100.6, 99.7, 100.0, 2.0, 0.15, 2.0));

   //--- highest / lowest / average / percent rank
   double a[] = {3, 9, 1, 7, 5};
   Check("highest of a[1..3] = 9", Near(SM_Highest(a, 1, 3), 9));
   Check("lowest of a[1..3] = 1", Near(SM_Lowest(a, 1, 3), 1));
   Check("average of a[0..4] = 5", Near(SM_Average(a, 0, 5), 5));
   long v[] = {10, 20, 30};
   Check("average of tick volume = 20", Near(SM_AverageLong(v, 0, 3), 20));
   Check("percent rank of 5 in a[0..4] = 0.6", Near(SM_PercentRank(a, 0, 5, 5), 0.6));

   //--- session range
   MqlRates r[3];
   r[0].time = D'2026.11.13 08:00';  r[0].high = 3880;  r[0].low = 3870;
   r[1].time = D'2026.11.13 03:00';  r[1].high = 3875;  r[1].low = 3860;
   r[2].time = D'2026.11.13 01:00';  r[2].high = 3878;  r[2].low = 3865;
   double h, l;
   bool found = SM_RangeInWindow(r, D'2026.11.13 00:00', D'2026.11.13 07:00', h, l);
   Check("Asian range 00:00-07:00 found", found);
   Check("Asian high 3878 (08:00 bar excluded)", Near(h, 3878));
   Check("Asian low 3860", Near(l, 3860));
   Check("empty window -> not found", !SM_RangeInWindow(r, D'2026.11.12 00:00', D'2026.11.12 07:00', h, l));

   string summary = StringFormat("StrategyTests: %d passed, %d failed", g_pass, g_fail);
   Print(summary);
   Alert(summary);
  }
