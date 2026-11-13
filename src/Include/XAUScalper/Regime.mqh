//+------------------------------------------------------------------+
//|                                                      Regime.mqh  |
//|  Market regime detector (M15, closed bars, once per new bar).     |
//|                                                                   |
//|  Each regime has a short list of conditions. Its score is the     |
//|  share of conditions that are true (0..1). The first regime, in   |
//|  priority order, whose score reaches MinScore is selected:        |
//|    DANGER > REVERSAL > BREAKOUT > MOMENTUM > TREND > RANGE        |
//|  Nothing qualifies -> UNCLEAR, and the system waits.              |
//|                                                                   |
//|  The score is a rule-agreement count. It is NOT a probability of  |
//|  a winning trade.                                                 |
//+------------------------------------------------------------------+
#ifndef XAUSCALPER_REGIME_MQH
#define XAUSCALPER_REGIME_MQH

#include <XAUScalper\Common.mqh>
#include <XAUScalper\Levels.mqh>

struct RegimeParams
  {
   double            minScore;          // 0..1, score needed to select a regime
   double            dangerATRMult;     // ATR above this x its average = dangerous
   double            trendADX;          // ADX for a trend
   double            momentumADX;       // ADX for strong momentum
   double            rangeADX;          // ADX below this for a range
   double            squeezePct;        // Bollinger width percentile counted as a squeeze
  };

class CRegime
  {
private:
   string            m_sym;
   RegimeParams      p;
   SessionHours      m_sh;
   int               hAdx, hE50, hE200, hAtr, hBands;
   datetime          m_lastBar;
   ENUM_REGIME       m_regime;
   double            m_score;
   string            m_detail;

   double            Score(const bool &c[])
     {
      int n = ArraySize(c), t = 0;
      for(int i = 0; i < n; i++)
         if(c[i])
            t++;
      return (n > 0) ? (double)t / n : 0.0;
     }

   void              Set(const ENUM_REGIME r, const double score, const string detail)
     {
      if(r != m_regime)
         PrintFormat("Regime: %s -> %s (score %.2f) %s", RegimeName(m_regime), RegimeName(r), score, detail);
      m_regime = r;
      m_score  = score;
      m_detail = detail;
     }

public:
                     CRegime() { hAdx = hE50 = hE200 = hAtr = hBands = INVALID_HANDLE; m_lastBar = 0;
                                 m_regime = REGIME_UNCLEAR; m_score = 0; m_detail = "waiting for data"; }
                    ~CRegime()
     {
      if(hAdx != INVALID_HANDLE)   IndicatorRelease(hAdx);
      if(hE50 != INVALID_HANDLE)   IndicatorRelease(hE50);
      if(hE200 != INVALID_HANDLE)  IndicatorRelease(hE200);
      if(hAtr != INVALID_HANDLE)   IndicatorRelease(hAtr);
      if(hBands != INVALID_HANDLE) IndicatorRelease(hBands);
     }

   bool              Init(const string sym, const RegimeParams &params, const SessionHours &sh)
     {
      m_sym = sym;  p = params;  m_sh = sh;
      hAdx   = iADX(sym, PERIOD_M15, 14);
      hE50   = iMA(sym, PERIOD_M15, 50, 0, MODE_EMA, PRICE_CLOSE);
      hE200  = iMA(sym, PERIOD_M15, 200, 0, MODE_EMA, PRICE_CLOSE);
      hAtr   = iATR(sym, PERIOD_M15, 14);
      hBands = iBands(sym, PERIOD_M15, 20, 0, 2.0, PRICE_CLOSE);
      return hAdx != INVALID_HANDLE && hE50 != INVALID_HANDLE && hE200 != INVALID_HANDLE
             && hAtr != INVALID_HANDLE && hBands != INVALID_HANDLE;
     }

   ENUM_REGIME       Regime() { return m_regime; }
   double            ScoreValue() { return m_score; }
   string            Detail() { return m_detail; }
   void              Reset() { m_lastBar = 0; }

   // Recomputes on a new M15 bar. Returns true when it was recomputed.
   bool              Update()
     {
      datetime bar = iTime(m_sym, PERIOD_M15, 0);
      if(bar == 0 || bar == m_lastBar)
         return false;

      const int W = 100;
      double adx[], e50[], e200[], atr[], up[], lo[], mid[];
      MqlRates r[];
      if(!GetBuf(hAdx, 0, 1, 3, adx) || !GetBuf(hE50, 0, 1, 6, e50) || !GetBuf(hE200, 0, 1, 1, e200)
         || !GetBuf(hAtr, 0, 1, 51, atr) || !GetBuf(hBands, 1, 1, W, up) || !GetBuf(hBands, 2, 1, W, lo)
         || !GetBuf(hBands, 0, 1, W, mid) || !GetRates(m_sym, PERIOD_M15, 1, 6, r))
         return false;
      m_lastBar = bar;

      double atrNow = atr[0];
      double atrAvg = SM_Average(atr, 1, 50);
      if(atrAvg <= 0)
         return false;
      double close = r[0].close;
      double slope = e50[0] - e50[5];

      double width[];
      ArrayResize(width, W);
      for(int i = 0; i < W; i++)
         width[i] = (mid[i] > 0) ? (up[i] - lo[i]) / mid[i] : 0.0;
      double rankNow = SM_PercentRank(width, 1, W - 1, width[0]);
      double minRecentRank = 1.0;
      for(int i = 1; i <= 5; i++)
         minRecentRank = MathMin(minRecentRank, SM_PercentRank(width, i + 1, W - i - 1, width[i]));

      // --- DANGER: abnormal volatility
      if(atrNow > p.dangerATRMult * atrAvg)
        {
         Set(REGIME_DANGER, 1.0, StringFormat("ATR %.2f is %.1fx normal", atrNow, atrNow / atrAvg));
         return true;
        }

      // --- REVERSAL: a recent M15 bar swept the previous day / Asian high or low and closed back
      bool sweep = false;
      string swept = "";
      KeyLevel levels[];
      GetKeyLevels(m_sym, m_sh, 60, 3, levels);
      for(int k = 0; k < ArraySize(levels) && !sweep; k++)
        {
         int kind = levels[k].kind;
         if(kind != LVL_PDH && kind != LVL_PDL && kind != LVL_ASIA_H && kind != LVL_ASIA_L)
            continue;
         for(int i = 0; i < 4 && !sweep; i++)
           {
            bool s = IsHighLevel(kind)
                     ? SM_SweepAbove(r[i].high, r[i].close, levels[k].price, atrNow, 0.1, 2.0)
                     : SM_SweepBelow(r[i].low, r[i].close, levels[k].price, atrNow, 0.1, 2.0);
            if(s)
              {
               sweep = true;
               swept = LevelName(kind);
              }
           }
        }
      bool rev[3];
      rev[0] = sweep;
      rev[1] = adx[0] < p.momentumADX;
      rev[2] = MathAbs(close - e50[0]) < 2.5 * atrAvg;
      double sRev = sweep ? Score(rev) : 0.0;

      // --- BREAKOUT: squeeze recently, now closing outside the bands with widening bands
      bool brk[3];
      brk[0] = minRecentRank <= p.squeezePct;
      brk[1] = close > up[0] || close < lo[0];
      brk[2] = width[0] > width[1];
      double sBrk = brk[1] ? Score(brk) : 0.0;

      // --- MOMENTUM: strong, rising ADX with a large bar in the direction of EMA 50
      double body = r[0].close - r[0].open;
      bool mom[4];
      mom[0] = adx[0] > p.momentumADX;
      mom[1] = adx[0] > adx[1];
      mom[2] = MathAbs(body) >= 1.2 * atrAvg;
      mom[3] = (body > 0 && slope > 0) || (body < 0 && slope < 0);
      double sMom = Score(mom);

      // --- TREND: ADX, EMA 50/200 aligned with price, EMA 50 sloping
      bool up_ = (e50[0] > e200[0] && close > e50[0] && slope > 0);
      bool dn_ = (e50[0] < e200[0] && close < e50[0] && slope < 0);
      bool trn[3];
      trn[0] = adx[0] >= p.trendADX;
      trn[1] = up_ || dn_;
      trn[2] = MathAbs(slope) >= 0.2 * atrAvg;
      double sTrn = Score(trn);

      // --- RANGE: weak ADX, narrow bands, price around EMA 50, flat EMA 50
      bool rng[4];
      rng[0] = adx[0] < p.rangeADX;
      rng[1] = rankNow <= 0.5;
      rng[2] = MathAbs(close - e50[0]) < 1.0 * atrAvg;
      rng[3] = MathAbs(slope) < 0.15 * atrAvg;
      double sRng = Score(rng);

      string sc = StringFormat("rev %.2f brk %.2f mom %.2f trend %.2f range %.2f", sRev, sBrk, sMom, sTrn, sRng);
      if(sRev >= p.minScore)
         Set(REGIME_REVERSAL, sRev, swept + " swept; " + sc);
      else if(sBrk >= p.minScore)
         Set(REGIME_BREAKOUT, sBrk, sc);
      else if(sMom >= p.minScore)
         Set(REGIME_MOMENTUM, sMom, sc);
      else if(sTrn >= p.minScore)
         Set(REGIME_TREND, sTrn, sc);
      else if(sRng >= p.minScore)
         Set(REGIME_RANGE, sRng, sc);
      else
         Set(REGIME_UNCLEAR, MathMax(MathMax(sTrn, sRng), sMom), sc);
      return true;
     }

  };

#endif
