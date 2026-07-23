//+------------------------------------------------------------------+
//|                                            MatlamaScalper.mq5    |
//|                                          Matlama Tech © 2026     |
//|                         M5 EMA/RSI Scalping EA                   |
//+------------------------------------------------------------------+
#property copyright "Matlama Tech 2026"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include "OrchestratorClient.mqh"
#include "DynamicLot.mqh"

//--- Input Parameters
input string   EA_Name        = "MatlamaScalper v1";
input double   LotSize        = 0.01;
input double   RiskPercent    = 1.0;          // % of equity risked per trade (0 = use fixed LotSize)
input int      SL_Pips        = 15;
input int      TP_Pips        = 20;
input int      Slippage       = 10;
input int      MagicNumber    = 20260103;
input bool     AutoTrade      = false;
input double   MaxDailyLoss   = 50.0;
input int      MaxTrades      = 3;
input int      MaxSpread      = 25;       // Max spread in points
input int      EMA_Fast       = 8;        // Fast EMA period
input int      EMA_Slow       = 21;       // Slow EMA period
input int      RSI_Period     = 14;       // RSI period
input int      RSI_OB         = 65;       // RSI overbought
input int      RSI_OS         = 35;       // RSI oversold
input bool     LondonSession  = true;     // Trade London session
input bool     NYSession      = true;     // Trade NY session

//--- Orchestrator v2 Settings (full override — replaces EMA/RSI signal logic)
input string   ORCH_SERVER            = "http://127.0.0.1:7000/decision_v2";
input string   ORCH_REPORT            = "http://127.0.0.1:7000/report_trade";
input bool     AllowNewsTrading       = false;
input bool     AllowCrisisTrading     = false;
input double   MaxAccountDrawdownPct  = 0.20;

//--- Global Variables
CTrade   trade;
double   dailyStartBalance;
datetime dailyResetTime;
datetime lastBarTime = 0;
int      emaFastHandle;
int      emaSlowHandle;
int      rsiHandle;
int      atrHandle;
int      adxHandle;
ulong    lastLoggedTicket = 0;
string   LastRegime = "UNKNOWN";
string   CSV_PATH  = "scalper_trades.csv";

void InitCSV()
{
   int handle = FileOpen(CSV_PATH, FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ',');
   if(handle == INVALID_HANDLE)
   {
      handle = FileOpen(CSV_PATH, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
      if(handle != INVALID_HANDLE)
      {
         FileWrite(handle,
            "ticket","symbol","type","open_time","close_time",
            "open_price","close_price","volume","profit",
            "swap","commission","duration_min",
            "ema_diff_pips","momentum_pips","rsi");
         FileClose(handle);
         Print("Scalper CSV initialized: ", CSV_PATH);
      }
   }
   else FileClose(handle);
}

//+------------------------------------------------------------------+
//| Detect newly closed trades and report them to the orchestrator   |
//+------------------------------------------------------------------+
void LogClosedTrades()
{
   HistorySelect(TimeCurrent() - 86400 * 7, TimeCurrent());
   int total = HistoryDealsTotal();
   if(total == 0) return;

   bool hasNew = false;
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket <= lastLoggedTicket) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != (ulong)MagicNumber) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      hasNew = true;
      break;
   }
   if(!hasNew) return;

   int handle = FileOpen(CSV_PATH, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ',');
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

      // Compute real Scalper features at close-time for the training CSV
      double pipSizeS = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
      double emaFastS[], emaSlowS[], rsiS[];
      ArraySetAsSeries(emaFastS, true);
      ArraySetAsSeries(emaSlowS, true);
      ArraySetAsSeries(rsiS, true);
      double emaDiffLog = 0, rsiLog = 50;
      if(CopyBuffer(emaFastHandle, 0, 0, 1, emaFastS) > 0 &&
         CopyBuffer(emaSlowHandle, 0, 0, 1, emaSlowS) > 0)
         emaDiffLog = (emaFastS[0] - emaSlowS[0]) / pipSizeS;
      if(CopyBuffer(rsiHandle, 0, 0, 1, rsiS) > 0) rsiLog = rsiS[0];
      double momentumLog = OrchCalcMomentum(_Symbol, PERIOD_M5, 10);

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
         DoubleToString(emaDiffLog,  2),
         DoubleToString(momentumLog, 2),
         DoubleToString(rsiLog,      1)
      );

      lastLoggedTicket = ticket;
      Print("Scalper trade logged | Ticket:", ticket, " Profit:", profit);

      int winFlag = (profit > 0) ? 1 : 0;
      OrchReportTrade(ORCH_REPORT, "SCALPER", LastRegime, winFlag, profit);
   }
   FileClose(handle);
}

//+------------------------------------------------------------------+
int OnInit()
{
   emaFastHandle = iMA(_Symbol, PERIOD_M5, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(_Symbol, PERIOD_M5, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle     = iRSI(_Symbol, PERIOD_M5, RSI_Period, PRICE_CLOSE);
   atrHandle     = iATR(_Symbol, PERIOD_M5, 14);
   adxHandle     = iADX(_Symbol, PERIOD_M5, 14);

   if(emaFastHandle == INVALID_HANDLE ||
      emaSlowHandle == INVALID_HANDLE ||
      rsiHandle     == INVALID_HANDLE ||
      atrHandle     == INVALID_HANDLE ||
      adxHandle     == INVALID_HANDLE)
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
   Print("Timeframe: M5");
   Print("AutoTrade: ", AutoTrade ? "ENABLED" : "DISABLED");
   Print("EMA: ",       EMA_Fast, "/", EMA_Slow);
   Print("RSI: ",       RSI_Period, " OB:", RSI_OB, " OS:", RSI_OS);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(emaFastHandle);
   IndicatorRelease(emaSlowHandle);
   IndicatorRelease(rsiHandle);
   IndicatorRelease(atrHandle);
   IndicatorRelease(adxHandle);
   Print(EA_Name, " stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
void OnTick()
{
   LogClosedTrades();

   // Reset daily balance at midnight
   MqlDateTime now, reset;
   TimeToStruct(TimeCurrent(), now);
   TimeToStruct(dailyResetTime, reset);
   if(now.day != reset.day)
   {
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyResetTime    = TimeCurrent();
      Print("Daily balance reset: ", dailyStartBalance);
   }

   // Daily loss limit
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if((dailyStartBalance - currentBalance) >= MaxDailyLoss)
   {
      Print("Daily loss limit reached. Halting.");
      return;
   }

   // Only trade on new M5 bar
   datetime currentBar = iTime(_Symbol, PERIOD_M5, 0);
   if(currentBar == lastBarTime) return;
   lastBarTime = currentBar;

   // Session filter
   if(!IsValidSession(now)) return;

   // Spread filter
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpread)
   {
      Print("Spread too wide: ", spread, " points. Skipping.");
      return;
   }

   // Max trades filter
   if(CountOpenTrades() >= MaxTrades)
   {
      Print("Max trades reached: ", MaxTrades);
      return;
   }

   // === ORCHESTRATOR v2 — FULL OVERRIDE ===
   // EMA cross / RSI signal logic is bypassed; the orchestrator's decision
   // (BUY/SELL/HOLD) is authoritative. Session filter, spread filter, max
   // trades, and daily loss checks above remain as hard structural gates.

   double price  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask0   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double spreadPips = (ask0 - price) / (SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10);

   double atrBuf[]; ArraySetAsSeries(atrBuf, true);
   double atr = 0;
   if(CopyBuffer(atrHandle, 0, 0, 1, atrBuf) > 0)
      atr = atrBuf[0] / (SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10);

   double adxBuf[]; ArraySetAsSeries(adxBuf, true);
   double adx = 0;
   if(CopyBuffer(adxHandle, 0, 0, 1, adxBuf) > 0) adx = adxBuf[0];

   double emaFastBuf[], emaSlowBuf[], rsiBuf[];
   ArraySetAsSeries(emaFastBuf, true);
   ArraySetAsSeries(emaSlowBuf, true);
   ArraySetAsSeries(rsiBuf, true);
   double emaFastVal = 0, emaSlowVal = 0, rsiVal = 50;
   if(CopyBuffer(emaFastHandle, 0, 0, 1, emaFastBuf) > 0) emaFastVal = emaFastBuf[0];
   if(CopyBuffer(emaSlowHandle, 0, 0, 1, emaSlowBuf) > 0) emaSlowVal = emaSlowBuf[0];
   if(CopyBuffer(rsiHandle,     0, 0, 1, rsiBuf)     > 0) rsiVal     = rsiBuf[0];

   double volatility = OrchCalcVolatility(_Symbol, PERIOD_M5, 20);
   double momentum   = OrchCalcMomentum(_Symbol, PERIOD_M5, 10);

   long volBuf[]; ArraySetAsSeries(volBuf, true);
   double volume = 0;
   if(CopyTickVolume(_Symbol, PERIOD_M1, 0, 1, volBuf) > 0) volume = (double)volBuf[0];

   int newsRisk = 0; // wire to a news calendar feed if/when available

   // Live Scalper-specific features for the dedicated SCALPER model.
   double emaDiffPips     = (emaFastVal - emaSlowVal) / (SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10);
   double momentumScalp   = OrchCalcMomentum(_Symbol, PERIOD_M5, 10);
   string extraFields     = "\"ema_diff_pips\":" + DoubleToString(emaDiffPips, 2) +
                             ",\"momentum_pips\":" + DoubleToString(momentumScalp, 2);

   string payload = OrchBuildPayload("SCALPER", price, spreadPips, atr, adx, volatility, momentum,
                                      volume, rsiVal, emaFastVal, emaSlowVal, newsRisk,
                                      (double)MaxSpread, AllowNewsTrading, AllowCrisisTrading,
                                      MaxAccountDrawdownPct, extraFields);

   OrchDecision dec = OrchGetDecision(ORCH_SERVER, payload);

   if(!dec.valid)
   {
      Print("Scalper | ORCH unreachable — holding, no trade this tick");
      return;
   }

   LastRegime = dec.regime;
   string signal = dec.decision; // "BUY" / "SELL" / "HOLD" — orchestrator is authoritative

   Print("Scalper | ORCH Decision:", signal,
         " Confidence:", DoubleToString(dec.confidence, 3),
         " Regime:", dec.regime,
         " EMA Fast:", DoubleToString(emaFastVal, 2),
         " Slow:", DoubleToString(emaSlowVal, 2),
         " RSI:", DoubleToString(rsiVal, 1));

   if(!AutoTrade || signal == "HOLD") return;

   // Execute trade
   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pipSize = point * 10;
   double sl_dist = SL_Pips * pipSize;
   double tp_dist = TP_Pips * pipSize;
   bool   success = false;

   if(signal == "BUY")
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = NormalizeDouble(ask - sl_dist, _Digits);
      double tp  = NormalizeDouble(ask + tp_dist, _Digits);
      double lot = CalcDynamicLot(_Symbol, (double)SL_Pips, RiskPercent, LotSize);
      success    = trade.Buy(lot, _Symbol, 0, sl, tp, "SCALP_BUY");
      if(success)
         Print("SCALP BUY | Ask:", ask, " SL:", sl, " TP:", tp, " Lot:", DoubleToString(lot, 2));
      else
         Print("SCALP BUY failed: ", trade.ResultRetcodeDescription());
   }
   else if(signal == "SELL")
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = NormalizeDouble(bid + sl_dist, _Digits);
      double tp  = NormalizeDouble(bid - tp_dist, _Digits);
      double lot = CalcDynamicLot(_Symbol, (double)SL_Pips, RiskPercent, LotSize);
      success    = trade.Sell(lot, _Symbol, 0, sl, tp, "SCALP_SELL");
      if(success)
         Print("SCALP SELL | Bid:", bid, " SL:", sl, " TP:", tp, " Lot:", DoubleToString(lot, 2));
      else
         Print("SCALP SELL failed: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Count open trades by this EA                                     |
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
//| Session filter — London 08:00-17:00, NY 13:00-22:00 UTC         |
//+------------------------------------------------------------------+
bool IsValidSession(MqlDateTime &dt)
{
   int hour = dt.hour;

   if(LondonSession && hour >= 8  && hour < 17) return true;
   if(NYSession     && hour >= 13 && hour < 22) return true;

   Print("Outside trading session. Hour: ", hour);
   return false;
}
