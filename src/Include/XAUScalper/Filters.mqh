//+------------------------------------------------------------------+
//|                                                     Filters.mqh  |
//|  Market filters checked before any new entry:                     |
//|  - max spread and spread-to-ATR                                   |
//|  - market hours: daily rollover, Friday close, Monday open        |
//|  - economic news (MQL5 economic calendar, high-impact USD events) |
//|  - abnormal volatility (last M1 bar range vs ATR)                 |
//|  - stale prices (no tick for too long)                            |
//|                                                                   |
//|  News: the MT5 calendar is not available in the Strategy Tester   |
//|  and can fail live. The filter then reports "unavailable" instead |
//|  of pretending that news protection is active.                    |
//+------------------------------------------------------------------+
#ifndef XAUSCALPER_FILTERS_MQH
#define XAUSCALPER_FILTERS_MQH

#include <XAUScalper\Common.mqh>
#include <XAUScalper\RiskMath.mqh>

struct FilterParams
  {
   double            maxSpread;          // price units, 0 = off
   double            maxSpreadATR;       // spread / ATR(M5), 0 = off
   int               rolloverFromHour;   // server time, no entries from...
   int               rolloverToHour;     // ...until (equal = off)
   int               fridayLastHour;     // no entries on Friday from this server hour (0 = off)
   int               mondayFirstHour;    // no entries on Monday before this server hour (0 = off)
   bool              useNews;
   int               newsBeforeMin;
   int               newsAfterMin;
   bool              blockIfNewsUnknown; // treat "calendar unavailable" as blocked
   double            maxM1RangeATR;      // last M1 range > this x ATR(M1) = abnormal, 0 = off
   int               volPauseMin;        // pause after abnormal volatility
   int               maxTickAgeSec;      // no tick for longer = stale prices, 0 = off
  };

class CFilters
  {
private:
   string            m_sym;
   FilterParams      p;
   int               hAtr5, hAtr1;
   string            m_newsStatus;
   bool              m_newsBlock;
   bool              m_newsKnown;
   datetime          m_newsChecked;
   datetime          m_volPauseUntil;
   datetime          m_lastM1Checked;

   void              CheckNews()
     {
      datetime now = TimeTradeServer();
      if(now - m_newsChecked < 60)
         return;
      m_newsChecked = now;
      m_newsBlock = false;
      if(!p.useNews)
        {
         m_newsKnown = false;
         m_newsStatus = "news filter OFF";
         return;
        }
      if(MQLInfoInteger(MQL_TESTER))
        {
         m_newsKnown = false;
         m_newsStatus = "news filter unavailable in tester";
         return;
        }
      MqlCalendarValue values[];
      datetime from = now - p.newsAfterMin * 60;
      datetime to   = now + p.newsBeforeMin * 60;
      ResetLastError();
      int n = CalendarValueHistory(values, from, to, NULL, "USD");
      if(n < 0 || (n == 0 && GetLastError() != 0))
        {
         m_newsKnown = false;
         m_newsStatus = "news data unavailable (calendar error " + IntegerToString(GetLastError()) + ")";
         return;
        }
      m_newsKnown = true;
      m_newsStatus = "no high-impact USD news nearby";
      for(int i = 0; i < n; i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev))
            continue;
         if(ev.importance != CALENDAR_IMPORTANCE_HIGH)
            continue;
         m_newsBlock = true;
         long mins = (long)(values[i].time - now) / 60;
         m_newsStatus = (mins >= 0) ? StringFormat("news: %s in %d min", ev.name, (int)mins)
                                    : StringFormat("news: %s %d min ago", ev.name, (int)-mins);
         break;
        }
     }

public:
                     CFilters() { hAtr5 = hAtr1 = INVALID_HANDLE; m_newsChecked = 0; m_volPauseUntil = 0;
                                  m_lastM1Checked = 0; m_newsBlock = false; m_newsKnown = false;
                                  m_newsStatus = "news not checked yet"; }
                    ~CFilters()
     {
      if(hAtr5 != INVALID_HANDLE) IndicatorRelease(hAtr5);
      if(hAtr1 != INVALID_HANDLE) IndicatorRelease(hAtr1);
     }

   bool              Init(const string sym, const FilterParams &params)
     {
      m_sym = sym;  p = params;
      hAtr5 = iATR(sym, PERIOD_M5, 14);
      hAtr1 = iATR(sym, PERIOD_M1, 14);
      return hAtr5 != INVALID_HANDLE && hAtr1 != INVALID_HANDLE;
     }

   string            NewsStatus() { return m_newsStatus; }
   bool              NewsActive() { return m_newsKnown; }

   // Called every timer tick: refreshes news and volatility state.
   void              Update()
     {
      CheckNews();
      datetime m1 = iTime(m_sym, PERIOD_M1, 0);
      if(p.maxM1RangeATR > 0 && m1 != 0 && m1 != m_lastM1Checked)
        {
         double atr[];
         MqlRates r[];
         if(GetBuf(hAtr1, 0, 2, 1, atr) && GetRates(m_sym, PERIOD_M1, 1, 1, r))
           {
            m_lastM1Checked = m1;
            if(atr[0] > 0 && (r[0].high - r[0].low) > p.maxM1RangeATR * atr[0])
              {
               m_volPauseUntil = TimeCurrent() + p.volPauseMin * 60;
               PrintFormat("Filters: abnormal M1 bar (range %.2f vs ATR %.2f), pausing %d min",
                           r[0].high - r[0].low, atr[0], p.volPauseMin);
              }
           }
        }
     }

   // "" = market conditions allow a new entry, otherwise the reason.
   string            Check()
     {
      MqlTick tick;
      if(!SymbolInfoTick(m_sym, tick))
         return "no price";
      double spread = tick.ask - tick.bid;
      if(p.maxSpread > 0 && spread > p.maxSpread)
         return StringFormat("spread too high (%.2f > %.2f)", spread, p.maxSpread);
      double atr[];
      if(p.maxSpreadATR > 0 && GetBuf(hAtr5, 0, 1, 1, atr) && atr[0] > 0 && spread / atr[0] > p.maxSpreadATR)
         return StringFormat("spread too high for current volatility (%.0f%% of ATR)", spread / atr[0] * 100.0);

      if(p.maxTickAgeSec > 0 && !MQLInfoInteger(MQL_TESTER) && TimeTradeServer() - tick.time > p.maxTickAgeSec)
         return "prices are stale (no recent tick)";

      MqlDateTime t;
      TimeToStruct(TimeTradeServer(), t);
      if(p.rolloverFromHour != p.rolloverToHour)
        {
         bool inRoll = (p.rolloverFromHour < p.rolloverToHour)
                       ? (t.hour >= p.rolloverFromHour && t.hour < p.rolloverToHour)
                       : (t.hour >= p.rolloverFromHour || t.hour < p.rolloverToHour);
         if(inRoll)
            return "daily rollover hours (wide spreads)";
        }
      if(p.fridayLastHour > 0 && t.day_of_week == 5 && t.hour >= p.fridayLastHour)
         return "Friday close approaching: no new trades";
      if(p.mondayFirstHour > 0 && t.day_of_week == 1 && t.hour < p.mondayFirstHour)
         return "Monday open: waiting for normal liquidity";

      if(TimeCurrent() < m_volPauseUntil)
         return StringFormat("abnormal volatility pause (%d min left)",
                             (int)MathCeil((m_volPauseUntil - TimeCurrent()) / 60.0));
      if(p.useNews && m_newsBlock)
         return m_newsStatus;
      if(p.useNews && !m_newsKnown && p.blockIfNewsUnknown && !MQLInfoInteger(MQL_TESTER))
         return m_newsStatus;
      return "";
     }
  };

#endif
