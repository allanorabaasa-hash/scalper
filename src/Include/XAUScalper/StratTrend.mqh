//+------------------------------------------------------------------+
//|                                                  StratTrend.mqh  |
//|  Strategy 8: higher-timeframe trend following (channel breakout)  |
//|                                                                   |
//|  Classic rules, deliberately not fitted to recent data:           |
//|  - trend filter: last closed daily bar above (below) its EMA      |
//|  - entry: H1 close above the highest high of the previous         |
//|    EntryBars H1 bars, in the direction of the daily trend         |
//|  - initial stop: StopATR x ATR(H1, 14) from entry, no fixed target|
//|  - exits: trailing stop TrailATR x ATR once the trade is          |
//|    TrailStartR x risk in profit, and an opposite breakout of the  |
//|    shorter ExitBars channel (H1 close below its lowest low)       |
//|  Few trades, low win rate, winners meant to be much larger than   |
//|  losers. Spread is small relative to H1 stops.                    |
//+------------------------------------------------------------------+
#ifndef XAUSCALPER_STRATTREND_MQH
#define XAUSCALPER_STRATTREND_MQH

#include <XAUScalper\StrategyBase.mqh>

struct TrendParams
  {
   int               entryBars;
   int               exitBars;
   ENUM_TIMEFRAMES   trendTF;
   int               trendEMA;
   double            stopATR;
   ManagePlan        plan;
  };

class CStratTrend : public CStrategy
  {
private:
   TrendParams       p;
   int               hTrend;
public:
                     CStratTrend() { hTrend = INVALID_HANDLE; }
                    ~CStratTrend() { if(hTrend != INVALID_HANDLE) IndicatorRelease(hTrend); }

   bool              Init(const string sym, const ENUM_TIMEFRAMES tf, const TrendParams &params)
     {
      m_sym = sym;  p = params;  m_plan = p.plan;  m_tf = tf;
      hTrend = iMA(sym, p.trendTF, p.trendEMA, 0, MODE_EMA, PRICE_CLOSE);
      m_hATR = iATR(sym, tf, 14);
      return hTrend != INVALID_HANDLE && m_hATR != INVALID_HANDLE;
     }
   virtual int       Id() { return STRAT_TREND; }

   virtual bool      Evaluate(TradeSignal &s)
     {
      datetime bar;
      if(!PendingBar(bar))
         return false;
      int n = MathMax(p.entryBars, 5);
      double ema[], atr[];
      MqlRates d1[], r[];
      if(!GetBuf(hTrend, 0, 1, 1, ema) || !GetBuf(m_hATR, 0, 1, 1, atr)
         || !GetRates(m_sym, p.trendTF, 1, 1, d1) || !GetRates(m_sym, m_tf, 1, n + 1, r))
         return false;
      MarkBar(bar);
      double a = atr[0];
      if(a <= 0)
         return false;

      int trend = (d1[0].close > ema[0]) ? 1 : (d1[0].close < ema[0] ? -1 : 0);
      if(trend == 0)
        {
         Status("no higher-timeframe trend");
         return false;
        }
      double o[], h[], l[], c[];
      RatesToArrays(r, o, h, l, c);
      double hi = SM_Highest(h, 1, n);
      double lo = SM_Lowest(l, 1, n);
      bool breakout = (trend > 0) ? c[0] > hi : c[0] < lo;
      if(!breakout)
        {
         Status(StringFormat("trend %s, waiting for a %d-bar %s breakout (%.2f)", trend > 0 ? "up" : "down",
                             n, trend > 0 ? "high" : "low", trend > 0 ? hi : lo));
         return false;
        }
      double slDist = p.stopATR * a;
      Fill(s, trend, slDist, 0.0, a, trend > 0 ? hi : lo);
      Status(StringFormat("%s signal: %d-bar breakout with the trend", trend > 0 ? "BUY" : "SELL", n));
      return true;
     }

   // Opposite breakout of the shorter exit channel on the last closed bar.
   virtual bool      ExitSignal(const int dir)
     {
      int n = MathMax(p.exitBars, 3);
      MqlRates r[];
      if(!GetRates(m_sym, m_tf, 1, n + 1, r))
         return false;
      double o[], h[], l[], c[];
      RatesToArrays(r, o, h, l, c);
      return (dir > 0) ? c[0] < SM_Lowest(l, 1, n) : c[0] > SM_Highest(h, 1, n);
     }
  };

#endif
