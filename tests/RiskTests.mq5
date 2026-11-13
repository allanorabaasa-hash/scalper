//+------------------------------------------------------------------+
//|                                                  RiskTests.mq5   |
//|  Unit tests for the risk calculations in RiskMath.mqh.            |
//|  Run: drag it from Navigator > Scripts > XAUScalper onto any      |
//|  chart. Results appear in the Experts tab and in an alert.        |
//+------------------------------------------------------------------+
#property script_show_inputs false
#include <XAUScalper\RiskMath.mqh>

int g_pass = 0;
int g_fail = 0;

void Check(const string name, const bool ok, const string detail = "")
  {
   if(ok)
     {
      g_pass++;
      Print("PASS  ", name);
     }
   else
     {
      g_fail++;
      Print("FAIL  ", name, "  ", detail);
     }
  }

bool Near(const double a, const double b, const double eps = 1e-6) { return MathAbs(a - b) <= eps; }

// XAUUSD-like contract: tick size 0.001, tick value 0.1 per 1.0 lot
// (= $100 per $1 move per lot, $1 per $1 move at 0.01 lot), min 0.01, max 200, step 0.01.
double Size(const double equity, const double riskPct, const double sl, const double cap,
            string &reason, double &riskOut)
  {
   return RM_PositionSize(equity, riskPct, sl, 0.001, 0.1, 0.01, 200.0, 0.01, cap, reason, riskOut);
  }

void OnStart()
  {
   string reason;
   double risk, lots;

   //--- position sizing
   lots = Size(5000, 0.5, 3.0, 0, reason, risk);
   Check("5000 equity, 0.5%, SL 3.00 -> 0.08 lots (rounded down)", Near(lots, 0.08), DoubleToString(lots, 4));
   Check("  real risk 0.48% (never above 0.5%)", Near(risk, 0.48, 1e-4), DoubleToString(risk, 4));

   lots = Size(1000, 0.5, 2.5, 0, reason, risk);
   Check("1000 equity, 0.5%, SL 2.50 -> exactly 0.02 lots", Near(lots, 0.02), DoubleToString(lots, 4));

   lots = Size(25, 0.5, 3.0, 0, reason, risk);
   Check("$25, strict mode, SL 3.00 -> rejected (min lot risks 12%)", lots == 0.0, DoubleToString(lots, 4));
   Check("  reason mentions minimum lot", StringFind(reason, "minimum lot") >= 0, reason);
   Check("  never raised to the minimum lot", lots < 0.01);

   lots = Size(25, 0.5, 2.0, 10.0, reason, risk);
   Check("$25, min-lot cap 10%, SL 2.00 -> 0.01 lots (8% risk)", Near(lots, 0.01), DoubleToString(lots, 4));
   Check("  reported risk 8%", Near(risk, 8.0, 1e-4), DoubleToString(risk, 4));

   lots = Size(25, 0.5, 3.0, 10.0, reason, risk);
   Check("$25, min-lot cap 10%, SL 3.00 -> rejected (12% > 10%)", lots == 0.0, DoubleToString(lots, 4));

   lots = Size(1e7, 1.0, 1.0, 0, reason, risk);
   Check("huge account -> clamped to max volume 200", Near(lots, 200.0), DoubleToString(lots, 4));

   lots = RM_PositionSize(5000, 1.0, 1.0, 0.001, 0.1, 0.1, 100, 0.1, 0, reason, risk);
   Check("volume step 0.1: 0.50 lots stays 0.5", Near(lots, 0.5), DoubleToString(lots, 4));
   lots = RM_PositionSize(5000, 1.0, 1.1, 0.001, 0.1, 0.1, 100, 0.1, 0, reason, risk);
   Check("volume step 0.1: 0.4545 lots rounds DOWN to 0.4", Near(lots, 0.4), DoubleToString(lots, 4));

   Check("SL 0 -> rejected",            Size(5000, 0.5, 0.0, 0, reason, risk) == 0.0);
   Check("equity 0 -> rejected",        Size(0, 0.5, 3.0, 0, reason, risk) == 0.0);
   Check("risk 0% -> rejected",         Size(5000, 0.0, 3.0, 0, reason, risk) == 0.0);
   Check("tick value 0 -> rejected",
         RM_PositionSize(5000, 0.5, 3.0, 0.001, 0.0, 0.01, 200, 0.01, 0, reason, risk) == 0.0);

   //--- consecutive losses
   double a[] = {1.0, -1.0, -1.0};
   Check("streak: win, loss, loss -> 2", RM_ConsecutiveLosses(a) == 2);
   double b[] = {-1.0, -1.0, -1.0};
   Check("streak: three losses -> 3", RM_ConsecutiveLosses(b) == 3);
   double c[] = {-1.0, 1.0};
   Check("streak: ends with a win -> 0", RM_ConsecutiveLosses(c) == 0);
   double d[] = {-1.0, 0.0, -1.0};
   Check("streak: break-even resets -> 1", RM_ConsecutiveLosses(d) == 1);
   double e[];
   Check("streak: no trades -> 0", RM_ConsecutiveLosses(e) == 0);

   //--- trading day boundary
   Check("day start of 2026.11.13 09:33:20 is 2026.11.13 00:00",
         RM_DayStart(D'2026.11.13 09:33:20') == D'2026.11.13 00:00:00');
   Check("day start at exactly midnight is that midnight",
         RM_DayStart(D'2026.11.14 00:00:00') == D'2026.11.14 00:00:00');

   //--- daily loss / target / drawdown
   Check("daily loss: 100 -> 98 at 2% is hit",          RM_DailyLossHit(100, 98, 2.0));
   Check("daily loss: 100 -> 98.01 at 2% is not hit",   !RM_DailyLossHit(100, 98.01, 2.0));
   Check("daily loss: 0% means off",                   !RM_DailyLossHit(100, 50, 0.0));
   Check("daily target: 100 -> 103 at 3% is hit",       RM_DailyTargetHit(100, 103, 3.0));
   Check("daily target: 0% means off",                 !RM_DailyTargetHit(100, 200, 0.0));
   Check("drawdown 100 -> 85 is 15%",                   Near(RM_DayDrawdownPct(100, 85), 15.0));
   Check("drawdown when equity is up is 0%",            RM_DayDrawdownPct(100, 110) == 0.0);

   string summary = StringFormat("RiskTests: %d passed, %d failed", g_pass, g_fail);
   Print(summary);
   Alert(summary);
  }
