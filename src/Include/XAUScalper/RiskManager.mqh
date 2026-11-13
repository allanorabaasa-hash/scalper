//+------------------------------------------------------------------+
//|                                                 RiskManager.mqh  |
//|  Independent risk manager. Strategies ask CanOpen() and           |
//|  SizeTrade(); they never size or approve trades themselves.       |
//|                                                                   |
//|  - Position size from equity, risk %, stop distance and the       |
//|    broker's tick size / tick value / volume limits                |
//|  - Daily loss limit and optional profit target (% of the equity   |
//|    at the start of the broker's trading day)                      |
//|  - Max consecutive losses, max trades per day, max open           |
//|    positions, minimum time between trades, cooldown after a loss  |
//|  - Emergency shutdown (equity drawdown, margin level or manual)   |
//|  - Daily state is saved in terminal global variables, so a        |
//|    restart cannot reset a lock or the day's starting equity       |
//+------------------------------------------------------------------+
#ifndef XAUSCALPER_RISKMANAGER_MQH
#define XAUSCALPER_RISKMANAGER_MQH

#include <XAUScalper\RiskMath.mqh>

enum ENUM_EMERGENCY_POLICY
  {
   EMERGENCY_CLOSE_ALL = 0,   // Close all bot positions
   EMERGENCY_KEEP      = 1    // Keep positions on their own SL/TP
  };

enum ENUM_RISK_LOCK
  {
   LOCK_NONE       = 0,
   LOCK_DAILY_LOSS = 1,
   LOCK_TARGET     = 2,
   LOCK_EMERGENCY  = 3
  };

// Only numbers and enums, so it can be copied safely.
struct RiskConfig
  {
   long              magic;
   double            riskPct;               // % of equity risked per trade
   double            minLotMaxRiskPct;      // 0 = reject when min lot is too big
   double            maxDailyLossPct;       // 0 = off
   double            dailyTargetPct;        // 0 = off
   int               maxConsecLosses;       // 0 = off
   int               maxPositions;
   int               maxDailyTrades;        // 0 = off
   int               minSecBetweenTrades;
   int               cooldownAfterLossMin;
   double            emergencyDDPct;        // 0 = off
   double            emergencyMarginLevel;  // %, 0 = off
   double            marginBufferPct;       // keep this % of free margin unused
   ENUM_EMERGENCY_POLICY emergencyPolicy;
  };

class CRiskManager
  {
private:
   RiskConfig        m_cfg;
   string            m_symbol;
   string            m_key;
   datetime          m_day;               // start of the current broker trading day
   double            m_dayStartEquity;
   int               m_lock;
   string            m_lockNote;

   // statistics of this EA's positions, current trading day
   double            m_realized;          // closed P/L incl. commission, fees, swap
   double            m_floating;          // open P/L incl. swap
   int               m_openPositions;
   int               m_entriesToday;
   int               m_closedToday;
   int               m_winsToday;
   int               m_consecLosses;
   double            m_grossWin;
   double            m_grossLoss;
   datetime          m_lastEntry;
   datetime          m_lastLossClose;

   string            GV(const string name) { return m_key + name; }
   datetime          Now() { return TimeTradeServer(); }
   void              SaveState();
   void              StartDay(const datetime day, const double startEquity, const string how);
   void              ScanHistory();
   void              ScanPositions();
   void              SetLock(const int lock, const string note);

public:
                     CRiskManager() { m_day = 0; m_dayStartEquity = 0; m_lock = LOCK_NONE; }
   bool              Init(const string symbol, const RiskConfig &cfg);
   bool              Update();
   void              TriggerEmergency(const string note);
   string            CanOpen();
   double            SizeTrade(const int dir, const double slDist, string &reason, double &riskPct);

   bool              Locked()          const { return m_lock != LOCK_NONE; }
   string            LockText();
   ENUM_EMERGENCY_POLICY EmergencyPolicy() const { return m_cfg.emergencyPolicy; }
   double            DayStartEquity()  const { return m_dayStartEquity; }
   double            Realized()        const { return m_realized; }
   double            Floating()        const { return m_floating; }
   double            DayPL()           const { return m_realized + m_floating; }
   double            DrawdownPct()     { return RM_DayDrawdownPct(m_dayStartEquity, AccountInfoDouble(ACCOUNT_EQUITY)); }
   double            DayLossUsedPct();
   int               OpenPositions()   const { return m_openPositions; }
   int               EntriesToday()    const { return m_entriesToday; }
   int               ClosedToday()     const { return m_closedToday; }
   int               WinsToday()       const { return m_winsToday; }
   int               ConsecLosses()    const { return m_consecLosses; }
   double            GrossWin()        const { return m_grossWin; }
   double            GrossLoss()       const { return m_grossLoss; }
   double            RiskPct()         const { return m_cfg.riskPct; }
   double            MaxDailyLossPct() const { return m_cfg.maxDailyLossPct; }
   int               MaxConsecLosses() const { return m_cfg.maxConsecLosses; }
   int               MaxDailyTrades()  const { return m_cfg.maxDailyTrades; }
  };

//+------------------------------------------------------------------+
bool CRiskManager::Init(const string symbol, const RiskConfig &cfg)
  {
   m_cfg    = cfg;
   m_symbol = symbol;
   m_key = "XSR_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + IntegerToString(m_cfg.magic) + "_";
   m_lock = LOCK_NONE;
   m_lockNote = "";

   datetime today = RM_DayStart(Now());
   ScanPositions();

   bool restored = GlobalVariableCheck(GV("day")) && GlobalVariableCheck(GV("dayeq"))
                   && (datetime)(long)GlobalVariableGet(GV("day")) == today;
   if(restored)
     {
      m_day = today;
      m_dayStartEquity = GlobalVariableGet(GV("dayeq"));
      if(GlobalVariableCheck(GV("lock")) && GlobalVariableCheck(GV("lockday"))
         && (datetime)(long)GlobalVariableGet(GV("lockday")) == today)
         m_lock = (int)GlobalVariableGet(GV("lock"));
      ScanHistory();
      PrintFormat("Risk: restored trading day %s, start equity %.2f, lock %d",
                  TimeToString(m_day, TIME_DATE), m_dayStartEquity, m_lock);
     }
   else
     {
      // Started during the day without saved state: estimate the day's starting
      // equity as balance minus what this EA has realised today.
      m_day = today;
      ScanHistory();
      StartDay(today, AccountInfoDouble(ACCOUNT_BALANCE) - m_realized, "estimated from balance");
     }
   return true;
  }

//+------------------------------------------------------------------+
void CRiskManager::SaveState()
  {
   GlobalVariableSet(GV("day"), (double)(long)m_day);
   GlobalVariableSet(GV("dayeq"), m_dayStartEquity);
   GlobalVariableSet(GV("lock"), (double)m_lock);
   GlobalVariableSet(GV("lockday"), (double)(long)m_day);
  }

void CRiskManager::StartDay(const datetime day, const double startEquity, const string how)
  {
   m_day            = day;
   m_dayStartEquity = startEquity;
   m_lock           = LOCK_NONE;
   m_lockNote       = "";
   SaveState();
   PrintFormat("Risk: new trading day %s, start equity %.2f (%s)", TimeToString(day, TIME_DATE), startEquity, how);
  }

void CRiskManager::SetLock(const int lock, const string note)
  {
   if(m_lock != LOCK_NONE)
      return;
   m_lock     = lock;
   m_lockNote = note;
   SaveState();
   PrintFormat("Risk: LOCKED (%d) %s", lock, note);
  }

//+------------------------------------------------------------------+
//| Open positions of this EA                                         |
//+------------------------------------------------------------------+
void CRiskManager::ScanPositions()
  {
   m_openPositions = 0;
   m_floating      = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != m_symbol || PositionGetInteger(POSITION_MAGIC) != m_cfg.magic)
         continue;
      m_openPositions++;
      m_floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
  }

//+------------------------------------------------------------------+
//| Today's deals of this EA: realised P/L, trades, wins, streak      |
//| (positions opened before today are not counted in the streak or   |
//| trade count; their effect on equity is still in the loss limit)   |
//+------------------------------------------------------------------+
void CRiskManager::ScanHistory()
  {
   m_realized = 0;  m_entriesToday = 0;  m_closedToday = 0;  m_winsToday = 0;
   m_consecLosses = 0;  m_grossWin = 0;  m_grossLoss = 0;
   m_lastEntry = 0;  m_lastLossClose = 0;

   if(!HistorySelect(m_day, Now() + 86400))
      return;
   int total = HistoryDealsTotal();

   long     ids[];
   double   net[];
   bool     closed[];
   datetime closeTime[];
   int      order[];       // position indexes in the order they were (finally) closed
   int      n = 0, nOrder = 0;

   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0 || HistoryDealGetString(d, DEAL_SYMBOL) != m_symbol)
         continue;
      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      long posId = HistoryDealGetInteger(d, DEAL_POSITION_ID);

      int idx = -1;
      for(int k = 0; k < n; k++)
         if(ids[k] == posId) { idx = k; break; }

      if(entry == DEAL_ENTRY_IN)
        {
         if(HistoryDealGetInteger(d, DEAL_MAGIC) != m_cfg.magic || idx >= 0)
            continue;
         ArrayResize(ids, n + 1, 16);  ArrayResize(net, n + 1, 16);
         ArrayResize(closed, n + 1, 16);  ArrayResize(closeTime, n + 1, 16);
         ids[n] = posId;  net[n] = 0;  closed[n] = false;  closeTime[n] = 0;
         idx = n++;
         m_entriesToday++;
         datetime t = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
         if(t > m_lastEntry)
            m_lastEntry = t;
        }
      if(idx < 0)
         continue;   // not a position this EA opened today

      double amount = HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
      if(entry != DEAL_ENTRY_IN)
        {
         amount += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP);
         closed[idx]    = true;
         closeTime[idx] = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
         // move this position to the end of the close order
         int w = 0;
         for(int k = 0; k < nOrder; k++)
            if(order[k] != idx)
               order[w++] = order[k];
         nOrder = w;
         ArrayResize(order, nOrder + 1, 16);
         order[nOrder++] = idx;
        }
      net[idx]   += amount;
      m_realized += amount;
     }

   double nets[];
   ArrayResize(nets, nOrder);
   for(int k = 0; k < nOrder; k++)
     {
      int idx = order[k];
      if(!closed[idx])
         continue;
      nets[k] = net[idx];
      m_closedToday++;
      if(net[idx] > 0)
        {
         m_winsToday++;
         m_grossWin += net[idx];
        }
      else if(net[idx] < 0)
        {
         m_grossLoss += -net[idx];
         if(closeTime[idx] > m_lastLossClose)
            m_lastLossClose = closeTime[idx];
        }
     }
   m_consecLosses = RM_ConsecutiveLosses(nets);
  }

//+------------------------------------------------------------------+
//| Call regularly (timer). Returns true when an emergency was        |
//| triggered by this call: the caller applies the emergency policy.  |
//+------------------------------------------------------------------+
bool CRiskManager::Update()
  {
   datetime today = RM_DayStart(Now());
   if(today > m_day)
      StartDay(today, AccountInfoDouble(ACCOUNT_EQUITY), "equity at the day boundary");

   ScanPositions();
   ScanHistory();
   if(m_lock != LOCK_NONE)
      return false;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   // Emergency: equity drawdown from the day's start
   double dd = RM_DayDrawdownPct(m_dayStartEquity, equity);
   if(m_cfg.emergencyDDPct > 0 && dd >= m_cfg.emergencyDDPct)
     {
      TriggerEmergency(StringFormat("equity down %.1f%% today", dd));
      return true;
     }
   // Emergency: margin level too low while positions are open
   if(m_cfg.emergencyMarginLevel > 0 && AccountInfoDouble(ACCOUNT_MARGIN) > 0
      && AccountInfoDouble(ACCOUNT_MARGIN_LEVEL) < m_cfg.emergencyMarginLevel)
     {
      TriggerEmergency(StringFormat("margin level %.0f%%", AccountInfoDouble(ACCOUNT_MARGIN_LEVEL)));
      return true;
     }

   // Daily loss / target: locked once reached with no position of this EA open,
   // i.e. on the realised result (open trades keep their own SL/TP).
   if(m_openPositions == 0)
     {
      if(RM_DailyLossHit(m_dayStartEquity, equity, m_cfg.maxDailyLossPct))
         SetLock(LOCK_DAILY_LOSS, StringFormat("day result %.2f", equity - m_dayStartEquity));
      else if(RM_DailyTargetHit(m_dayStartEquity, equity, m_cfg.dailyTargetPct))
         SetLock(LOCK_TARGET, StringFormat("day result +%.2f", equity - m_dayStartEquity));
     }
   return false;
  }

void CRiskManager::TriggerEmergency(const string note)
  {
   m_lock = LOCK_NONE;   // emergency overrides any other lock
   SetLock(LOCK_EMERGENCY, note);
  }

string CRiskManager::LockText()
  {
   switch(m_lock)
     {
      case LOCK_DAILY_LOSS: return "daily loss limit reached; locked until next trading day";
      case LOCK_TARGET:     return "daily profit target reached; locked until next trading day";
      case LOCK_EMERGENCY:  return "emergency shutdown" + (m_lockNote != "" ? " (" + m_lockNote + ")" : "")
                                   + "; locked until next trading day";
     }
   return "";
  }

double CRiskManager::DayLossUsedPct()
  {
   if(m_dayStartEquity <= 0 || m_cfg.maxDailyLossPct <= 0)
      return 0.0;
   double loss = m_dayStartEquity - AccountInfoDouble(ACCOUNT_EQUITY);
   if(loss <= 0)
      return 0.0;
   return loss / (m_dayStartEquity * m_cfg.maxDailyLossPct / 100.0) * 100.0;
  }

//+------------------------------------------------------------------+
//| "" = a new trade is allowed; otherwise the reason it is not       |
//+------------------------------------------------------------------+
string CRiskManager::CanOpen()
  {
   if(m_lock != LOCK_NONE)
      return LockText();

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(RM_DailyLossHit(m_dayStartEquity, equity, m_cfg.maxDailyLossPct))
      return StringFormat("daily loss limit reached (%.2f of %.2f allowed)",
                          m_dayStartEquity - equity, m_dayStartEquity * m_cfg.maxDailyLossPct / 100.0);
   if(m_cfg.maxConsecLosses > 0 && m_consecLosses >= m_cfg.maxConsecLosses)
      return StringFormat("%d losses in a row: no new trades today", m_consecLosses);
   if(m_cfg.maxDailyTrades > 0 && m_entriesToday >= m_cfg.maxDailyTrades)
      return StringFormat("daily trade limit reached (%d)", m_cfg.maxDailyTrades);
   if(m_openPositions >= m_cfg.maxPositions)
      return StringFormat("max open positions reached (%d)", m_cfg.maxPositions);

   datetime now = Now();
   if(m_cfg.minSecBetweenTrades > 0 && m_lastEntry > 0 && now - m_lastEntry < m_cfg.minSecBetweenTrades)
      return StringFormat("spacing between trades (%d s left)", (int)(m_cfg.minSecBetweenTrades - (now - m_lastEntry)));
   if(m_cfg.cooldownAfterLossMin > 0 && m_lastLossClose > 0
      && now - m_lastLossClose < m_cfg.cooldownAfterLossMin * 60)
      return StringFormat("cooldown after a loss (%d min left)",
                          (int)MathCeil((m_cfg.cooldownAfterLossMin * 60 - (now - m_lastLossClose)) / 60.0));
   return "";
  }

//+------------------------------------------------------------------+
//| Volume for a trade, or 0 with the reason when it is rejected.     |
//+------------------------------------------------------------------+
double CRiskManager::SizeTrade(const int dir, const double slDist, string &reason, double &riskPct)
  {
   string sym       = m_symbol;
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0)
      tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);

   double lots = RM_PositionSize(AccountInfoDouble(ACCOUNT_EQUITY), m_cfg.riskPct, slDist,
                                 tickSize, tickValue,
                                 SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN),
                                 SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX),
                                 SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP),
                                 m_cfg.minLotMaxRiskPct, reason, riskPct);
   if(lots <= 0)
      return 0.0;

   MqlTick tick;
   if(!SymbolInfoTick(sym, tick))
     {
      reason = "no price for the margin check";
      return 0.0;
     }
   ENUM_ORDER_TYPE type = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double price  = (dir > 0) ? tick.ask : tick.bid;
   double margin = 0.0;
   if(!OrderCalcMargin(type, sym, lots, price, margin))
     {
      reason = "could not calculate the margin";
      return 0.0;
     }
   double usable = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * (100.0 - m_cfg.marginBufferPct) / 100.0;
   if(margin > usable)
     {
      reason = StringFormat("not enough free margin (needs %.2f, usable %.2f)", margin, usable);
      return 0.0;
     }
   return lots;
  }

#endif
