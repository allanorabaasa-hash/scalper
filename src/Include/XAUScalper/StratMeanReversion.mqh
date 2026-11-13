//+------------------------------------------------------------------+
//|                                          StratMeanReversion.mqh  |
//|  Strategy 3: RSI + Bollinger Bands mean reversion (M5)            |
//|                                                                   |
//|  Only in a ranging market: ADX below MaxADX and EMA 200 nearly    |
//|  flat (it never trades against a strong trend, whatever the       |
//|  regime detector says).                                           |
//|                                                                   |
//|  BUY (SELL mirrored):                                             |
//|  - one of the last two closed bars reached the lower band (20, 2) |
//|  - RSI 14 was below Oversold on one of them                       |
//|  - last closed bar is bullish and closed back inside the bands    |
//|  Target: the middle band. Stop below the extreme + ATR buffer.    |
//|  Skipped when the distance to the middle band is below            |
//|  MinRewardR x risk.                                               |
//+------------------------------------------------------------------+
#ifndef XAUSCALPER_STRATMEANREV_MQH
#define XAUSCALPER_STRATMEANREV_MQH

#include <XAUScalper\StrategyBase.mqh>

struct MeanRevParams
  {
   double            rsiOversold;
   double            rsiOverbought;
   double            maxADX;
   double            maxEmaSlopeATR;   // max EMA 200 move over 10 bars (x ATR)
   double            slBufferATR;
   double            minSLATR;
   double            maxSLATR;
   double            minRewardR;
   ManagePlan        plan;
  };

class CStratMeanRev : public CStrategy
  {
private:
   MeanRevParams     p;
   int               hBands, hRsi, hEma, hAdx;
public:
                     CStratMeanRev() { hBands = hRsi = hEma = hAdx = INVALID_HANDLE; }
                    ~CStratMeanRev()
     {
      if(hBands != INVALID_HANDLE) IndicatorRelease(hBands);
      if(hRsi != INVALID_HANDLE)   IndicatorRelease(hRsi);
      if(hEma != INVALID_HANDLE)   IndicatorRelease(hEma);
      if(hAdx != INVALID_HANDLE)   IndicatorRelease(hAdx);
     }
   bool              Init(const string sym, const MeanRevParams &params)
     {
      m_sym = sym;  p = params;  m_plan = p.plan;  m_tf = PERIOD_M5;
      hBands = iBands(sym, PERIOD_M5, 20, 0, 2.0, PRICE_CLOSE);
      hRsi   = iRSI(sym, PERIOD_M5, 14, PRICE_CLOSE);
      hEma   = iMA(sym, PERIOD_M5, 200, 0, MODE_EMA, PRICE_CLOSE);
      hAdx   = iADX(sym, PERIOD_M5, 14);
      m_hATR = iATR(sym, PERIOD_M5, 14);
      return hBands != INVALID_HANDLE && hRsi != INVALID_HANDLE && hEma != INVALID_HANDLE
             && hAdx != INVALID_HANDLE && m_hATR != INVALID_HANDLE;
     }
   virtual int       Id() { return STRAT_MEANREV; }

   virtual bool      Evaluate(TradeSignal &s)
     {
      datetime bar;
      if(!PendingBar(bar))
         return false;
      double mid[], up[], lo[], rsi[], ema[], adx[], atr[];
      MqlRates r[];
      if(!GetBuf(hBands, 0, 1, 2, mid) || !GetBuf(hBands, 1, 1, 2, up) || !GetBuf(hBands, 2, 1, 2, lo)
         || !GetBuf(hRsi, 0, 1, 2, rsi) || !GetBuf(hEma, 0, 1, 11, ema) || !GetBuf(hAdx, 0, 1, 1, adx)
         || !GetBuf(m_hATR, 0, 1, 1, atr) || !GetRates(m_sym, PERIOD_M5, 1, 2, r))
         return false;
      MarkBar(bar);
      double a = atr[0];
      if(a <= 0)
         return false;

      if(adx[0] >= p.maxADX || MathAbs(ema[0] - ema[10]) >= p.maxEmaSlopeATR * a)
        {
         Status(StringFormat("not ranging (ADX %.0f, EMA200 sloped): mean reversion off", adx[0]));
         return false;
        }

      int dir = 0;
      bool touchLow  = (r[0].low <= lo[0] || r[1].low <= lo[1]);
      bool touchHigh = (r[0].high >= up[0] || r[1].high >= up[1]);
      bool oversold   = MathMin(rsi[0], rsi[1]) < p.rsiOversold;
      bool overbought = MathMax(rsi[0], rsi[1]) > p.rsiOverbought;
      if(touchLow && oversold && r[0].close > r[0].open && r[0].close > lo[0] && r[0].close < mid[0])
         dir = 1;
      else if(touchHigh && overbought && r[0].close < r[0].open && r[0].close < up[0] && r[0].close > mid[0])
         dir = -1;
      if(dir == 0)
        {
         if(touchLow || touchHigh)
            Status("at a band, waiting for RSI extreme + reversal close inside");
         else
            Status("ranging, price inside the bands");
         return false;
        }

      MqlTick tick;
      if(!SymbolInfoTick(m_sym, tick))
         return false;
      double entry   = (dir > 0) ? tick.ask : tick.bid;
      double extreme = (dir > 0) ? MathMin(r[0].low, r[1].low) : MathMax(r[0].high, r[1].high);
      double stop    = (dir > 0) ? extreme - p.slBufferATR * a : extreme + p.slBufferATR * a;
      double slDist  = (dir > 0) ? entry - stop : stop - entry;
      double tpDist  = (dir > 0) ? mid[0] - entry : entry - mid[0];
      if(slDist <= 0 || !ClampStop(slDist, a, p.minSLATR, p.maxSLATR))
         return false;
      if(tpDist < p.minRewardR * slDist)
        {
         Status(StringFormat("setup skipped: middle band only %.2fR away", tpDist / slDist));
         return false;
        }
      Fill(s, dir, slDist, tpDist, a, mid[0]);
      Status(StringFormat("%s signal: reversion to the middle band %.2f", dir > 0 ? "BUY" : "SELL", mid[0]));
      return true;
     }
  };

#endif
