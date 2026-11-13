//+------------------------------------------------------------------+
//|                                                     Journal.mqh  |
//|  CSV trade journal in the terminal's COMMON files folder, so live |
//|  runs and Strategy Tester runs write to the same place:           |
//|    .../MetaQuotes/Terminal/Common/Files/                          |
//|  Live: XAUScalper_trades.csv                                      |
//|  Tester: XAUScalper_tester_trades.csv (recreated on each test)    |
//|  Read by tools/analyze_trades.py.                                 |
//+------------------------------------------------------------------+
#ifndef XAUSCALPER_JOURNAL_MQH
#define XAUSCALPER_JOURNAL_MQH

#define JOURNAL_HEADER "event,time,account,mode,position,side,strategy,regime,lots,price,spread,sl_dist,tp_dist,atr,risk_money,risk_pct,spread_cost,profit,commission,hold_s,r_multiple,reason"

string g_journalFile = "XAUScalper_trades.csv";
bool   g_journalOn   = true;

void JournalInit(const bool enabled)
  {
   g_journalOn = enabled && !MQLInfoInteger(MQL_OPTIMIZATION);
   if(MQLInfoInteger(MQL_TESTER))
     {
      g_journalFile = "XAUScalper_tester_trades.csv";
      if(g_journalOn)
         FileDelete(g_journalFile, FILE_COMMON);
     }
  }

string AccountMode()
  {
   if(MQLInfoInteger(MQL_TESTER))
      return "tester";
   long m = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(m == ACCOUNT_TRADE_MODE_REAL)
      return "real";
   if(m == ACCOUNT_TRADE_MODE_CONTEST)
      return "contest";
   return "demo";
  }

// Commas are not allowed inside fields.
string CsvSafe(const string s)
  {
   string t = s;
   StringReplace(t, ",", ";");
   StringReplace(t, "\n", " ");
   return t;
  }

void JournalLine(const string line)
  {
   if(!g_journalOn)
      return;
   int h = FileOpen(g_journalFile, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
     {
      Print("Journal: cannot open ", g_journalFile, " (error ", GetLastError(), ")");
      return;
     }
   if(FileSize(h) == 0)
      FileWriteString(h, JOURNAL_HEADER + "\r\n");
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, line + "\r\n");
   FileClose(h);
  }

string JF(const double v, const int digits) { return DoubleToString(v, digits); }

void JournalOpen(const long position, const int dir, const string strategy, const string regime,
                 const double lots, const double price, const double spread, const double slDist,
                 const double tpDist, const double atr, const double riskMoney, const double riskPct,
                 const double spreadCost, const string note)
  {
   string line = StringFormat("OPEN,%s,%I64d,%s,%I64d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,,,,,%s",
                              TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
                              AccountInfoInteger(ACCOUNT_LOGIN), AccountMode(), position,
                              dir > 0 ? "BUY" : "SELL", strategy, CsvSafe(regime),
                              JF(lots, 2), JF(price, _Digits), JF(spread, _Digits), JF(slDist, 3), JF(tpDist, 3),
                              JF(atr, 3), JF(riskMoney, 2), JF(riskPct, 3), JF(spreadCost, 2), CsvSafe(note));
   JournalLine(line);
  }

void JournalClose(const long position, const string side, const string strategy, const double lots,
                  const double price, const double profit, const double commission, const double holdSec,
                  const double rMultiple, const bool hasR, const string reason)
  {
   string line = StringFormat("CLOSE,%s,%I64d,%s,%I64d,%s,%s,,%s,%s,,,,,,,,%s,%s,%s,%s,%s",
                              TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
                              AccountInfoInteger(ACCOUNT_LOGIN), AccountMode(), position, side, strategy,
                              JF(lots, 2), JF(price, _Digits), JF(profit, 2), JF(commission, 2), JF(holdSec, 1),
                              hasR ? JF(rMultiple, 3) : "", CsvSafe(reason));
   JournalLine(line);
  }

#endif
