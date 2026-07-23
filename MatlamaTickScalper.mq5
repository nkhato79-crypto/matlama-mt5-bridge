//+------------------------------------------------------------------+
//|                                        MatlamaTickScalper.mq5    |
//|                                      Matlama Tech © 2026         |
//|              VWAP Mean-Reversion Micro Scalper                   |
//|         Institutional strategy: enter when price deviates from   |
//|         VWAP bands, profit as it reverts to fair value.          |
//+------------------------------------------------------------------+
#property copyright "Matlama Tech 2026"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include "OrchestratorClient.mqh"
#include "DynamicLot.mqh"

//--- Core Parameters
input string   EA_Name          = "MatlamaTickScalper v2";
input double   LotSize          = 0.01;
input double   RiskPercent      = 1.0;         // % of equity risked per trade (0 = use fixed LotSize)
input int      MagicNumber      = 20260104;
input int      MaxHoldSeconds   = 300;         // 5 min max hold
input int      MaxTradesPerDay  = 20;          // quality over quantity
input double   MaxDailyLoss     = 50.0;        // account-currency cap
input bool     AutoTrade        = true;

//--- VWAP Settings
input int      VWAPBars         = 60;          // M1 bars for rolling VWAP (1 hour)
input double   EntryBandMult    = 1.5;         // enter at VWAP ± 1.5σ
input double   StopBandMult     = 2.5;         // SL at VWAP ± 2.5σ
input int      MinTP_Pips       = 2;           // skip if VWAP too close
input int      MaxTP_Pips       = 15;          // cap the TP distance
input int      MinSL_Pips       = 3;           // floor for SL
input int      MaxSL_Pips       = 15;          // cap for SL

//--- Confirmation Filters
input int      RSI_Period       = 14;          // RSI period
input int      RSI_OB           = 65;          // overbought threshold
input int      RSI_OS           = 35;          // oversold threshold
input int      ADX_Period       = 14;          // ADX period
input int      ADX_Max          = 30;          // skip trending markets
input double   MaxSpreadPips    = 2.5;         // max spread to enter
input double   MinBandWidth     = 0.5;         // skip if σ < 0.5 pips

//--- Risk Management
input double   BreakevenPips    = 3.0;         // move SL to BE
input double   TrailStartPips   = 4.0;         // start trailing
input double   TrailStepPips    = 1.5;         // trail distance
input int      CooldownSeconds  = 10;          // gap between trades

//--- Session Filter
input bool     LondonSession    = true;        // 07:00-16:00 UTC
input bool     NewYorkSession   = true;        // 12:00-21:00 UTC
input bool     AsiaSession      = false;       // 00:00-09:00 UTC

//--- Orchestrator (feedback loop only)
input string   ORCH_REPORT      = "http://127.0.0.1:7000/report_trade";

//+------------------------------------------------------------------+
//| Global state                                                      |
//+------------------------------------------------------------------+
CTrade      trade;
double      pipSize;
int         digits;
int         dailyTradeCount  = 0;
double      dailyPnL         = 0.0;
datetime    currentDay       = 0;
datetime    lastEntryTime    = 0;
string      LastRegime       = "UNKNOWN";
ulong       lastLoggedTicket = 0;

// indicator handles
int         rsiHandle        = INVALID_HANDLE;
int         adxHandle        = INVALID_HANDLE;

// cached calculations (updated once per M1 bar)
datetime    lastVWAPBar      = 0;
double      cachedVWAP       = 0;
double      cachedStdDev     = 0;
double      prevVWAP         = 0;
double      vwapSlope        = 0;

datetime    lastIndBar       = 0;
double      cachedRSI        = 50;
double      cachedADX        = 25;

// entry-time features for CSV logging
double      entryVWAPDev     = 0;
double      entryRSI         = 0;
double      entryADX         = 0;
double      entrySpread      = 0;
double      entryVWAPSlope   = 0;

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(5);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   rsiHandle = iRSI(_Symbol, PERIOD_M5, RSI_Period, PRICE_CLOSE);
   adxHandle = iADX(_Symbol, PERIOD_M5, ADX_Period);

   if(rsiHandle == INVALID_HANDLE || adxHandle == INVALID_HANDLE)
   {
      Print(EA_Name, " FAILED — indicator handles invalid");
      return INIT_FAILED;
   }

   currentDay = iTime(_Symbol, PERIOD_D1, 0);
   InitCSV();

   Print(EA_Name, " init | ", _Symbol,
         " pip=", pipSize,
         " VWAP=", VWAPBars, " bars",
         " entry=", DoubleToString(EntryBandMult, 1), "σ",
         " stop=", DoubleToString(StopBandMult, 1), "σ");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(adxHandle != INVALID_HANDLE) IndicatorRelease(adxHandle);
   Print(EA_Name, " removed | trades=", dailyTradeCount,
         " pnl=", DoubleToString(dailyPnL, 2));
}

//+------------------------------------------------------------------+
//| OnTick — main loop                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   // daily reset
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today != currentDay)
   {
      Print("VWAP_SCALP day reset | trades=", dailyTradeCount,
            " pnl=", DoubleToString(dailyPnL, 2));
      dailyTradeCount = 0;
      dailyPnL        = 0.0;
      currentDay      = today;
   }

   // update cached indicators
   UpdateVWAP();
   UpdateIndicators();

   // log closed trades
   LogClosedTrades();

   // manage open position
   if(HasPosition())
   {
      ManagePosition();
      return;
   }

   // entry gates
   if(!AutoTrade)                                      return;
   if(dailyTradeCount >= MaxTradesPerDay)               return;
   if(dailyPnL <= -MaxDailyLoss)                        return;
   if(!InSession())                                     return;
   if((int)(TimeCurrent() - lastEntryTime) < CooldownSeconds) return;

   CheckEntry();
}

//+------------------------------------------------------------------+
//| VWAP calculation from M1 bars (updated once per new M1 bar)       |
//+------------------------------------------------------------------+
void UpdateVWAP()
{
   datetime currentBar = iTime(_Symbol, PERIOD_M1, 0);
   if(currentBar == lastVWAPBar) return;
   lastVWAPBar = currentBar;

   prevVWAP = cachedVWAP;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, PERIOD_M1, 0, VWAPBars, rates);
   if(copied < VWAPBars / 2)
   {
      cachedVWAP   = 0;
      cachedStdDev = 0;
      return;
   }

   // VWAP = Σ(typical_price × tick_volume) / Σ(tick_volume)
   double sumPV = 0, sumV = 0;
   for(int i = 0; i < copied; i++)
   {
      double tp  = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
      double vol = (double)rates[i].tick_volume;
      if(vol <= 0) vol = 1;
      sumPV += tp * vol;
      sumV  += vol;
   }

   if(sumV <= 0) { cachedVWAP = 0; cachedStdDev = 0; return; }
   cachedVWAP = sumPV / sumV;

   // volume-weighted standard deviation
   double sumVar = 0;
   for(int i = 0; i < copied; i++)
   {
      double tp  = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
      double vol = (double)rates[i].tick_volume;
      if(vol <= 0) vol = 1;
      sumVar += vol * (tp - cachedVWAP) * (tp - cachedVWAP);
   }
   cachedStdDev = MathSqrt(sumVar / sumV);

   // VWAP slope (pips per M1 bar)
   if(prevVWAP > 0)
      vwapSlope = (cachedVWAP - prevVWAP) / pipSize;
}

//+------------------------------------------------------------------+
//| RSI + ADX (updated once per new M5 bar)                           |
//+------------------------------------------------------------------+
void UpdateIndicators()
{
   datetime currentBar = iTime(_Symbol, PERIOD_M5, 0);
   if(currentBar == lastIndBar) return;
   lastIndBar = currentBar;

   double rsiVal[1], adxVal[1];
   if(CopyBuffer(rsiHandle, 0, 0, 1, rsiVal) == 1) cachedRSI = rsiVal[0];
   if(CopyBuffer(adxHandle, 0, 0, 1, adxVal) == 1) cachedADX = adxVal[0];
}

//+------------------------------------------------------------------+
//| Entry logic — VWAP mean reversion                                 |
//+------------------------------------------------------------------+
void CheckEntry()
{
   if(cachedVWAP <= 0 || cachedStdDev <= 0) return;

   // band width too narrow — no meaningful deviation
   double bandWidthPips = cachedStdDev / pipSize;
   if(bandWidthPips < MinBandWidth) return;

   // trend filter — skip trending markets
   if(cachedADX > ADX_Max) return;

   // spread check
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double spread = (ask - bid) / pipSize;
   if(spread > MaxSpreadPips) return;

   double price = (bid + ask) / 2.0;

   // how far is price from VWAP in standard deviations?
   double deviation = (price - cachedVWAP) / cachedStdDev;

   // entry bands
   double upperEntry = cachedVWAP + EntryBandMult * cachedStdDev;
   double lowerEntry = cachedVWAP - EntryBandMult * cachedStdDev;

   string direction = "";

   // BUY: price at/below lower band + RSI confirms oversold
   if(price <= lowerEntry && cachedRSI < RSI_OS)
      direction = "BUY";
   // SELL: price at/above upper band + RSI confirms overbought
   else if(price >= upperEntry && cachedRSI > RSI_OB)
      direction = "SELL";

   if(direction == "") return;

   // calculate dynamic TP (to VWAP) and SL (to outer band)
   double tp_dist_raw = 0, sl_dist_raw = 0;
   if(direction == "BUY")
   {
      tp_dist_raw = cachedVWAP - ask;                                  // distance to VWAP
      sl_dist_raw = ask - (cachedVWAP - StopBandMult * cachedStdDev);  // distance to stop band
   }
   else
   {
      tp_dist_raw = bid - cachedVWAP;
      sl_dist_raw = (cachedVWAP + StopBandMult * cachedStdDev) - bid;
   }

   double tp_pips = tp_dist_raw / pipSize;
   double sl_pips = sl_dist_raw / pipSize;

   // enforce min/max
   if(tp_pips < MinTP_Pips) return;      // deviation too small to be worth it
   if(tp_pips > MaxTP_Pips) tp_pips = MaxTP_Pips;
   if(sl_pips < MinSL_Pips) sl_pips = MinSL_Pips;
   if(sl_pips > MaxSL_Pips) sl_pips = MaxSL_Pips;

   double tp_dist = tp_pips * pipSize;
   double sl_dist = sl_pips * pipSize;

   // store entry features for CSV
   entryVWAPDev   = deviation;
   entryRSI       = cachedRSI;
   entryADX       = cachedADX;
   entrySpread    = spread;
   entryVWAPSlope = vwapSlope;

   double lot = CalcDynamicLot(_Symbol, sl_pips, RiskPercent, LotSize);
   bool success = false;
   if(direction == "BUY")
   {
      double sl = NormalizeDouble(ask - sl_dist, digits);
      double tp = NormalizeDouble(ask + tp_dist, digits);
      success   = trade.Buy(lot, _Symbol, 0, sl, tp, EA_Name);
   }
   else
   {
      double sl = NormalizeDouble(bid + sl_dist, digits);
      double tp = NormalizeDouble(bid - tp_dist, digits);
      success   = trade.Sell(lot, _Symbol, 0, sl, tp, EA_Name);
   }

   if(success)
   {
      dailyTradeCount++;
      lastEntryTime = TimeCurrent();
      Print("VWAP SCALP ", direction,
            " | dev=", DoubleToString(deviation, 2), "σ",
            " vwap=", DoubleToString(cachedVWAP, digits),
            " rsi=", DoubleToString(cachedRSI, 1),
            " adx=", DoubleToString(cachedADX, 1),
            " tp=", DoubleToString(tp_pips, 1),
            " sl=", DoubleToString(sl_pips, 1),
            " lot=", DoubleToString(lot, 2),
            " spread=", DoubleToString(spread, 1));
   }
   else
      Print("VWAP SCALP ", direction, " FAILED: ", trade.ResultRetcodeDescription());
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
//| Manage position — breakeven, trail, time exit                     |
//+------------------------------------------------------------------+
void ManagePosition()
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

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double profitPips = 0;
      if(posType == POSITION_TYPE_BUY)
         profitPips = (bid - openPrice) / pipSize;
      else
         profitPips = (openPrice - ask) / pipSize;

      // time exit
      if((int)(TimeCurrent() - openTime) >= MaxHoldSeconds)
      {
         trade.PositionClose(ticket);
         Print("VWAP SCALP TIME EXIT | pips=", DoubleToString(profitPips, 1));
         return;
      }

      // breakeven
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

      // trailing stop
      if(profitPips >= TrailStartPips)
      {
         double trailDist = TrailStepPips * pipSize;
         double newSL;
         if(posType == POSITION_TYPE_BUY)
         {
            newSL = NormalizeDouble(bid - trailDist, digits);
            if(newSL > curSL)
               trade.PositionModify(ticket, newSL, curTP);
         }
         else
         {
            newSL = NormalizeDouble(ask + trailDist, digits);
            if(newSL < curSL)
               trade.PositionModify(ticket, newSL, curTP);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Session filter (UTC)                                              |
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
//| CSV — create with header                                          |
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
      "duration_sec","vwap_deviation","rsi","adx","spread_pips","vwap_slope");
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
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicNumber) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if(ticket <= lastLoggedTicket) continue;

      double   profit   = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      double   swap     = HistoryDealGetDouble(ticket, DEAL_SWAP);
      double   comm     = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      double   volume   = HistoryDealGetDouble(ticket, DEAL_VOLUME);
      double   cPrice   = HistoryDealGetDouble(ticket, DEAL_PRICE);
      long     dealType = HistoryDealGetInteger(ticket, DEAL_TYPE);
      datetime cTime    = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);

      long     posId    = (long)HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
      double   oPrice   = cPrice;
      datetime oTime    = cTime;
      string   typeStr  = (dealType == DEAL_TYPE_SELL) ? "BUY" : "SELL";

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
         DoubleToString(entryVWAPDev,   3),
         DoubleToString(entryRSI,       1),
         DoubleToString(entryADX,       1),
         DoubleToString(entrySpread,    2),
         DoubleToString(entryVWAPSlope, 3)
      );
      FileClose(handle);

      lastLoggedTicket = ticket;
      dailyPnL += profit;
      Print("VWAP SCALP closed | #", ticket,
            " profit=", DoubleToString(profit, 2),
            " dur=", durationSec, "s");

      int winFlag = (profit > 0) ? 1 : 0;
      OrchReportTrade(ORCH_REPORT, "TICK_SCALPER", LastRegime, winFlag, profit);
   }
}
//+------------------------------------------------------------------+
