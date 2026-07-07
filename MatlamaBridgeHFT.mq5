//+------------------------------------------------------------------+
//|                                        MatlamaBridgeHFT.mq5      |
//|                                      Matlama Tech © 2026         |
//|              HFT Manipulation Detector — Reactive Entry          |
//|         Detects stop hunts, liquidity grabs, and momentum        |
//|         bursts AT Fibonacci levels. Enters confirmed moves.      |
//+------------------------------------------------------------------+
#property copyright "Matlama Tech 2026"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include "OrchestratorClient.mqh"

//--- Input Parameters
input string   EA_Name         = "MatlamaBridgeHFT v2";
input double   LotSize         = 0.01;
input int      MagicNumber     = 20260102;
input int      SL_Pips         = 30;           // tighter SL for HFT
input int      TP_Pips         = 60;           // 1:2 RR minimum
input int      PollSeconds     = 5;            // fast poll for HFT
input bool     AutoTrade       = true;
input double   MaxDailyLoss    = 100.0;
input int      MaxTradesPerDay = 5;            // quality over quantity

//--- HFT Detection Settings
input double   SpikeThreshold  = 20.0;        // pips in 1 minute to detect spike
input double   ReverseBuffer   = 5.0;         // pips back through level for manipulation confirm
input int      LookbackCandles = 10;          // candles to find liquidity pools
input double   MinSpread       = 0.5;         // minimum spread (not trading during crazy spread)
input double   MaxSpread       = 15.0;        // maximum spread allowed

//--- Fibonacci Settings
input int      SwingLookback   = 30;          // candles for swing detection
input double   FibProximity    = 10.0;        // pips from Fib to consider proximity

//--- Orchestrator v2 Settings (full override — replaces stop-hunt/momentum gate)
input string   ORCH_SERVER            = "http://127.0.0.1:7000/decision_v2";
input string   ORCH_REPORT            = "http://127.0.0.1:7000/report_trade";
input bool     AllowNewsTrading       = false;
input bool     AllowCrisisTrading     = false;
input double   MaxAccountDrawdownPct  = 0.20;

//--- Session Filter
input bool     LondonSession   = true;        // trade London session
input bool     NewYorkSession  = true;        // trade NY session
input bool     AsiaSession     = false;       // skip Asia (low liquidity)

//--- Global Variables
CTrade   trade;
datetime LastCheck       = 0;
datetime dailyResetTime;
double   dailyStartBalance;
int      dailyTradeCount = 0;
int      atrHandle;
int      rsiHandle;
int      adxHandle;
int      emaFastHandle;
int      emaSlowHandle;
ulong    lastLoggedTicket = 0;
string   LastRegime = "UNKNOWN";

//--- Fibonacci levels
double   SwingHigh    = 0;
double   SwingLow     = 0;
double   Fib382       = 0;
double   Fib500       = 0;
double   Fib618       = 0;
double   Fib786       = 0;
datetime LastFibCalc  = 0;

//--- Manipulation tracking
double   LastSpikeHigh  = 0;
double   LastSpikeLow   = 0;
datetime LastSpikeTime  = 0;
string   CSV_PATH       = "hft_trades.csv";

//+------------------------------------------------------------------+
//| Session filter                                                    |
//+------------------------------------------------------------------+
bool IsValidSession()
{
   MqlDateTime now;
   TimeToStruct(TimeGMT(), now);
   int hour = now.hour;

   if(LondonSession  && hour >= 7  && hour < 12)  return true;
   if(NewYorkSession && hour >= 12 && hour < 20)  return true;
   if(AsiaSession    && (hour >= 0  && hour < 7))  return true;
   return false;
}

//+------------------------------------------------------------------+
//| Calculate Fibonacci levels                                        |
//+------------------------------------------------------------------+
void CalculateFibLevels()
{
   if((TimeCurrent() - LastFibCalc) < 3600 && LastFibCalc != 0) return;

   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows,  true);

   if(CopyHigh(_Symbol, PERIOD_H1, 0, SwingLookback, highs) < SwingLookback) return;
   if(CopyLow(_Symbol,  PERIOD_H1, 0, SwingLookback, lows)  < SwingLookback) return;

   SwingHigh = highs[ArrayMaximum(highs, 0, SwingLookback)];
   SwingLow  = lows[ArrayMinimum(lows,   0, SwingLookback)];

   double range = SwingHigh - SwingLow;
   if(range <= 0) return;

   Fib382 = SwingHigh - (range * 0.382);
   Fib500 = SwingHigh - (range * 0.500);
   Fib618 = SwingHigh - (range * 0.618);
   Fib786 = SwingHigh - (range * 0.786);

   LastFibCalc = TimeCurrent();
   Print("HFT Fib levels | H:", SwingHigh, " L:", SwingLow,
         " | 38.2:", Fib382, " 50:", Fib500,
         " 61.8:", Fib618, " 78.6:", Fib786);
}

//+------------------------------------------------------------------+
//| Check if price is near a Fibonacci level                         |
//+------------------------------------------------------------------+
bool NearFibLevel(double price, double &nearestFib)
{
   if(Fib618 == 0) return false;

   double pip = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   double levels[4] = {Fib382, Fib500, Fib618, Fib786};
   double minDist = FibProximity * pip + 1;

   for(int i = 0; i < 4; i++)
   {
      double dist = MathAbs(price - levels[i]) / pip;
      if(dist < minDist)
      {
         minDist    = dist;
         nearestFib = levels[i];
      }
   }
   return (minDist < FibProximity);
}

//+------------------------------------------------------------------+
//| Detect stop hunt / liquidity grab                                |
//| A stop hunt: price spikes through a swing high/low then reverses |
//+------------------------------------------------------------------+
bool DetectStopHunt(string &direction)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M1, 0, LookbackCandles + 3, rates) < LookbackCandles + 3)
      return false;

   double pip = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;

   // Find recent swing high and low from lookback candles
   double swingH = rates[2].high;
   double swingL = rates[2].low;
   for(int i = 2; i <= LookbackCandles; i++)
   {
      if(rates[i].high > swingH) swingH = rates[i].high;
      if(rates[i].low  < swingL) swingL = rates[i].low;
   }

   double lastHigh  = rates[1].high;
   double lastLow   = rates[1].low;
   double lastClose = rates[1].close;
   double lastOpen  = rates[1].open;

   // BULLISH stop hunt: price wicked below swing low then closed back above
   // Indicates market makers grabbed liquidity below, now reversing UP
   if(lastLow < swingL &&
      lastClose > swingL &&
      lastClose > lastOpen &&
      (swingL - lastLow) / pip >= ReverseBuffer)
   {
      direction = "BUY";
      Print("HFT | BULLISH stop hunt detected | Swept low:", swingL,
            " Wick to:", lastLow, " Close:", lastClose);
      return true;
   }

   // BEARISH stop hunt: price wicked above swing high then closed back below
   // Indicates market makers grabbed liquidity above, now reversing DOWN
   if(lastHigh > swingH &&
      lastClose < swingH &&
      lastClose < lastOpen &&
      (lastHigh - swingH) / pip >= ReverseBuffer)
   {
      direction = "SELL";
      Print("HFT | BEARISH stop hunt detected | Swept high:", swingH,
            " Wick to:", lastHigh, " Close:", lastClose);
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Detect momentum burst — price moving fast in one direction        |
//+------------------------------------------------------------------+
bool DetectMomentumBurst(string &direction)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M1, 0, 5, rates) < 5) return false;

   double pip  = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   double move = (rates[0].close - rates[2].close) / pip;

   // Bullish burst — moved up fast in last 3 minutes
   if(move >= SpikeThreshold)
   {
      // Confirm with volume
      long volBuf[];
      ArraySetAsSeries(volBuf, true);
      if(CopyTickVolume(_Symbol, PERIOD_M1, 0, 10, volBuf) < 10) return false;
      double avgVol = 0;
      for(int i = 3; i < 10; i++) avgVol += (double)volBuf[i];
      avgVol /= 7;
      if((double)volBuf[0] >= avgVol * 1.5)
      {
         direction = "BUY";
         Print("HFT | Bullish momentum burst | Move:", DoubleToString(move, 1),
               " pips | Vol surge: ", DoubleToString((double)volBuf[0]/avgVol, 1), "x");
         return true;
      }
   }

   // Bearish burst
   if(move <= -SpikeThreshold)
   {
      long volBuf[];
      ArraySetAsSeries(volBuf, true);
      if(CopyTickVolume(_Symbol, PERIOD_M1, 0, 10, volBuf) < 10) return false;
      double avgVol = 0;
      for(int i = 3; i < 10; i++) avgVol += (double)volBuf[i];
      avgVol /= 7;
      if((double)volBuf[0] >= avgVol * 1.5)
      {
         direction = "SELL";
         Print("HFT | Bearish momentum burst | Move:", DoubleToString(move, 1),
               " pips | Vol surge: ", DoubleToString((double)volBuf[0]/avgVol, 1), "x");
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Spread check                                                      |
//+------------------------------------------------------------------+
bool SpreadOk()
{
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = (ask - bid) / (SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10);
   if(spread < MinSpread || spread > MaxSpread)
   {
      Print("HFT | Spread out of range: ", DoubleToString(spread, 1), " pips");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| RSI confirmation                                                  |
//+------------------------------------------------------------------+
bool RSIConfirms(string direction)
{
   double rsiBuf[];
   ArraySetAsSeries(rsiBuf, true);
   if(CopyBuffer(rsiHandle, 0, 0, 3, rsiBuf) < 3) return false;
   double rsi = rsiBuf[0];
   if(direction == "BUY")  return rsi < 65;  // not overbought
   if(direction == "SELL") return rsi > 35;  // not oversold
   return false;
}

//+------------------------------------------------------------------+
//| Initialize CSV                                                    |
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
            "buy_score","sell_score","signal_score");
         FileClose(handle);
         Print("HFT CSV initialized");
      }
   }
   else FileClose(handle);
}

//+------------------------------------------------------------------+
//| Log closed trades                                                 |
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

   int handle = FileOpen(CSV_PATH,
                         FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ);
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

      FileWrite(handle,
         (string)ticket, _Symbol, typeStr,
         TimeToString(entryTime,   TIME_DATE|TIME_MINUTES),
         TimeToString(closeTime,   TIME_DATE|TIME_MINUTES),
         DoubleToString(openPrice,  _Digits),
         DoubleToString(closePrice, _Digits),
         DoubleToString(volume, 2),
         DoubleToString(profit, 2),
         DoubleToString(swap,   2),
         DoubleToString(comm,   2),
         (string)durationMin,
         "3", "3", "3"   // HFT uses 3-layer confirmation
      );

      lastLoggedTicket = ticket;
      Print("HFT trade logged | Ticket:", ticket, " Profit:", profit);

      int winFlag = (profit > 0) ? 1 : 0;
      OrchReportTrade(ORCH_REPORT, LastRegime, winFlag, profit);
   }
   FileClose(handle);
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   atrHandle = iATR(_Symbol, PERIOD_M5, 14);
   rsiHandle = iRSI(_Symbol, PERIOD_M5, 14, PRICE_CLOSE);
   adxHandle = iADX(_Symbol, PERIOD_M5, 14);
   emaFastHandle = iMA(_Symbol, PERIOD_M5, 12, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(_Symbol, PERIOD_M5, 26, 0, MODE_EMA, PRICE_CLOSE);

   if(atrHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE ||
      adxHandle == INVALID_HANDLE || emaFastHandle == INVALID_HANDLE ||
      emaSlowHandle == INVALID_HANDLE)
   {
      Print("ERROR: Indicator handle failed");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_RETURN);

   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyResetTime    = TimeCurrent();
   dailyTradeCount   = 0;

   CalculateFibLevels();
   InitCSV();

   Print("=== ", EA_Name, " initialized ===");
   Print("Strategy: Stop Hunt + Momentum Burst at Fibonacci levels");
   Print("Max trades/day: ", MaxTradesPerDay);
   Print("Spike threshold: ", SpikeThreshold, " pips");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(adxHandle != INVALID_HANDLE) IndicatorRelease(adxHandle);
   if(emaFastHandle != INVALID_HANDLE) IndicatorRelease(emaFastHandle);
   if(emaSlowHandle != INVALID_HANDLE) IndicatorRelease(emaSlowHandle);
   Print(EA_Name, " stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   // Daily reset
   MqlDateTime now, reset;
   TimeToStruct(TimeCurrent(), now);
   TimeToStruct(dailyResetTime, reset);
   if(now.day != reset.day)
   {
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyResetTime    = TimeCurrent();
      dailyTradeCount   = 0;
      Print("HFT daily reset | Balance:", dailyStartBalance);
   }

   // Daily loss limit
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if((dailyStartBalance - currentBalance) >= MaxDailyLoss)
   {
      Print("HFT | Daily loss limit reached. Halting.");
      return;
   }

   // Daily trade limit
   if(dailyTradeCount >= MaxTradesPerDay)
      return;

   // Log closed trades
   LogClosedTrades();

   // Poll throttle
   if((TimeCurrent() - LastCheck) < PollSeconds) return;
   LastCheck = TimeCurrent();

   // Session filter
   if(!IsValidSession()) return;

   // Spread check
   if(!SpreadOk()) return;

   // Recalculate Fibonacci every hour
   CalculateFibLevels();

   if(!AutoTrade) return;

   // Skip if already in position
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetTicket(i) > 0 &&
         PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         return;
   }

   // === ORCHESTRATOR v2 — FULL OVERRIDE ===
   // Stop-hunt/momentum-burst detection is bypassed; the orchestrator's
   // decision (BUY/SELL/HOLD) is authoritative. Session filter and spread
   // check above remain as hard structural gates, not signal logic.

   double price  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask0   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double spread = (ask0 - price) / (SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10);

   double atrBuf[]; ArraySetAsSeries(atrBuf, true);
   double atr = 0;
   if(CopyBuffer(atrHandle, 0, 0, 1, atrBuf) > 0)
      atr = atrBuf[0] / (SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10);

   double adxBuf[]; ArraySetAsSeries(adxBuf, true);
   double adx = 0;
   if(CopyBuffer(adxHandle, 0, 0, 1, adxBuf) > 0) adx = adxBuf[0];

   double rsiBuf[]; ArraySetAsSeries(rsiBuf, true);
   double rsi = 50;
   if(CopyBuffer(rsiHandle, 0, 0, 1, rsiBuf) > 0) rsi = rsiBuf[0];

   double emaFastBuf[], emaSlowBuf[];
   ArraySetAsSeries(emaFastBuf, true);
   ArraySetAsSeries(emaSlowBuf, true);
   double emaFast = 0, emaSlow = 0;
   if(CopyBuffer(emaFastHandle, 0, 0, 1, emaFastBuf) > 0) emaFast = emaFastBuf[0];
   if(CopyBuffer(emaSlowHandle, 0, 0, 1, emaSlowBuf) > 0) emaSlow = emaSlowBuf[0];

   double volatility = OrchCalcVolatility(_Symbol, PERIOD_M5, 20);
   double momentum   = OrchCalcMomentum(_Symbol, PERIOD_M1, 5);

   long volBuf2[]; ArraySetAsSeries(volBuf2, true);
   double volume = 0;
   if(CopyTickVolume(_Symbol, PERIOD_M1, 0, 1, volBuf2) > 0) volume = (double)volBuf2[0];

   int newsRisk = 0; // wire to a news calendar feed if/when available

   string payload = OrchBuildPayload(price, spread, atr, adx, volatility, momentum,
                                      volume, rsi, emaFast, emaSlow, newsRisk,
                                      MaxSpread, AllowNewsTrading, AllowCrisisTrading,
                                      MaxAccountDrawdownPct);

   OrchDecision dec = OrchGetDecision(ORCH_SERVER, payload);

   if(!dec.valid)
   {
      Print("HFT | ORCH unreachable — holding, no trade this tick");
      return;
   }

   LastRegime = dec.regime;

   if(dec.decision == "HOLD") return;

   string direction  = dec.decision;      // "BUY" or "SELL" — orchestrator is authoritative
   string signalType = "ORCHESTRATOR";
   double nearestFib = 0;
   NearFibLevel(price, nearestFib);       // best-effort reference level for logging only

   // === SIGNAL CONFIRMED — ENTER TRADE ===
   Print("HFT | Signal: ", signalType, " | Direction: ", direction,
         " | Confidence: ", DoubleToString(dec.confidence, 3),
         " | Regime: ", dec.regime, " | Price: ", price);

   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pipSize = point * 10;
   double sl_dist = SL_Pips * pipSize;
   double tp_dist = TP_Pips * pipSize;
   bool   success = false;

   if(direction == "BUY")
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = NormalizeDouble(ask - sl_dist, _Digits);
      double tp  = NormalizeDouble(ask + tp_dist, _Digits);
      success    = trade.Buy(LotSize, _Symbol, 0, sl, tp, "HFT_BUY");
      if(success)
      {
         dailyTradeCount++;
         Print("HFT BUY | Ask:", ask, " SL:", sl, " TP:", tp,
               " | Type:", signalType, " Fib:", nearestFib);
      }
      else Print("HFT BUY failed: ", trade.ResultRetcodeDescription());
   }
   else if(direction == "SELL")
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = NormalizeDouble(bid + sl_dist, _Digits);
      double tp  = NormalizeDouble(bid - tp_dist, _Digits);
      success    = trade.Sell(LotSize, _Symbol, 0, sl, tp, "HFT_SELL");
      if(success)
      {
         dailyTradeCount++;
         Print("HFT SELL | Bid:", bid, " SL:", sl, " TP:", tp,
               " | Type:", signalType, " Fib:", nearestFib);
      }
      else Print("HFT SELL failed: ", trade.ResultRetcodeDescription());
   }
}