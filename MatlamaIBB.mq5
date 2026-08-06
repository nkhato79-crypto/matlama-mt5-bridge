//+------------------------------------------------------------------+
//|                                              MatlamaIBB.mq5      |
//|                                          Matlama Tech 2026       |
//+------------------------------------------------------------------+
//|  Initial Balance Breakout — XAUUSD specialist.                   |
//|  Measures the high/low of the first N minutes of London & NY     |
//|  sessions (the "Initial Balance"), classifies IB width against   |
//|  ATR, and trades confirmed breakouts with extension targets.     |
//|                                                                   |
//|  Key differentiators vs generic ORB:                              |
//|    - IB width filter (narrow=trade, wide=skip or fade)           |
//|    - Close-based confirmation (body must clear IB, not just wick)|
//|    - Partial TP at 1× IB extension, final TP at user-set R:R    |
//|    - Optional retest entry (waits for pullback to IB boundary)   |
//|    - ATR trailing stop for Gold's trending moves                 |
//|    - Gold-specific pip handling and spread tolerance              |
//+------------------------------------------------------------------+
#property copyright "Matlama Tech 2026"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include "DynamicLot.mqh"
#include "PropFirmGuard.mqh"
CTrade trade;

//--- Identity
input int      MagicIBB            = 20260801;   // Unique magic number
input string   EA_Name             = "MatlamaIBB v1";

//--- Session timing (UTC)
input int      LondonStartHour     = 8;
input int      LondonStartMin      = 0;
input int      NYStartHour         = 13;
input int      NYStartMin          = 30;
input int      IBWindowMins        = 30;         // Initial Balance measurement window
input int      BreakoutValidMins   = 180;        // Breakout entry window after IB closes

//--- Entry rules
input bool     RequireCloseConfirm = true;       // M1 candle must CLOSE beyond IB (not just wick)
input bool     EnableRetestEntry   = false;       // Wait for pullback to IB boundary before entering
input int      RetestLookbackBars  = 10;         // How many M1 bars to look for retest after breakout
input double   RetestTolerancePips = 2.0;        // Price must come within this distance of IB boundary

//--- IB width filter (compare IB range to ATR to skip abnormal sessions)
input bool     EnableIBWidthFilter = true;
input double   IBMinWidthATR       = 0.4;        // Skip if IB < 40% of ATR (too narrow, whipsaw)
input double   IBMaxWidthATR       = 1.0;        // Skip if IB > 100% of ATR (too wide, poor R:R)
input int      ATRPeriod           = 14;

//--- Risk & targets
input bool     UseFixedLot         = true;       // Always trade LotSize; ignore RiskPercent
input double   LotSize             = 0.01;
input double   RiskPercent         = 1.0;        // % of equity per trade (ignored when UseFixedLot)
input double   SLBufferPips        = 3.0;        // SL buffer beyond IB boundary
input double   SLCap_ATR           = 1.0;        // cap SL distance at this × ATR (0 = no cap)
input double   RR_TP1              = 1.0;        // TP1 at this × IB range extension
input double   RR_TP2              = 2.0;        // TP2 (final) at this × IB range extension
input double   TP1_ClosePercent    = 50.0;       // Close this % of position at TP1
input int      MaxTradesPerDay     = 4;
input bool     OneSidePerSession   = true;       // only take first breakout direction per IB

//--- Trailing stop
input bool     EnableTrailing      = true;
input double   TrailATRMultiple    = 1.0;        // Trail distance = ATR × this
input double   TrailActivationRR   = 1.0;        // Activate trail after price moves this × IB range

//--- Spread filter (Gold can have wide spreads during low liquidity)
input double   MaxSpreadPips       = 5.0;        // Block entry if spread > this

//--- Session hours
input int      EarliestTradeHour   = 7;
input int      LatestTradeHour     = 20;

//--- CSV logging
string   CSV_PATH = "ibb_trades.csv";
ulong    lastLoggedTicket = 0;

//--- ATR handle
int atrHandle = INVALID_HANDLE;

//--- Per-session state, index 0 = London, index 1 = NY
datetime ibDayStamp[2];
datetime ibStartTime[2];
datetime ibEndTime[2];
double   ibHigh[2];
double   ibLow[2];
bool     ibLocked[2];
bool     longTaken[2];
bool     shortTaken[2];
bool     longBreakoutSeen[2];
bool     shortBreakoutSeen[2];
datetime longBreakoutTime[2];
datetime shortBreakoutTime[2];
string   sessionLabel[2];

//+------------------------------------------------------------------+
int OnInit()
{
   sessionLabel[0] = "LONDON";
   sessionLabel[1] = "NY";

   atrHandle = iATR(_Symbol, PERIOD_H1, ATRPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print(EA_Name, " FATAL: Cannot create ATR indicator");
      return(INIT_FAILED);
   }

   InitCSV();

   for(int s = 0; s < 2; s++)
   {
      ibDayStamp[s]       = 0;
      ibHigh[s]           = 0;
      ibLow[s]            = 0;
      ibLocked[s]         = false;
      longTaken[s]        = false;
      shortTaken[s]       = false;
      longBreakoutSeen[s] = false;
      shortBreakoutSeen[s]= false;

      string gvHigh = "IBB_RangeHigh_" + sessionLabel[s] + "_" + _Symbol + "_" + (string)MagicIBB;
      string gvLow  = "IBB_RangeLow_"  + sessionLabel[s] + "_" + _Symbol + "_" + (string)MagicIBB;
      string gvDay  = "IBB_RangeDay_"  + sessionLabel[s] + "_" + _Symbol + "_" + (string)MagicIBB;
      if(GlobalVariableCheck(gvDay))
      {
         datetime savedDay = (datetime)GlobalVariableGet(gvDay);
         if(IsSameTradingDay(savedDay, TimeGMT()))
         {
            ibDayStamp[s] = savedDay;
            ibHigh[s] = GlobalVariableGet(gvHigh);
            ibLow[s]  = GlobalVariableGet(gvLow);
            ibLocked[s] = (ibHigh[s] > 0 && ibLow[s] > 0);
         }
      }
   }

   PropGuardInit();

   Print(EA_Name, " initialized | Magic:", MagicIBB,
         " | London ", LondonStartHour, ":", LondonStartMin,
         " | NY ", NYStartHour, ":", NYStartMin,
         " | IB Window:", IBWindowMins, "min",
         " | Retest:", EnableRetestEntry,
         " | Trail:", EnableTrailing,
         " | Sizing:", (UseFixedLot ? "FIXED " + DoubleToString(LotSize, 2) + " lots"
                                    : "RISK " + DoubleToString(RiskPercent, 2) + "%"));
   Print(PropGuardStatus());
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
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
double GetATR()
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(atrHandle, 0, 0, 1, buf) < 1)
      return 0;
   return buf[0];
}

//+------------------------------------------------------------------+
double PipSize()
{
   return SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
}

//+------------------------------------------------------------------+
//  Fixed lot means risk per trade varies with stop distance. That is
//  deliberate while we are measuring the strategy rather than sizing it.
double ResolveLot(double slPips)
{
   double lot = UseFixedLot
                ? LotSize
                : CalcDynamicLot(_Symbol, slPips, PropGuardClampRisk(RiskPercent), LotSize);

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep > 0) lot = MathRound(lot / lotStep) * lotStep;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
double PriceToPips(double distance)
{
   double ps = PipSize();
   if(ps <= 0) return 0;
   return distance / ps;
}

//+------------------------------------------------------------------+
void ResetDailyStateIfNeeded(int s, int startHour, int startMin)
{
   datetime now = TimeGMT();
   if(ibDayStamp[s] == 0 || !IsSameTradingDay(ibDayStamp[s], now))
   {
      ibDayStamp[s]       = now;
      ibHigh[s]           = 0;
      ibLow[s]            = 0;
      ibLocked[s]         = false;
      longTaken[s]        = false;
      shortTaken[s]       = false;
      longBreakoutSeen[s] = false;
      shortBreakoutSeen[s]= false;

      MqlDateTime dt;
      TimeToStruct(now, dt);
      dt.hour = startHour;
      dt.min  = startMin;
      dt.sec  = 0;
      ibStartTime[s] = StructToTime(dt);
      ibEndTime[s]   = ibStartTime[s] + IBWindowMins * 60;
   }
}

//+------------------------------------------------------------------+
void BuildInitialBalance(int s)
{
   datetime now = TimeGMT();
   if(now < ibStartTime[s] || ibLocked[s]) return;

   if(now <= ibEndTime[s])
   {
      int bars = Bars(_Symbol, PERIOD_M1, ibStartTime[s], now);
      if(bars <= 0) return;
      double hi = iHigh(_Symbol, PERIOD_M1, iHighest(_Symbol, PERIOD_M1, MODE_HIGH, bars, 0));
      double lo = iLow(_Symbol, PERIOD_M1, iLowest(_Symbol, PERIOD_M1, MODE_LOW, bars, 0));
      if(hi > ibHigh[s]) ibHigh[s] = hi;
      if(ibLow[s] == 0 || lo < ibLow[s]) ibLow[s] = lo;
   }
   else
   {
      ibLocked[s] = true;

      string gvHigh = "IBB_RangeHigh_" + sessionLabel[s] + "_" + _Symbol + "_" + (string)MagicIBB;
      string gvLow  = "IBB_RangeLow_"  + sessionLabel[s] + "_" + _Symbol + "_" + (string)MagicIBB;
      string gvDay  = "IBB_RangeDay_"  + sessionLabel[s] + "_" + _Symbol + "_" + (string)MagicIBB;
      GlobalVariableSet(gvHigh, ibHigh[s]);
      GlobalVariableSet(gvLow, ibLow[s]);
      GlobalVariableSet(gvDay, (double)ibDayStamp[s]);

      double ibRange = ibHigh[s] - ibLow[s];
      double atr = GetATR();
      string widthClass = "NORMAL";
      if(atr > 0)
      {
         double ratio = ibRange / atr;
         if(ratio < IBMinWidthATR)      widthClass = "NARROW";
         else if(ratio > IBMaxWidthATR) widthClass = "WIDE";
      }

      Print(EA_Name, " | ", sessionLabel[s], " IB locked | High:", DoubleToString(ibHigh[s], 2),
            " Low:", DoubleToString(ibLow[s], 2),
            " Range:", DoubleToString(PriceToPips(ibRange), 1), " pips",
            " | ATR:", DoubleToString(PriceToPips(atr), 1), " pips",
            " | Class:", widthClass);
   }
}

//+------------------------------------------------------------------+
bool WithinBreakoutWindow(int s)
{
   datetime now = TimeGMT();
   return(ibLocked[s] && now > ibEndTime[s] && now <= ibEndTime[s] + BreakoutValidMins * 60);
}

//+------------------------------------------------------------------+
bool PassesIBWidthFilter(int s)
{
   if(!EnableIBWidthFilter) return true;

   double ibRange = ibHigh[s] - ibLow[s];
   double atr = GetATR();
   if(atr <= 0) return true;

   double ratio = ibRange / atr;
   if(ratio < IBMinWidthATR)
   {
      Print(EA_Name, " | ", sessionLabel[s], " IB WIDTH FILTER | Range/ATR=",
            DoubleToString(ratio, 2), " < ", DoubleToString(IBMinWidthATR, 2), " (too narrow)");
      return false;
   }
   if(ratio > IBMaxWidthATR)
   {
      Print(EA_Name, " | ", sessionLabel[s], " IB WIDTH FILTER | Range/ATR=",
            DoubleToString(ratio, 2), " > ", DoubleToString(IBMaxWidthATR, 2), " (too wide)");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
bool PassesSpreadFilter()
{
   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spreadPips = PriceToPips(spread);
   if(spreadPips > MaxSpreadPips)
   {
      Print(EA_Name, " | SPREAD FILTER | ", DoubleToString(spreadPips, 1),
            " pips > max ", DoubleToString(MaxSpreadPips, 1));
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
bool HasCloseConfirmation(string dir, int s)
{
   if(!RequireCloseConfirm) return true;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M1, 0, 2, rates) < 2) return false;

   if(dir == "BUY")
      return (rates[1].close > ibHigh[s]);
   else
      return (rates[1].close < ibLow[s]);
}

//+------------------------------------------------------------------+
bool CheckRetestEntry(string dir, int s)
{
   if(!EnableRetestEntry) return true;

   double tolerance = RetestTolerancePips * PipSize();

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M1, 0, RetestLookbackBars + 1, rates) < RetestLookbackBars + 1)
      return false;

   if(dir == "BUY")
   {
      for(int i = 1; i <= RetestLookbackBars; i++)
      {
         if(rates[i].low <= ibHigh[s] + tolerance && rates[i].low >= ibHigh[s] - tolerance)
         {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            if(ask > ibHigh[s])
            {
               Print(EA_Name, " | ", sessionLabel[s],
                     " RETEST CONFIRMED | BUY pullback to IB high at bar -", i);
               return true;
            }
         }
      }
      return false;
   }
   else
   {
      for(int i = 1; i <= RetestLookbackBars; i++)
      {
         if(rates[i].high >= ibLow[s] - tolerance && rates[i].high <= ibLow[s] + tolerance)
         {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            if(bid < ibLow[s])
            {
               Print(EA_Name, " | ", sessionLabel[s],
                     " RETEST CONFIRMED | SELL pullback to IB low at bar -", i);
               return true;
            }
         }
      }
      return false;
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
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == MagicIBB &&
         HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_IN)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
void CheckBreakoutEntries(int s)
{
   if(!WithinBreakoutWindow(s)) return;
   if(ibHigh[s] <= 0 || ibLow[s] <= 0) return;

   MqlDateTime nowDt;
   TimeToStruct(TimeGMT(), nowDt);
   if(nowDt.hour < EarliestTradeHour || nowDt.hour >= LatestTradeHour) return;

   if(!PassesIBWidthFilter(s)) return;

   double ibRange  = ibHigh[s] - ibLow[s];
   double pipSz    = PipSize();
   double buffer   = SLBufferPips * pipSz;
   double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   //--- Detect breakout (for retest mode, record when breakout first happens)
   if(!longBreakoutSeen[s] && ask > ibHigh[s])
   {
      longBreakoutSeen[s] = true;
      longBreakoutTime[s] = TimeGMT();
      if(EnableRetestEntry)
         Print(EA_Name, " | ", sessionLabel[s], " LONG breakout detected, waiting for retest...");
   }
   if(!shortBreakoutSeen[s] && bid < ibLow[s])
   {
      shortBreakoutSeen[s] = true;
      shortBreakoutTime[s] = TimeGMT();
      if(EnableRetestEntry)
         Print(EA_Name, " | ", sessionLabel[s], " SHORT breakout detected, waiting for retest...");
   }

   if(CountTradesToday() >= MaxTradesPerDay) return;
   if(!PropGuardCanTrade()) return;
   if(!PassesSpreadFilter()) return;

   //--- One-side-per-session: if either direction already taken, skip both
   if(OneSidePerSession && (longTaken[s] || shortTaken[s])) return;

   //--- LONG breakout
   if(!longTaken[s] && longBreakoutSeen[s] && ask > ibHigh[s])
   {
      if(!HasCloseConfirmation("BUY", s)) return;
      if(!CheckRetestEntry("BUY", s)) return;

      double sl = ibLow[s] - buffer;

      //--- SL cap: prevent oversized SL when IB range is wide
      if(SLCap_ATR > 0)
      {
         double atrNow = GetATR();
         if(atrNow > 0)
         {
            double maxSLDist = SLCap_ATR * atrNow;
            if(ask - sl > maxSLDist)
            {
               Print(EA_Name, " | SL CAP | BUY SL capped from ", DoubleToString(sl, 2),
                     " to ", DoubleToString(ask - maxSLDist, 2));
               sl = ask - maxSLDist;
            }
         }
      }

      double tp1 = ask + (ibRange * RR_TP1);
      double tp2 = ask + (ibRange * RR_TP2);

      double slPips = PriceToPips(ask - sl);
      double lot = ResolveLot(slPips);

      trade.SetExpertMagicNumber(MagicIBB);

      double tp = (TP1_ClosePercent >= 100.0) ? tp1 : tp2;
      string comment = EA_Name + " " + sessionLabel[s] + " LONG";

      if(trade.Buy(lot, _Symbol, ask, sl, tp, comment))
      {
         PropGuardOnTrade();
         longTaken[s] = true;
         ulong posTicket = trade.ResultOrder();
         if(posTicket > 0)
         {
            GlobalVariableSet("IBB_EntryRH_" + (string)posTicket, ibHigh[s]);
            GlobalVariableSet("IBB_EntryRL_" + (string)posTicket, ibLow[s]);
            GlobalVariableSet("IBB_EntryOP_" + (string)posTicket, ask);
            GlobalVariableSet("IBB_TP1_" + (string)posTicket, tp1);
            GlobalVariableSet("IBB_TP1Done_" + (string)posTicket, 0);
         }
         Print(EA_Name, " | ", sessionLabel[s], " LONG @", DoubleToString(ask, 2),
               " SL:", DoubleToString(sl, 2),
               " TP1:", DoubleToString(tp1, 2),
               " TP2:", DoubleToString(tp2, 2),
               " Lot:", DoubleToString(lot, 2),
               " IB:", DoubleToString(PriceToPips(ibRange), 1), "pips");
      }
   }

   //--- SHORT breakout
   if(!shortTaken[s] && shortBreakoutSeen[s] && bid < ibLow[s])
   {
      if(!HasCloseConfirmation("SELL", s)) return;
      if(!CheckRetestEntry("SELL", s)) return;

      double sl = ibHigh[s] + buffer;

      //--- SL cap
      if(SLCap_ATR > 0)
      {
         double atrNow = GetATR();
         if(atrNow > 0)
         {
            double maxSLDist = SLCap_ATR * atrNow;
            if(sl - bid > maxSLDist)
            {
               Print(EA_Name, " | SL CAP | SELL SL capped from ", DoubleToString(sl, 2),
                     " to ", DoubleToString(bid + maxSLDist, 2));
               sl = bid + maxSLDist;
            }
         }
      }

      double tp1 = bid - (ibRange * RR_TP1);
      double tp2 = bid - (ibRange * RR_TP2);

      double slPips = PriceToPips(sl - bid);
      double lot = ResolveLot(slPips);

      trade.SetExpertMagicNumber(MagicIBB);

      double tp = (TP1_ClosePercent >= 100.0) ? tp1 : tp2;
      string comment = EA_Name + " " + sessionLabel[s] + " SHORT";

      if(trade.Sell(lot, _Symbol, bid, sl, tp, comment))
      {
         PropGuardOnTrade();
         shortTaken[s] = true;
         ulong posTicket = trade.ResultOrder();
         if(posTicket > 0)
         {
            GlobalVariableSet("IBB_EntryRH_" + (string)posTicket, ibHigh[s]);
            GlobalVariableSet("IBB_EntryRL_" + (string)posTicket, ibLow[s]);
            GlobalVariableSet("IBB_EntryOP_" + (string)posTicket, bid);
            GlobalVariableSet("IBB_TP1_" + (string)posTicket, tp1);
            GlobalVariableSet("IBB_TP1Done_" + (string)posTicket, 0);
         }
         Print(EA_Name, " | ", sessionLabel[s], " SHORT @", DoubleToString(bid, 2),
               " SL:", DoubleToString(sl, 2),
               " TP1:", DoubleToString(tp1, 2),
               " TP2:", DoubleToString(tp2, 2),
               " Lot:", DoubleToString(lot, 2),
               " IB:", DoubleToString(PriceToPips(ibRange), 1), "pips");
      }
   }
}

//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicIBB) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long posType    = PositionGetInteger(POSITION_TYPE);
      double openPr   = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL    = PositionGetDouble(POSITION_SL);
      double curTP    = PositionGetDouble(POSITION_TP);
      double volume   = PositionGetDouble(POSITION_VOLUME);
      string posKey   = (string)ticket;

      double entryRH = 0, entryRL = 0, entryOP = 0, tp1 = 0;
      bool hasGV = false;
      if(GlobalVariableCheck("IBB_EntryRH_" + posKey))
      {
         entryRH = GlobalVariableGet("IBB_EntryRH_" + posKey);
         entryRL = GlobalVariableGet("IBB_EntryRL_" + posKey);
         entryOP = GlobalVariableGet("IBB_EntryOP_" + posKey);
         tp1     = GlobalVariableGet("IBB_TP1_" + posKey);
         hasGV   = true;
      }

      double ibRange = entryRH - entryRL;
      if(ibRange <= 0) continue;

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double currentPrice = (posType == POSITION_TYPE_BUY) ? bid : ask;

      //--- Partial close at TP1
      if(hasGV && TP1_ClosePercent > 0 && TP1_ClosePercent < 100.0)
      {
         double tp1Done = GlobalVariableGet("IBB_TP1Done_" + posKey);
         if(tp1Done < 1 && tp1 > 0)
         {
            bool tp1Hit = false;
            if(posType == POSITION_TYPE_BUY && bid >= tp1)   tp1Hit = true;
            if(posType == POSITION_TYPE_SELL && ask <= tp1)   tp1Hit = true;

            if(tp1Hit)
            {
               double closeLot = NormalizeDouble(volume * TP1_ClosePercent / 100.0, 2);
               double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
               double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
               if(lotStep > 0)
                  closeLot = MathFloor(closeLot / lotStep) * lotStep;
               if(closeLot < minLot) closeLot = minLot;

               if(closeLot < volume)
               {
                  trade.SetExpertMagicNumber(MagicIBB);
                  if(posType == POSITION_TYPE_BUY)
                     trade.Sell(closeLot, _Symbol, bid, 0, 0, "IBB TP1 partial");
                  else
                     trade.Buy(closeLot, _Symbol, ask, 0, 0, "IBB TP1 partial");

                  GlobalVariableSet("IBB_TP1Done_" + posKey, 1);
                  Print(EA_Name, " | TP1 partial close ", DoubleToString(closeLot, 2),
                        " lots @ ", DoubleToString(currentPrice, 2));

                  // Move SL to breakeven on remaining position
                  trade.PositionModify(ticket, openPr, curTP);
                  Print(EA_Name, " | SL moved to breakeven: ", DoubleToString(openPr, 2));
               }
            }
         }
      }

      //--- ATR trailing stop
      if(EnableTrailing)
      {
         double atr = GetATR();
         if(atr <= 0) continue;

         double trailDist = atr * TrailATRMultiple;
         double activationDist = ibRange * TrailActivationRR;

         if(posType == POSITION_TYPE_BUY)
         {
            double moveFromEntry = bid - openPr;
            if(moveFromEntry >= activationDist)
            {
               double newSL = bid - trailDist;
               newSL = NormalizeDouble(newSL, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
               if(newSL > curSL && newSL < bid)
               {
                  trade.PositionModify(ticket, newSL, curTP);
               }
            }
         }
         else
         {
            double moveFromEntry = openPr - ask;
            if(moveFromEntry >= activationDist)
            {
               double newSL = ask + trailDist;
               newSL = NormalizeDouble(newSL, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
               if(newSL < curSL && newSL > ask)
               {
                  trade.PositionModify(ticket, newSL, curTP);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//--- CSV logging
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
                   "open_price","close_price","volume","profit","ib_high","ib_low","ib_range_pips");
         FileClose(handle);
      }
   }
   else FileClose(handle);

   string gvTicket = "IBB_LastLoggedTicket_" + _Symbol + "_" + (string)MagicIBB;
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
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicIBB) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      if(ticket <= lastLoggedTicket) continue;

      string comment = HistoryDealGetString(ticket, DEAL_COMMENT);
      if(StringFind(comment, "TP1 partial") >= 0) continue;

      string session = (StringFind(comment, "NY") >= 0) ? "NY" : "LONDON";
      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);

      double openPrice = 0;
      ulong positionId = (ulong)HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
      for(int j = 0; j < total; j++)
      {
         ulong entryTicket = HistoryDealGetTicket(j);
         if(HistoryDealGetInteger(entryTicket, DEAL_POSITION_ID) == (long)positionId &&
            HistoryDealGetInteger(entryTicket, DEAL_ENTRY) == DEAL_ENTRY_IN)
         {
            openPrice = HistoryDealGetDouble(entryTicket, DEAL_PRICE);
            break;
         }
      }

      string posKey = (string)positionId;
      double logRangeHigh = 0, logRangeLow = 0;
      if(GlobalVariableCheck("IBB_EntryRH_" + posKey))
      {
         logRangeHigh = GlobalVariableGet("IBB_EntryRH_" + posKey);
         logRangeLow  = GlobalVariableGet("IBB_EntryRL_" + posKey);
         if(openPrice == 0 && GlobalVariableCheck("IBB_EntryOP_" + posKey))
            openPrice = GlobalVariableGet("IBB_EntryOP_" + posKey);

         GlobalVariableDel("IBB_EntryRH_" + posKey);
         GlobalVariableDel("IBB_EntryRL_" + posKey);
         GlobalVariableDel("IBB_EntryOP_" + posKey);
         GlobalVariableDel("IBB_TP1_" + posKey);
         GlobalVariableDel("IBB_TP1Done_" + posKey);
      }
      else
      {
         int s = (session == "NY") ? 1 : 0;
         logRangeHigh = ibHigh[s];
         logRangeLow  = ibLow[s];
      }

      double ibRangePips = PriceToPips(logRangeHigh - logRangeLow);

      int handle = FileOpen(CSV_PATH, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ);
      if(handle != INVALID_HANDLE)
      {
         FileSeek(handle, 0, SEEK_END);
         FileWrite(handle, ticket, _Symbol, session,
                   (HistoryDealGetInteger(ticket, DEAL_TYPE) == DEAL_TYPE_SELL ? "BUY" : "SELL"),
                   TimeToString(HistoryDealGetInteger(ticket, DEAL_TIME)),
                   TimeToString(TimeCurrent()),
                   openPrice, HistoryDealGetDouble(ticket, DEAL_PRICE),
                   HistoryDealGetDouble(ticket, DEAL_VOLUME),
                   profit,
                   logRangeHigh, logRangeLow,
                   DoubleToString(ibRangePips, 1));
         FileClose(handle);
      }
      lastLoggedTicket = ticket;
      GlobalVariableSet("IBB_LastLoggedTicket_" + _Symbol + "_" + (string)MagicIBB, (double)lastLoggedTicket);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   PropGuardOnTick();

   ResetDailyStateIfNeeded(0, LondonStartHour, LondonStartMin);
   ResetDailyStateIfNeeded(1, NYStartHour, NYStartMin);

   BuildInitialBalance(0);
   BuildInitialBalance(1);

   CheckBreakoutEntries(0);
   CheckBreakoutEntries(1);

   ManageOpenPositions();

   LogClosedTrades();
}
//+------------------------------------------------------------------+
