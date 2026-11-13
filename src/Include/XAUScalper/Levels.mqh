//+------------------------------------------------------------------+
//|                                                      Levels.mqh  |
//|  Key price levels: previous day, Asian session, previous session  |
//|  and recent swing highs/lows. Session hours are broker server     |
//|  hours (Exness: GMT).                                             |
//+------------------------------------------------------------------+
#ifndef XAUSCALPER_LEVELS_MQH
#define XAUSCALPER_LEVELS_MQH

#include <XAUScalper\Common.mqh>
#include <XAUScalper\RiskMath.mqh>

#define LVL_PDH      1   // previous day high
#define LVL_PDL      2   // previous day low
#define LVL_ASIA_H   3
#define LVL_ASIA_L   4
#define LVL_SESS_H   5   // previous completed session high
#define LVL_SESS_L   6
#define LVL_SWING_H  7
#define LVL_SWING_L  8

struct KeyLevel
  {
   double            price;
   int               kind;
  };

struct SessionHours
  {
   int               asiaStart;
   int               asiaEnd;
   int               londonStart;
   int               londonEnd;
   int               nyStart;
   int               nyEnd;
  };

bool IsHighLevel(const int kind)
  {
   return kind == LVL_PDH || kind == LVL_ASIA_H || kind == LVL_SESS_H || kind == LVL_SWING_H;
  }

string LevelName(const int kind)
  {
   switch(kind)
     {
      case LVL_PDH:     return "prev day high";
      case LVL_PDL:     return "prev day low";
      case LVL_ASIA_H:  return "Asian high";
      case LVL_ASIA_L:  return "Asian low";
      case LVL_SESS_H:  return "prev session high";
      case LVL_SESS_L:  return "prev session low";
      case LVL_SWING_H: return "swing high";
      case LVL_SWING_L: return "swing low";
     }
   return "level";
  }

void AddLevel(KeyLevel &levels[], const double price, const int kind)
  {
   if(price <= 0 || price == DBL_MAX || price == -DBL_MAX)
      return;
   int n = ArraySize(levels);
   ArrayResize(levels, n + 1, 8);
   levels[n].price = price;
   levels[n].kind  = kind;
  }

// Fills `levels` with the current key levels. Returns the number of levels.
int GetKeyLevels(const string sym, const SessionHours &sh, const int swingBars, const int swingStrength,
                 KeyLevel &levels[])
  {
   ArrayResize(levels, 0);

   // Previous day
   double pdh = iHigh(sym, PERIOD_D1, 1);
   double pdl = iLow(sym, PERIOD_D1, 1);
   if(pdh > 0 && pdl > 0)
     {
      AddLevel(levels, pdh, LVL_PDH);
      AddLevel(levels, pdl, LVL_PDL);
     }

   // Sessions from M15 bars of the last two days
   MqlRates r[];
   datetime now   = TimeCurrent();
   datetime today = RM_DayStart(now);
   if(GetRates(sym, PERIOD_M15, 0, 200, r))
     {
      double hi, lo;
      // Asian range of today, once the Asian session has ended
      if(now >= today + sh.asiaEnd * 3600
         && SM_RangeInWindow(r, today + sh.asiaStart * 3600, today + sh.asiaEnd * 3600, hi, lo))
        {
         AddLevel(levels, hi, LVL_ASIA_H);
         AddLevel(levels, lo, LVL_ASIA_L);
        }
      // Previous completed session: NY -> London, London -> Asia, Asia -> yesterday's NY
      datetime from = 0, to = 0;
      int hour = (int)((now - today) / 3600);
      if(hour >= sh.nyStart)
        { from = today + sh.londonStart * 3600;  to = today + sh.londonEnd * 3600; }
      else if(hour >= sh.londonStart)
        { from = today + sh.asiaStart * 3600;    to = today + sh.asiaEnd * 3600; }
      else
        { from = today - 86400 + sh.nyStart * 3600;  to = today - 86400 + sh.nyEnd * 3600; }
      if(SM_RangeInWindow(r, from, to, hi, lo))
        {
         AddLevel(levels, hi, LVL_SESS_H);
         AddLevel(levels, lo, LVL_SESS_L);
        }
     }

   // Most recent swing high and swing low on M15 (closed bars only)
   MqlRates s[];
   if(swingBars > 2 * swingStrength + 2 && GetRates(sym, PERIOD_M15, 1, swingBars, s))
     {
      double o[], h[], l[], c[];
      RatesToArrays(s, o, h, l, c);
      int ih = SM_LastSwingHigh(h, swingStrength, swingBars - swingStrength - 1, swingStrength);
      int il = SM_LastSwingLow(l, swingStrength, swingBars - swingStrength - 1, swingStrength);
      if(ih >= 0)
         AddLevel(levels, h[ih], LVL_SWING_H);
      if(il >= 0)
         AddLevel(levels, l[il], LVL_SWING_L);
     }
   return ArraySize(levels);
  }

#endif
