//+------------------------------------------------------------------+
//|                                                    RiskMath.mqh  |
//|  Pure risk calculations: no MT5 state, so they can be unit-tested |
//|  (tests/RiskTests.mq5).                                           |
//+------------------------------------------------------------------+
#ifndef XAUSCALPER_RISKMATH_MQH
#define XAUSCALPER_RISKMATH_MQH

// Decimal places of a volume step (0.01 -> 2, 0.1 -> 1, 1 -> 0).
int RM_VolumeDigits(double step)
  {
   int d = 0;
   while(step < 1.0 - 1e-9 && d < 8)
     {
      step *= 10.0;
      d++;
     }
   return d;
  }

// Round a volume DOWN to the broker's volume step (never up).
double RM_FloorToStep(const double lots, const double step)
  {
   if(step <= 0)
      return lots;
   double n = MathFloor(lots / step + 1e-9);
   return NormalizeDouble(n * step, RM_VolumeDigits(step));
  }

// Money lost per 1.0 lot if price moves slDist against the position.
// tickValue is the broker's loss value of one tick for 1.0 lot (it already
// contains the contract size), so contract size is not applied twice.
double RM_LossPerLot(const double slDist, const double tickSize, const double tickValue)
  {
   if(slDist <= 0 || tickSize <= 0 || tickValue <= 0)
      return 0.0;
   return slDist / tickSize * tickValue;
  }

//+------------------------------------------------------------------+
//| Position size from equity, risk % and stop distance.              |
//|                                                                   |
//| Returns the volume, or 0.0 when the trade must be rejected        |
//| (reason explains why). riskPctOut = real % of equity at risk.     |
//|                                                                   |
//| minLotMaxRiskPct: what to do when the risk-based size is below    |
//| the broker minimum volume.                                        |
//|   0   -> reject (strict: never raise the size to the minimum)     |
//|   > 0 -> use the minimum volume only if its risk is <= this %     |
//|          of equity, otherwise reject.                             |
//+------------------------------------------------------------------+
double RM_PositionSize(const double equity, const double riskPct, const double slDist,
                       const double tickSize, const double tickValue,
                       const double volMin, const double volMax, const double volStep,
                       const double minLotMaxRiskPct,
                       string &reason, double &riskPctOut)
  {
   reason     = "";
   riskPctOut = 0.0;

   if(equity <= 0)
     {
      reason = "equity is zero or negative";
      return 0.0;
     }
   if(riskPct <= 0)
     {
      reason = "risk % must be above 0";
      return 0.0;
     }
   double lossPerLot = RM_LossPerLot(slDist, tickSize, tickValue);
   if(lossPerLot <= 0)
     {
      reason = "invalid stop distance or symbol tick data";
      return 0.0;
     }
   if(volMin <= 0 || volStep <= 0 || volMax < volMin)
     {
      reason = "invalid broker volume limits";
      return 0.0;
     }

   double riskMoney = equity * riskPct / 100.0;
   double lots      = RM_FloorToStep(riskMoney / lossPerLot, volStep);

   if(lots < volMin - 1e-9)
     {
      double riskAtMin = volMin * lossPerLot / equity * 100.0;
      if(minLotMaxRiskPct > 0 && riskAtMin <= minLotMaxRiskPct + 1e-9)
        {
         riskPctOut = riskAtMin;
         reason     = StringFormat("minimum lot used: risk %.1f%% (allowed up to %.1f%%)",
                                   riskAtMin, minLotMaxRiskPct);
         return NormalizeDouble(volMin, RM_VolumeDigits(volStep));
        }
      reason = StringFormat("minimum lot too large: it would risk %.1f%% of equity (limit %.1f%%)",
                            riskAtMin, (minLotMaxRiskPct > 0 ? minLotMaxRiskPct : riskPct));
      return 0.0;
     }

   if(lots > volMax)
      lots = RM_FloorToStep(volMax, volStep);

   riskPctOut = lots * lossPerLot / equity * 100.0;
   return lots;
  }

// Number of losing trades at the END of the list (oldest first, newest last).
// A trade with net result < 0 is a loss; a win or a break-even (0) ends the streak.
int RM_ConsecutiveLosses(const double &nets[])
  {
   int n = 0;
   for(int i = ArraySize(nets) - 1; i >= 0; i--)
     {
      if(nets[i] < 0)
         n++;
      else
         break;
     }
   return n;
  }

// Start (00:00) of the trading day that contains t, in the same clock as t
// (pass broker server time to get the broker's day boundary).
datetime RM_DayStart(const datetime t)
  {
   long v = (long)t;
   return (datetime)(v - v % 86400);
  }

// True when equity has fallen by at least pct % of the day's starting equity.
bool RM_DailyLossHit(const double dayStartEquity, const double equity, const double pct)
  {
   if(pct <= 0 || dayStartEquity <= 0)
      return false;
   return (dayStartEquity - equity) >= dayStartEquity * pct / 100.0 - 1e-9;
  }

// True when equity has risen by at least pct % of the day's starting equity.
bool RM_DailyTargetHit(const double dayStartEquity, const double equity, const double pct)
  {
   if(pct <= 0 || dayStartEquity <= 0)
      return false;
   return (equity - dayStartEquity) >= dayStartEquity * pct / 100.0 - 1e-9;
  }

// Drawdown of equity from the day's starting equity, in % (0 if equity is higher).
double RM_DayDrawdownPct(const double dayStartEquity, const double equity)
  {
   if(dayStartEquity <= 0 || equity >= dayStartEquity)
      return 0.0;
   return (dayStartEquity - equity) / dayStartEquity * 100.0;
  }

#endif
