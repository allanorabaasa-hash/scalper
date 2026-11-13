//+------------------------------------------------------------------+
//|                                               StratBreakout.mqh  |
//|  Strategy 2: support / resistance breakout + retest (M5)          |
//|                                                                   |
//|  Levels: previous day high/low, Asian session high/low, previous  |
//|  session high/low, most recent M15 swing high/low.                |
//|                                                                   |
//|  BUY (SELL mirrored):                                             |
//|  - a strong M5 candle closed above the level (crossing it), body  |
//|    >= MinBody of the range, range >= MinRange x ATR, close at     |
//|    least MinBeyond x ATR above the level                          |
//|  - false-breakout check: no bar since then closed back below the  |
//|    level by more than FailClose x ATR                             |
//|  - retest: price came back to within RetestTol x ATR of the level |
//|  - confirmation: last closed bar bullish, above the level, and    |
//|    above the previous bar's high                                  |
//|  Stop below the retest low + buffer, target RewardR x risk.       |
//+------------------------------------------------------------------+
#ifndef XAUSCALPER_STRATBREAKOUT_MQH
#define XAUSCALPER_STRATBREAKOUT_MQH

#include <XAUScalper\StrategyBase.mqh>

struct BreakoutParams
  {
   int               maxBarsSinceBreak;
   double            minBodyRatio;
   double            minRangeATR;
   double            minBeyondATR;
   double            retestTolATR;
   double            failCloseATR;
   double            slBufferATR;
   double            minSLATR;
   double            maxSLATR;
   double            rewardR;
   int               swingBars;
   int               swingStrength;
   ManagePlan        plan;
  };

class CStratBreakout : public CStrategy
  {
private:
   BreakoutParams    p;
   SessionHours      m_sh;
public:
   bool              Init(const string sym, const BreakoutParams &params, const SessionHours &sh)
     {
      m_sym = sym;  p = params;  m_sh = sh;  m_plan = p.plan;  m_tf = PERIOD_M5;
      m_hATR = iATR(sym, PERIOD_M5, 14);
      return m_hATR != INVALID_HANDLE;
     }
   virtual int       Id() { return STRAT_BREAKOUT; }

   virtual bool      Evaluate(TradeSignal &s)
     {
      datetime bar;
      if(!PendingBar(bar))
         return false;
      int nb = MathMax(p.maxBarsSinceBreak, 3);
      int count = nb + 2;
      double atr[];
      MqlRates r[];
      if(!GetBuf(m_hATR, 0, 1, 1, atr) || !GetRates(m_sym, PERIOD_M5, 1, count, r))
         return false;
      KeyLevel levels[];
      if(GetKeyLevels(m_sym, m_sh, p.swingBars, p.swingStrength, levels) == 0)
         return false;
      MarkBar(bar);
      double a = atr[0];
      if(a <= 0)
         return false;

      double o[], h[], l[], c[];
      RatesToArrays(r, o, h, l, c);

      int    bestDir = 0, bestB = 9999;
      double bestLevel = 0, bestStop = 0;
      int    bestKind = 0;
      bool   sawBreak = false;

      for(int k = 0; k < ArraySize(levels); k++)
        {
         double L = levels[k].price;
         for(int dir = -1; dir <= 1; dir += 2)
           {
            // breakout candle b (2 .. nb): crossed the level with strength
            int b = -1;
            for(int i = 1; i <= nb && i + 1 < count; i++)
              {
               bool crossed = (dir > 0) ? (c[i] > L + p.minBeyondATR * a && c[i + 1] <= L)
                                        : (c[i] < L - p.minBeyondATR * a && c[i + 1] >= L);
               if(crossed && SM_StrongCandle(o[i], h[i], l[i], c[i], dir, a, p.minBodyRatio, p.minRangeATR))
                 {
                  b = i;
                  break;
                 }
              }
            if(b < 1)
               continue;
            sawBreak = true;

            // false breakout: a close back through the level since the breakout
            bool failed = false, retested = false;
            double extreme = (dir > 0) ? DBL_MAX : -DBL_MAX;
            for(int j = 0; j < b; j++)
              {
               if(dir > 0 && c[j] < L - p.failCloseATR * a)
                  failed = true;
               if(dir < 0 && c[j] > L + p.failCloseATR * a)
                  failed = true;
               if(dir > 0 && l[j] <= L + p.retestTolATR * a)
                  retested = true;
               if(dir < 0 && h[j] >= L - p.retestTolATR * a)
                  retested = true;
               extreme = (dir > 0) ? MathMin(extreme, l[j]) : MathMax(extreme, h[j]);
              }
            if(failed || !retested)
               continue;

            bool confirmed = (dir > 0) ? (c[0] > o[0] && c[0] > h[1] && c[0] > L)
                                       : (c[0] < o[0] && c[0] < l[1] && c[0] < L);
            if(!confirmed)
               continue;
            if(b < bestB)
              {
               bestB = b;  bestDir = dir;  bestLevel = L;  bestKind = levels[k].kind;
               bestStop = (dir > 0) ? extreme - p.slBufferATR * a : extreme + p.slBufferATR * a;
              }
           }
        }

      if(bestDir == 0)
        {
         Status(sawBreak ? "breakout seen, waiting for a clean retest + confirmation"
                         : "no strong breakout of a key level");
         return false;
        }

      MqlTick tick;
      if(!SymbolInfoTick(m_sym, tick))
         return false;
      double entry  = (bestDir > 0) ? tick.ask : tick.bid;
      double slDist = (bestDir > 0) ? entry - bestStop : bestStop - entry;
      if(slDist <= 0 || !ClampStop(slDist, a, p.minSLATR, p.maxSLATR))
         return false;
      Fill(s, bestDir, slDist, p.rewardR * slDist, a, bestLevel);
      Status(StringFormat("%s signal: retest of %s %.2f held", bestDir > 0 ? "BUY" : "SELL",
                          LevelName(bestKind), bestLevel));
      return true;
     }
  };

#endif
