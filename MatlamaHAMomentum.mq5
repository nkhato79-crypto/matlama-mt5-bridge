//+------------------------------------------------------------------+
//|                                       MatlamaHAMomentum.mq5       |
//|                                          Matlama Tech 2026        |
//+------------------------------------------------------------------+
//|  Heikin Ashi Momentum System — standalone trend-continuation EA.  |
//|                                                                    |
//|  Heikin Ashi averages the OHLC into a smoothed candle series:      |
//|      HA_Close = (O + H + L + C) / 4                                |
//|      HA_Open  = (prev HA_Open + prev HA_Close) / 2                 |
//|      HA_High  = max(H, HA_Open, HA_Close)                          |
//|      HA_Low   = min(L, HA_Open, HA_Close)                          |
//|                                                                    |
//|  The recursion suppresses noise, so colour persistence is a much   |
//|  cleaner trend proxy than raw candles. This EA trades that:        |
//|                                                                    |
//|    - Entry on a confirmed HA colour flip or an N-candle streak     |
//|    - Body >= X * ATR, so only expansion candles qualify            |
//|    - Flat-base rule: a genuine HA momentum candle has little or no |
//|      wick on the trend side (no lower shadow in an uptrend)        |
//|    - Body expansion vs the prior candle (momentum accelerating)    |
//|    - EMA of HA close as the directional gate                       |
//|    - Higher-timeframe HA must agree                                |
//|    - ADX regime filter — HA whipsaws badly in ranges               |
//|    - Exit on colour flip or on an HA doji (momentum exhaustion)    |
//|    - R-multiple partial TP, breakeven, ATR trail                   |
//|                                                                    |
//|  HA is computed internally from raw rates, not read from an        |
//|  indicator, so the EA is self-contained and backtest-deterministic.|
//|                                                                    |
//|  NOTE: HA open/close are synthetic averages, NOT tradeable prices. |
//|  All orders, stops and targets use real bid/ask.                   |
//+------------------------------------------------------------------+
#property copyright "Matlama Tech 2026"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include "DynamicLot.mqh"
#include "PropFirmGuard.mqh"
CTrade trade;

//--- Entry style
enum ENUM_HA_ENTRY
{
   HA_ENTRY_FLIP,       // First HA candle of a new colour (early, more signals)
   HA_ENTRY_STREAK      // Nth consecutive HA candle of one colour (later, cleaner)
};

//--- Stop placement
enum ENUM_HA_SL
{
   HA_SL_ATR,           // Entry -/+ ATR multiple
   HA_SL_SIGNAL_CANDLE  // Beyond the raw low/high of the signal candle
};

//--- Identity
input int             MagicHA             = 20260802;  // Unique magic number
input string          EA_Name             = "MatlamaHAMomentum v1";

//--- Timeframes
input ENUM_TIMEFRAMES SignalTF            = PERIOD_M15; // HA signal timeframe
input bool            UseHTFFilter        = true;       // Require higher-TF HA agreement
input ENUM_TIMEFRAMES HTF                 = PERIOD_H4;  // Higher timeframe

//--- Entry rules
input ENUM_HA_ENTRY   EntryMode           = HA_ENTRY_STREAK;
input int             StreakCandles       = 2;          // Consecutive HA candles required (STREAK mode)

//--- Momentum quality (this is what separates the system from a colour-flip toy)
input double          MinBodyATR          = 0.35;       // Signal body must be >= this x ATR
input bool            RequireFlatBase     = true;       // Trend-side wick must be small
input double          MaxBaseWickPct      = 25.0;       // Trend-side wick as % of body
input bool            RequireExpansion    = true;       // Body must exceed the prior body
input double          MinExpansionRatio   = 1.0;        // body[1] >= body[2] x this

//--- Trend / regime filters
input bool            UseEMAFilter        = true;       // HA close vs its own EMA
input int             EMAPeriod           = 34;
input bool            UseADXFilter        = true;       // Block range-bound conditions
input int             ADXPeriod           = 14;
input double          MinADX              = 20.0;

//--- Risk & targets
input double          LotSize             = 0.01;
input double          RiskPercent         = 1.0;        // % equity per trade (0 = fixed lot)
input ENUM_HA_SL      SLMode              = HA_SL_ATR;
input double          SLATRMultiple       = 1.5;        // SL distance when SLMode = ATR
input double          SLBufferPips        = 3.0;        // Extra buffer in SIGNAL_CANDLE mode
input double          SLCap_ATR           = 2.0;        // Hard cap on SL distance (0 = no cap)
input double          RR_TP1              = 1.0;        // Partial target, in R
input double          RR_TP2              = 2.5;        // Final target, in R
input double          TP1_ClosePercent    = 50.0;       // % closed at TP1 (100 = single exit at TP1)
input int             ATRPeriod           = 14;

//--- Exits
input bool            ExitOnFlip          = true;       // Close when HA colour flips against us
input bool            ExitOnDoji          = false;      // Close on an HA doji (exhaustion)
input double          DojiBodyATR         = 0.10;       // Body below this x ATR counts as a doji
input bool            EnableTrailing      = true;
input double          TrailATRMultiple    = 1.5;
input double          TrailActivationR    = 1.0;        // Start trailing after this many R
input double          TrailStepPips       = 5.0;        // Minimum SL improvement before re-modifying

//--- Execution guards
input int             MaxTradesPerDay     = 6;
input double          MaxSpreadPips       = 5.0;
input int             EarliestTradeHour   = 6;          // UTC
input int             LatestTradeHour     = 21;         // UTC

//--- CSV logging
string   CSV_PATH = "ha_momentum_trades.csv";
ulong    lastLoggedTicket = 0;

//--- Indicator handles
int atrHandle = INVALID_HANDLE;
int adxHandle = INVALID_HANDLE;

//--- HA warm-up: the HA_Open recursion needs history to converge.
const int HA_WARMUP = 250;

//--- Bar gating
datetime lastSignalBar = 0;

//--- Heikin Ashi candle
struct HACandle
{
   datetime time;
   double   open;
   double   high;
   double   low;
   double   close;
   double   rawHigh;   // real candle high — stops go here, not on HA levels
   double   rawLow;
};

//+------------------------------------------------------------------+
int OnInit()
{
   if(StreakCandles < 1)
   {
      Print(EA_Name, " FATAL: StreakCandles must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
   }

   atrHandle = iATR(_Symbol, SignalTF, ATRPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print(EA_Name, " FATAL: Cannot create ATR indicator");
      return(INIT_FAILED);
   }

   if(UseADXFilter)
   {
      adxHandle = iADX(_Symbol, SignalTF, ADXPeriod);
      if(adxHandle == INVALID_HANDLE)
      {
         Print(EA_Name, " FATAL: Cannot create ADX indicator");
         return(INIT_FAILED);
      }
   }

   InitCSV();
   PropGuardInit();

   Print(EA_Name, " initialized | Magic:", MagicHA,
         " | Signal TF:", EnumToString(SignalTF),
         " | HTF:", (UseHTFFilter ? EnumToString(HTF) : "off"),
         " | Mode:", (EntryMode == HA_ENTRY_FLIP ? "FLIP" : "STREAK x" + (string)StreakCandles),
         " | MinBody:", DoubleToString(MinBodyATR, 2), "xATR",
         " | Trail:", EnableTrailing);
   Print(PropGuardStatus());
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(adxHandle != INVALID_HANDLE) IndicatorRelease(adxHandle);
   Print(EA_Name, " stopped.");
}

//+------------------------------------------------------------------+
//--- Heikin Ashi construction
//+------------------------------------------------------------------+
//  Builds `needed` HA candles as a series (index 0 = forming bar,
//  1 = last closed) plus an EMA of HA close aligned to the same index.
//  The recursion runs forward over HA_WARMUP extra bars first so the
//  synthetic open has converged before the bars we actually read.
bool BuildHASeries(ENUM_TIMEFRAMES tf, int needed, int emaPeriod,
                   HACandle &out[], double &emaOut[])
{
   if(needed < 1) return false;

   int total = needed + HA_WARMUP;
   MqlRates r[];
   ArraySetAsSeries(r, false);                  // chronological, oldest first
   int copied = CopyRates(_Symbol, tf, 0, total, r);
   if(copied < needed + 2) return false;

   double haOpen[], haClose[], ema[];
   ArrayResize(haOpen,  copied);
   ArrayResize(haClose, copied);
   ArrayResize(ema,     copied);

   double k = (emaPeriod > 0) ? 2.0 / (emaPeriod + 1.0) : 0.0;

   for(int i = 0; i < copied; i++)
   {
      haClose[i] = (r[i].open + r[i].high + r[i].low + r[i].close) / 4.0;
      haOpen[i]  = (i == 0) ? (r[i].open + r[i].close) / 2.0
                            : (haOpen[i - 1] + haClose[i - 1]) / 2.0;
      ema[i]     = (i == 0) ? haClose[i]
                            : haClose[i] * k + ema[i - 1] * (1.0 - k);
   }

   ArrayResize(out,    needed);
   ArrayResize(emaOut, needed);

   for(int s = 0; s < needed; s++)
   {
      int i = copied - 1 - s;                   // s = 0 -> newest bar
      if(i < 0) return false;

      out[s].time    = r[i].time;
      out[s].open    = haOpen[i];
      out[s].close   = haClose[i];
      out[s].high    = MathMax(r[i].high, MathMax(haOpen[i], haClose[i]));
      out[s].low     = MathMin(r[i].low,  MathMin(haOpen[i], haClose[i]));
      out[s].rawHigh = r[i].high;
      out[s].rawLow  = r[i].low;
      emaOut[s]      = ema[i];
   }
   return true;
}

//+------------------------------------------------------------------+
bool   HAIsBull(const HACandle &c)   { return (c.close > c.open); }
double HABody(const HACandle &c)     { return MathAbs(c.close - c.open); }
double HAUpperWick(const HACandle &c){ return c.high - MathMax(c.open, c.close); }
double HALowerWick(const HACandle &c){ return MathMin(c.open, c.close) - c.low; }

//+------------------------------------------------------------------+
double GetATR()
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(atrHandle, 0, 0, 2, buf) < 2) return 0;
   return buf[1];                                // last closed bar
}

//+------------------------------------------------------------------+
double GetADX()
{
   if(adxHandle == INVALID_HANDLE) return 0;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(adxHandle, 0, 0, 2, buf) < 2) return 0;
   return buf[1];
}

//+------------------------------------------------------------------+
double PipSize()
{
   return SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
}

//+------------------------------------------------------------------+
double PriceToPips(double distance)
{
   double ps = PipSize();
   if(ps <= 0) return 0;
   return distance / ps;
}

//+------------------------------------------------------------------+
//  Brokers reject stops closer than SYMBOL_TRADE_STOPS_LEVEL. Gold
//  routinely trips this, so push the level out rather than lose the fill.
double EnforceStopDistance(double price, double level, bool isStopBelow)
{
   long stopLevelPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stopLevelPts <= 0) return level;

   double minDist = stopLevelPts * SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(isStopBelow && price - level < minDist) level = price - minDist;
   if(!isStopBelow && level - price < minDist) level = price + minDist;

   return level;
}

//+------------------------------------------------------------------+
double NormPrice(double p)
{
   return NormalizeDouble(p, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

//+------------------------------------------------------------------+
//--- Filters
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
bool WithinTradingHours()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   return (dt.hour >= EarliestTradeHour && dt.hour < LatestTradeHour);
}

//+------------------------------------------------------------------+
//  Higher-timeframe HA must be the same colour as the signal.
bool HTFAgrees(bool wantBull)
{
   if(!UseHTFFilter) return true;

   HACandle htf[];
   double   htfEma[];
   if(!BuildHASeries(HTF, 3, EMAPeriod, htf, htfEma))
   {
      Print(EA_Name, " | HTF filter: insufficient ", EnumToString(HTF), " history");
      return false;
   }

   bool htfBull = HAIsBull(htf[1]);
   if(htfBull != wantBull)
   {
      Print(EA_Name, " | HTF FILTER | ", EnumToString(HTF), " HA is ",
            (htfBull ? "BULL" : "BEAR"), ", signal wants ", (wantBull ? "BULL" : "BEAR"));
      return false;
   }
   return true;
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
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == MagicHA &&
         HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_IN)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == MagicHA &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//--- Signal detection
//+------------------------------------------------------------------+
//  Returns "BUY", "SELL" or "" for the last closed candle. `reason`
//  carries the rejection cause so the journal explains every skip.
string DetectSignal(const HACandle &ha[], const double &ema[], double atr, string &reason)
{
   reason = "";

   //--- Need index 1..StreakCandles+1
   int need = (EntryMode == HA_ENTRY_FLIP) ? 3 : StreakCandles + 2;
   if(ArraySize(ha) < need)
   {
      reason = "insufficient HA history";
      return "";
   }

   bool bull = HAIsBull(ha[1]);

   //--- Colour pattern
   if(EntryMode == HA_ENTRY_FLIP)
   {
      // ha[1] is the first candle of a new colour
      if(HAIsBull(ha[2]) == bull)
      {
         reason = "no flip on last closed candle";
         return "";
      }
   }
   else
   {
      // ha[1..StreakCandles] share a colour, and the candle before them does not,
      // so the streak fires exactly once per trend leg instead of on every bar.
      for(int i = 1; i <= StreakCandles; i++)
      {
         if(HAIsBull(ha[i]) != bull)
         {
            reason = "streak broken at bar -" + (string)i;
            return "";
         }
      }
      if(HAIsBull(ha[StreakCandles + 1]) == bull)
      {
         reason = "streak already running (not the " + (string)StreakCandles + "th candle)";
         return "";
      }
   }

   //--- Body must be an expansion candle, not a drift
   double body = HABody(ha[1]);
   if(atr > 0 && body < MinBodyATR * atr)
   {
      reason = "body " + DoubleToString(body / atr, 2) + "xATR < " + DoubleToString(MinBodyATR, 2);
      return "";
   }

   //--- Flat base: a true HA momentum candle has almost no wick on the trend side
   if(RequireFlatBase && body > 0)
   {
      double baseWick = bull ? HALowerWick(ha[1]) : HAUpperWick(ha[1]);
      double pct = baseWick / body * 100.0;
      if(pct > MaxBaseWickPct)
      {
         reason = "base wick " + DoubleToString(pct, 1) + "% of body > " +
                  DoubleToString(MaxBaseWickPct, 1) + "%";
         return "";
      }
   }

   //--- Momentum accelerating
   if(RequireExpansion)
   {
      double prevBody = HABody(ha[2]);
      if(prevBody > 0 && body < prevBody * MinExpansionRatio)
      {
         reason = "body not expanding (" + DoubleToString(body / prevBody, 2) + "x prior)";
         return "";
      }
   }

   //--- Directional gate
   if(UseEMAFilter && ArraySize(ema) > 1)
   {
      if(bull && ha[1].close <= ema[1])
      {
         reason = "HA close below EMA" + (string)EMAPeriod;
         return "";
      }
      if(!bull && ha[1].close >= ema[1])
      {
         reason = "HA close above EMA" + (string)EMAPeriod;
         return "";
      }
   }

   //--- Regime gate: HA colour is meaningless in chop
   if(UseADXFilter)
   {
      double adx = GetADX();
      if(adx > 0 && adx < MinADX)
      {
         reason = "ADX " + DoubleToString(adx, 1) + " < " + DoubleToString(MinADX, 1);
         return "";
      }
   }

   return (bull ? "BUY" : "SELL");
}

//+------------------------------------------------------------------+
//--- Entry
//+------------------------------------------------------------------+
void OpenTrade(string dir, const HACandle &ha[], double atr)
{
   if(SLMode == HA_SL_ATR && atr <= 0)
   {
      Print(EA_Name, " | ABORT | ATR unavailable, cannot size the stop");
      return;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry = (dir == "BUY") ? ask : bid;
   double buffer = SLBufferPips * PipSize();

   //--- Stop placement. HA levels are synthetic averages, so the candle-based
   //--- stop uses the RAW low/high — the price that actually traded.
   double sl;
   if(SLMode == HA_SL_SIGNAL_CANDLE)
      sl = (dir == "BUY") ? ha[1].rawLow - buffer : ha[1].rawHigh + buffer;
   else
      sl = (dir == "BUY") ? entry - SLATRMultiple * atr : entry + SLATRMultiple * atr;

   //--- Cap runaway stops
   if(SLCap_ATR > 0 && atr > 0)
   {
      double maxDist = SLCap_ATR * atr;
      if(dir == "BUY" && entry - sl > maxDist)
      {
         Print(EA_Name, " | SL CAP | BUY SL ", DoubleToString(sl, 2),
               " -> ", DoubleToString(entry - maxDist, 2));
         sl = entry - maxDist;
      }
      if(dir == "SELL" && sl - entry > maxDist)
      {
         Print(EA_Name, " | SL CAP | SELL SL ", DoubleToString(sl, 2),
               " -> ", DoubleToString(entry + maxDist, 2));
         sl = entry + maxDist;
      }
   }

   sl = EnforceStopDistance(entry, sl, dir == "BUY");
   sl = NormPrice(sl);

   double risk = MathAbs(entry - sl);
   if(risk <= 0)
   {
      Print(EA_Name, " | ABORT | zero stop distance");
      return;
   }

   double tp1 = (dir == "BUY") ? entry + risk * RR_TP1 : entry - risk * RR_TP1;
   double tp2 = (dir == "BUY") ? entry + risk * RR_TP2 : entry - risk * RR_TP2;

   //--- With a partial exit the order carries TP2; TP1 is managed in code.
   double tp = (TP1_ClosePercent >= 100.0) ? tp1 : tp2;
   tp = EnforceStopDistance(entry, tp, dir == "SELL");
   tp = NormPrice(tp);

   double slPips = PriceToPips(risk);
   double lot = CalcDynamicLot(_Symbol, slPips, PropGuardClampRisk(RiskPercent), LotSize);

   trade.SetExpertMagicNumber(MagicHA);
   string comment = EA_Name + " " + dir;

   bool ok = (dir == "BUY") ? trade.Buy(lot, _Symbol, ask, sl, tp, comment)
                            : trade.Sell(lot, _Symbol, bid, sl, tp, comment);
   if(!ok)
   {
      Print(EA_Name, " | ORDER FAILED | ", dir, " retcode:", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription());
      return;
   }

   PropGuardOnTrade();

   ulong posTicket = trade.ResultOrder();
   if(posTicket > 0)
   {
      GlobalVariableSet("HAM_Risk_"   + (string)posTicket, risk);
      GlobalVariableSet("HAM_Entry_"  + (string)posTicket, entry);
      GlobalVariableSet("HAM_TP1_"    + (string)posTicket, tp1);
      GlobalVariableSet("HAM_TP1Done_"+ (string)posTicket, 0);
   }

   Print(EA_Name, " | ", dir, " @", DoubleToString(entry, 2),
         " SL:", DoubleToString(sl, 2),
         " TP1:", DoubleToString(tp1, 2),
         " TP2:", DoubleToString(tp2, 2),
         " Lot:", DoubleToString(lot, 2),
         " Risk:", DoubleToString(slPips, 1), "pips",
         " | Body:", DoubleToString(atr > 0 ? HABody(ha[1]) / atr : 0, 2), "xATR",
         " ADX:", DoubleToString(GetADX(), 1));
}

//+------------------------------------------------------------------+
//--- Position management
//+------------------------------------------------------------------+
void ManageOpenPositions(const HACandle &ha[], double atr, bool newBar)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicHA) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long   posType = PositionGetInteger(POSITION_TYPE);
      double openPr  = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL   = PositionGetDouble(POSITION_SL);
      double curTP   = PositionGetDouble(POSITION_TP);
      double volume  = PositionGetDouble(POSITION_VOLUME);
      string posKey  = (string)ticket;

      bool isBuy = (posType == POSITION_TYPE_BUY);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double risk = 0, tp1 = 0;
      bool hasGV = GlobalVariableCheck("HAM_Risk_" + posKey);
      if(hasGV)
      {
         risk = GlobalVariableGet("HAM_Risk_" + posKey);
         tp1  = GlobalVariableGet("HAM_TP1_"  + posKey);
      }
      if(risk <= 0) risk = MathAbs(openPr - curSL);
      if(risk <= 0) continue;

      trade.SetExpertMagicNumber(MagicHA);

      //--- Signal-based exits, evaluated once per closed candle
      if(newBar && ArraySize(ha) > 1)
      {
         bool haBull = HAIsBull(ha[1]);

         if(ExitOnFlip && haBull != isBuy)
         {
            Print(EA_Name, " | EXIT ON FLIP | HA turned ", (haBull ? "BULL" : "BEAR"),
                  " against ", (isBuy ? "LONG" : "SHORT"));
            trade.PositionClose(ticket);
            continue;
         }

         if(ExitOnDoji && atr > 0 && HABody(ha[1]) < DojiBodyATR * atr)
         {
            Print(EA_Name, " | EXIT ON DOJI | body ",
                  DoubleToString(HABody(ha[1]) / atr, 3), "xATR — momentum stalled");
            trade.PositionClose(ticket);
            continue;
         }
      }

      //--- Partial close at TP1, then breakeven on the remainder
      if(hasGV && TP1_ClosePercent > 0 && TP1_ClosePercent < 100.0 && tp1 > 0)
      {
         double tp1Done = GlobalVariableGet("HAM_TP1Done_" + posKey);
         bool tp1Hit = (isBuy && bid >= tp1) || (!isBuy && ask <= tp1);

         if(tp1Done < 1 && tp1Hit)
         {
            double closeLot = volume * TP1_ClosePercent / 100.0;
            double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
            double lotStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
            if(lotStep > 0) closeLot = MathFloor(closeLot / lotStep) * lotStep;
            closeLot = NormalizeDouble(closeLot, 2);

            //--- Only split when both halves are tradeable sizes.
            if(closeLot >= minLot && volume - closeLot >= minLot)
            {
               if(trade.PositionClosePartial(ticket, closeLot))
               {
                  GlobalVariableSet("HAM_TP1Done_" + posKey, 1);
                  Print(EA_Name, " | TP1 partial ", DoubleToString(closeLot, 2),
                        " lots @ ", DoubleToString(isBuy ? bid : ask, 2));

                  double bePrice = NormPrice(openPr);
                  bool beValid = isBuy ? (bePrice > curSL) : (bePrice < curSL || curSL == 0);
                  if(beValid && trade.PositionModify(ticket, bePrice, curTP))
                     Print(EA_Name, " | SL to breakeven: ", DoubleToString(bePrice, 2));
               }
               else
               {
                  Print(EA_Name, " | TP1 partial FAILED retcode:", trade.ResultRetcode());
               }
            }
            else
            {
               //--- Too small to split; let the order's TP handle the exit.
               GlobalVariableSet("HAM_TP1Done_" + posKey, 1);
            }
            continue;
         }
      }

      //--- ATR trailing stop, activated after TrailActivationR
      if(EnableTrailing && atr > 0)
      {
         double trailDist  = atr * TrailATRMultiple;
         double activation = risk * TrailActivationR;

         //--- Without a minimum step the stop ratchets on every tick, which
         //--- floods the broker with modify requests for a fraction of a pip.
         double trailStep = TrailStepPips * PipSize();

         if(isBuy)
         {
            if(bid - openPr >= activation)
            {
               double newSL = NormPrice(bid - trailDist);
               newSL = EnforceStopDistance(bid, newSL, true);
               if(newSL < bid && (curSL == 0 || newSL >= curSL + trailStep))
                  trade.PositionModify(ticket, newSL, curTP);
            }
         }
         else
         {
            if(openPr - ask >= activation)
            {
               double newSL = NormPrice(ask + trailDist);
               newSL = EnforceStopDistance(ask, newSL, false);
               if(newSL > ask && (curSL == 0 || newSL <= curSL - trailStep))
                  trade.PositionModify(ticket, newSL, curTP);
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
         FileWrite(handle, "ticket","symbol","type","open_time","close_time",
                   "open_price","close_price","volume","profit","risk_pips","r_multiple");
         FileClose(handle);
      }
   }
   else FileClose(handle);

   string gvTicket = "HAM_LastLoggedTicket_" + _Symbol + "_" + (string)MagicHA;
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
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicHA) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      if(ticket <= lastLoggedTicket) continue;

      ulong positionId = (ulong)HistoryDealGetInteger(ticket, DEAL_POSITION_ID);

      //--- A TP1 partial also produces a DEAL_ENTRY_OUT. If the position is
      //--- still open this is that partial — wait for the final exit so the
      //--- row (and the R multiple) describes the whole trade.
      if(PositionSelectByTicket(positionId)) continue;

      string posKey = (string)positionId;

      double openPrice = 0;
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

      double risk = 0;
      if(GlobalVariableCheck("HAM_Risk_" + posKey))
      {
         risk = GlobalVariableGet("HAM_Risk_" + posKey);
         if(openPrice == 0 && GlobalVariableCheck("HAM_Entry_" + posKey))
            openPrice = GlobalVariableGet("HAM_Entry_" + posKey);
      }

      double closePrice = HistoryDealGetDouble(ticket, DEAL_PRICE);
      // A closing SELL deal means the position was a BUY, and vice versa.
      bool wasBuy = (HistoryDealGetInteger(ticket, DEAL_TYPE) == DEAL_TYPE_SELL);
      double rMultiple = 0;
      if(risk > 0 && openPrice > 0)
         rMultiple = (wasBuy ? closePrice - openPrice : openPrice - closePrice) / risk;

      int handle = FileOpen(CSV_PATH, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ);
      if(handle != INVALID_HANDLE)
      {
         FileSeek(handle, 0, SEEK_END);
         FileWrite(handle, ticket, _Symbol, (wasBuy ? "BUY" : "SELL"),
                   TimeToString(HistoryDealGetInteger(ticket, DEAL_TIME)),
                   TimeToString(TimeCurrent()),
                   openPrice, closePrice,
                   HistoryDealGetDouble(ticket, DEAL_VOLUME),
                   HistoryDealGetDouble(ticket, DEAL_PROFIT),
                   DoubleToString(PriceToPips(risk), 1),
                   DoubleToString(rMultiple, 2));
         FileClose(handle);
      }

      //--- Position is finished; drop its bookkeeping.
      GlobalVariableDel("HAM_Risk_"    + posKey);
      GlobalVariableDel("HAM_Entry_"   + posKey);
      GlobalVariableDel("HAM_TP1_"     + posKey);
      GlobalVariableDel("HAM_TP1Done_" + posKey);

      lastLoggedTicket = ticket;
      GlobalVariableSet("HAM_LastLoggedTicket_" + _Symbol + "_" + (string)MagicHA,
                        (double)lastLoggedTicket);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   PropGuardOnTick();

   //--- Signal work is bar-close driven; management runs every tick. The HA
   //--- recursion needs a few hundred bars, so only rebuild it once per bar.
   datetime curBar = iTime(_Symbol, SignalTF, 0);
   if(curBar == 0) return;
   bool newBar = (curBar != lastSignalBar);

   double   atr = GetATR();
   HACandle ha[];
   double   ema[];
   bool     haReady = false;

   if(newBar)
   {
      int needed = ((EntryMode == HA_ENTRY_FLIP) ? 3 : StreakCandles + 2) + 1;
      haReady = BuildHASeries(SignalTF, needed, EMAPeriod, ha, ema);
   }

   ManageOpenPositions(ha, atr, newBar && haReady);
   LogClosedTrades();

   if(!newBar) return;
   lastSignalBar = curBar;
   if(!haReady) return;

   //--- One position at a time — this is a momentum system, not a grid.
   if(HasOpenPosition()) return;
   if(!WithinTradingHours()) return;
   if(CountTradesToday() >= MaxTradesPerDay) return;
   if(!PropGuardCanTrade()) return;

   string reason = "";
   string signal = DetectSignal(ha, ema, atr, reason);
   if(signal == "")
   {
      if(reason != "" && StringFind(reason, "streak already running") < 0 &&
         StringFind(reason, "no flip") < 0)
         Print(EA_Name, " | NO TRADE | ", reason);
      return;
   }

   if(!HTFAgrees(signal == "BUY")) return;
   if(!PassesSpreadFilter()) return;

   OpenTrade(signal, ha, atr);
}
//+------------------------------------------------------------------+
