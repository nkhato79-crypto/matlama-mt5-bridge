//+------------------------------------------------------------------+
//|                                              MatlamaORB.mq5      |
//|                                          Matlama Tech 2026       |
//+------------------------------------------------------------------+
//|  Standalone Opening Range Breakout strategy.                     |
//|  Deliberately NOT wired to orchestrator_v2 (no ML scoring —      |
//|  ORB logic is deterministic rule-based, nothing to learn).       |
//|  Protection from high-impact news still comes from               |
//|  MatlamaFundamentals via CloseByMagic(MagicORB).                 |
//+------------------------------------------------------------------+
#property copyright "Matlama Tech 2026"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- Identity
input int    MagicORB          = 20260301;   // Unique magic number for this EA
input string EA_Name           = "MatlamaORB v1";

//--- Session / range settings (all times UTC)
input int    SessionStartHour  = 8;          // Session open hour (e.g. 8 = London open)
input int    SessionStartMin   = 0;
input int    RangeWindowMins   = 30;         // Length of the opening range window
input int    BreakoutValidMins = 180;        // How long after range closes a breakout is still valid

//--- Risk settings
input double LotSize           = 0.01;
input double SLBufferPips      = 5.0;        // Extra buffer beyond range boundary for SL
input double RR_Multiple       = 2.0;        // TP = range size * this multiple
input int    MaxTradesPerDay   = 2;          // 1 long + 1 short max, per session

//--- CSV logging
string   CSV_PATH = "orb_trades.csv";
ulong    lastLoggedTicket = 0;

//--- Internal state (reset daily)
datetime rangeDayStamp   = 0;   // which trading day the current range belongs to
datetime rangeStartTime  = 0;
datetime rangeEndTime    = 0;
double   rangeHigh       = 0;
double   rangeLow        = 0;
bool     rangeLocked     = false;   // true once the window has closed and range is final
bool     longTaken       = false;
bool     shortTaken      = false;

//+------------------------------------------------------------------+
int OnInit()
{
   InitCSV();
   string gvHigh = "ORB_RangeHigh_" + _Symbol + "_" + (string)MagicORB;
   string gvLow  = "ORB_RangeLow_"  + _Symbol + "_" + (string)MagicORB;
   string gvDay  = "ORB_RangeDay_"  + _Symbol + "_" + (string)MagicORB;
   // Restore today's range across recompiles/restarts so we don't miss a breakout
   // that's already in progress when the EA reinitializes mid-session.
   if(GlobalVariableCheck(gvDay))
   {
      rangeDayStamp = (datetime)GlobalVariableGet(gvDay);
      if(IsSameTradingDay(rangeDayStamp, TimeGMT()))
      {
         rangeHigh = GlobalVariableGet(gvHigh);
         rangeLow  = GlobalVariableGet(gvLow);
         rangeLocked = (rangeHigh > 0 && rangeLow > 0);
      }
   }
   Print(EA_Name, " initialized | Magic:", MagicORB, " | Session start (UTC): ",
         SessionStartHour, ":", SessionStartMin, " | Window:", RangeWindowMins, "min");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print(EA_Name, " stopped.");
}

//+------------------------------------------------------------------+
bool IsSameTradingDay(datetime a, datetime b)
{
   MqlDateTime da, db;
   TimeToStruct(a, da);
   TimeToStruct(b, db);
   return(da.year == db.year && da.mon == db.mon && da.day == db.day);
}

//+------------------------------------------------------------------+
void ResetDailyStateIfNeeded()
{
   datetime now = TimeGMT();
   if(rangeDayStamp == 0 || !IsSameTradingDay(rangeDayStamp, now))
   {
      rangeDayStamp = now;
      rangeHigh     = 0;
      rangeLow      = 0;
      rangeLocked   = false;
      longTaken     = false;
      shortTaken    = false;

      MqlDateTime dt;
      TimeToStruct(now, dt);
      dt.hour = SessionStartHour;
      dt.min  = SessionStartMin;
      dt.sec  = 0;
      rangeStartTime = StructToTime(dt);
      rangeEndTime   = rangeStartTime + RangeWindowMins * 60;
   }
}

//+------------------------------------------------------------------+
void BuildOpeningRange()
{
   datetime now = TimeGMT();
   if(now < rangeStartTime || rangeLocked) return;

   // While inside the window: keep expanding high/low from H1... use a finer
   // timeframe internally for accuracy regardless of chart timeframe.
   if(now <= rangeEndTime)
   {
      int bars = Bars(_Symbol, PERIOD_M1, rangeStartTime, now);
      if(bars <= 0) return;
      double hi = iHigh(_Symbol, PERIOD_M1, iHighest(_Symbol, PERIOD_M1, MODE_HIGH, bars, 0));
      double lo = iLow(_Symbol, PERIOD_M1, iLowest(_Symbol, PERIOD_M1, MODE_LOW, bars, 0));
      if(hi > rangeHigh) rangeHigh = hi;
      if(rangeLow == 0 || lo < rangeLow) rangeLow = lo;
   }
   else
   {
      // Window just closed — lock the range and persist it
      rangeLocked = true;
      string gvHigh = "ORB_RangeHigh_" + _Symbol + "_" + (string)MagicORB;
      string gvLow  = "ORB_RangeLow_"  + _Symbol + "_" + (string)MagicORB;
      string gvDay  = "ORB_RangeDay_"  + _Symbol + "_" + (string)MagicORB;
      GlobalVariableSet(gvHigh, rangeHigh);
      GlobalVariableSet(gvLow, rangeLow);
      GlobalVariableSet(gvDay, (double)rangeDayStamp);
      Print(EA_Name, " | Range locked | High:", rangeHigh, " Low:", rangeLow,
            " Size:", (rangeHigh - rangeLow));
   }
}

//+------------------------------------------------------------------+
bool WithinBreakoutWindow()
{
   datetime now = TimeGMT();
   return(rangeLocked && now > rangeEndTime && now <= rangeEndTime + BreakoutValidMins * 60);
}

//+------------------------------------------------------------------+
void CheckBreakoutEntries()
{
   if(!WithinBreakoutWindow()) return;
   if(rangeHigh <= 0 || rangeLow <= 0) return;

   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double buffer  = SLBufferPips * point * 10; // rough pip->price buffer, gold-appropriate
   double rangeSize = rangeHigh - rangeLow;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   int totalToday = CountTradesToday();
   if(totalToday >= MaxTradesPerDay) return;

   // Long breakout
   if(!longTaken && ask > rangeHigh)
   {
      double sl = rangeLow - buffer;
      double tp = ask + (rangeSize * RR_Multiple);
      trade.SetExpertMagicNumber(MagicORB);
      if(trade.Buy(LotSize, _Symbol, ask, sl, tp, EA_Name + " long breakout"))
      {
         longTaken = true;
         Print(EA_Name, " | LONG breakout entry @", ask, " SL:", sl, " TP:", tp);
      }
   }

   // Short breakdown
   if(!shortTaken && bid < rangeLow)
   {
      double sl = rangeHigh + buffer;
      double tp = bid - (rangeSize * RR_Multiple);
      trade.SetExpertMagicNumber(MagicORB);
      if(trade.Sell(LotSize, _Symbol, bid, sl, tp, EA_Name + " short breakdown"))
      {
         shortTaken = true;
         Print(EA_Name, " | SHORT breakdown entry @", bid, " SL:", sl, " TP:", tp);
      }
   }
}

//+------------------------------------------------------------------+
int CountTradesToday()
{
   int count = 0;
   datetime dayStart = rangeDayStamp - (rangeDayStamp % 86400);
   if(!HistorySelect(dayStart, TimeGMT())) return 0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == MagicORB &&
         HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_IN)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
void InitCSV()
{
   int handle = FileOpen(CSV_PATH, FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ);
   if(handle == INVALID_HANDLE)
   {
      handle = FileOpen(CSV_PATH, FILE_WRITE|FILE_CSV|FILE_ANSI);
      if(handle != INVALID_HANDLE)
      {
         FileWrite(handle, "ticket","symbol","type","open_time","close_time",
                   "open_price","close_price","volume","profit","range_high","range_low");
         FileClose(handle);
      }
   }
   else FileClose(handle);

   string gvTicket = "ORB_LastLoggedTicket_" + _Symbol + "_" + (string)MagicORB;
   if(GlobalVariableCheck(gvTicket))
      lastLoggedTicket = (ulong)GlobalVariableGet(gvTicket);
}

//+------------------------------------------------------------------+
void LogClosedTrades()
{
   if(!HistorySelect(TimeCurrent() - 7*86400, TimeCurrent())) return;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicORB) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      if(ticket <= lastLoggedTicket) continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      int handle = FileOpen(CSV_PATH, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ);
      if(handle != INVALID_HANDLE)
      {
         FileSeek(handle, 0, SEEK_END);
         FileWrite(handle, ticket, _Symbol,
                   (HistoryDealGetInteger(ticket, DEAL_TYPE) == DEAL_TYPE_SELL ? "BUY" : "SELL"),
                   TimeToString(HistoryDealGetInteger(ticket, DEAL_TIME)),
                   TimeToString(TimeCurrent()),
                   0, HistoryDealGetDouble(ticket, DEAL_PRICE),
                   HistoryDealGetDouble(ticket, DEAL_VOLUME),
                   profit, rangeHigh, rangeLow);
         FileClose(handle);
      }
      lastLoggedTicket = ticket;
      GlobalVariableSet("ORB_LastLoggedTicket_" + _Symbol + "_" + (string)MagicORB, (double)lastLoggedTicket);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   ResetDailyStateIfNeeded();
   BuildOpeningRange();
   CheckBreakoutEntries();
   LogClosedTrades();
}
//+------------------------------------------------------------------+
