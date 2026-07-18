//+------------------------------------------------------------------+
//|                                        MatlamaTickScalper.mq5    |
//|                                      Matlama Tech © 2026         |
//|              Tick-Based Micro Scalper                             |
//|         Targets small quick profits via tick microstructure.      |
//|         Analyzes tick velocity, frequency, and bid/ask flow.     |
//+------------------------------------------------------------------+
#property copyright "Matlama Tech 2026"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include "OrchestratorClient.mqh"

//--- Input Parameters
input string   EA_Name          = "MatlamaTickScalper v1";
input double   LotSize          = 0.01;
input int      MagicNumber      = 20260103;
input int      TP_Pips          = 5;           // take profit
input int      SL_Pips          = 8;           // stop loss
input int      MaxHoldSeconds   = 120;         // forced exit after this
input int      MaxTradesPerDay  = 30;          // quality gate
input double   MaxDailyLoss     = 50.0;        // account-currency cap
input bool     AutoTrade        = true;

//--- Tick Analysis
input int      TickBufferSize   = 50;          // ticks to keep
input double   MinTickVelocity  = 2.0;         // pips/sec for burst
input double   MinImbalance     = 0.65;        // directional bias (0.5 = neutral)
input double   MinTickFreq      = 3.0;         // ticks/sec liquidity floor
input double   MaxSpreadPips    = 2.5;         // max spread to enter
input double   MinSpreadPips    = 0.3;         // below this is suspicious

//--- Risk Management
input double   BreakevenPips    = 3.0;         // move SL to BE after X pips
input double   TrailStartPips   = 4.0;         // start trailing after X pips
input double   TrailStepPips    = 1.5;         // trail distance
input int      CooldownSeconds  = 5;           // gap between trades

//--- Session Filter
input bool     LondonSession    = true;        // 07:00–16:00 UTC
input bool     NewYorkSession   = true;        // 12:00–21:00 UTC
input bool     AsiaSession      = false;       // 00:00–09:00 UTC

//--- Orchestrator (feedback only — entry decisions are local)
input string   ORCH_REPORT      = "http://127.0.0.1:7000/report_trade";

//+------------------------------------------------------------------+
//| Tick ring-buffer record                                           |
//+------------------------------------------------------------------+
struct TickRecord
{
   long     time_msc;
   double   bid;
   double   ask;
   int      direction;     // +1 uptick, -1 downtick, 0 flat
};

//+------------------------------------------------------------------+
//| Global state                                                      |
//+------------------------------------------------------------------+
TickRecord  ticks[];
int         tHead            = 0;
int         tCount           = 0;

CTrade      trade;
double      pipSize;
int         digits;
int         dailyTradeCount  = 0;
double      dailyPnL         = 0.0;
datetime    currentDay       = 0;
long        lastEntryMsc     = 0;
double      lastBid          = 0;
string      LastRegime       = "UNKNOWN";
ulong       lastLoggedTicket = 0;

// entry-time features kept for CSV logging
double      entryTickVelocity  = 0;
double      entryTickFreq      = 0;
double      entrySpreadPips    = 0;
double      entryImbalance     = 0;
double      entryMomentum      = 0;

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   ArrayResize(ticks, TickBufferSize);
   for(int i = 0; i < TickBufferSize; i++)
   {
      ticks[i].time_msc  = 0;
      ticks[i].bid       = 0;
      ticks[i].ask       = 0;
      ticks[i].direction = 0;
   }

   pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(5);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   currentDay = iTime(_Symbol, PERIOD_D1, 0);
   InitCSV();

   Print(EA_Name, " init | ", _Symbol, " pip=", pipSize,
         " TP=", TP_Pips, " SL=", SL_Pips,
         " buf=", TickBufferSize);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print(EA_Name, " removed | reason=", reason,
         " | day_trades=", dailyTradeCount,
         " | day_pnl=", DoubleToString(dailyPnL, 2));
}

//+------------------------------------------------------------------+
//| OnTick — main loop                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   // --- daily reset ---
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today != currentDay)
   {
      Print("TICK_SCALPER day reset | trades=", dailyTradeCount,
            " pnl=", DoubleToString(dailyPnL, 2));
      dailyTradeCount = 0;
      dailyPnL        = 0.0;
      currentDay       = today;
   }

   // --- collect tick ---
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   AddTick(tick);

   // --- log any closed trades ---
   LogClosedTrades();

   // --- manage open position ---
   if(HasPosition())
   {
      ManagePosition(tick);
      return;        // one position at a time
   }

   // --- entry gates ---
   if(!AutoTrade)                                return;
   if(dailyTradeCount >= MaxTradesPerDay)         return;
   if(dailyPnL <= -MaxDailyLoss)                  return;
   if(!InSession())                               return;
   if(tick.time_msc - lastEntryMsc < CooldownSeconds * 1000) return;
   if(tCount < TickBufferSize / 2)                return;

   CheckEntry(tick);
}

//+------------------------------------------------------------------+
//| Ring-buffer: add tick                                              |
//+------------------------------------------------------------------+
void AddTick(const MqlTick &tick)
{
   int dir = 0;
   if(lastBid > 0)
   {
      if(tick.bid > lastBid)      dir =  1;
      else if(tick.bid < lastBid) dir = -1;
   }
   lastBid = tick.bid;

   ticks[tHead].time_msc  = tick.time_msc;
   ticks[tHead].bid       = tick.bid;
   ticks[tHead].ask       = tick.ask;
   ticks[tHead].direction = dir;

   tHead = (tHead + 1) % TickBufferSize;
   if(tCount < TickBufferSize) tCount++;
}

//+------------------------------------------------------------------+
//| Tick velocity — signed pips / second over the buffer              |
//+------------------------------------------------------------------+
double GetTickVelocity()
{
   if(tCount < 5) return 0;
   int newest = (tHead - 1 + TickBufferSize) % TickBufferSize;
   int oldest = (tHead - tCount + TickBufferSize) % TickBufferSize;

   double priceDiff = (ticks[newest].bid - ticks[oldest].bid) / pipSize;
   double timeDiff  = (double)(ticks[newest].time_msc - ticks[oldest].time_msc) / 1000.0;
   if(timeDiff <= 0) return 0;
   return priceDiff / timeDiff;
}

//+------------------------------------------------------------------+
//| Tick frequency — ticks / second                                   |
//+------------------------------------------------------------------+
double GetTickFrequency()
{
   if(tCount < 5) return 0;
   int newest = (tHead - 1 + TickBufferSize) % TickBufferSize;
   int oldest = (tHead - tCount + TickBufferSize) % TickBufferSize;

   double timeDiff = (double)(ticks[newest].time_msc - ticks[oldest].time_msc) / 1000.0;
   if(timeDiff <= 0) return 0;
   return (double)tCount / timeDiff;
}

//+------------------------------------------------------------------+
//| Directional imbalance — fraction of up-ticks (1.0=all up)         |
//+------------------------------------------------------------------+
double GetImbalance()
{
   if(tCount < 5) return 0.5;
   int ups = 0, moves = 0;
   for(int i = 0; i < tCount; i++)
   {
      int idx = (tHead - 1 - i + TickBufferSize) % TickBufferSize;
      if(ticks[idx].direction != 0)
      {
         moves++;
         if(ticks[idx].direction > 0) ups++;
      }
   }
   if(moves == 0) return 0.5;
   return (double)ups / (double)moves;
}

//+------------------------------------------------------------------+
//| Momentum score — combined velocity × directional conviction       |
//+------------------------------------------------------------------+
double GetMomentumScore(double velocity, double imbalance)
{
   double dirBias = MathAbs(imbalance - 0.5) * 2.0;   // 0→1
   return MathAbs(velocity) * (0.5 + 0.5 * dirBias);
}

//+------------------------------------------------------------------+
//| Entry logic                                                       |
//+------------------------------------------------------------------+
void CheckEntry(const MqlTick &tick)
{
   double spread = (tick.ask - tick.bid) / pipSize;
   if(spread > MaxSpreadPips || spread < MinSpreadPips) return;

   double velocity  = GetTickVelocity();
   double frequency = GetTickFrequency();
   double imbalance = GetImbalance();
   double momentum  = GetMomentumScore(velocity, imbalance);

   if(frequency < MinTickFreq)              return;
   if(MathAbs(velocity) < MinTickVelocity)  return;

   // direction from momentum + imbalance agreement
   string direction = "";
   if(velocity > MinTickVelocity && imbalance > MinImbalance)
      direction = "BUY";
   else if(velocity < -MinTickVelocity && imbalance < (1.0 - MinImbalance))
      direction = "SELL";
   if(direction == "") return;

   // store features for CSV
   entryTickVelocity = velocity;
   entryTickFreq     = frequency;
   entrySpreadPips   = spread;
   entryImbalance    = imbalance;
   entryMomentum     = momentum;

   double sl_dist = SL_Pips * pipSize;
   double tp_dist = TP_Pips * pipSize;
   bool   success = false;

   if(direction == "BUY")
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = NormalizeDouble(ask - sl_dist, digits);
      double tp  = NormalizeDouble(ask + tp_dist, digits);
      success    = trade.Buy(LotSize, _Symbol, 0, sl, tp, EA_Name);
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = NormalizeDouble(bid + sl_dist, digits);
      double tp  = NormalizeDouble(bid - tp_dist, digits);
      success    = trade.Sell(LotSize, _Symbol, 0, sl, tp, EA_Name);
   }

   if(success)
   {
      dailyTradeCount++;
      lastEntryMsc = tick.time_msc;
      Print("TICK SCALP ", direction,
            " | vel=", DoubleToString(velocity, 2),
            " freq=", DoubleToString(frequency, 1),
            " imbal=", DoubleToString(imbalance, 2),
            " spread=", DoubleToString(spread, 1),
            " mom=", DoubleToString(momentum, 2));
   }
   else
      Print("TICK SCALP ", direction, " FAILED: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Check for own open position                                       |
//+------------------------------------------------------------------+
bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) > 0 &&
         PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Manage open position — breakeven, trail, time exit                |
//+------------------------------------------------------------------+
void ManagePosition(const MqlTick &tick)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      double   openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double   curSL     = PositionGetDouble(POSITION_SL);
      double   curTP     = PositionGetDouble(POSITION_TP);
      long     posType   = PositionGetInteger(POSITION_TYPE);
      datetime openTime  = (datetime)PositionGetInteger(POSITION_TIME);

      double profitPips = 0;
      if(posType == POSITION_TYPE_BUY)
         profitPips = (tick.bid - openPrice) / pipSize;
      else
         profitPips = (openPrice - tick.ask) / pipSize;

      // --- time exit ---
      if((int)(TimeCurrent() - openTime) >= MaxHoldSeconds)
      {
         trade.PositionClose(ticket);
         Print("TICK SCALP TIME EXIT | pips=", DoubleToString(profitPips, 1));
         return;
      }

      // --- breakeven ---
      if(profitPips >= BreakevenPips && profitPips < TrailStartPips)
      {
         double beSL;
         if(posType == POSITION_TYPE_BUY)
         {
            beSL = NormalizeDouble(openPrice + 1.0 * pipSize, digits);
            if(curSL < beSL)
               trade.PositionModify(ticket, beSL, curTP);
         }
         else
         {
            beSL = NormalizeDouble(openPrice - 1.0 * pipSize, digits);
            if(curSL > beSL || curSL == 0)
               trade.PositionModify(ticket, beSL, curTP);
         }
      }

      // --- trailing stop ---
      if(profitPips >= TrailStartPips)
      {
         double trailDist = TrailStepPips * pipSize;
         double newSL;
         if(posType == POSITION_TYPE_BUY)
         {
            newSL = NormalizeDouble(tick.bid - trailDist, digits);
            if(newSL > curSL)
               trade.PositionModify(ticket, newSL, curTP);
         }
         else
         {
            newSL = NormalizeDouble(tick.ask + trailDist, digits);
            if(newSL < curSL)
               trade.PositionModify(ticket, newSL, curTP);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Session filter (UTC hours)                                        |
//+------------------------------------------------------------------+
bool InSession()
{
   MqlDateTime dt;
   TimeGMT(dt);
   int h = dt.hour;

   if(LondonSession   && h >= 7  && h < 16) return true;
   if(NewYorkSession   && h >= 12 && h < 21) return true;
   if(AsiaSession      && (h >= 0 && h < 9)) return true;
   return false;
}

//+------------------------------------------------------------------+
//| CSV — initialise with header row                                  |
//+------------------------------------------------------------------+
void InitCSV()
{
   string fname = "tick_scalper_trades.csv";
   if(FileIsExist(fname))
   {
      int tmp = FileOpen(fname, FILE_READ | FILE_CSV | FILE_ANSI, ',');
      if(tmp != INVALID_HANDLE) { FileClose(tmp); return; }
   }

   int h = FileOpen(fname, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h == INVALID_HANDLE) { Print("CSV create failed"); return; }
   FileWrite(h,
      "ticket","symbol","type","open_time","close_time",
      "open_price","close_price","volume","profit","swap","commission",
      "duration_sec","tick_velocity","tick_frequency","spread_pips",
      "imbalance","momentum_score");
   FileClose(h);
}

//+------------------------------------------------------------------+
//| CSV — log closed trades + report to orchestrator                  |
//+------------------------------------------------------------------+
void LogClosedTrades()
{
   datetime from = iTime(_Symbol, PERIOD_D1, 5);
   datetime to   = TimeCurrent();
   if(!HistorySelect(from, to)) return;

   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC)  != MagicNumber) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY)  != DEAL_ENTRY_OUT) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL)  != _Symbol) continue;
      if(ticket <= lastLoggedTicket) continue;

      double profit  = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      double swap    = HistoryDealGetDouble(ticket, DEAL_SWAP);
      double comm    = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      double volume  = HistoryDealGetDouble(ticket, DEAL_VOLUME);
      double cPrice  = HistoryDealGetDouble(ticket, DEAL_PRICE);
      long   dealType = HistoryDealGetInteger(ticket, DEAL_TYPE);
      datetime cTime  = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);

      // find matching entry deal for open_price / open_time
      long   posId    = (long)HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
      double oPrice   = cPrice;
      datetime oTime  = cTime;
      string typeStr  = (dealType == DEAL_TYPE_SELL) ? "BUY" : "SELL";

      for(int j = 0; j < total; j++)
      {
         ulong t2 = HistoryDealGetTicket(j);
         if(t2 == 0) continue;
         if((long)HistoryDealGetInteger(t2, DEAL_POSITION_ID) != posId) continue;
         if(HistoryDealGetInteger(t2, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
         oPrice = HistoryDealGetDouble(t2, DEAL_PRICE);
         oTime  = (datetime)HistoryDealGetInteger(t2, DEAL_TIME);
         break;
      }

      int durationSec = (int)(cTime - oTime);

      int handle = FileOpen("tick_scalper_trades.csv",
                            FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
      if(handle == INVALID_HANDLE) continue;
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle,
         (string)ticket, _Symbol, typeStr,
         TimeToString(oTime, TIME_DATE | TIME_SECONDS),
         TimeToString(cTime, TIME_DATE | TIME_SECONDS),
         DoubleToString(oPrice, digits),
         DoubleToString(cPrice, digits),
         DoubleToString(volume, 2),
         DoubleToString(profit, 2),
         DoubleToString(swap,   2),
         DoubleToString(comm,   2),
         (string)durationSec,
         DoubleToString(entryTickVelocity, 3),
         DoubleToString(entryTickFreq,     2),
         DoubleToString(entrySpreadPips,   2),
         DoubleToString(entryImbalance,    3),
         DoubleToString(entryMomentum,     3)
      );
      FileClose(handle);

      lastLoggedTicket = ticket;
      dailyPnL += profit;
      Print("TICK SCALP closed | #", ticket,
            " profit=", DoubleToString(profit, 2),
            " dur=", durationSec, "s");

      int winFlag = (profit > 0) ? 1 : 0;
      OrchReportTrade(ORCH_REPORT, "TICK_SCALPER", LastRegime, winFlag, profit);
   }
}
//+------------------------------------------------------------------+
