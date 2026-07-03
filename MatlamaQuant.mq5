
//+------------------------------------------------------------------+
//|                                            MatlamaQuant.mq5      |
//|                                        Matlama Tech © 2026       |
//|              Medallion-inspired Reactive Gold Strategy           |
//|         Fibonacci pressure points + velocity + volume            |
//+------------------------------------------------------------------+
#property copyright "Matlama Tech 2026"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
input string   EA_Name         = "MatlamaQuant v1";
input double   LotSize         = 0.01;
input int      MagicNumber     = 20260201;
input int      SL_Buffer       = 10;        // pips beyond Fib level for SL
input int      PollSeconds     = 10;        // faster poll for reactive entries
input double   MaxDailyLoss    = 100.0;
input bool     AutoTrade       = true;

//--- Fibonacci Settings
input int      SwingLookback   = 50;        // candles to look back for swing high/low
input double   FibProximity    = 8.0;       // pips from Fib level to trigger proximity check
input double   FibBreakBuffer  = 3.0;       // pips beyond Fib level to confirm break

//--- Volume Settings
input int      VolumePeriod    = 20;
input double   VolumeSurge     = 2.5;       // volume must be 2.5x average

//--- Velocity Settings
input double   MinVelocity     = 10.0;      // minimum pips per 3 ticks to confirm velocity
input int      VelocityTicks   = 3;         // ticks to measure velocity over

//--- RSI Settings
input int      RSI_Period      = 14;

//--- MACD Settings
input int      MACD_Fast       = 12;
input int      MACD_Slow       = 26;
input int      MACD_Signal     = 9;

//--- TP Settings (Fibonacci-based)
input double   TP1_Percent     = 0.50;      // close 50% at next Fib level
input double   TP2_Percent     = 0.30;      // close 30% at 127.2% extension
input double   TP3_Percent     = 0.20;      // close 20% at 161.8% extension
input int      MaxHoldHours    = 4;         // hard time exit

//--- ML Threshold Settings
input string   ML_SERVER       = "http://127.0.0.1:6000/quant_threshold";
input double   DefaultThreshold = 0.60;     // higher threshold than MBV3

//--- Global Variables
CTrade   trade;
datetime LastCheck      = 0;
datetime EntryTime      = 0;
double   dailyStartBalance;
datetime dailyResetTime;
int      rsiHandle;
int      macdHandle;
ulong    lastLoggedTicket = 0;

//--- Fibonacci Levels (calculated dynamically)
double   SwingHigh      = 0;
double   SwingLow       = 0;
double   Fib236         = 0;
double   Fib382         = 0;
double   Fib500         = 0;
double   Fib618         = 0;
double   Fib786         = 0;
double   Ext127         = 0;
double   Ext162         = 0;
datetime LastFibCalc    = 0;

//--- Velocity tracking
double   PriceTick[];
int      TickCount      = 0;

//--- CSV logging
string   CSV_PATH = "quant_trades.csv";

//+------------------------------------------------------------------+
//| Calculate Fibonacci levels from swing high/low                   |
//+------------------------------------------------------------------+
void CalculateFibLevels()
{
   // Recalculate every 4 hours
   if((TimeCurrent() - LastFibCalc) < 14400 && LastFibCalc != 0) return;

   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows,  true);

   if(CopyHigh(_Symbol, PERIOD_H1, 0, SwingLookback, highs) < SwingLookback) return;
   if(CopyLow(_Symbol,  PERIOD_H1, 0, SwingLookback, lows)  < SwingLookback) return;

   SwingHigh = highs[ArrayMaximum(highs, 0, SwingLookback)];
   SwingLow  = lows[ArrayMinimum(lows,  0, SwingLookback)];

   double range = SwingHigh - SwingLow;
   if(range <= 0) return;

   // Retracement levels (from high down)
   Fib236 = SwingHigh - (range * 0.236);
   Fib382 = SwingHigh - (range * 0.382);
   Fib500 = SwingHigh - (range * 0.500);
   Fib618 = SwingHigh - (range * 0.618);
   Fib786 = SwingHigh - (range * 0.786);

   // Extension levels (beyond swing low)
   Ext127 = SwingLow  - (range * 0.272);
   Ext162 = SwingLow  - (range * 0.618);

   LastFibCalc = TimeCurrent();

   Print("=== Fibonacci Levels Calculated ===");
   Print("Swing High: ", SwingHigh, " | Swing Low: ", SwingLow);
   Print("Fib 23.6%: ", Fib236);
   Print("Fib 38.2%: ", Fib382);
   Print("Fib 50.0%: ", Fib500);
   Print("Fib 61.8%: ", Fib618, " [GOLDEN RATIO]");
   Print("Fib 78.6%: ", Fib786);
   Print("Ext 127.2%: ", Ext127);
   Print("Ext 161.8%: ", Ext162);
}

//+------------------------------------------------------------------+
//| Get nearest Fibonacci level and distance                         |
//+------------------------------------------------------------------+
double GetNearestFibLevel(double price, double &distance)
{
   double levels[5];
   levels[0] = Fib382;  // skip 23.6 — too weak
   levels[1] = Fib500;
   levels[2] = Fib618;
   levels[3] = Fib786;
   levels[4] = Fib236;  // include but lowest priority

   double nearest = levels[0];
   distance = MathAbs(price - levels[0]);

   for(int i = 1; i < 5; i++)
   {
      double d = MathAbs(price - levels[i]);
      if(d < distance)
      {
         distance = d;
         nearest  = levels[i];
      }
   }

   // Convert distance to pips
   double pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   distance = distance / pipSize;

   return nearest;
}

//+------------------------------------------------------------------+
//| Layer 1 — Fibonacci Proximity Check                              |
//+------------------------------------------------------------------+
bool CheckFibProximity(double price, double &nearestFib, string &direction)
{
   if(Fib618 == 0) return false; // Fibs not calculated yet

   double distance;
   nearestFib = GetNearestFibLevel(price, distance);

   if(distance > FibProximity) return false; // too far from any Fib level

   // Determine expected direction based on which side of Fib we're on
   // If price is below the Fib level coming up → expect BUY break
   // If price is above the Fib level coming down → expect SELL break
   if(price < nearestFib)
      direction = "BUY";
   else
      direction = "SELL";

   Print("Layer 1 ✓ | Price ", price, " within ", DoubleToString(distance, 1),
         " pips of Fib ", DoubleToString(nearestFib, 2), " | Direction: ", direction);
   return true;
}

//+------------------------------------------------------------------+
//| Layer 2 — Velocity Check                                         |
//+------------------------------------------------------------------+
bool CheckVelocity(string direction)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M1, 0, 5, rates) < 5) return false;

   // Measure pip movement over last 3 M1 candles
   double pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   double move    = 0;

   if(direction == "BUY")
      move = (rates[0].close - rates[2].close) / pipSize;
   else
      move = (rates[2].close - rates[0].close) / pipSize;

   if(move < MinVelocity)
   {
      Print("Layer 2 ✗ | Velocity: ", DoubleToString(move, 1), " pips (need ", MinVelocity, ")");
      return false;
   }

   Print("Layer 2 ✓ | Velocity: ", DoubleToString(move, 1), " pips in 3 candles");
   return true;
}

//+------------------------------------------------------------------+
//| Layer 3 — Volume Surge Check                                     |
//+------------------------------------------------------------------+
bool CheckVolumeSurge()
{
   long volBuf[];
   ArraySetAsSeries(volBuf, true);
   if(CopyTickVolume(_Symbol, PERIOD_M1, 0, VolumePeriod + 1, volBuf) < VolumePeriod + 1)
      return false;

   double avgVol = 0;
   for(int i = 1; i <= VolumePeriod; i++) avgVol += (double)volBuf[i];
   avgVol /= VolumePeriod;

   double currentVol = (double)volBuf[0];
   double ratio      = currentVol / avgVol;

   if(ratio < VolumeSurge)
   {
      Print("Layer 3 ✗ | Volume ratio: ", DoubleToString(ratio, 2), "x (need ", VolumeSurge, "x)");
      return false;
   }

   Print("Layer 3 ✓ | Volume surge: ", DoubleToString(ratio, 2), "x average");
   return true;
}

//+------------------------------------------------------------------+
//| Layer 4 — Fibonacci Break and Close Confirmation                 |
//+------------------------------------------------------------------+
bool CheckFibBreak(double nearestFib, string direction)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M5, 0, 3, rates) < 3) return false;

   double pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   double buffer  = FibBreakBuffer * pipSize;

   // Last closed candle must have closed beyond the Fib level
   double lastClose = rates[1].close; // [1] = last fully closed candle

   if(direction == "BUY" && lastClose > (nearestFib + buffer))
   {
      Print("Layer 4 ✓ | BUY break confirmed | Closed: ", lastClose,
            " above Fib: ", nearestFib);
      return true;
   }
   else if(direction == "SELL" && lastClose < (nearestFib - buffer))
   {
      Print("Layer 4 ✓ | SELL break confirmed | Closed: ", lastClose,
            " below Fib: ", nearestFib);
      return true;
   }

   Print("Layer 4 ✗ | No confirmed close beyond Fib level ", nearestFib);
   return false;
}

//+------------------------------------------------------------------+
//| Layer 5 — Momentum Acceleration                                  |
//+------------------------------------------------------------------+
bool CheckMomentumAcceleration(string direction)
{
   // RSI acceleration
   double rsiBuf[];
   ArraySetAsSeries(rsiBuf, true);
   if(CopyBuffer(rsiHandle, 0, 0, 5, rsiBuf) < 5) return false;

   double rsiAccel = (rsiBuf[0] - rsiBuf[1]) - (rsiBuf[1] - rsiBuf[2]);

   // MACD histogram expansion
   double macdMain[], macdSignal[];
   ArraySetAsSeries(macdMain,   true);
   ArraySetAsSeries(macdSignal, true);
   if(CopyBuffer(macdHandle, 0, 0, 5, macdMain)   < 5) return false;
   if(CopyBuffer(macdHandle, 1, 0, 5, macdSignal) < 5) return false;

   double hist0 = macdMain[0] - macdSignal[0];
   double hist1 = macdMain[1] - macdSignal[1];
   double hist2 = macdMain[2] - macdSignal[2];
   bool   histExpanding = (MathAbs(hist0) > MathAbs(hist1)) &&
                          (MathAbs(hist1) > MathAbs(hist2));

   bool rsiAccelOk = false;
   if(direction == "BUY"  && rsiAccel > 0) rsiAccelOk = true;
   if(direction == "SELL" && rsiAccel < 0) rsiAccelOk = true;

   bool macdOk = false;
   if(direction == "BUY"  && hist0 > 0 && histExpanding) macdOk = true;
   if(direction == "SELL" && hist0 < 0 && histExpanding) macdOk = true;

   if(!rsiAccelOk || !macdOk)
   {
      Print("Layer 5 ✗ | RSI accel: ", DoubleToString(rsiAccel, 3),
            " | MACD expanding: ", histExpanding ? "YES" : "NO");
      return false;
   }

   Print("Layer 5 ✓ | Momentum accelerating | RSI accel: ",
         DoubleToString(rsiAccel, 3), " | MACD expanding");
   return true;
}

//+------------------------------------------------------------------+
//| Dynamic spread check relative to nearest Fib distance            |
//+------------------------------------------------------------------+
bool CheckDynamicSpread(double nearestFib)
{
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread  = (ask - bid) / (SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10);
   double fibDist = MathAbs(ask - nearestFib) /
                    (SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10);

   // Spread must be less than 30% of distance to Fib level
   double maxSpread = fibDist * 0.30;
   if(maxSpread < 3.0) maxSpread = 3.0; // minimum 3 pip floor

   if(spread > maxSpread)
   {
      Print("Spread check ✗ | Spread: ", DoubleToString(spread, 1),
            " pips | Max allowed: ", DoubleToString(maxSpread, 1), " pips");
      return false;
   }

   Print("Spread check ✓ | Spread: ", DoubleToString(spread, 1),
         " pips | Max allowed: ", DoubleToString(maxSpread, 1), " pips");
   return true;
}

//+------------------------------------------------------------------+
//| Calculate trade levels using Fibonacci                           |
//+------------------------------------------------------------------+
void GetTradeLevels(string direction, double nearestFib,
                    double &sl, double &tp1, double &tp2, double &tp3)
{
   double pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   double buffer  = SL_Buffer * pipSize;

   if(direction == "BUY")
   {
      sl  = nearestFib - buffer;         // SL below the Fib level we broke
      tp1 = Fib382;                      // next Fib up
      tp2 = Fib236;                      // next Fib after that
      tp3 = SwingHigh + (SwingHigh - SwingLow) * 0.272; // 127.2% extension
   }
   else
   {
      sl  = nearestFib + buffer;         // SL above the Fib level we broke
      tp1 = Fib786;                      // next Fib down
      tp2 = Ext127;                      // 127.2% extension
      tp3 = Ext162;                      // 161.8% extension
   }
}

//+------------------------------------------------------------------+
//| Initialize CSV logging                                           |
//+------------------------------------------------------------------+
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
            "fib_level","velocity","volume_ratio",
            "rsi_accel","signal_score");
         FileClose(handle);
         Print("Quant CSV initialized: ", CSV_PATH);
      }
   }
   else FileClose(handle);
}

//+------------------------------------------------------------------+
//| Log closed trades to CSV                                         |
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
      if(ticket == 0) continue;
      if(ticket <= lastLoggedTicket) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != (ulong)MagicNumber) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      hasNew = true;
      break;
   }
   if(!hasNew) return;

   int handle = FileOpen(CSV_PATH,
                         FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ);
   if(handle == INVALID_HANDLE) return;
   FileSeek(handle, 0, SEEK_END);

   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
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

      // Calculate current Fib level and velocity for logging
      double distance;
      double nearestFib = GetNearestFibLevel(closePrice, distance);

      // Get volume ratio
      long volBuf[];
      ArraySetAsSeries(volBuf, true);
      double volRatio = 0;
      if(CopyTickVolume(_Symbol, PERIOD_M1, 0, VolumePeriod + 1, volBuf) >= VolumePeriod + 1)
      {
         double avgVol = 0;
         for(int k = 1; k <= VolumePeriod; k++) avgVol += (double)volBuf[k];
         avgVol /= VolumePeriod;
         volRatio = (double)volBuf[0] / avgVol;
      }

      // Get RSI acceleration
      double rsiBuf[];
      ArraySetAsSeries(rsiBuf, true);
      double rsiAccel = 0;
      if(CopyBuffer(rsiHandle, 0, 0, 3, rsiBuf) >= 3)
         rsiAccel = (rsiBuf[0] - rsiBuf[1]) - (rsiBuf[1] - rsiBuf[2]);

      FileWrite(handle,
         (string)ticket,
         _Symbol,
         typeStr,
         TimeToString(entryTime,   TIME_DATE|TIME_MINUTES),
         TimeToString(closeTime,   TIME_DATE|TIME_MINUTES),
         DoubleToString(openPrice,  _Digits),
         DoubleToString(closePrice, _Digits),
         DoubleToString(volume, 2),
         DoubleToString(profit, 2),
         DoubleToString(swap,   2),
         DoubleToString(comm,   2),
         (string)durationMin,
         DoubleToString(nearestFib, 2),
         DoubleToString(distance,   2),
         DoubleToString(volRatio,   2),
         DoubleToString(rsiAccel,   4),
         "5"  // all 5 layers confirmed at entry
      );

      lastLoggedTicket = ticket;
      Print("Quant trade logged | Ticket:", ticket, " Profit:", profit);
   }

   FileClose(handle);
}

//+------------------------------------------------------------------+
//| Time exit — close if held too long                               |
//+------------------------------------------------------------------+
void CheckTimeExit()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      int hoursHeld = (int)((TimeCurrent() - openTime) / 3600);

      if(hoursHeld >= MaxHoldHours)
      {
         trade.PositionClose(ticket);
         Print("Time exit | Ticket:", ticket, " held ", hoursHeld, " hours");
      }
   }
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   rsiHandle  = iRSI(_Symbol,  PERIOD_M5, RSI_Period, PRICE_CLOSE);
   macdHandle = iMACD(_Symbol, PERIOD_M5, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);

   if(rsiHandle == INVALID_HANDLE || macdHandle == INVALID_HANDLE)
   {
      Print("ERROR: Indicator handle failed");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_RETURN);

   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyResetTime    = TimeCurrent();

   CalculateFibLevels();
   InitCSV();

   Print("=== ", EA_Name, " initialized ===");
   Print("Symbol: ",       _Symbol);
   Print("AutoTrade: ",    AutoTrade ? "ENABLED" : "DISABLED");
   Print("Magic: ",        MagicNumber
Print("Strategy: Fibonacci Reactive | 5-Layer Confirmation");
   Print("CSV: quant_trades.csv");

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(rsiHandle  != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(macdHandle != INVALID_HANDLE) IndicatorRelease(macdHandle);
   Print(EA_Name, " stopped. Reason: ", reason);
}

void OnTick()
{
   MqlDateTime now, reset;
   TimeToStruct(TimeCurrent(), now);
   TimeToStruct(dailyResetTime, reset);
   if(now.day != reset.day)
   {
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyResetTime    = TimeCurrent();
      Print("Daily balance reset: ", dailyStartBalance);
   }

   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if((dailyStartBalance - currentBalance) >= MaxDailyLoss)
   {
      Print("Daily loss limit reached. Halting.");
      return;
   }

   LogClosedTrades();
   CheckTimeExit();

   if((TimeCurrent() - LastCheck) < PollSeconds) return;
   LastCheck = TimeCurrent();

   CalculateFibLevels();

   if(!AutoTrade) return;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetTicket(i) > 0 &&
         PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         Print("Position open. Monitoring...");
         return;
      }
   }

   double price      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double nearestFib = 0;
   string direction  = "";

   if(!CheckFibProximity(price, nearestFib, direction))
   { Print("Signal: HOLD | Layer 1 failed"); return; }

   if(!CheckVelocity(direction))
   { Print("Signal: HOLD | Layer 2 failed"); return; }

   if(!CheckVolumeSurge())
   { Print("Signal: HOLD | Layer 3 failed"); return; }

   if(!CheckFibBreak(nearestFib, direction))
   { Print("Signal: HOLD | Layer 4 failed"); return; }

   if(!CheckMomentumAcceleration(direction))
   { Print("Signal: HOLD | Layer 5 failed"); return; }

   if(!CheckDynamicSpread(nearestFib))
   { Print("Signal: HOLD | Spread too wide"); return; }

   Print("=== SIGNAL CONFIRMED | All 5 layers passed | Direction: ", direction, " ===");

   double sl, tp1, tp2, tp3;
   GetTradeLevels(direction, nearestFib, sl, tp1, tp2, tp3);

   bool success = false;

   if(direction == "BUY")
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl  = NormalizeDouble(sl,  _Digits);
      tp1 = NormalizeDouble(tp1, _Digits);
      success = trade.Buy(LotSize, _Symbol, 0, sl, tp1, "MQ_BUY");
      if(success)
         Print("BUY executed | Ask:", ask, " SL:", sl, " TP1:", tp1, " | Fib:", nearestFib);
      else
         Print("BUY failed: ", trade.ResultRetcodeDescription());
   }
   else if(direction == "SELL")
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl  = NormalizeDouble(sl,  _Digits);
      tp1 = NormalizeDouble(tp1, _Digits);
      success = trade.Sell(LotSize, _Symbol, 0, sl, tp1, "MQ_SELL");
      if(success)
         Print("SELL executed | Bid:", bid, " SL:", sl, " TP1:", tp1, " | Fib:", nearestFib);
      else
         Print("SELL failed: ", trade.ResultRetcodeDescription());
   }
}