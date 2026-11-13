//+------------------------------------------------------------------+
//|                                                StrategyBase.mqh  |
//|  Base class for the five strategies.                              |
//|                                                                   |
//|  Rules shared by all strategies:                                  |
//|  - signals use CLOSED bars only (shift >= 1)                      |
//|  - each strategy evaluates once per new bar of its timeframe, so  |
//|    one setup produces at most one signal per bar                  |
//|  - a strategy proposes direction, stop and target; it never sizes |
//|    or approves a trade (that is the risk manager's job)           |
//+------------------------------------------------------------------+
#ifndef XAUSCALPER_STRATEGYBASE_MQH
#define XAUSCALPER_STRATEGYBASE_MQH

#include <XAUScalper\Common.mqh>
#include <XAUScalper\Levels.mqh>

// How an open position of this strategy is managed.
struct ManagePlan
  {
   double            beR;          // move stop to breakeven at this multiple of initial risk (0 = off)
   double            trailStartR;  // start trailing at this multiple of initial risk (0 = off)
   double            trailATR;     // trailing distance in ATR of the strategy timeframe
   int               maxHoldMin;   // close after this many minutes (0 = off)
   int               staleMin;     // close if not at staleR x risk after this many minutes (0 = off)
   double            staleR;
  };

class CStrategy
  {
protected:
   string            m_sym;
   string            m_status;
   datetime          m_lastBar;
   ENUM_TIMEFRAMES   m_tf;        // timeframe whose new bar triggers an evaluation
   int               m_hATR;      // ATR used for stops and trailing
   ManagePlan        m_plan;

public:
   virtual int       Id()   { return STRAT_NONE; }

protected:
   // True when a bar of m_tf has opened that was not evaluated yet.
   bool              PendingBar(datetime &bar)
     {
      bar = iTime(m_sym, m_tf, 0);
      return (bar != 0 && bar != m_lastBar);
     }
   // Call once the data for `bar` was read successfully.
   void              MarkBar(const datetime bar) { m_lastBar = bar; }
   void              Status(const string s) { m_status = s; }

   // Applies min/max stop distance in ATR. Returns false when the stop is too wide.
   bool              ClampStop(double &slDist, const double atr, const double minATR, const double maxATR)
     {
      if(slDist < minATR * atr)
         slDist = minATR * atr;
      if(maxATR > 0 && slDist > maxATR * atr)
        {
         Status(StringFormat("setup skipped: stop %.2f wider than %.1f x ATR", slDist, maxATR));
         return false;
        }
      return true;
     }

   void              Fill(TradeSignal &s, const int dir, const double slDist, const double tpDist,
                          const double atr, const double level)
     {
      s.dir = dir;  s.strat = Id();  s.slDist = slDist;  s.tpDist = tpDist;  s.atr = atr;  s.level = level;
     }

public:
                     CStrategy() { m_lastBar = 0; m_hATR = INVALID_HANDLE; m_status = "waiting for data"; m_tf = PERIOD_M5; }
   virtual          ~CStrategy() { if(m_hATR != INVALID_HANDLE) IndicatorRelease(m_hATR); }

   virtual bool      Ready() { return m_hATR != INVALID_HANDLE; }
   // Fills `s` and returns true when a new signal appeared on the last closed bar.
   virtual bool      Evaluate(TradeSignal &s) { return false; }
   // True when an open position in direction `dir` has lost its momentum.
   virtual bool      ExitSignal(const int dir) { return false; }

   string            Name()   { return StrategyCode(Id()); }
   string            GetStatus() { return m_status; }
   void              SetIdle(const string why) { m_status = why; }
   void              ResetBar() { m_lastBar = 0; }
   void              GetPlan(ManagePlan &p) { p = m_plan; }
   double            CurrentATR()
     {
      double b[];
      if(GetBuf(m_hATR, 0, 1, 1, b))
         return b[0];
      return 0.0;
     }
  };

#endif
