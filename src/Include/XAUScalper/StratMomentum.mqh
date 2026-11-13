//+------------------------------------------------------------------+
//|                                               StratMomentum.mqh  |
//|  Strategy 5: momentum scalping                                    |
//|                                                                   |
//|  BUY (SELL mirrored, RSI below 45):                               |
//|  - EMA 9 crossed above EMA 21 within the last CrossBars bars and  |
//|    is still above                                                 |
//|  - RSI 7 above 55                                                 |
//|  - ADX 14 above 20 and rising                                     |
//|  - tick volume above its recent average (broker tick volume, not  |
//|    exchange volume)                                               |
//|  - close above the highest high of the previous BreakBars bars    |
//|  - not an over-extended candle: range <= MaxCandle x ATR and      |
//|    close no more than MaxExtension x ATR from EMA 9               |
//|  Stop below the low of the last 3 bars + buffer, target RewardR.  |
//|  Exit early when EMA 9 crosses back through EMA 21.               |
//+------------------------------------------------------------------+
#ifndef XAUSCALPER_STRATMOMENTUM_MQH
#define XAUSCALPER_STRATMOMENTUM_MQH

#include <XAUScalper\StrategyBase.mqh>

struct MomentumParams
  {
   int               crossBars;
   double            rsiBuy;
   double            rsiSell;
   double            minADX;
   int               volAvgBars;
   int               breakBars;
   double            maxCandleATR;
   double            maxExtensionATR;
   double            slBufferATR;
   double            minSLATR;
   double            maxSLATR;
   double            rewardR;
   ManagePlan        plan;
  };

class CStratMomentum : public CStrategy
  {
private:
   MomentumParams    p;
   int               h9, h21, hRsi, hAdx;
public:
                     CStratMomentum() { h9 = h21 = hRsi = hAdx = INVALID_HANDLE; }
                    ~CStratMomentum()
     {
      if(h9 != INVALID_HANDLE)   IndicatorRelease(h9);
      if(h21 != INVALID_HANDLE)  IndicatorRelease(h21);
      if(hRsi != INVALID_HANDLE) IndicatorRelease(hRsi);
      if(hAdx != INVALID_HANDLE) IndicatorRelease(hAdx);
     }
   bool              Init(const string sym, const ENUM_TIMEFRAMES tf, const MomentumParams &params)
     {
      m_sym = sym;  p = params;  m_plan = p.plan;  m_tf = tf;
      h9     = iMA(sym, tf, 9, 0, MODE_EMA, PRICE_CLOSE);
      h21    = iMA(sym, tf, 21, 0, MODE_EMA, PRICE_CLOSE);
      hRsi   = iRSI(sym, tf, 7, PRICE_CLOSE);
      hAdx   = iADX(sym, tf, 14);
      m_hATR = iATR(sym, tf, 14);
      return h9 != INVALID_HANDLE && h21 != INVALID_HANDLE && hRsi != INVALID_HANDLE
             && hAdx != INVALID_HANDLE && m_hATR != INVALID_HANDLE;
     }
   virtual int       Id() { return STRAT_MOMENTUM; }

   virtual bool      Evaluate(TradeSignal &s)
     {
      datetime bar;
      if(!PendingBar(bar))
         return false;
      int cb = MathMax(p.crossBars, 1);
      int bb = MathMax(p.breakBars, 2);
      int va = MathMax(p.volAvgBars, 5);
      double e9[], e21[], rsi[], adx[], atr[];
      long   vol[];
      MqlRates r[];
      ArraySetAsSeries(vol, true);
      if(!GetBuf(h9, 0, 1, cb + 1, e9) || !GetBuf(h21, 0, 1, cb + 1, e21) || !GetBuf(hRsi, 0, 1, 1, rsi)
         || !GetBuf(hAdx, 0, 1, 2, adx) || !GetBuf(m_hATR, 0, 1, 1, atr)
         || !GetRates(m_sym, m_tf, 1, MathMax(bb + 1, 3), r)
         || CopyTickVolume(m_sym, m_tf, 1, va + 1, vol) != va + 1)
         return false;
      MarkBar(bar);
      double a = atr[0];
      if(a <= 0)
         return false;

      double o[], h[], l[], c[];
      RatesToArrays(r, o, h, l, c);

      int dir = 0;
      for(int k = 0; k < cb && dir == 0; k++)
        {
         if(SM_CrossUp(e9[k], e21[k], e9[k + 1], e21[k + 1]) && e9[0] > e21[0])
            dir = 1;
         else if(SM_CrossDown(e9[k], e21[k], e9[k + 1], e21[k + 1]) && e9[0] < e21[0])
            dir = -1;
        }
      if(dir == 0)
        {
         Status("no fresh EMA 9/21 cross");
         return false;
        }
      string side = (dir > 0) ? "BUY" : "SELL";
      bool rsiOk = (dir > 0) ? rsi[0] > p.rsiBuy : rsi[0] < p.rsiSell;
      bool adxOk = adx[0] > p.minADX && adx[0] > adx[1];
      bool volOk = (double)vol[0] > SM_AverageLong(vol, 1, va);
      bool brkOk = (dir > 0) ? c[0] > SM_Highest(h, 1, bb) : c[0] < SM_Lowest(l, 1, bb);
      if(!rsiOk || !adxOk || !volOk || !brkOk)
        {
         Status(StringFormat("%s cross, waiting: %s%s%s%s", side, rsiOk ? "" : "RSI ", adxOk ? "" : "ADX ",
                             volOk ? "" : "volume ", brkOk ? "" : "high/low break"));
         return false;
        }
      double ext = (dir > 0) ? c[0] - e9[0] : e9[0] - c[0];
      if(h[0] - l[0] > p.maxCandleATR * a || ext > p.maxExtensionATR * a)
        {
         Status("setup skipped: candle over-extended");
         return false;
        }

      MqlTick tick;
      if(!SymbolInfoTick(m_sym, tick))
         return false;
      double entry  = (dir > 0) ? tick.ask : tick.bid;
      double stop   = (dir > 0) ? SM_Lowest(l, 0, 3) - p.slBufferATR * a : SM_Highest(h, 0, 3) + p.slBufferATR * a;
      double slDist = (dir > 0) ? entry - stop : stop - entry;
      if(slDist <= 0 || !ClampStop(slDist, a, p.minSLATR, p.maxSLATR))
         return false;
      Fill(s, dir, slDist, p.rewardR * slDist, a, 0.0);
      Status(side + " signal: momentum breakout confirmed");
      return true;
     }

   // Momentum lost: EMA 9 back through EMA 21 on the last closed bar.
   virtual bool      ExitSignal(const int dir)
     {
      double e9[], e21[];
      if(!GetBuf(h9, 0, 1, 1, e9) || !GetBuf(h21, 0, 1, 1, e21))
         return false;
      return (dir > 0) ? e9[0] < e21[0] : e9[0] > e21[0];
     }
  };

#endif
