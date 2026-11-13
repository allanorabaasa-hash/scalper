//+------------------------------------------------------------------+
//|                                               StratPullback.mqh  |
//|  Strategy 1: EMA trend pullback                                   |
//|                                                                   |
//|  BUY (SELL mirrored):                                             |
//|  - optional higher-timeframe filter: last closed HTF bar above    |
//|    its EMA (default H1 EMA 200), so pullbacks are only traded in  |
//|    the direction of the bigger trend                              |
//|  - M15: price above EMA 200                                       |
//|  - M5: EMA 20 above EMA 50, MAs not flat (gap and slope in ATR)   |
//|  - M5: price pulled back to EMA 20 / EMA 50 in the last N bars    |
//|        without closing far below EMA 50 (structure intact)        |
//|  - M5: RSI 14 above 50 and rising (renewed momentum)              |
//|  - M1: closed bullish candle that breaks the previous M1 high     |
//|  Stop below the pullback low + ATR buffer, target RewardR x risk. |
//|  Exit early if an M5 bar closes clearly beyond EMA 50.            |
//+------------------------------------------------------------------+
#ifndef XAUSCALPER_STRATPULLBACK_MQH
#define XAUSCALPER_STRATPULLBACK_MQH

#include <XAUScalper\StrategyBase.mqh>

struct PullbackParams
  {
   int               lookback;       // M5 bars searched for the pullback
   double            touchATR;       // "towards the EMA": within this x ATR of EMA 20
   double            minGapATR;      // min EMA20-EMA50 gap (x ATR), else flat
   double            minSlopeATR;    // min EMA50 move over 5 bars (x ATR), else flat
   double            rsiLevel;       // RSI above this for buys (100 - this for sells)
   double            slBufferATR;
   double            minSLATR;
   double            maxSLATR;
   double            rewardR;
   bool              useHTF;         // higher-timeframe trend filter
   ENUM_TIMEFRAMES   htfTF;
   int               htfPeriod;
   ManagePlan        plan;
  };

class CStratPullback : public CStrategy
  {
private:
   PullbackParams    p;
   int               h200, h20, h50, hRsi, hHTF;
public:
                     CStratPullback() { h200 = h20 = h50 = hRsi = hHTF = INVALID_HANDLE; }
                    ~CStratPullback()
     {
      if(h200 != INVALID_HANDLE) IndicatorRelease(h200);
      if(h20 != INVALID_HANDLE)  IndicatorRelease(h20);
      if(h50 != INVALID_HANDLE)  IndicatorRelease(h50);
      if(hRsi != INVALID_HANDLE) IndicatorRelease(hRsi);
      if(hHTF != INVALID_HANDLE) IndicatorRelease(hHTF);
     }
   bool              Init(const string sym, const PullbackParams &params)
     {
      m_sym = sym;  p = params;  m_plan = p.plan;  m_tf = PERIOD_M1;
      h200   = iMA(sym, PERIOD_M15, 200, 0, MODE_EMA, PRICE_CLOSE);
      h20    = iMA(sym, PERIOD_M5, 20, 0, MODE_EMA, PRICE_CLOSE);
      h50    = iMA(sym, PERIOD_M5, 50, 0, MODE_EMA, PRICE_CLOSE);
      hRsi   = iRSI(sym, PERIOD_M5, 14, PRICE_CLOSE);
      m_hATR = iATR(sym, PERIOD_M5, 14);
      if(p.useHTF)
        {
         hHTF = iMA(sym, p.htfTF, p.htfPeriod, 0, MODE_EMA, PRICE_CLOSE);
         if(hHTF == INVALID_HANDLE)
            return false;
        }
      return h200 != INVALID_HANDLE && h20 != INVALID_HANDLE && h50 != INVALID_HANDLE
             && hRsi != INVALID_HANDLE && m_hATR != INVALID_HANDLE;
     }
   virtual int       Id() { return STRAT_PULLBACK; }

   virtual bool      Evaluate(TradeSignal &s)
     {
      datetime bar;
      if(!PendingBar(bar))
         return false;
      int lb = MathMax(p.lookback, 2);
      int n50 = MathMax(lb, 6);
      double e200[], e20[], e50[], rsi[], atr[];
      MqlRates m15[], m5[], m1[];
      if(!GetBuf(h200, 0, 1, 1, e200) || !GetBuf(h20, 0, 1, lb, e20) || !GetBuf(h50, 0, 1, n50, e50)
         || !GetBuf(hRsi, 0, 1, 2, rsi) || !GetBuf(m_hATR, 0, 1, 1, atr))
         return false;
      if(!GetRates(m_sym, PERIOD_M15, 1, 1, m15) || !GetRates(m_sym, PERIOD_M5, 1, lb, m5)
         || !GetRates(m_sym, PERIOD_M1, 1, 2, m1))
         return false;
      MarkBar(bar);
      double a = atr[0];
      if(a <= 0)
         return false;

      int dir = 0;
      if(m15[0].close > e200[0] && e20[0] > e50[0])
         dir = 1;
      else if(m15[0].close < e200[0] && e20[0] < e50[0])
         dir = -1;
      if(dir == 0)
        {
         Status("no trend alignment (M15 EMA200 vs M5 EMA20/50)");
         return false;
        }
      string side = (dir > 0) ? "up" : "down";
      if(p.useHTF)
        {
         double eh[];
         MqlRates hr[];
         if(!GetBuf(hHTF, 0, 1, 1, eh) || !GetRates(m_sym, p.htfTF, 1, 1, hr))
            return false;
         bool agree = (dir > 0) ? hr[0].close > eh[0] : hr[0].close < eh[0];
         if(!agree)
           {
            Status("trend " + side + " on M15 but against the higher-timeframe trend: skip");
            return false;
           }
        }
      if(MathAbs(e20[0] - e50[0]) < p.minGapATR * a || MathAbs(e50[0] - e50[5]) < p.minSlopeATR * a)
        {
         Status("trend " + side + " but EMAs flat (choppy), waiting");
         return false;
        }

      bool   touched = false, broken = false;
      double swing = (dir > 0) ? DBL_MAX : -DBL_MAX;
      for(int i = 0; i < lb; i++)
        {
         if(dir > 0)
           {
            if(m5[i].low <= e20[i] + p.touchATR * a)
               touched = true;
            if(m5[i].close < e50[i] - 0.5 * a)
               broken = true;
            swing = MathMin(swing, m5[i].low);
           }
         else
           {
            if(m5[i].high >= e20[i] - p.touchATR * a)
               touched = true;
            if(m5[i].close > e50[i] + 0.5 * a)
               broken = true;
            swing = MathMax(swing, m5[i].high);
           }
        }
      if(!touched)
        {
         Status("trend " + side + ", waiting for a pullback to EMA 20/50");
         return false;
        }
      if(broken)
        {
         Status("pullback broke through EMA 50, structure not intact");
         return false;
        }
      bool rsiOk = (dir > 0) ? (rsi[0] > p.rsiLevel && rsi[0] > rsi[1])
                             : (rsi[0] < 100.0 - p.rsiLevel && rsi[0] < rsi[1]);
      if(!rsiOk)
        {
         Status(StringFormat("pullback seen, RSI %.0f not confirming yet", rsi[0]));
         return false;
        }
      bool m1Ok = (dir > 0) ? (m1[0].close > m1[0].open && m1[0].close > m1[1].high)
                            : (m1[0].close < m1[0].open && m1[0].close < m1[1].low);
      if(!m1Ok)
        {
         Status("setup ready, waiting for M1 confirmation candle");
         return false;
        }

      MqlTick tick;
      if(!SymbolInfoTick(m_sym, tick))
         return false;
      double entry  = (dir > 0) ? tick.ask : tick.bid;
      double stop   = (dir > 0) ? swing - p.slBufferATR * a : swing + p.slBufferATR * a;
      double slDist = (dir > 0) ? entry - stop : stop - entry;
      if(slDist <= 0 || !ClampStop(slDist, a, p.minSLATR, p.maxSLATR))
         return false;
      Fill(s, dir, slDist, p.rewardR * slDist, a, 0.0);
      Status(StringFormat("%s signal: pullback in %s-trend confirmed", dir > 0 ? "BUY" : "SELL", side));
      return true;
     }

   // Momentum lost: last closed M5 bar closed beyond EMA 50 against the trade.
   virtual bool      ExitSignal(const int dir)
     {
      double e50[], atr[];
      MqlRates m5[];
      if(!GetBuf(h50, 0, 1, 1, e50) || !GetBuf(m_hATR, 0, 1, 1, atr) || !GetRates(m_sym, PERIOD_M5, 1, 1, m5))
         return false;
      if(dir > 0)
         return m5[0].close < e50[0] - 0.2 * atr[0];
      return m5[0].close > e50[0] + 0.2 * atr[0];
     }
  };

#endif
