//+------------------------------------------------------------------+
//|                                              MatlamaORB.mq5      |
//|                                          Matlama Tech 2026       |
//+------------------------------------------------------------------+
//|  Standalone Opening Range Breakout strategy — London + NY.       |
//|  Deliberately NOT wired to orchestrator_v2 (no ML scoring —      |
//|  ORB logic is deterministic rule-based, nothing to learn).       |
//|  Protection from high-impact news still comes from               |
//|  MatlamaFundamentals via CloseByMagic(MagicORB).                 |
//+------------------------------------------------------------------+
#property copyright "Matlama Tech 2026"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include "DynamicLot.mqh"
CTrade trade;

//--- Identity
input int    MagicORB          = 20260301;   // Unique magic number for this EA
input string EA_Name           = "MatlamaORB v2";

//--- Session 0 = London, Session 1 = NY. All times UTC.
input int    LondonStartHour   = 8;
input int    LondonStartMin    = 0;
input int    NYStartHour       = 13;
input int    NYStartMin        = 30;
input int    RangeWindowMins   = 30;         // Length of the opening range window (both sessions)
input int    BreakoutValidMins = 180;        // How long after range closes a breakout is still valid

//--- Risk settings
input double LotSize           = 0.01;
input double RiskPercent       = 1.0;        // % of equity risked per trade (0 = use fixed LotSize)
input double SLBufferPips      = 5.0;        // Extra buffer beyond range boundary for SL
input double RR_Multiple       = 2.0;        // TP = range size * this multiple
input int    MaxTradesPerDay   = 4;          // Across both sessions combined (2 sessions x long/short)

//--- CSV logging
string   CSV_PATH = "orb_trades.csv";
ulong    lastLoggedTicket = 0;

//--- Per-session state, index 0 = London, index 1 = NY
datetime rangeDayStamp[2];
datetime rangeStartTime[2];
datetime rangeEndTime[2];
double   rangeHigh[2];
double   rangeLow[2];
bool     rangeLocked[2];
bool     longTaken[2];
bool     shortTaken[2];
string   sessionLabel[2];

//+------------------------------------------------------------------+
int OnInit()
{
   sessionLabel[0] = "LONDON";
   sessionLabel[1] = "NY";

   InitCSV();

   for(int s = 0; s < 2; s++)
   {
      rangeDayStamp[s] = 0;
      rangeHigh[s]     = 0;
      rangeLow[s]      = 0;
      rangeLocked[s]   = false;
      longTaken[s]     = false;
      shortTaken[s]    = false;

      // Restore today's range across recompiles/restarts so we don't miss
      // a breakout already in progress when the EA reinitializes mid-session.
      string gvHigh = "ORB_RangeHigh_" + sessionLabel[s] + "_" + _Symbol + "_" + (string)MagicORB;
      string gvLow  = "ORB_RangeLow_"  + sessionLabel[s] + "_" + _Symbol + "_" + (string)MagicORB;
      string gvDay  = "ORB_RangeDay_"  + sessionLabel[s] + "_" + _Symbol + "_" + (string)MagicORB;
      if(GlobalVariableCheck(gvDay))
      {
         datetime savedDay = (datetime)GlobalVariableGet(gvDay);
         if(IsSameTradingDay(savedDay, TimeGMT()))
         {
            rangeDayStamp[s] = savedDay;
            rangeHigh[s] = GlobalVariableGet(gvHigh);
            rangeLow[s]  = GlobalVariableGet(gvLow);
            rangeLocked[s] = (rangeHigh[s] > 0 && rangeLow[s] > 0);
         }
      }
   }

   Print(EA_Name, " initialized | Magic:", MagicORB,
         " | London ", LondonStartHour, ":", LondonStartMin,
         " | NY ", NYStartHour, ":", NYStartMin,
         " | Window:", RangeWindowMins, "min");
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
void ResetDailyStateIfNeeded(int s, int startHour, int startMin)
{
   datetime now = TimeGMT();
   if(rangeDayStamp[s] == 0 || !IsSameTradingDay(rangeDayStamp[s], now))
   {
      rangeDayStamp[s] = now;
      rangeHigh[s]     = 0;
      rangeLow[s]      = 0;
      rangeLocked[s]   = false;
      longTaken[s]     = false;
      shortTaken[s]    = false;

      MqlDateTime dt;
      TimeToStruct(now, dt);
      dt.hour = startHour;
      dt.min  = startMin;
      dt.sec  = 0;
      rangeStartTime[s] = StructToTime(dt);
      rangeEndTime[s]   = rangeStartTime[s] + RangeWindowMins * 60;
   }
}

//+------------------------------------------------------------------+
void BuildOpeningRange(int s)
{
   datetime now = TimeGMT();
   if(now < rangeStartTime[s] || rangeLocked[s]) return;

   if(now <= rangeEndTime[s])
   {
      int bars = Bars(_Symbol, PERIOD_M1, rangeStartTime[s], now);
      if(bars <= 0) return;
      double hi = iHigh(_Symbol, PERIOD_M1, iHighest(_Symbol, PERIOD_M1, MODE_HIGH, bars, 0));
      double lo = iLow(_Symbol, PERIOD_M1, iLowest(_Symbol, PERIOD_M1, MODE_LOW, bars, 0));
      if(hi > rangeHigh[s]) rangeHigh[s] = hi;
      if(rangeLow[s] == 0 || lo < rangeLow[s]) rangeLow[s] = lo;
   }
   else
   {
      rangeLocked[s] = true;
      string gvHigh = "ORB_RangeHigh_" + sessionLabel[s] + "_" + _Symbol + "_" + (string)MagicORB;
      string gvLow  = "ORB_RangeLow_"  + sessionLabel[s] + "_" + _Symbol + "_" + (string)MagicORB;
      string gvDay  = "ORB_RangeDay_"  + sessionLabel[s] + "_" + _Symbol + "_" + (string)MagicORB;
      GlobalVariableSet(gvHigh, rangeHigh[s]);
      GlobalVariableSet(gvLow, rangeLow[s]);
      GlobalVariableSet(gvDay, (double)rangeDayStamp[s]);
      Print(EA_Name, " | ", sessionLabel[s], " range locked | High:", rangeHigh[s],
            " Low:", rangeLow[s], " Size:", (rangeHigh[s] - rangeLow[s]));
   }
}

//+------------------------------------------------------------------+
bool WithinBreakoutWindow(int s)
{
   datetime now = TimeGMT();
   return(rangeLocked[s] && now > rangeEndTime[s] && now <= rangeEndTime[s] + BreakoutValidMins * 60);
}

//+------------------------------------------------------------------+
void CheckBreakoutEntries(int s)
{
   if(!WithinBreakoutWindow(s)) return;
   if(rangeHigh[s] <= 0 || rangeLow[s] <= 0) return;

   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double buffer  = SLBufferPips * point * 10;
   double rangeSize = rangeHigh[s] - rangeLow[s];
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(CountTradesToday() >= MaxTradesPerDay) return;

   if(!longTaken[s] && ask > rangeHigh[s])
   {
      double sl = rangeLow[s] - buffer;
      double tp = ask + (rangeSize * RR_Multiple);
      double sl_pips_long = (ask - sl) / (point * 10);
      double lot = CalcDynamicLot(_Symbol, sl_pips_long, RiskPercent, LotSize);
      trade.SetExpertMagicNumber(MagicORB);
      if(trade.Buy(lot, _Symbol, ask, sl, tp, EA_Name + " " + sessionLabel[s] + " long"))
      {
         longTaken[s] = true;
         Print(EA_Name, " | ", sessionLabel[s], " LONG breakout @", ask,
               " SL:", sl, " TP:", tp, " Lot:", DoubleToString(lot, 2));
      }
   }

   if(!shortTaken[s] && bid < rangeLow[s])
   {
      double sl = rangeHigh[s] + buffer;
      double tp = bid - (rangeSize * RR_Multiple);
      double sl_pips_short = (sl - bid) / (point * 10);
      double lot = CalcDynamicLot(_Symbol, sl_pips_short, RiskPercent, LotSize);
      trade.SetExpertMagicNumber(MagicORB);
      if(trade.Sell(lot, _Symbol, bid, sl, tp, EA_Name + " " + sessionLabel[s] + " short"))
      {
         shortTaken[s] = true;
         Print(EA_Name, " | ", sessionLabel[s], " SHORT breakdown @", bid,
               " SL:", sl, " TP:", tp, " Lot:", DoubleToString(lot, 2));
      }
   }
}

//+------------------------------------------------------------------+
int CountTradesToday()
{
   int count = 0;
   datetime now = TimeGMT();
   datetime dayStart = now - (now % 86400);
   if(!HistorySelect(dayStart, now)) return 0;
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
         FileWrite(handle, "ticket","symbol","session","type","open_time","close_time",
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

      string comment = HistoryDealGetString(ticket, DEAL_COMMENT);
      string session = (StringFind(comment, "NY") >= 0) ? "NY" : "LONDON";
      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);

      int handle = FileOpen(CSV_PATH, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ);
      if(handle != INVALID_HANDLE)
      {
         FileSeek(handle, 0, SEEK_END);
         FileWrite(handle, ticket, _Symbol, session,
                   (HistoryDealGetInteger(ticket, DEAL_TYPE) == DEAL_TYPE_SELL ? "BUY" : "SELL"),
                   TimeToString(HistoryDealGetInteger(ticket, DEAL_TIME)),
                   TimeToString(TimeCurrent()),
                   0, HistoryDealGetDouble(ticket, DEAL_PRICE),
                   HistoryDealGetDouble(ticket, DEAL_VOLUME),
                   profit,
                   (session == "NY" ? rangeHigh[1] : rangeHigh[0]),
                   (session == "NY" ? rangeLow[1]  : rangeLow[0]));
         FileClose(handle);
      }
      lastLoggedTicket = ticket;
      GlobalVariableSet("ORB_LastLoggedTicket_" + _Symbol + "_" + (string)MagicORB, (double)lastLoggedTicket);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   ResetDailyStateIfNeeded(0, LondonStartHour, LondonStartMin);
   ResetDailyStateIfNeeded(1, NYStartHour, NYStartMin);

   BuildOpeningRange(0);
   BuildOpeningRange(1);

   CheckBreakoutEntries(0);
   CheckBreakoutEntries(1);

   LogClosedTrades();
}
//+------------------------------------------------------------------+
