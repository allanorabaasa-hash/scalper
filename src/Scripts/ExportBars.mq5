//+------------------------------------------------------------------+
//|                                                  ExportBars.mq5  |
//| Writes the chart symbol's bars to CSV files in Common/Files for  |
//| tools/backtest_ema_trend.py:  <symbol>_<TF>.csv and <symbol>_D1  |
//+------------------------------------------------------------------+
#property script_show_inputs
#property version "1.00"

input ENUM_TIMEFRAMES InpTF   = PERIOD_M5;   // Trading timeframe to export (D1 is always exported too)
input int             InpBars = 200000;      // Max bars (MT5 limit: Tools > Options > Charts > Max bars)

bool Export(const ENUM_TIMEFRAMES tf, const int count)
  {
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int n = CopyRates(_Symbol, tf, 0, count, r);
   if(n <= 0)
     {
      Print("ExportBars: no data for ", EnumToString(tf), " (error ", GetLastError(), ")");
      return false;
     }
   string tfName = StringSubstr(EnumToString(tf), 7);   // PERIOD_M5 -> M5
   string file = _Symbol + "_" + tfName + ".csv";
   int h = FileOpen(file, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(h == INVALID_HANDLE)
     {
      Print("ExportBars: cannot write ", file);
      return false;
     }
   FileWrite(h, "time", "open", "high", "low", "close", "spread_points");
   for(int i = 0; i < n - 1; i++)                         // skip the bar still forming
      FileWrite(h, TimeToString(r[i].time, TIME_DATE | TIME_MINUTES), DoubleToString(r[i].open, _Digits),
                DoubleToString(r[i].high, _Digits), DoubleToString(r[i].low, _Digits),
                DoubleToString(r[i].close, _Digits), IntegerToString(r[i].spread));
   FileClose(h);
   Print("ExportBars: ", n - 1, " bars -> Common/Files/", file, "  from ", TimeToString(r[0].time), " to ",
         TimeToString(r[n - 2].time));
   return true;
  }

void OnStart()
  {
   Export(InpTF, InpBars);
   Export(PERIOD_D1, 5000);
  }
