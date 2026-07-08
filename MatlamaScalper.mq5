//+------------------------------------------------------------------+
//|                                            MatlamaScalper.mq5    |
//|                                          Matlama Tech © 2026     |
//|                         M5 EMA/RSI Scalping EA                   |
//+------------------------------------------------------------------+
#property copyright "Matlama Tech 2026"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
input string   EA_Name        = "MatlamaScalper v1";
input double   LotSize        = 0.01;
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

//--- Global Variables
CTrade   trade;
double   dailyStartBalance;
datetime dailyResetTime;
datetime lastBarTime = 0;
int      emaFastHandle;
int      emaSlowHandle;
int      rsiHandle;

//+------------------------------------------------------------------+
int OnInit()
{
   emaFastHandle = iMA(_Symbol, PERIOD_M5, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(_Symbol, PERIOD_M5, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle     = iRSI(_Symbol, PERIOD_M5, RSI_Period, PRICE_CLOSE);

   if(emaFastHandle == INVALID_HANDLE ||
      emaSlowHandle == INVALID_HANDLE ||
      rsiHandle     == INVALID_HANDLE)
   {
      Print("ERROR: Indicator handle failed");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_RETURN);

   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyResetTime    = TimeCurrent();

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
   Print(EA_Name, " stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
void OnTick()
{
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

   // Get indicator values
   double emaFast[], emaSlow[], rsi[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(rsi,     true);

   if(CopyBuffer(emaFastHandle, 0, 0, 3, emaFast) < 3) return;
   if(CopyBuffer(emaSlowHandle, 0, 0, 3, emaSlow) < 3) return;
   if(CopyBuffer(rsiHandle,     0, 0, 3, rsi)     < 3) return;

   // Signal logic
   bool emaCrossUp   = emaFast[1] > emaSlow[1] && emaFast[2] <= emaSlow[2];
   bool emaCrossDown = emaFast[1] < emaSlow[1] && emaFast[2] >= emaSlow[2];
   bool rsiOversold  = rsi[1] < RSI_OS;
   bool rsiOverbought= rsi[1] > RSI_OB;
   bool emaAbove     = emaFast[1] > emaSlow[1];
   bool emaBelow     = emaFast[1] < emaSlow[1];

   string signal = "HOLD";

   // BUY: EMA cross up + RSI not overbought OR EMA above + RSI oversold bounce
   if((emaCrossUp && !rsiOverbought) || (emaAbove && rsiOversold))
      signal = "BUY";

   // SELL: EMA cross down + RSI not oversold OR EMA below + RSI overbought drop
   if((emaCrossDown && !rsiOversold) || (emaBelow && rsiOverbought))
      signal = "SELL";

   Print("Scalper | EMA Fast:", DoubleToString(emaFast[1], 2),
         " Slow:", DoubleToString(emaSlow[1], 2),
         " RSI:", DoubleToString(rsi[1], 1),
         " Signal:", signal);

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
      success    = trade.Buy(LotSize, _Symbol, 0, sl, tp, "SCALP_BUY");
      if(success)
         Print("SCALP BUY | Ask:", ask, " SL:", sl, " TP:", tp);
      else
         Print("SCALP BUY failed: ", trade.ResultRetcodeDescription());
   }
   else if(signal == "SELL")
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = NormalizeDouble(bid + sl_dist, _Digits);
      double tp  = NormalizeDouble(bid - tp_dist, _Digits);
      success    = trade.Sell(LotSize, _Symbol, 0, sl, tp, "SCALP_SELL");
      if(success)
         Print("SCALP SELL | Bid:", bid, " SL:", sl, " TP:", tp);
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
