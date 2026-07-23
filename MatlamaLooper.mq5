//+------------------------------------------------------------------+
//|                                            MatlamaLooper.mq5     |
//|                                          Matlama Tech © 2026     |
//|              Grid / Range-Loop Mean-Reversion EA                  |
//|                                                                    |
//|  Identifies Bollinger Band range, computes grid levels, and       |
//|  loops buy/sell entries — buying near the lower band, selling     |
//|  near the upper band, with TP at the opposing grid level.         |
//|  Optimized for RANGE regime; complements trend-following EAs.     |
//+------------------------------------------------------------------+
#property copyright "Matlama Tech 2026"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include "OrchestratorClient.mqh"

//--- Input Parameters
input string   EA_Name        = "MatlamaLooper v1";
input double   LotSize        = 0.01;
input int      SL_Pips        = 25;
input int      TP_Pips        = 15;
input int      Slippage       = 10;
input int      MagicNumber    = 20260104;
input bool     AutoTrade      = false;
input double   MaxDailyLoss   = 60.0;
input int      MaxTrades      = 5;       // Max concurrent positions
input int      MaxDailyTrades = 8;       // Max trades per day
input int      MaxSpread      = 25;      // Max spread in points
input int      PollSeconds    = 15;      // Throttle between evaluations
input int      BB_Period      = 20;      // Bollinger Band period
input double   BB_Deviation   = 2.0;     // Bollinger Band std dev
input int      RSI_Period     = 14;
input double   BandEntryZone  = 0.15;    // Enter when price is within this % of band edge
input int      GridLevels     = 4;       // Number of grid divisions within the band
input bool     LondonSession  = true;
input bool     NYSession      = true;

//--- Orchestrator v2 Settings
input string   ORCH_SERVER            = "http://127.0.0.1:7000/decision_v2";
input string   ORCH_REPORT            = "http://127.0.0.1:7000/report_trade";
input bool     AllowNewsTrading       = false;
input bool     AllowCrisisTrading     = false;
input double   MaxAccountDrawdownPct  = 0.20;

//--- Global Variables
CTrade   trade;
double   dailyStartBalance;
datetime dailyResetTime;
datetime lastPollTime = 0;
int      dailyTradeCount = 0;
int      bbHandle;
int      rsiHandle;
int      atrHandle;
int      adxHandle;
ulong    lastLoggedTicket = 0;
string   LastRegime = "UNKNOWN";
string   CSV_PATH   = "looper_trades.csv";

void InitCSV()
{
   int handle = FileOpen(CSV_PATH, FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ);
   if(handle == INVALID_HANDLE)
   {
      handle = FileOpen(CSV_PATH, FILE_WRITE|FILE_CSV|FILE_ANSI);
      if(handle != INVALID_HANDLE)
      {
         FileWrite(handle,
            "ticket","symbol","type","open_time","close_time",
            "open_price","close_price","volume","profit",
            "swap","commission","duration_min",
            "band_position","range_width_pips","rsi","volume_ratio");
         FileClose(handle);
         Print("Looper CSV initialized: ", CSV_PATH);
      }
   }
   else FileClose(handle);
}

//+------------------------------------------------------------------+
//| Compute where price sits within the Bollinger Band (0=lower, 1=upper)
//+------------------------------------------------------------------+
double CalcBandPosition(double price, double upper, double lower)
{
   double width = upper - lower;
   if(width <= 0) return 0.5;
   double pos = (price - lower) / width;
   if(pos < 0.0) pos = 0.0;
   if(pos > 1.0) pos = 1.0;
   return pos;
}

//+------------------------------------------------------------------+
//| Compute volume ratio (current bar vs 20-bar average)              |
//+------------------------------------------------------------------+
double CalcVolumeRatio()
{
   long volBuf[];
   ArraySetAsSeries(volBuf, true);
   if(CopyTickVolume(_Symbol, PERIOD_M15, 0, 21, volBuf) < 21) return 1.0;

   double current = (double)volBuf[0];
   double avg = 0;
   for(int i = 1; i <= 20; i++) avg += (double)volBuf[i];
   avg /= 20.0;
   if(avg <= 0) return 1.0;
   return current / avg;
}

//+------------------------------------------------------------------+
//| Detect newly closed trades and report to orchestrator             |
//+------------------------------------------------------------------+
void LogClosedTrades()
{
   HistorySelect(TimeCurrent() - 86400 * 7, TimeCurrent());
   int total = HistoryDealsTotal();
   if(total == 0) return;

   int handle = FileOpen(CSV_PATH, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ);
   if(handle == INVALID_HANDLE) return;
   FileSeek(handle, 0, SEEK_END);

   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket <= lastLoggedTicket) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != (ulong)MagicNumber) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

      long     dtype      = HistoryDealGetInteger(ticket, DEAL_TYPE);
      string   typeStr    = (dtype == DEAL_TYPE_BUY) ? "BUY" : "SELL";
      datetime closeTime  = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
      double   closePrice = HistoryDealGetDouble(ticket, DEAL_PRICE);
      double   volume     = HistoryDealGetDouble(ticket, DEAL_VOLUME);
      double   profit     = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      double   swap       = HistoryDealGetDouble(ticket, DEAL_SWAP);
      double   comm       = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      double   openPrice  = 0;
      datetime entryTime  = 0;

      ulong posId = (ulong)HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
      for(int j = 0; j < total; j++)
      {
         ulong t2 = HistoryDealGetTicket(j);
         if((ulong)HistoryDealGetInteger(t2, DEAL_POSITION_ID) == posId &&
            HistoryDealGetInteger(t2, DEAL_ENTRY) == DEAL_ENTRY_IN)
         {
            openPrice = HistoryDealGetDouble(t2, DEAL_PRICE);
            entryTime = (datetime)HistoryDealGetInteger(t2, DEAL_TIME);
            break;
         }
      }

      int durationMin = (int)((closeTime - entryTime) / 60);

      double bbUpper[], bbLower[], bbMid[], rsiLog[];
      ArraySetAsSeries(bbUpper, true);
      ArraySetAsSeries(bbLower, true);
      ArraySetAsSeries(bbMid, true);
      ArraySetAsSeries(rsiLog, true);

      double bandPos = 0.5, rangeWidth = 0, rsiVal = 50;
      double pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;

      if(CopyBuffer(bbHandle, 1, 0, 1, bbUpper) > 0 &&
         CopyBuffer(bbHandle, 2, 0, 1, bbLower) > 0)
      {
         bandPos    = CalcBandPosition(closePrice, bbUpper[0], bbLower[0]);
         rangeWidth = (bbUpper[0] - bbLower[0]) / pipSize;
      }
      if(CopyBuffer(rsiHandle, 0, 0, 1, rsiLog) > 0) rsiVal = rsiLog[0];
      double volRatio = CalcVolumeRatio();

      FileWrite(handle,
         (string)ticket, _Symbol, typeStr,
         TimeToString(entryTime,  TIME_DATE|TIME_MINUTES),
         TimeToString(closeTime,  TIME_DATE|TIME_MINUTES),
         DoubleToString(openPrice,  _Digits),
         DoubleToString(closePrice, _Digits),
         DoubleToString(volume, 2),
         DoubleToString(profit, 2),
         DoubleToString(swap,   2),
         DoubleToString(comm,   2),
         (string)durationMin,
         DoubleToString(bandPos, 4),
         DoubleToString(rangeWidth, 2),
         DoubleToString(rsiVal, 1),
         DoubleToString(volRatio, 3)
      );

      lastLoggedTicket = ticket;
      Print("Looper trade logged | Ticket:", ticket, " Profit:", profit);

      int winFlag = (profit > 0) ? 1 : 0;
      OrchReportTrade(ORCH_REPORT, "LOOPER", LastRegime, winFlag, profit);
   }
   FileClose(handle);
}

//+------------------------------------------------------------------+
int OnInit()
{
   bbHandle  = iBands(_Symbol, PERIOD_M15, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
   rsiHandle = iRSI(_Symbol, PERIOD_M15, RSI_Period, PRICE_CLOSE);
   atrHandle = iATR(_Symbol, PERIOD_M15, 14);
   adxHandle = iADX(_Symbol, PERIOD_M15, 14);

   if(bbHandle  == INVALID_HANDLE ||
      rsiHandle == INVALID_HANDLE ||
      atrHandle == INVALID_HANDLE ||
      adxHandle == INVALID_HANDLE)
   {
      Print("ERROR: Indicator handle failed");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_RETURN);

   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyResetTime    = TimeCurrent();

   InitCSV();

   Print("=== ", EA_Name, " initialized ===");
   Print("Symbol: ",    _Symbol);
   Print("Timeframe: M15");
   Print("AutoTrade: ", AutoTrade ? "ENABLED" : "DISABLED");
   Print("BB: ",        BB_Period, " / ", BB_Deviation, " dev");
   Print("Grid: ",      GridLevels, " levels");
   Print("Entry zone: ", DoubleToString(BandEntryZone * 100, 0), "% from band edge");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(bbHandle);
   IndicatorRelease(rsiHandle);
   IndicatorRelease(atrHandle);
   IndicatorRelease(adxHandle);
   Print(EA_Name, " stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
void OnTick()
{
   LogClosedTrades();

   // Daily reset
   MqlDateTime now, reset;
   TimeToStruct(TimeCurrent(), now);
   TimeToStruct(dailyResetTime, reset);
   if(now.day != reset.day)
   {
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyResetTime    = TimeCurrent();
      dailyTradeCount   = 0;
      Print("Daily reset: balance=", dailyStartBalance);
   }

   // Daily loss limit
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if((dailyStartBalance - currentBalance) >= MaxDailyLoss)
   {
      Print("Daily loss limit reached. Halting.");
      return;
   }

   // Poll throttle
   if((TimeCurrent() - lastPollTime) < PollSeconds) return;
   lastPollTime = TimeCurrent();

   // Session filter
   if(!IsValidSession(now)) return;

   // Spread filter
   long spreadPts = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spreadPts > MaxSpread)
   {
      Print("Spread too wide: ", spreadPts, " points. Skipping.");
      return;
   }

   // Max concurrent trades
   if(CountOpenTrades() >= MaxTrades)
   {
      Print("Max concurrent trades reached: ", MaxTrades);
      return;
   }

   // Max daily trades
   if(dailyTradeCount >= MaxDailyTrades)
   {
      Print("Max daily trades reached: ", MaxDailyTrades);
      return;
   }

   // === Gather indicators ===
   double price   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask0    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   double spreadPips = (ask0 - price) / pipSize;

   double bbUpper[], bbLower[], bbMid[];
   ArraySetAsSeries(bbUpper, true);
   ArraySetAsSeries(bbLower, true);
   ArraySetAsSeries(bbMid, true);

   if(CopyBuffer(bbHandle, 0, 0, 1, bbMid)   < 1 ||
      CopyBuffer(bbHandle, 1, 0, 1, bbUpper)  < 1 ||
      CopyBuffer(bbHandle, 2, 0, 1, bbLower)  < 1)
   {
      Print("BB buffer copy failed");
      return;
   }

   double rsiBuf[];
   ArraySetAsSeries(rsiBuf, true);
   double rsiVal = 50;
   if(CopyBuffer(rsiHandle, 0, 0, 1, rsiBuf) > 0) rsiVal = rsiBuf[0];

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   double atr = 0;
   if(CopyBuffer(atrHandle, 0, 0, 1, atrBuf) > 0)
      atr = atrBuf[0] / pipSize;

   double adxBuf[];
   ArraySetAsSeries(adxBuf, true);
   double adx = 0;
   if(CopyBuffer(adxHandle, 0, 0, 1, adxBuf) > 0) adx = adxBuf[0];

   double volatility = OrchCalcVolatility(_Symbol, PERIOD_M15, 20);
   double momentum   = OrchCalcMomentum(_Symbol, PERIOD_M15, 10);

   long volBuf[];
   ArraySetAsSeries(volBuf, true);
   double volume = 0;
   if(CopyTickVolume(_Symbol, PERIOD_M1, 0, 1, volBuf) > 0) volume = (double)volBuf[0];

   int newsRisk = 0;

   // === Looper-specific features ===
   double bandPos      = CalcBandPosition(price, bbUpper[0], bbLower[0]);
   double rangeWidth   = (bbUpper[0] - bbLower[0]) / pipSize;
   double volRatio     = CalcVolumeRatio();

   string extraFields = "\"band_position\":"    + DoubleToString(bandPos, 4) +
                         ",\"range_width_pips\":" + DoubleToString(rangeWidth, 2) +
                         ",\"volume_ratio\":"     + DoubleToString(volRatio, 3);

   // === ORCHESTRATOR v2 — FULL OVERRIDE ===
   string payload = OrchBuildPayload("LOOPER", price, spreadPips, atr, adx, volatility, momentum,
                                      volume, rsiVal, bbUpper[0], bbLower[0], newsRisk,
                                      (double)MaxSpread, AllowNewsTrading, AllowCrisisTrading,
                                      MaxAccountDrawdownPct, extraFields);

   OrchDecision dec = OrchGetDecision(ORCH_SERVER, payload);

   if(!dec.valid)
   {
      Print("Looper | ORCH unreachable — holding");
      return;
   }

   LastRegime = dec.regime;
   string signal = dec.decision;

   Print("Looper | ORCH:", signal,
         " Conf:", DoubleToString(dec.confidence, 3),
         " Regime:", dec.regime,
         " BandPos:", DoubleToString(bandPos, 3),
         " RangeW:", DoubleToString(rangeWidth, 1),
         " RSI:", DoubleToString(rsiVal, 1));

   if(!AutoTrade || signal == "HOLD") return;

   // === Compute adaptive SL/TP based on grid spacing ===
   double gridSpacing = rangeWidth / GridLevels;
   double sl_pips = (double)SL_Pips;
   double tp_pips = (double)TP_Pips;

   // Use grid spacing for TP when range is wide enough
   if(gridSpacing > 8.0)
   {
      tp_pips = gridSpacing;
      sl_pips = gridSpacing * 1.5;
   }

   double sl_dist = sl_pips * pipSize;
   double tp_dist = tp_pips * pipSize;
   bool   success = false;

   if(signal == "BUY")
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = NormalizeDouble(ask - sl_dist, _Digits);
      double tp  = NormalizeDouble(ask + tp_dist, _Digits);
      success    = trade.Buy(LotSize, _Symbol, 0, sl, tp, "LOOP_BUY");
      if(success)
      {
         dailyTradeCount++;
         Print("LOOP BUY | Ask:", ask, " SL:", sl, " TP:", tp,
               " Grid:", DoubleToString(gridSpacing, 1), "p");
      }
      else
         Print("LOOP BUY failed: ", trade.ResultRetcodeDescription());
   }
   else if(signal == "SELL")
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = NormalizeDouble(bid + sl_dist, _Digits);
      double tp  = NormalizeDouble(bid - tp_dist, _Digits);
      success    = trade.Sell(LotSize, _Symbol, 0, sl, tp, "LOOP_SELL");
      if(success)
      {
         dailyTradeCount++;
         Print("LOOP SELL | Bid:", bid, " SL:", sl, " TP:", tp,
               " Grid:", DoubleToString(gridSpacing, 1), "p");
      }
      else
         Print("LOOP SELL failed: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
int CountOpenTrades()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetTicket(i) > 0 &&
         PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
bool IsValidSession(MqlDateTime &dt)
{
   int hour = dt.hour;
   if(LondonSession && hour >= 8  && hour < 17) return true;
   if(NYSession     && hour >= 13 && hour < 22) return true;
   Print("Outside trading session. Hour: ", hour);
   return false;
}
