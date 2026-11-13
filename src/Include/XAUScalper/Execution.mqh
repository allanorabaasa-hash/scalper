//+------------------------------------------------------------------+
//|                                                   Execution.mqh  |
//|  Order execution with verification.                               |
//|  - an order counts as executed only with retcode DONE/PLACED and  |
//|    a deal ticket from the broker                                  |
//|  - after the fill, the position is checked for a stop loss; if    |
//|    the broker did not attach it, it is set, and if that fails the |
//|    position is closed (no trade is left without a stop)           |
//|  - slippage beyond the limit is reported                          |
//|  - stop changes respect the stops level and the freeze level and  |
//|    never move a stop against the position                         |
//+------------------------------------------------------------------+
#ifndef XAUSCALPER_EXECUTION_MQH
#define XAUSCALPER_EXECUTION_MQH

#include <Trade\Trade.mqh>

class CExecution
  {
private:
   CTrade            m_trade;
   string            m_sym;
   long              m_magic;
   int               m_slipPoints;
   bool              m_busy;          // duplicate-order guard while a request is in flight

   double            Point_() { return SymbolInfoDouble(m_sym, SYMBOL_POINT); }
   int               Digits_() { return (int)SymbolInfoInteger(m_sym, SYMBOL_DIGITS); }

public:
                     CExecution() { m_busy = false; m_magic = 0; m_slipPoints = 30; }

   void              Init(const string sym, const long magic, const int slipPoints)
     {
      m_sym = sym;  m_magic = magic;  m_slipPoints = slipPoints;
      m_trade.SetExpertMagicNumber(magic);
      m_trade.SetDeviationInPoints(slipPoints);
      m_trade.SetTypeFillingBySymbol(sym);
      m_trade.SetMarginMode();
      m_trade.LogLevel(LOG_LEVEL_ERRORS);
     }

   // Minimum distance of a stop from the current price (stops level + spread).
   double            MinStopDistance()
     {
      MqlTick tick;
      double spread = SymbolInfoTick(m_sym, tick) ? tick.ask - tick.bid : 0.0;
      return SymbolInfoInteger(m_sym, SYMBOL_TRADE_STOPS_LEVEL) * Point_() + spread;
     }

   // Opens a market position. Returns the position ticket (0 = not executed; err explains).
   ulong             Open(const int dir, const double lots, const double slDist, const double tpDist,
                          const string comment, string &err, double &fillPrice)
     {
      err = "";
      fillPrice = 0;
      if(m_busy)
        {
         err = "another order is still being processed";
         return 0;
        }
      MqlTick tick;
      if(!SymbolInfoTick(m_sym, tick))
        {
         err = "no price";
         return 0;
        }
      int    dg    = Digits_();
      double price = (dir > 0) ? tick.ask : tick.bid;
      double sl    = NormalizeDouble((dir > 0) ? price - slDist : price + slDist, dg);
      double tp    = (tpDist > 0) ? NormalizeDouble((dir > 0) ? price + tpDist : price - tpDist, dg) : 0.0;

      m_busy = true;
      bool sent = (dir > 0) ? m_trade.Buy(lots, m_sym, price, sl, tp, comment)
                            : m_trade.Sell(lots, m_sym, price, sl, tp, comment);
      m_busy = false;

      uint rc = m_trade.ResultRetcode();
      ulong deal = m_trade.ResultDeal();
      if(!sent || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_PLACED) || deal == 0)
        {
         err = StringFormat("order not executed (%u: %s)", rc, m_trade.ResultRetcodeDescription());
         return 0;
        }
      fillPrice = m_trade.ResultPrice();

      // Find the position created by this deal
      ulong pos = 0;
      if(HistoryDealSelect(deal))
         pos = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      if(pos == 0)
         pos = m_trade.ResultOrder();

      double slip = MathAbs(fillPrice - price) / Point_();
      if(slip > m_slipPoints)
         Print("Execution: slippage ", DoubleToString(slip, 0), " points (requested ",
               DoubleToString(price, dg), ", filled ", DoubleToString(fillPrice, dg), ")");

      // Verify the stop loss is attached
      if(PositionSelectByTicket(pos))
        {
         if(PositionGetDouble(POSITION_SL) == 0)
           {
            double fsl = NormalizeDouble((dir > 0) ? fillPrice - slDist : fillPrice + slDist, dg);
            if(!m_trade.PositionModify(pos, fsl, PositionGetDouble(POSITION_TP)))
              {
               m_trade.PositionClose(pos, m_slipPoints);
               err = "position opened without a stop and the stop could not be set: closed it";
               return 0;
              }
           }
        }
      else
         Print("Execution: filled, but the position could not be selected for the stop check");
      return pos;
     }

   bool              Close(const ulong ticket, string &err)
     {
      err = "";
      if(m_trade.PositionClose(ticket, m_slipPoints))
         return true;
      err = StringFormat("close #%I64u failed (%u: %s)", ticket, m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
      return false;
     }

   // Moves the stop of a selected-by-ticket position, only in the position's favour.
   // Returns false with err when not allowed or rejected ("" err = nothing to do).
   bool              MoveStop(const ulong ticket, double newSL, string &err)
     {
      err = "";
      if(!PositionSelectByTicket(ticket))
        {
         err = "position not found";
         return false;
        }
      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      MqlTick tick;
      if(!SymbolInfoTick(m_sym, tick))
         return false;
      newSL = NormalizeDouble(newSL, Digits_());
      if(sl != 0 && ((isBuy && newSL <= sl) || (!isBuy && newSL >= sl)))
         return false;   // would not improve the stop: never add risk
      double stops  = SymbolInfoInteger(m_sym, SYMBOL_TRADE_STOPS_LEVEL) * Point_();
      double freeze = SymbolInfoInteger(m_sym, SYMBOL_TRADE_FREEZE_LEVEL) * Point_();
      double price  = isBuy ? tick.bid : tick.ask;
      if((isBuy && newSL > price - stops) || (!isBuy && newSL < price + stops))
         return false;   // too close to the price for the broker
      if(freeze > 0 && (MathAbs(price - sl) <= freeze || (tp > 0 && MathAbs(tp - price) <= freeze)))
         return false;   // inside the freeze level
      if(m_trade.PositionModify(ticket, newSL, tp))
         return true;
      err = StringFormat("stop change on #%I64u failed (%u: %s)", ticket, m_trade.ResultRetcode(),
                         m_trade.ResultRetcodeDescription());
      return false;
     }
  };

#endif
