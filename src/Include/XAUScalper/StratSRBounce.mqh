//+------------------------------------------------------------------+
//|                                               StratSRBounce.mqh  |
//|  Strategy 7: support / resistance bounce (M5)                     |
//|                                                                   |
//|  Levels: previous day, Asian session, previous session, recent    |
//|  M15 swing (same as Strategies 2 and 4).                          |
//|                                                                   |
//|  BUY at support (SELL at resistance mirrored):                    |
//|  - price came down to the level: the 3 bars before closed above   |
//|  - the last closed bar touched it (low within Tolerance x ATR     |
//|    above, at most MaxPierce x ATR below) and closed back above    |
//|  - rejection: long lower wick (>= WickRatio of the range) or a    |
//|    bullish engulfing candle                                       |
//|  - not against a strong trend: skip buys when M15 ADX > MaxADX    |
//|    and EMA 50 is below EMA 200                                    |
//|  Stop below the level / bar low + buffer, target RewardR x risk.  |
//|  Differs from Strategy 4: no break of the level is needed.        |
//+------------------------------------------------------------------+
#ifndef XAUSCALPER_STRATSRBOUNCE_MQH
#define XAUSCALPER_STRATSRBOUNCE_MQH

#include <XAUScalper\StrategyBase.mqh>

struct SRBounceParams
  {
   double            tolATR;
   double            maxPierceATR;
   double            wickRatio;
   double            maxADX;
   double            slBufferATR;
   double            minSLATR;
   double            maxSLATR;
   double            rewardR;
   int               swingBars;
   int               swingStrength;
   ManagePlan        plan;
  };

class CStratSRBounce : public CStrategy
  {
private:
   SRBounceParams    p;
   SessionHours      m_sh;
   int               hAdx, h50, h200;
public:
                     CStratSRBounce() { hAdx = h50 = h200 = INVALID_HANDLE; }
                    ~CStratSRBounce()
     {
      if(hAdx != INVALID_HANDLE) IndicatorRelease(hAdx);
      if(h50 != INVALID_HANDLE)  IndicatorRelease(h50);
      if(h200 != INVALID_HANDLE) IndicatorRelease(h200);
     }
   bool              Init(const string sym, const SRBounceParams &params, const SessionHours &sh)
     {
      m_sym = sym;  p = params;  m_sh = sh;  m_plan = p.plan;  m_tf = PERIOD_M5;
      hAdx   = iADX(sym, PERIOD_M15, 14);
      h50    = iMA(sym, PERIOD_M15, 50, 0, MODE_EMA, PRICE_CLOSE);
      h200   = iMA(sym, PERIOD_M15, 200, 0, MODE_EMA, PRICE_CLOSE);
      m_hATR = iATR(sym, PERIOD_M5, 14);
      return hAdx != INVALID_HANDLE && h50 != INVALID_HANDLE && h200 != INVALID_HANDLE && m_hATR != INVALID_HANDLE;
     }
   virtual int       Id() { return STRAT_SRBOUNCE; }

   virtual bool      Evaluate(TradeSignal &s)
     {
      datetime bar;
      if(!PendingBar(bar))
         return false;
      double atr[], adx[], e50[], e200[];
      MqlRates r[];
      if(!GetBuf(m_hATR, 0, 1, 1, atr) || !GetBuf(hAdx, 0, 1, 1, adx) || !GetBuf(h50, 0, 1, 1, e50)
         || !GetBuf(h200, 0, 1, 1, e200) || !GetRates(m_sym, PERIOD_M5, 1, 4, r))
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
      bool strongDown = adx[0] > p.maxADX && e50[0] < e200[0];
      bool strongUp   = adx[0] > p.maxADX && e50[0] > e200[0];

      int    bestDir = 0, bestKind = 0;
      double bestLevel = 0, bestDist = DBL_MAX;
      bool   near = false;
      for(int k = 0; k < ArraySize(levels); k++)
        {
         double L = levels[k].price;
         // support below the close -> buy; resistance above -> sell
         int dir = (c[0] > L) ? 1 : -1;
         bool touched = (dir > 0) ? (l[0] <= L + p.tolATR * a && l[0] >= L - p.maxPierceATR * a)
                                  : (h[0] >= L - p.tolATR * a && h[0] <= L + p.maxPierceATR * a);
         if(!touched)
            continue;
         near = true;
         bool approach = (dir > 0) ? (c[1] > L && c[2] > L && c[3] > L) : (c[1] < L && c[2] < L && c[3] < L);
         bool engulf   = (dir > 0) ? (c[0] > o[0] && c[1] < o[1] && c[0] > o[1] && o[0] <= c[1])
                                   : (c[0] < o[0] && c[1] > o[1] && c[0] < o[1] && o[0] >= c[1]);
         bool reject   = SM_RejectionWick(o[0], h[0], l[0], c[0], dir, p.wickRatio) || engulf;
         bool againstTrend = (dir > 0 && strongDown) || (dir < 0 && strongUp);
         if(!approach || !reject || againstTrend)
            continue;
         double dist = MathAbs(c[0] - L);
         if(dist < bestDist)
           {
            bestDist = dist;  bestDir = dir;  bestLevel = L;  bestKind = levels[k].kind;
           }
        }

      if(bestDir == 0)
        {
         Status(near ? "at a level, waiting for a clean rejection candle" : "price not at a key level");
         return false;
        }

      MqlTick tick;
      if(!SymbolInfoTick(m_sym, tick))
         return false;
      double entry  = (bestDir > 0) ? tick.ask : tick.bid;
      double stop   = (bestDir > 0) ? MathMin(bestLevel, l[0]) - p.slBufferATR * a
                                    : MathMax(bestLevel, h[0]) + p.slBufferATR * a;
      double slDist = (bestDir > 0) ? entry - stop : stop - entry;
      if(slDist <= 0 || !ClampStop(slDist, a, p.minSLATR, p.maxSLATR))
         return false;
      Fill(s, bestDir, slDist, p.rewardR * slDist, a, bestLevel);
      Status(StringFormat("%s signal: rejection at %s %.2f", bestDir > 0 ? "BUY" : "SELL",
                          LevelName(bestKind), bestLevel));
      return true;
     }
  };

#endif
