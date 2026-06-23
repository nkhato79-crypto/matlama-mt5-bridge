//+------------------------------------------------------------------+
//|                                              MatlamaBridge.mq5   |
//|                                          Matlama Tech © 2026     |
//|                     Self-contained 5-layer signal engine         |
//+------------------------------------------------------------------+
#property copyright "Matlama Tech 2026"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
input string   EA_Name       = "MatlamaBridge v3";
input double   LotSize       = 0.01;
input int      SL_Pips       = 50;
input int      TP_Pips       = 100;
input int      Slippage      = 10;
input int      PollSeconds   = 30;
input int      MagicNumber   = 20260101;
input bool     AutoTrade     = false;
input double   MaxDailyLoss  = 100.0;

// --- COT & Gamma (update weekly from CFTC report)
input string   COT_Bias      = "BUY";   // BUY, SELL, or NEUTRAL
input double   DealerGamma   = -0.5;    // Negative = amplifies moves
input int      ScoreThreshold = 3;      // Minimum score to trade (out of 5)

//--- Global Variables
CTrade   trade;
datetime LastCheck        = 0;
string   LastSignal       = "";
double   dailyStartBalance;
datetime dailyResetTime;
int      atrHandle;

//+------------------------------------------------------------------+
int OnInit()
{
   atrHandle = iATR(_Symbol, PERIOD_H1, 14);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: ATR handle failed");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_RETURN);

   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyResetTime    = TimeCurrent();

   Print("=== ", EA_Name, " initialized ===");
   Print("Symbol: ",     _Symbol);
   Print("AutoTrade: ",  AutoTrade ? "ENABLED" : "DISABLED");
   Print("COT Bias: ",   COT_Bias);
   Print("Threshold: ",  ScoreThreshold, "/5");
   Print("Lot Size: ",   LotSize);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
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

   // Poll throttle
   if((TimeCurrent() - LastCheck) < PollSeconds)
      return;
   LastCheck = TimeCurrent();

   // ── Run signal engine ──────────────────────────────────────────
   int buyScore  = EvaluateSignal("BUY");
   int sellScore = EvaluateSignal("SELL");

   string action   = "HOLD";
   int    score    = 0;

   if(buyScore >= sellScore && buyScore >= ScoreThreshold)
   {
      action = "BUY";
      score  = buyScore;
   }
   else if(sellScore > buyScore && sellScore >= ScoreThreshold)
   {
      action = "SELL";
      score  = sellScore;
   }

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   Print("Signal: ", action, " | BUY=", buyScore, "/5 | SELL=", sellScore,
         "/5 | Gold: $", DoubleToString(price, 2));

   if(!AutoTrade || action == "HOLD")
      return;

   // Skip duplicate
   if(action == LastSignal)
      return;

   // Check for existing position
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetTicket(i) > 0 &&
         PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         Print("Position already open. Skipping.");
         return;
      }
   }

   // Execute trade
   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pipSize = point * 10;
   double sl_dist = SL_Pips * pipSize;
   double tp_dist = TP_Pips * pipSize;
   bool   success = false;

   if(action == "BUY")
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = NormalizeDouble(ask - sl_dist, _Digits);
      double tp  = NormalizeDouble(ask + tp_dist, _Digits);
      success    = trade.Buy(LotSize, _Symbol, 0, sl, tp, "MB_BUY");
      if(success)
         Print("BUY executed | Ask:", ask, " SL:", sl, " TP:", tp);
      else
         Print("BUY failed: ", trade.ResultRetcodeDescription());
   }
   else if(action == "SELL")
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = NormalizeDouble(bid + sl_dist, _Digits);
      double tp  = NormalizeDouble(bid - tp_dist, _Digits);
      success    = trade.Sell(LotSize, _Symbol, 0, sl, tp, "MB_SELL");
      if(success)
         Print("SELL executed | Bid:", bid, " SL:", sl, " TP:", tp);
      else
         Print("SELL failed: ", trade.ResultRetcodeDescription());
   }

   if(success) LastSignal = action;
}

//+------------------------------------------------------------------+
//| Evaluate signal score for a given direction (0-5)                |
//+------------------------------------------------------------------+
int EvaluateSignal(string direction)
{
   int score = 0;

   // Layer 1: COT/CFTC Bias
   if(COT_Bias == "NEUTRAL") score++;
   else if(COT_Bias == direction) score++;

   // Layer 2: Dealer Gamma
   if(direction == "BUY"  && DealerGamma <= 0) score++;
   if(direction == "SELL" && DealerGamma >= 0) score++;

   // Layer 3: Market Structure (H1 - Higher Highs/Lower Lows)
   if(CheckStructure(direction)) score++;

   // Layer 4: Price Action (H1 - Momentum candle)
   if(CheckPriceAction(direction)) score++;

   // Layer 5: Chart Patterns (H4 - Double top/bottom)
   if(CheckPatterns(direction)) score++;

   return score;
}

//+------------------------------------------------------------------+
//| Layer 3: Market Structure                                         |
//+------------------------------------------------------------------+
bool CheckStructure(string direction)
{
   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows,  true);

   if(CopyHigh(_Symbol, PERIOD_H1, 0, 20, highs) < 20) return false;
   if(CopyLow(_Symbol,  PERIOD_H1, 0, 20, lows)  < 20) return false;

   // Recent 5 bars vs prior 5 bars
   double recentHigh = highs[0];
   double recentLow  = lows[0];
   double priorHigh  = highs[5];
   double priorLow   = lows[5];

   for(int i = 1; i < 5; i++)
   {
      if(highs[i] > recentHigh) recentHigh = highs[i];
      if(lows[i]  < recentLow)  recentLow  = lows[i];
   }
   for(int i = 5; i < 10; i++)
   {
      if(highs[i] > priorHigh) priorHigh = highs[i];
      if(lows[i]  < priorLow)  priorLow  = lows[i];
   }

   if(direction == "BUY")
      return (recentHigh > priorHigh && recentLow > priorLow);
   else
      return (recentHigh < priorHigh && recentLow < priorLow);
}

//+------------------------------------------------------------------+
//| Layer 4: Price Action                                             |
//+------------------------------------------------------------------+
bool CheckPriceAction(string direction)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_H1, 0, 3, rates) < 3) return false;

   double open  = rates[0].open;
   double close = rates[0].close;
   double high  = rates[0].high;
   double low   = rates[0].low;
   double body  = MathAbs(close - open);

   if(body == 0) return false;

   double wickUp   = high  - MathMax(close, open);
   double wickDown = MathMin(close, open) - low;

   if(direction == "BUY")
      return (close > open && wickDown < body * 0.5);
   else
      return (close < open && wickUp   < body * 0.5);
}

//+------------------------------------------------------------------+
//| Layer 5: Chart Patterns (Double top/bottom on H4)                |
//+------------------------------------------------------------------+
bool CheckPatterns(string direction)
{
   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows,  true);

   if(CopyHigh(_Symbol, PERIOD_H4, 0, 30, highs) < 30) return false;
   if(CopyLow(_Symbol,  PERIOD_H4, 0, 30, lows)  < 30) return false;

   if(direction == "BUY")
   {
      // Double bottom — two similar lows
      double low1 = lows[10];
      double low2 = lows[20];
      for(int i = 10; i < 20; i++) if(lows[i] < low1) low1 = lows[i];
      for(int i = 20; i < 30; i++) if(lows[i] < low2) low2 = lows[i];
      if(low1 == 0) return false;
      return (MathAbs(low1 - low2) / low1 < 0.005);
   }
   else
   {
      // Double top — two similar highs
      double high1 = highs[10];
      double high2 = highs[20];
      for(int i = 10; i < 20; i++) if(highs[i] > high1) high1 = highs[i];
      for(int i = 20; i < 30; i++) if(highs[i] > high2) high2 = highs[i];
      if(high1 == 0) return false;
      return (MathAbs(high1 - high2) / high1 < 0.005);
   }
}
