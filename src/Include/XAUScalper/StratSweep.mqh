//+------------------------------------------------------------------+
//|                                                  StratSweep.mqh  |
//|  Strategy 4: liquidity sweep + market structure shift (M5)        |
//|                                                                   |
//|  BUY (SELL mirrored):                                             |
//|  - within the last SweepBars closed bars, a bar's wick went below |
//|    a significant low (previous day / Asian / previous session /   |
//|    M15 swing low) by MinDepth..MaxDepth x ATR and the bar CLOSED  |
//|    back above the level (a wick alone is not a sweep)             |
//|  - no close below the sweep low since                             |
//|  - structure shift: the last closed bar is the FIRST close above  |
//|    the most recent swing high (lower high) formed before the      |
//|    sweep                                                          |
//|  Stop below the sweep low + buffer, target RewardR x risk.        |
//+------------------------------------------------------------------+
#ifndef XAUSCALPER_STRATSWEEP_MQH
#define XAUSCALPER_STRATSWEEP_MQH

#include <XAUScalper\StrategyBase.mqh>

struct SweepParams
  {
   int               sweepBars;
   double            minDepthATR;
   double            maxDepthATR;
   int               mssLookback;
   int               mssStrength;
   double            slBufferATR;
   double            minSLATR;
   double            maxSLATR;
   double            rewardR;
   int               swingBars;
   int               swingStrength;
   ManagePlan        plan;
  };

class CStratSweep : public CStrategy
  {
private:
   SweepParams       p;
   SessionHours      m_sh;
public:
   bool              Init(const string sym, const SweepParams &params, const SessionHours &sh)
     {
      m_sym = sym;  p = params;  m_sh = sh;  m_plan = p.plan;  m_tf = PERIOD_M5;
      m_hATR = iATR(sym, PERIOD_M5, 14);
      return m_hATR != INVALID_HANDLE;
     }
   virtual int       Id() { return STRAT_SWEEP; }

   virtual bool      Evaluate(TradeSignal &s)
     {
      datetime bar;
      if(!PendingBar(bar))
         return false;
      int sb    = MathMax(p.sweepBars, 2);
      int count = sb + p.mssLookback + p.mssStrength + 2;
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

      int    bestDir = 0, bestS = 9999, bestKind = 0;
      double bestStop = 0, bestLevel = 0;
      bool   sawSweep = false;

      for(int k = 0; k < ArraySize(levels); k++)
        {
         double L    = levels[k].price;
         bool   isHi = IsHighLevel(levels[k].kind);
         int    dir  = isHi ? -1 : 1;     // sweep of a low -> buy, of a high -> sell
         for(int sIdx = 1; sIdx <= sb; sIdx++)
           {
            bool swept = (dir > 0) ? SM_SweepBelow(l[sIdx], c[sIdx], L, a, p.minDepthATR, p.maxDepthATR)
                                   : SM_SweepAbove(h[sIdx], c[sIdx], L, a, p.minDepthATR, p.maxDepthATR);
            if(!swept)
               continue;
            sawSweep = true;

            // the sweep extreme must hold
            bool held = true;
            for(int j = 0; j < sIdx; j++)
               if((dir > 0 && c[j] <= l[sIdx]) || (dir < 0 && c[j] >= h[sIdx]))
                  held = false;
            if(!held)
               break;

            // most recent opposite swing formed before the sweep
            int from = sIdx + 1, to = MathMin(sIdx + p.mssLookback, count - p.mssStrength - 1);
            int sw = (dir > 0) ? SM_LastSwingHigh(h, from, to, p.mssStrength)
                               : SM_LastSwingLow(l, from, to, p.mssStrength);
            if(sw < 0)
               break;
            double structure = (dir > 0) ? h[sw] : l[sw];

            // first close beyond that structure happens on the last closed bar
            bool firstBreak = (dir > 0) ? (c[0] > structure) : (c[0] < structure);
            for(int j = 1; j < sIdx && firstBreak; j++)
               if((dir > 0 && c[j] > structure) || (dir < 0 && c[j] < structure))
                  firstBreak = false;
            if(firstBreak && sIdx < bestS)
              {
               bestS = sIdx;  bestDir = dir;  bestLevel = L;  bestKind = levels[k].kind;
               bestStop = (dir > 0) ? l[sIdx] - p.slBufferATR * a : h[sIdx] + p.slBufferATR * a;
              }
            break;   // only the most recent sweep of this level counts
           }
        }

      if(bestDir == 0)
        {
         Status(sawSweep ? "sweep seen, waiting for a structure shift"
                         : "no sweep of a significant level");
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
      Status(StringFormat("%s signal: %s swept, structure shifted", bestDir > 0 ? "BUY" : "SELL", LevelName(bestKind)));
      return true;
     }
  };

#endif
