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
#include "OrchestratorClient.mqh"

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

//--- Orchestrator v2 Settings (full override — orchestrator decision replaces layer logic)
input string   ORCH_SERVER            = "http://127.0.0.1:7000/decision_v2";
input string   ORCH_REPORT            = "http://127.0.0.1:7000/report_trade";
input double   MaxSpreadPips          = 5.0;
input bool     AllowNewsTrading       = false;
input bool     AllowCrisisTrading     = false;
input double   MaxAccountDrawdownPct  = 0.20;

//--- Layer 6/7 — Liquidity Sweep + FVG (OR-path override when ORCH says HOLD)
input bool     EnableSweepFVG          = true;   // allow Sweep+FVG to fire trades ORCH declined
input int      SweepLookback           = 30;     // M5 candles to establish the reference swing range
input double   SweepMinPips            = 5.0;    // min pips beyond swing level to count as a sweep
input int      FVG_Lookback            = 30;     // M5 candles to scan for unfilled FVGs
input double   FVG_MinGapPips          = 3.0;    // minimum FVG size in pips to be tradeable
input double   SweepFVG_SL_BufferPips  = 8.0;    // SL buffer beyond the sweep level for override trades
input bool     EnableContinuation      = true;   // allow sweep + fresh (unretested) FVG to fire a continuation entry
input int      ContinuationFVGMaxAge   = 5;      // max bars since FVG formed to still count as "fresh"
input double   ContinuationSL_BufferPips = 5.0;  // SL buffer beyond the fresh FVG's near edge

//--- False Sweep Continuation Filter (blocks exhausted moves)
input bool     EnableFalseSweepFilter     = true;
input double   MaxTravelFromSweepPips     = 40.0;  // max pips price can travel from sweep and still chase
input double   MaxEMAExtensionATR         = 2.0;   // max ATR units from slow EMA — beyond = overextended
input int      RSIDivergenceBars          = 5;     // M5 bars to check for momentum divergence
input double   MinContinuationVolRatio    = 1.0;   // volume must be above average to confirm institutional flow
input int      FalseSweepMinFails         = 2;     // block if this many exhaustion signals fire (out of 4)

//--- Global Variables
CTrade   trade;
datetime LastCheck      = 0;
datetime EntryTime      = 0;
double   dailyStartBalance;
datetime dailyResetTime;
int      rsiHandle;
int      macdHandle;
int      adxHandle;
int      atrHandle;
int      emaFastHandle;
int      emaSlowHandle;
ulong    lastLoggedTicket = 0;
string   LastRegime = "UNKNOWN";   // regime returned by orchestrator for the currently open position

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
   // Was PERIOD_M1 while every other layer (RSI, MACD, ADX, ATR, EMA,
   // Sweep, FVG) runs on PERIOD_M5 — meant Volume was evaluating a
   // different, faster-refreshing clock than the rest of the system.
   // On any given tick, an M1 candle could have just opened seconds ago
   // (low volume so far -> ratio fails) while the M5 RSI/MACD reading
   // reflected several minutes of established move (already oversold /
   // trending) — a real mismatch between layers, not noise. Aligned to
   // M5 so every layer describes the same slice of time.
   long volBuf[];
   ArraySetAsSeries(volBuf, true);
   if(CopyTickVolume(_Symbol, PERIOD_M5, 0, VolumePeriod + 1, volBuf) < VolumePeriod + 1)
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
//| Layer 6 — Liquidity Sweep Check                                  |
//| Detects a wick-based stop hunt: price pierces a recent swing     |
//| high/low by SweepMinPips then closes back inside the range —     |
//| the classic liquidity-grab signature that precedes a reversal.   |
//+------------------------------------------------------------------+
bool CheckLiquiditySweep(string &direction, double &sweepLevel)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int need = SweepLookback + 5;
   if(CopyRates(_Symbol, PERIOD_M5, 0, need, rates) < need) return false;

   double pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   double buffer  = SweepMinPips * pipSize;

   // Reference swing range from the oldest portion of the lookback window.
   double refHigh = rates[SweepLookback].high;
   double refLow  = rates[SweepLookback].low;
   for(int i = SweepLookback + 1; i < need; i++)
   {
      if(rates[i].high > refHigh) refHigh = rates[i].high;
      if(rates[i].low  < refLow)  refLow  = rates[i].low;
   }

   // Scan the FULL recent window (not just the last 3 bars) for a sweep-
   // and-reclaim, most recent first. A sweep+FVG retest sequence takes
   // several bars to fully develop (sweep -> reversal impulse -> FVG forms
   // -> price pulls back to retest it), so the sweep itself needs to stay
   // "remembered" for longer than just 3 bars for Layer 7 to ever have a
   // chance to co-confirm on the same tick.
   for(int i = 1; i < SweepLookback; i++)
   {
      // Bullish sweep: wick pierces below refLow, candle closes back above it.
      if(rates[i].low < (refLow - buffer) && rates[i].close > refLow)
      {
         // Only valid if no bar since (more recent than i) has closed back
         // below the swept low — that would mean the level actually broke
         // rather than held, invalidating the sweep thesis.
         bool invalidated = false;
         for(int j = i - 1; j >= 0; j--)
         {
            if(rates[j].close < refLow) { invalidated = true; break; }
         }
         if(invalidated) continue;

         direction  = "BUY";
         sweepLevel = refLow;
         Print("Layer 6 ✓ | Bullish liquidity sweep | Low pierced ", refLow,
               " by ", DoubleToString((refLow - rates[i].low) / pipSize, 1),
               " pips, ", i, " bars ago, still unmitigated");
         return true;
      }
      // Bearish sweep: wick pierces above refHigh, candle closes back below it.
      if(rates[i].high > (refHigh + buffer) && rates[i].close < refHigh)
      {
         bool invalidated = false;
         for(int j = i - 1; j >= 0; j--)
         {
            if(rates[j].close > refHigh) { invalidated = true; break; }
         }
         if(invalidated) continue;

         direction  = "SELL";
         sweepLevel = refHigh;
         Print("Layer 6 ✓ | Bearish liquidity sweep | High pierced ", refHigh,
               " by ", DoubleToString((rates[i].high - refHigh) / pipSize, 1),
               " pips, ", i, " bars ago, still unmitigated");
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Layer 7 — Fair Value Gap (FVG) Check                             |
//| Scans for an unfilled 3-candle imbalance and checks whether       |
//| price is currently retesting into that gap. Single pass over     |
//| FVG_Lookback bars — do not raise the lookback without profiling, |
//| the fill-check below is O(n) per candidate gap.                  |
//+------------------------------------------------------------------+
bool CheckFairValueGap(string direction, double &gapTop, double &gapBottom)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int need = FVG_Lookback + 3;
   if(CopyRates(_Symbol, PERIOD_M5, 0, need, rates) < need) return false;

   double pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   double minGap  = FVG_MinGapPips * pipSize;
   double price   = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // rates[i+2] = oldest (A), rates[i+1] = middle (B, impulse), rates[i] = newest (C)
   // Scan from most recent gaps backward so we find the freshest unfilled one first.
   for(int i = 1; i <= FVG_Lookback; i++)
   {
      int a = i + 2, c = i;
      if(a >= need) break;

      if(direction == "BUY")
      {
         // Bullish FVG: candle A's high sits below candle C's low.
         double top    = rates[c].low;
         double bottom = rates[a].high;
         if(top - bottom < minGap) continue;

         // Unfilled check: no candle between formation and now has traded
         // all the way through the gap (closed below the gap's bottom).
         bool filled = false;
         for(int j = i - 1; j >= 0; j--)
         {
            if(rates[j].low <= bottom) { filled = true; break; }
         }
         if(filled) continue;

         // Retest in progress: current price sitting inside the gap.
         if(price >= bottom && price <= top)
         {
            gapTop    = top;
            gapBottom = bottom;
            Print("Layer 7 ✓ | Bullish FVG retest | Gap ", DoubleToString(bottom, 2),
                  " - ", DoubleToString(top, 2), " | Price: ", price);
            return true;
         }
      }
      else // SELL
      {
         // Bearish FVG: candle A's low sits above candle C's high.
         double top    = rates[a].low;
         double bottom = rates[c].high;
         if(top - bottom < minGap) continue;

         bool filled = false;
         for(int j = i - 1; j >= 0; j--)
         {
            if(rates[j].high >= top) { filled = true; break; }
         }
         if(filled) continue;

         if(price >= bottom && price <= top)
         {
            gapTop    = top;
            gapBottom = bottom;
            Print("Layer 7 ✓ | Bearish FVG retest | Gap ", DoubleToString(bottom, 2),
                  " - ", DoubleToString(top, 2), " | Price: ", price);
            return true;
         }
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Combined Layer 6+7 — OR-path override                            |
//| Fires only when a liquidity sweep AND an unfilled FVG agree on    |
//| the same direction, with price actively retesting the gap now.   |
//+------------------------------------------------------------------+
bool CheckLiquiditySweepFVG(string &direction, double &sweepLevel,
                            double &gapTop, double &gapBottom)
{
   string sweepDir;
   double level;
   if(!CheckLiquiditySweep(sweepDir, level)) return false;

   double top, bottom;
   if(!CheckFairValueGap(sweepDir, top, bottom)) return false;

   direction  = sweepDir;
   sweepLevel = level;
   gapTop     = top;
   gapBottom  = bottom;

   Print("=== LAYER 6+7 CONFLUENCE | Sweep + FVG agree on ", direction, " ===");
   return true;
}

//+------------------------------------------------------------------+
//| Trade levels for a Sweep+FVG override entry.                     |
//| SL anchors to the swept liquidity level (the level that must NOT |
//| be re-broken for the trade thesis to remain valid), not the      |
//| nearest Fib — Fib is irrelevant to this signal's own logic.      |
//+------------------------------------------------------------------+
void GetSweepFVGTradeLevels(string direction, double sweepLevel,
                             double gapTop, double gapBottom, double currentPrice,
                             double &sl, double &tp1, double &tp2, double &tp3)
{
   double pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   double buffer  = SweepFVG_SL_BufferPips * pipSize;

   if(direction == "BUY")
   {
      sl  = sweepLevel - buffer;
      double risk = currentPrice - sl;
      tp1 = currentPrice + 2.0 * risk;   // conservative 2R lock-in
      tp2 = Fib236;                      // reuse existing Fib map for scale-out targets
      tp3 = SwingHigh + (SwingHigh - SwingLow) * 0.272;
   }
   else
   {
      sl  = sweepLevel + buffer;
      double risk = sl - currentPrice;
      tp1 = currentPrice - 2.0 * risk;
      tp2 = Ext127;
      tp3 = Ext162;
   }
}

//+------------------------------------------------------------------+
//| Layer 7b — Fresh (unretested) FVG check for continuation entries |
//| Unlike CheckFairValueGap (which requires price to be sitting     |
//| INSIDE the gap right now — a retest), this checks whether a      |
//| qualifying unfilled FVG recently FORMED in the given direction,  |
//| regardless of where price currently sits relative to it. A       |
//| fresh, unfilled gap is itself evidence the impulse leg had real  |
//| conviction — useful for riding a continuation move that never    |
//| pulls back far enough to retest.                                 |
//+------------------------------------------------------------------+
bool CheckFreshFVG(string direction, double &gapTop, double &gapBottom, int &barsAgo)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int need = FVG_Lookback + 3;
   if(CopyRates(_Symbol, PERIOD_M5, 0, need, rates) < need) return false;

   double pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   double minGap  = FVG_MinGapPips * pipSize;

   for(int i = 1; i <= ContinuationFVGMaxAge; i++)
   {
      int a = i + 2, c = i;
      if(a >= need) break;

      if(direction == "BUY")
      {
         double top    = rates[c].low;
         double bottom = rates[a].high;
         if(top - bottom < minGap) continue;

         bool filled = false;
         for(int j = i - 1; j >= 0; j--)
         {
            if(rates[j].low <= bottom) { filled = true; break; }
         }
         if(filled) continue;

         gapTop = top; gapBottom = bottom; barsAgo = i;
         Print("Layer 7b ✓ | Fresh bullish FVG (unretested) | Gap ",
               DoubleToString(bottom, 2), " - ", DoubleToString(top, 2),
               " | Formed ", i, " bars ago");
         return true;
      }
      else // SELL
      {
         double top    = rates[a].low;
         double bottom = rates[c].high;
         if(top - bottom < minGap) continue;

         bool filled = false;
         for(int j = i - 1; j >= 0; j--)
         {
            if(rates[j].high >= top) { filled = true; break; }
         }
         if(filled) continue;

         gapTop = top; gapBottom = bottom; barsAgo = i;
         Print("Layer 7b ✓ | Fresh bearish FVG (unretested) | Gap ",
               DoubleToString(bottom, 2), " - ", DoubleToString(top, 2),
               " | Formed ", i, " bars ago");
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Combined — Sweep + Continuation (no retest required)              |
//| Complements CheckLiquiditySweepFVG: that function catches the     |
//| mean-reversion case (pullback into an existing gap); this one     |
//| catches a move that just keeps going, confirmed by the fact that  |
//| it's leaving fresh, unfilled imbalance behind it as it goes.      |
//+------------------------------------------------------------------+
bool CheckSweepContinuation(string &direction, double &sweepLevel,
                            double &gapTop, double &gapBottom, int &fvgBarsAgo)
{
   string sweepDir;
   double level;
   if(!CheckLiquiditySweep(sweepDir, level)) return false;

   double top, bottom;
   int barsAgo;
   if(!CheckFreshFVG(sweepDir, top, bottom, barsAgo)) return false;

   direction  = sweepDir;
   sweepLevel = level;
   gapTop     = top;
   gapBottom  = bottom;
   fvgBarsAgo = barsAgo;

   Print("=== SWEEP + CONTINUATION | Sweep confirmed, fresh FVG (",
         barsAgo, " bars old) confirms momentum in ", direction, " ===");
   return true;
}

//+------------------------------------------------------------------+
//| Trade levels for a continuation entry.                           |
//| SL anchors to the fresh FVG's near edge — the gap being filled    |
//| back through is the signal the impulse has failed, not the       |
//| original (now distant) swept level.                              |
//+------------------------------------------------------------------+
void GetContinuationTradeLevels(string direction, double gapTop, double gapBottom,
                                 double currentPrice, double &sl, double &tp1,
                                 double &tp2, double &tp3)
{
   double pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   double buffer  = ContinuationSL_BufferPips * pipSize;

   if(direction == "BUY")
   {
      sl  = gapBottom - buffer;   // near edge of the fresh gap
      double risk = currentPrice - sl;
      tp1 = currentPrice + 1.5 * risk;   // tighter target — chasing, not at a discount
      tp2 = SwingHigh;
      tp3 = SwingHigh + (SwingHigh - SwingLow) * 0.272;
   }
   else
   {
      sl  = gapTop + buffer;
      double risk = sl - currentPrice;
      tp1 = currentPrice - 1.5 * risk;
      tp2 = SwingLow;
      tp3 = SwingLow - (SwingHigh - SwingLow) * 0.272;
   }
}

//+------------------------------------------------------------------+
//| False Sweep Continuation Filter                                  |
//| Blocks continuation entries when the move is exhausted:          |
//|   1. Price already traveled too far from the sweep level         |
//|   2. Price overextended from slow EMA (in ATR units)             |
//|   3. RSI diverging from price (momentum not confirming)          |
//|   4. Volume below average (institutions not participating)       |
//| Returns true if the continuation looks FALSE and should be       |
//| blocked.  Requires FalseSweepMinFails (default 2) to trigger.    |
//+------------------------------------------------------------------+
bool IsFalseSweepContinuation(string direction, double sweepLevel)
{
   if(!EnableFalseSweepFilter) return false;

   int    failCount = 0;
   double pipSize   = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   double price     = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // --- Filter 1: Travel Distance ---
   double travelPips = MathAbs(price - sweepLevel) / pipSize;
   if(travelPips > MaxTravelFromSweepPips)
   {
      Print("FalseSweep [1] ✗ | Travel: ", DoubleToString(travelPips, 1),
            " pips from sweep (max ", DoubleToString(MaxTravelFromSweepPips, 0), ")");
      failCount++;
   }
   else
      Print("FalseSweep [1] ✓ | Travel: ", DoubleToString(travelPips, 1), " pips — within range");

   // --- Filter 2: EMA Extension ---
   double emaSlBuf[];
   ArraySetAsSeries(emaSlBuf, true);
   double atrBuf2[];
   ArraySetAsSeries(atrBuf2, true);
   if(CopyBuffer(emaSlowHandle, 0, 0, 1, emaSlBuf) > 0 &&
      CopyBuffer(atrHandle, 0, 0, 1, atrBuf2) > 0 && atrBuf2[0] > 0)
   {
      double emaDistance = MathAbs(price - emaSlBuf[0]);
      double atrUnits   = emaDistance / atrBuf2[0];
      if(atrUnits > MaxEMAExtensionATR)
      {
         Print("FalseSweep [2] ✗ | EMA extension: ", DoubleToString(atrUnits, 2),
               " ATR from EMA26 (max ", DoubleToString(MaxEMAExtensionATR, 1), ")");
         failCount++;
      }
      else
         Print("FalseSweep [2] ✓ | EMA extension: ", DoubleToString(atrUnits, 2), " ATR — OK");
   }

   // --- Filter 3: RSI Divergence ---
   double rsiBufDiv[];
   ArraySetAsSeries(rsiBufDiv, true);
   MqlRates divRates[];
   ArraySetAsSeries(divRates, true);
   if(CopyBuffer(rsiHandle, 0, 0, RSIDivergenceBars, rsiBufDiv) >= RSIDivergenceBars &&
      CopyRates(_Symbol, PERIOD_M5, 0, RSIDivergenceBars, divRates) >= RSIDivergenceBars)
   {
      int last = RSIDivergenceBars - 1;
      bool diverging = false;
      if(direction == "BUY")
      {
         if(divRates[0].close > divRates[last].close && rsiBufDiv[0] < rsiBufDiv[last])
            diverging = true;
      }
      else
      {
         if(divRates[0].close < divRates[last].close && rsiBufDiv[0] > rsiBufDiv[last])
            diverging = true;
      }

      if(diverging)
      {
         Print("FalseSweep [3] ✗ | RSI divergence — momentum not confirming price");
         failCount++;
      }
      else
         Print("FalseSweep [3] ✓ | No RSI divergence — momentum aligned");
   }

   // --- Filter 4: Volume Fade ---
   long volBufFS[];
   ArraySetAsSeries(volBufFS, true);
   if(CopyTickVolume(_Symbol, PERIOD_M5, 0, VolumePeriod + 1, volBufFS) >= VolumePeriod + 1)
   {
      double avgVol = 0;
      for(int i = 1; i <= VolumePeriod; i++) avgVol += (double)volBufFS[i];
      avgVol /= VolumePeriod;
      double volRatio = (avgVol > 0) ? (double)volBufFS[0] / avgVol : 0;
      if(volRatio < MinContinuationVolRatio)
      {
         Print("FalseSweep [4] ✗ | Volume fading: ", DoubleToString(volRatio, 2),
               "x avg (need ", DoubleToString(MinContinuationVolRatio, 1), "x)");
         failCount++;
      }
      else
         Print("FalseSweep [4] ✓ | Volume: ", DoubleToString(volRatio, 2), "x avg — supported");
   }

   // --- Verdict ---
   if(failCount >= FalseSweepMinFails)
   {
      Print("=== FALSE SWEEP CONTINUATION BLOCKED | ", failCount, "/4 exhaustion signals fired ===");
      return true;
   }

   Print("FalseSweep ✓ | Only ", failCount, "/4 failed — continuation valid");
   return false;
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
void GetTradeLevels(string direction, double nearestFib, string regime, double currentPrice,
                    double &sl, double &tp1, double &tp2, double &tp3)
{
   double pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   double buffer  = SL_Buffer * pipSize;

   // REGIME-ADAPTIVE TP1 (backtested on 2021+2024 M1 data: +107% combined P&L,
   // ~5x lower max drawdown vs always targeting the far Fib level):
   //   RANGE -> price rarely reaches the far Fib extension before reversing,
   //            so lock in a tight 2R target instead.
   //   TREND -> the original far-Fib target captures more of the run; keep it.
   // tp2/tp3 are left as the wider Fib/extension levels either way (scale-out
   // targets if/when partial-close logic uses them).

   if(direction == "BUY")
   {
      sl  = nearestFib - buffer;         // SL below the Fib level we broke
      double risk = currentPrice - sl;
      if(regime == "RANGE")
         tp1 = currentPrice + 2.0 * risk;  // tight lock-in
      else
         tp1 = Fib382;                     // next Fib up (TREND / other regimes)
      tp2 = Fib236;                      // next Fib after that
      tp3 = SwingHigh + (SwingHigh - SwingLow) * 0.272; // 127.2% extension
   }
   else
   {
      sl  = nearestFib + buffer;         // SL above the Fib level we broke
      double risk = sl - currentPrice;
      if(regime == "RANGE")
         tp1 = currentPrice - 2.0 * risk;  // tight lock-in
      else
         tp1 = Fib786;                     // next Fib down (TREND / other regimes)
      tp2 = Ext127;                      // 127.2% extension
      tp3 = Ext162;                      // 161.8% extension
   }
}

//+------------------------------------------------------------------+
//| Initialize CSV logging                                           |
//+------------------------------------------------------------------+
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
            "fib_level","velocity","volume_ratio",
            "rsi_accel","signal_score");
         FileClose(handle);
         Print("Quant CSV initialized: ", CSV_PATH);
      }
   }
   else FileClose(handle);

   // Restore lastLoggedTicket across recompiles/reattaches/terminal restarts.
   // Without this, the global resets to 0 on every EA reinit and
   // LogClosedTrades() re-appends already-logged closed trades as duplicates.
   string gvName = "Quant_LastLoggedTicket_" + _Symbol + "_" + (string)MagicNumber;
   if(GlobalVariableCheck(gvName))
      lastLoggedTicket = (ulong)GlobalVariableGet(gvName);
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
                         FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ',');
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

      // Real velocity: pips moved over the last 3 M1 candles (this was
      // previously mislabeled — the column was actually storing Fib
      // distance, not velocity, since the two share a similar magnitude
      // and the bug went unnoticed)
      MqlRates velRates[]; ArraySetAsSeries(velRates, true);
      double velocityPipsLog = 0;
      if(CopyRates(_Symbol, PERIOD_M1, 0, 5, velRates) >= 5)
      {
         double pipSizeLog = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
         velocityPipsLog = (velRates[0].close - velRates[2].close) / pipSizeLog;
      }

      // Get volume ratio — M5 to match live serving in OnTick
      long volBuf[];
      ArraySetAsSeries(volBuf, true);
      double volRatio = 0;
      if(CopyTickVolume(_Symbol, PERIOD_M5, 0, VolumePeriod + 1, volBuf) >= VolumePeriod + 1)
      {
         double avgVol = 0;
         for(int k = 1; k <= VolumePeriod; k++) avgVol += (double)volBuf[k];
         avgVol /= VolumePeriod;
         if(avgVol > 0)
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
         DoubleToString(velocityPipsLog, 2),
         DoubleToString(volRatio,   2),
         DoubleToString(rsiAccel,   4),
         "5"  // full-override trades are orchestrator-authorized, not layer-gated;
              // this "5" is a historical placeholder matching the old all-5-confirmed
              // convention and should be revisited once enough post-override trades exist
      );

      lastLoggedTicket = ticket;
      GlobalVariableSet("Quant_LastLoggedTicket_" + _Symbol + "_" + (string)MagicNumber, (double)lastLoggedTicket);
      Print("Quant trade logged | Ticket:", ticket, " Profit:", profit);

      // Feed result back into the orchestrator's trade memory
      int winFlag = (profit > 0) ? 1 : 0;
      OrchReportTrade(ORCH_REPORT, "QUANT", LastRegime, winFlag, profit);
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
   rsiHandle     = iRSI(_Symbol,  PERIOD_M5, RSI_Period, PRICE_CLOSE);
   macdHandle    = iMACD(_Symbol, PERIOD_M5, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   adxHandle     = iADX(_Symbol,  PERIOD_M5, 14);
   atrHandle     = iATR(_Symbol,  PERIOD_M5, 14);
   emaFastHandle = iMA(_Symbol,   PERIOD_M5, 12, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(_Symbol,   PERIOD_M5, 26, 0, MODE_EMA, PRICE_CLOSE);

   if(rsiHandle == INVALID_HANDLE || macdHandle == INVALID_HANDLE ||
      adxHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE ||
      emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE)
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
   Print("Magic: ",        MagicNumber);
   Print("Strategy: Fibonacci Reactive | 5-Layer Confirmation");
   Print("CSV: quant_trades.csv");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(rsiHandle     != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(macdHandle    != INVALID_HANDLE) IndicatorRelease(macdHandle);
   if(adxHandle     != INVALID_HANDLE) IndicatorRelease(adxHandle);
   if(atrHandle     != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(emaFastHandle != INVALID_HANDLE) IndicatorRelease(emaFastHandle);
   if(emaSlowHandle != INVALID_HANDLE) IndicatorRelease(emaSlowHandle);
   Print(EA_Name, " stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
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
      Print("Daily balance reset: ", dailyStartBalance);
   }

   // Daily loss limit
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if((dailyStartBalance - currentBalance) >= MaxDailyLoss)
   {
      Print("Daily loss limit reached. Halting.");
      return;
   }

   // Log closed trades
   LogClosedTrades();

   // Check time exit on open positions
   CheckTimeExit();

   // Poll interval
   if((TimeCurrent() - LastCheck) < PollSeconds) return;
   LastCheck = TimeCurrent();

   // Recalculate Fibonacci levels every 4 hours
   CalculateFibLevels();

   if(!AutoTrade) return;

   // Skip if already in a position
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

   // === ORCHESTRATOR v2 — FULL OVERRIDE ===
   // The 5-layer Fibonacci confirmation logic is bypassed; the orchestrator's
   // decision (BUY/SELL/HOLD) is authoritative. Fib levels are still used
   // afterward purely for SL/TP placement, not for gating entry.

   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double spread = (ask - price) / (SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10);

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
   double momentum   = OrchCalcMomentum(_Symbol, PERIOD_M5, 10);

   long volBuf[]; ArraySetAsSeries(volBuf, true);
   double volume = 0;
   if(CopyTickVolume(_Symbol, PERIOD_M1, 0, 1, volBuf) > 0) volume = (double)volBuf[0];

   int newsRisk = 0; // wire to a news calendar feed if/when available

   // Live, non-gating computation of Quant's own strategy features. These
   // no longer gate entry (orchestrator is authoritative), but the
   // orchestrator's dedicated QUANT model was trained on exactly these
   // features, so they must be supplied for a meaningful prediction.
   double distanceFib;
   double nearestFibLevel = GetNearestFibLevel(price, distanceFib);
   string dirGuess = (price < nearestFibLevel) ? "BUY" : "SELL";

   MqlRates fRates[]; ArraySetAsSeries(fRates, true);
   double velocityPips = 0;
   if(CopyRates(_Symbol, PERIOD_M1, 0, 5, fRates) >= 5)
   {
      double pipSizeV = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
      if(dirGuess == "BUY") velocityPips = (fRates[0].close - fRates[2].close) / pipSizeV;
      else                  velocityPips = (fRates[2].close - fRates[0].close) / pipSizeV;
   }

   long volBuf3[]; ArraySetAsSeries(volBuf3, true);
   double volRatioLive = 0;
   // Aligned to M5 to match CheckVolumeSurge's gate (Layer 3) — this value
   // is reported to the orchestrator as "volume_ratio" and the QUANT model
   // was trained expecting it to describe the same timeframe as everything
   // else, not a faster M1 reading under the same feature name.
   if(CopyTickVolume(_Symbol, PERIOD_M5, 0, VolumePeriod + 1, volBuf3) >= VolumePeriod + 1)
   {
      double avgVolLive = 0;
      for(int k = 1; k <= VolumePeriod; k++) avgVolLive += (double)volBuf3[k];
      avgVolLive /= VolumePeriod;
      if(avgVolLive > 0)
         volRatioLive = (double)volBuf3[0] / avgVolLive;
   }

   double rsiAccelLive = 0;
   double rsiBuf3[]; ArraySetAsSeries(rsiBuf3, true);
   if(CopyBuffer(rsiHandle, 0, 0, 3, rsiBuf3) >= 3)
      rsiAccelLive = (rsiBuf3[0] - rsiBuf3[1]) - (rsiBuf3[1] - rsiBuf3[2]);

   // Count how many of the 5 original layers currently pass, purely as a
   // feature value — no gating, since the orchestrator decides.
   int confirmedLayers = 0;
   if(distanceFib <= FibProximity)             confirmedLayers++;
   if(CheckVelocity(dirGuess))                 confirmedLayers++;
   if(CheckVolumeSurge())                      confirmedLayers++;
   if(CheckFibBreak(nearestFibLevel, dirGuess)) confirmedLayers++;
   if(CheckMomentumAcceleration(dirGuess))      confirmedLayers++;

   // Layer 6+7 features — computed every tick and reported to the orchestrator
   // regardless of outcome, so future retrains can learn from sweep/FVG context
   // even on ticks where the OR-path override below doesn't end up firing.
   string sweepDirFeat = "";
   double sweepLevelFeat = 0, gapTopFeat = 0, gapBottomFeat = 0;
   bool sweepFvgFeat = CheckLiquiditySweepFVG(sweepDirFeat, sweepLevelFeat, gapTopFeat, gapBottomFeat);

   string extraFields = "\"fib_level\":" + DoubleToString(nearestFibLevel, 2) +
                         ",\"velocity\":" + DoubleToString(velocityPips, 2) +
                         ",\"volume_ratio\":" + DoubleToString(volRatioLive, 2) +
                         ",\"rsi_accel\":" + DoubleToString(rsiAccelLive, 4) +
                         ",\"signal_score\":" + (string)confirmedLayers +
                         ",\"sweep_fvg_detected\":" + (sweepFvgFeat ? "1" : "0") +
                         ",\"sweep_fvg_direction\":\"" + (sweepFvgFeat ? sweepDirFeat : "NONE") + "\"";

   string payload = OrchBuildPayload("QUANT", price, spread, atr, adx, volatility, momentum,
                                      volume, rsi, emaFast, emaSlow, newsRisk,
                                      MaxSpreadPips, AllowNewsTrading, AllowCrisisTrading,
                                      MaxAccountDrawdownPct, extraFields);

   OrchDecision dec = OrchGetDecision(ORCH_SERVER, payload);

   if(!dec.valid)
   {
      Print("ORCH | Unreachable — holding, no trade this tick");
      return;
   }

   Print("ORCH | Decision:", dec.decision, " Confidence:", DoubleToString(dec.confidence, 3),
         " Regime:", dec.regime, " Score:", DoubleToString(dec.ensemble_score, 3));

   LastRegime = dec.regime;

   bool   isOverride    = false;
   string overrideMode  = "";   // "RETEST" or "CONTINUATION"
   double sweepLevel = 0, gapTop = 0, gapBottom = 0;
   int    fvgBarsAgo = 0;

   if(dec.decision == "HOLD")
   {
      // OR-path #1: retest — Layer 6+7 as originally built. Catches a
      // sweep followed by a pullback into the FVG left on the reversal.
      if(EnableSweepFVG && CheckLiquiditySweepFVG(direction, sweepLevel, gapTop, gapBottom))
      {
         isOverride   = true;
         overrideMode = "RETEST";
         Print("=== SWEEP+FVG RETEST OVERRIDE | ORCH said HOLD, taking ", direction,
               " on Layer 6+7 confluence ===");
      }
      // OR-path #2: continuation — sweep confirmed, but instead of waiting
      // for a pullback that may never come, a fresh unfilled FVG in the
      // same direction confirms the impulse itself has conviction, so we
      // ride the move rather than only ever catching mean-reversions.
      else if(EnableContinuation && CheckSweepContinuation(direction, sweepLevel, gapTop, gapBottom, fvgBarsAgo))
      {
         if(IsFalseSweepContinuation(direction, sweepLevel))
         {
            Print("Signal: HOLD | Sweep continuation blocked — exhaustion detected");
            return;
         }
         isOverride   = true;
         overrideMode = "CONTINUATION";
         Print("=== SWEEP+CONTINUATION OVERRIDE | ORCH said HOLD, taking ", direction,
               " on sweep + fresh FVG (no retest required) ===");
      }
      else
      {
         Print("Signal: HOLD | Orchestrator declined, no Sweep+FVG override available (retest or continuation)");
         return;
      }
   }
   else
   {
      direction = dec.decision; // "BUY" or "SELL" — orchestrator is authoritative
   }

   if(isOverride && !CheckDynamicSpread(sweepLevel))
   {
      // Reuse the existing dynamic spread guard for override trades too —
      // the orchestrator path already applies its own spread check server-side,
      // but the override path bypasses the orchestrator entirely so it needs
      // this safety net applied locally. Distance is measured against the
      // swept level itself, since that's the structural reference for this signal.
      Print(overrideMode, " override skipped | Spread too wide relative to structure");
      return;
   }

   double distance;
   nearestFib = GetNearestFibLevel(price, distance);

   if(isOverride)
      Print("=== ", overrideMode, " SIGNAL | Direction: ", direction,
            " | Sweep level: ", DoubleToString(sweepLevel, 2),
            " | FVG: ", DoubleToString(gapBottom, 2), "-", DoubleToString(gapTop, 2), " ===");
   else
      Print("=== ORCHESTRATOR SIGNAL | Direction: ", direction,
            " | Confidence: ", DoubleToString(dec.confidence, 3), " ===");

   double sl, tp1, tp2, tp3;
   if(overrideMode == "RETEST")
      GetSweepFVGTradeLevels(direction, sweepLevel, gapTop, gapBottom, price, sl, tp1, tp2, tp3);
   else if(overrideMode == "CONTINUATION")
      GetContinuationTradeLevels(direction, gapTop, gapBottom, price, sl, tp1, tp2, tp3);
   else
      GetTradeLevels(direction, nearestFib, dec.regime, price, sl, tp1, tp2, tp3);

   string tradeComment = "";
   if(overrideMode == "RETEST")       tradeComment = "_SWEEPFVG";
   else if(overrideMode == "CONTINUATION") tradeComment = "_SWEEPCONT";

   string sourceTag = isOverride ? (" | Source: " + overrideMode + " OVERRIDE") : " | Source: ORCH";
   bool success = false;

   if(direction == "BUY")
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl  = NormalizeDouble(sl,  _Digits);
      tp1 = NormalizeDouble(tp1, _Digits);
      success = trade.Buy(LotSize, _Symbol, 0, sl, tp1, "MQ_BUY" + tradeComment);
      if(success)
      {
         Print("BUY executed | Ask:", ask, " SL:", sl, " TP1:", tp1,
               " TP2:", tp2, " TP3:", tp3, " | Fib:", nearestFib, sourceTag);
         EntryTime = TimeCurrent();
      }
      else Print("BUY failed: ", trade.ResultRetcodeDescription());
   }
   else if(direction == "SELL")
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl  = NormalizeDouble(sl,  _Digits);
      tp1 = NormalizeDouble(tp1, _Digits);
      success = trade.Sell(LotSize, _Symbol, 0, sl, tp1, "MQ_SELL" + tradeComment);
      if(success)
      {
         Print("SELL executed | Bid:", bid, " SL:", sl, " TP1:", tp1,
               " TP2:", tp2, " TP3:", tp3, " | Fib:", nearestFib, sourceTag);
         EntryTime = TimeCurrent();
      }
      else Print("SELL failed: ", trade.ResultRetcodeDescription());
   }
}