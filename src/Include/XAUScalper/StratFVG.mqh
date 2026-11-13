//+------------------------------------------------------------------+
//|                                                    StratFVG.mqh  |
//|  Strategy 6: fair value gap (FVG) retracement, with the trend     |
//|                                                                   |
//|  BUY (SELL mirrored):                                             |
//|  - trend: M15 close above EMA 200 and EMA 50 above EMA 200        |
//|  - M5 bullish FVG formed within the last MaxAge bars: candle C's  |
//|    low is above candle A's high (two bars older), gap at least    |
//|    MinGap x ATR, and the middle candle B is a strong bullish      |
//|    displacement (body >= Displacement x ATR)                      |
//|  - fresh gap: no bar touched it between its formation and the     |
//|    last closed bar, and no close below the gap bottom since       |
//|  - last closed bar dips into the gap, closes bullish and above    |
//|    the middle of the gap                                          |
//|  Stop below the gap bottom (or the bar low) + buffer, target      |
//|  RewardR x risk.                                                  |
//+------------------------------------------------------------------+
#ifndef XAUSCALPER_STRATFVG_MQH
#define XAUSCALPER_STRATFVG_MQH

#include <XAUScalper\StrategyBase.mqh>

struct FVGParams
  {
   int               maxAge;            // bars since the gap formed
   double            minGapATR;
   double            displacementATR;
   double            slBufferATR;
   double            minSLATR;
   double            maxSLATR;
   double            rewardR;
   ManagePlan        plan;
  };

class CStratFVG : public CStrategy
  {
private:
   FVGParams         p;
   int               h50, h200;
public:
                     CStratFVG() { h50 = h200 = INVALID_HANDLE; }
                    ~CStratFVG()
     {
      if(h50 != INVALID_HANDLE)  IndicatorRelease(h50);
      if(h200 != INVALID_HANDLE) IndicatorRelease(h200);
     }
   bool              Init(const string sym, const FVGParams &params)
     {
      m_sym = sym;  p = params;  m_plan = p.plan;  m_tf = PERIOD_M5;
      h50    = iMA(sym, PERIOD_M15, 50, 0, MODE_EMA, PRICE_CLOSE);
      h200   = iMA(sym, PERIOD_M15, 200, 0, MODE_EMA, PRICE_CLOSE);
      m_hATR = iATR(sym, PERIOD_M5, 14);
      return h50 != INVALID_HANDLE && h200 != INVALID_HANDLE && m_hATR != INVALID_HANDLE;
     }
   virtual int       Id() { return STRAT_FVG; }

   virtual bool      Evaluate(TradeSignal &s)
     {
      datetime bar;
      if(!PendingBar(bar))
         return false;
      int age   = MathMax(p.maxAge, 2);
      int count = age + 3;
      double e50[], e200[], atr[];
      MqlRates m15[], r[];
      if(!GetBuf(h50, 0, 1, 1, e50) || !GetBuf(h200, 0, 1, 1, e200) || !GetBuf(m_hATR, 0, 1, 1, atr)
         || !GetRates(m_sym, PERIOD_M15, 1, 1, m15) || !GetRates(m_sym, PERIOD_M5, 1, count, r))
         return false;
      MarkBar(bar);
      double a = atr[0];
      if(a <= 0)
         return false;

      int trend = 0;
      if(m15[0].close > e200[0] && e50[0] > e200[0])
         trend = 1;
      else if(m15[0].close < e200[0] && e50[0] < e200[0])
         trend = -1;
      if(trend == 0)
        {
         Status("no M15 trend (EMA 50/200), FVG off");
         return false;
        }

      double o[], h[], l[], c[];
      RatesToArrays(r, o, h, l, c);

      bool   sawGap = false;
      double gapTop = 0, gapBottom = 0;
      int    found = -1;
      for(int k = 1; k <= age && found < 0; k++)     // k = candle C, k+1 = B, k+2 = A
        {
         double gap = (trend > 0) ? SM_BullFVG(h[k + 2], l[k]) : SM_BearFVG(l[k + 2], h[k]);
         if(gap < p.minGapATR * a)
            continue;
         double body = (trend > 0) ? c[k + 1] - o[k + 1] : o[k + 1] - c[k + 1];
         if(body < p.displacementATR * a)
            continue;
         sawGap = true;
         // gap zone: for buys [highA, lowC], for sells [highC, lowA]
         double top    = (trend > 0) ? l[k] : l[k + 2];
         double bottom = (trend > 0) ? h[k + 2] : h[k];
         bool fresh = true;
         for(int j = 1; j < k && fresh; j++)
           {
            if(trend > 0 && (l[j] <= top || c[j] < bottom))
               fresh = false;
            if(trend < 0 && (h[j] >= bottom || c[j] > top))
               fresh = false;
           }
         if(!fresh)
            continue;
         bool entry = (trend > 0)
                      ? (l[0] <= top && c[0] > o[0] && c[0] > (top + bottom) / 2.0 && c[0] > bottom)
                      : (h[0] >= bottom && c[0] < o[0] && c[0] < (top + bottom) / 2.0 && c[0] < top);
         if(entry)
           {
            found = k;
            gapTop = top;
            gapBottom = bottom;
           }
        }

      string side = (trend > 0) ? "BUY" : "SELL";
      if(found < 0)
        {
         Status(sawGap ? side + " FVG open, waiting for a fresh retest + rejection"
                       : (trend > 0 ? "trend up, no fair value gap" : "trend down, no fair value gap"));
         return false;
        }

      MqlTick tick;
      if(!SymbolInfoTick(m_sym, tick))
         return false;
      double entryPx = (trend > 0) ? tick.ask : tick.bid;
      double stop    = (trend > 0) ? MathMin(gapBottom, l[0]) - p.slBufferATR * a
                                   : MathMax(gapTop, h[0]) + p.slBufferATR * a;
      double slDist  = (trend > 0) ? entryPx - stop : stop - entryPx;
      if(slDist <= 0 || !ClampStop(slDist, a, p.minSLATR, p.maxSLATR))
         return false;
      Fill(s, trend, slDist, p.rewardR * slDist, a, (gapTop + gapBottom) / 2.0);
      Status(StringFormat("%s signal: FVG %.2f-%.2f retested", side, gapBottom, gapTop));
      return true;
     }
  };

#endif
