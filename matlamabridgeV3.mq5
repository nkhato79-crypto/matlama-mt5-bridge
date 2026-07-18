//+------------------------------------------------------------------+
//|                                            MatlamaBridgeV3.mq5   |
//|                                          Matlama Tech © 2026     |
//|                     Self-contained 9-layer signal engine         |
//+------------------------------------------------------------------+
#property copyright "Matlama Tech 2026"
#property version   "5.00"
#property strict

#include <Trade\Trade.mqh>
#include "OrchestratorClient.mqh"

//--- Input Parameters
input string   EA_Name        = "MatlamaBridge v5";
input double   LotSize        = 0.01;
input int      SL_Pips        = 50;
input int      TP_Pips        = 100;
input int      Slippage       = 10;
input int      PollSeconds    = 30;
input int      MagicNumber    = 20260101;
input bool     AutoTrade      = false;
input double   MaxDailyLoss   = 100.0;

//--- COT & Gamma (update weekly)
input string   COT_Bias       = "BUY";
input double   DealerGamma    = -0.5;
input int      ScoreThreshold = 5;

//--- Volume settings
input int      VolumePeriod   = 20;
input double   VolumeMultiple = 1.5;

//--- RSI settings
input int      RSI_Period     = 14;
input int      RSI_OB         = 70;
input int      RSI_OS         = 30;

//--- MACD settings
input int      MACD_Fast      = 12;
input int      MACD_Slow      = 26;
input int      MACD_Signal    = 9;

//--- ADX settings
input int      ADX_Period     = 14;
input int      ADX_MinLevel   = 25;

//--- Orchestrator v2 Settings (full override — replaces 9-layer scoring)
input string   ORCH_SERVER            = "http://127.0.0.1:7000/decision_v2";
input string   ORCH_REPORT            = "http://127.0.0.1:7000/report_trade";
input double   MaxSpreadPips          = 5.0;
input bool     AllowNewsTrading       = false;
input bool     AllowCrisisTrading     = false;
input double   MaxAccountDrawdownPct  = 0.20;

//--- Global Variables
CTrade   trade;
datetime LastCheck        = 0;
string   LastSignal       = "";
datetime LastSignalBar    = 0;
double   dailyStartBalance;
datetime dailyResetTime;
int      atrHandle;
int      rsiHandle;
int      macdHandle;
int      adxHandle;
int      emaFastHandle;
int      emaSlowHandle;
string   LastRegime = "UNKNOWN";
int      entryBuyScore   = 0;
int      entrySellScore  = 0;

//--- CSV logging
string   CSV_PATH = "bridgev3_trades.csv"; // renamed from hft_trades.csv — was colliding with MatlamaBridgeHFT.mq5, which writes to the same filename with incompatible column meaning
ulong    lastLoggedTicket = 0;

//+------------------------------------------------------------------+
//| Write CSV header if file doesn't exist                           |
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
            "buy_score","sell_score","signal_score");
         FileClose(handle);
         Print("CSV initialized: ", CSV_PATH);
      }
   }
   else FileClose(handle);
}

//+------------------------------------------------------------------+
//| Log closed trades to CSV — FIXED: append mode, no truncation    |
//+------------------------------------------------------------------+
void LogClosedTrades()
{
   HistorySelect(TimeCurrent() - 86400*7, TimeCurrent());
   int total = HistoryDealsTotal();
   if(total == 0) return;

   // Check if there are any new trades before opening file
   bool hasNew = false;
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(ticket <= lastLoggedTicket) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      hasNew = true;
      break;
   }
   if(!hasNew) return;

   // Open in append mode — READ|WRITE then seek to end
   int handle = FileOpen(CSV_PATH,
                         FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ',');
   if(handle == INVALID_HANDLE)
   {
      Print("CSV ERROR: Cannot open for append. Error:", GetLastError());
      return;
   }
   FileSeek(handle, 0, SEEK_END);

   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(ticket <= lastLoggedTicket) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;

      long dealEntry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(dealEntry != DEAL_ENTRY_OUT) continue;

      long     dtype     = HistoryDealGetInteger(ticket, DEAL_TYPE);
      string   typeStr   = (dtype == DEAL_TYPE_BUY) ? "BUY" : "SELL";
      datetime closeTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
      double   closePrice = HistoryDealGetDouble(ticket, DEAL_PRICE);
      double   volume    = HistoryDealGetDouble(ticket, DEAL_VOLUME);
      double   profit    = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      double   swap      = HistoryDealGetDouble(ticket, DEAL_SWAP);
      double   comm      = HistoryDealGetDouble(ticket, DEAL_COMMISSION);

      double   openPrice = 0;
      datetime entryTime = 0;
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
      int bScore = entryBuyScore;
      int sScore = entrySellScore;

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
         (string)bScore,
         (string)sScore,
         (string)MathMax(bScore, sScore)
      );

      lastLoggedTicket = ticket;
      Print("Trade logged | Ticket:", ticket, " Profit:", profit);

      int winFlag = (profit > 0) ? 1 : 0;
      OrchReportTrade(ORCH_REPORT, "MBV3", LastRegime, winFlag, profit);
   }

   FileClose(handle);
}

//+------------------------------------------------------------------+
int OnInit()
{
   atrHandle  = iATR(_Symbol,  PERIOD_H1, 14);
   rsiHandle  = iRSI(_Symbol,  PERIOD_H1, RSI_Period, PRICE_CLOSE);
   macdHandle = iMACD(_Symbol, PERIOD_H1, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   adxHandle  = iADX(_Symbol,  PERIOD_H1, ADX_Period);
   emaFastHandle = iMA(_Symbol, PERIOD_H1, 12, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(_Symbol, PERIOD_H1, 26, 0, MODE_EMA, PRICE_CLOSE);

   if(atrHandle  == INVALID_HANDLE || rsiHandle == INVALID_HANDLE ||
      macdHandle == INVALID_HANDLE || adxHandle == INVALID_HANDLE ||
      emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE)
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
   Print("Symbol: ",     _Symbol);
   Print("AutoTrade: ",  AutoTrade ? "ENABLED" : "DISABLED");
   Print("COT Bias: ",   COT_Bias);
   Print("Threshold: ",  ScoreThreshold, "/9");
   Print("CSV Logging: ENABLED → ", CSV_PATH);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle  != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(rsiHandle  != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(macdHandle != INVALID_HANDLE) IndicatorRelease(macdHandle);
   if(adxHandle  != INVALID_HANDLE) IndicatorRelease(adxHandle);
   if(emaFastHandle != INVALID_HANDLE) IndicatorRelease(emaFastHandle);
   if(emaSlowHandle != INVALID_HANDLE) IndicatorRelease(emaSlowHandle);
   Print(EA_Name, " stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
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

   if((TimeCurrent() - LastCheck) < PollSeconds) return;
   LastCheck = TimeCurrent();

   datetime currentBar = iTime(_Symbol, PERIOD_H1, 0);
   if(currentBar != LastSignalBar)
   {
      LastSignal = "";
      LastSignalBar = currentBar;
   }

   // === ORCHESTRATOR v2 — FULL OVERRIDE ===
   // The 9-layer scoring model (EvaluateSignal) is bypassed; the orchestrator's
   // decision (BUY/SELL/HOLD) is authoritative.

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

   double volatility = OrchCalcVolatility(_Symbol, PERIOD_H1, 20);
   double momentum   = OrchCalcMomentum(_Symbol, PERIOD_H1, 10);

   long volBuf2[]; ArraySetAsSeries(volBuf2, true);
   double volume = 0;
   if(CopyTickVolume(_Symbol, PERIOD_M1, 0, 1, volBuf2) > 0) volume = (double)volBuf2[0];

   int newsRisk = 0; // wire to a news calendar feed if/when available

   // Live, non-gating computation of BridgeV3's own 9-layer scores. These
   // no longer gate entry (orchestrator is authoritative), but the
   // orchestrator's dedicated MBV3 model was trained on exactly these
   // features, so they must be supplied for a meaningful prediction.
   int    bScoreLive   = EvaluateSignal("BUY");
   int    sScoreLive   = EvaluateSignal("SELL");
   int    sigScoreLive = MathMax(bScoreLive, sScoreLive);
   string extraFields  = "\"buy_score\":" + (string)bScoreLive +
                          ",\"sell_score\":" + (string)sScoreLive +
                          ",\"signal_score\":" + (string)sigScoreLive;

   string payload = OrchBuildPayload("MBV3", price, spread, atr, adx, volatility, momentum,
                                      volume, rsi, emaFast, emaSlow, newsRisk,
                                      MaxSpreadPips, AllowNewsTrading, AllowCrisisTrading,
                                      MaxAccountDrawdownPct, extraFields);

   OrchDecision dec = OrchGetDecision(ORCH_SERVER, payload);

   if(!dec.valid)
   {
      Print("ORCH | Unreachable — holding, no trade this tick");
      return;
   }

   LastRegime = dec.regime;

   string action = dec.decision; // "BUY" / "SELL" / "HOLD" — orchestrator is authoritative
   int    score  = (int)MathRound(dec.confidence * 9); // scaled for CSV/print continuity

   Print("Signal: ", action,
         " | ORCH confidence=",  DoubleToString(dec.confidence, 3),
         " | Regime=", dec.regime,
         " | Ensemble=", DoubleToString(dec.ensemble_score, 3),
         " | Gold: $", DoubleToString(price, 2));

   if(!AutoTrade || action == "HOLD") return;
   if(action == LastSignal) return;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetTicket(i) > 0 &&
         PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
      {
         Print("Position already open. Skipping.");
         return;
      }
   }

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
      if(success) Print("BUY executed | Ask:", ask, " SL:", sl, " TP:", tp);
      else        Print("BUY failed: ", trade.ResultRetcodeDescription());
   }
   else if(action == "SELL")
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = NormalizeDouble(bid + sl_dist, _Digits);
      double tp  = NormalizeDouble(bid - tp_dist, _Digits);
      success    = trade.Sell(LotSize, _Symbol, 0, sl, tp, "MB_SELL");
      if(success) Print("SELL executed | Bid:", bid, " SL:", sl, " TP:", tp);
      else        Print("SELL failed: ", trade.ResultRetcodeDescription());
   }

   if(success)
   {
      LastSignal = action;
      entryBuyScore  = EvaluateSignal("BUY");
      entrySellScore = EvaluateSignal("SELL");
   }
}

//+------------------------------------------------------------------+
int EvaluateSignal(string direction)
{
   int score = 0;
   if(COT_Bias == "NEUTRAL")      score++;
   else if(COT_Bias == direction) score++;
   if(direction == "BUY"  && DealerGamma <= 0) score++;
   if(direction == "SELL" && DealerGamma >= 0) score++;
   if(CheckStructure(direction))   score++;
   if(CheckPriceAction(direction)) score++;
   if(CheckPatterns(direction))    score++;
   if(CheckVolume(direction))      score++;
   if(CheckRSI(direction))         score++;
   if(CheckMACD(direction))        score++;
   if(CheckADX(direction))         score++;
   return score;
}

bool CheckStructure(string direction)
{
   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows,  true);
   if(CopyHigh(_Symbol, PERIOD_H1, 0, 20, highs) < 20) return false;
   if(CopyLow(_Symbol,  PERIOD_H1, 0, 20, lows)  < 20) return false;
   double rH=highs[0],rL=lows[0],pH=highs[5],pL=lows[5];
   for(int i=1;i<5;i++) { if(highs[i]>rH) rH=highs[i]; if(lows[i]<rL) rL=lows[i]; }
   for(int i=5;i<10;i++){ if(highs[i]>pH) pH=highs[i]; if(lows[i]<pL) pL=lows[i]; }
   if(direction == "BUY") return (rH > pH && rL > pL);
   return (rH < pH && rL < pL);
}

bool CheckPriceAction(string direction)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_H1, 0, 3, rates) < 3) return false;
   double body=MathAbs(rates[0].close-rates[0].open);
   if(body==0) return false;
   double wickUp  =rates[0].high -MathMax(rates[0].close,rates[0].open);
   double wickDown=MathMin(rates[0].close,rates[0].open)-rates[0].low;
   if(direction=="BUY") return (rates[0].close>rates[0].open && wickDown<body*0.5);
   return (rates[0].close<rates[0].open && wickUp<body*0.5);
}

bool CheckPatterns(string direction)
{
   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows,  true);
   if(CopyHigh(_Symbol, PERIOD_H4, 0, 30, highs) < 30) return false;
   if(CopyLow(_Symbol,  PERIOD_H4, 0, 30, lows)  < 30) return false;
   if(direction == "BUY")
   {
      double l1=lows[10],l2=lows[20];
      for(int i=10;i<20;i++) if(lows[i]<l1) l1=lows[i];
      for(int i=20;i<30;i++) if(lows[i]<l2) l2=lows[i];
      if(l1==0) return false;
      return (MathAbs(l1-l2)/l1 < 0.005);
   }
   double h1=highs[10],h2=highs[20];
   for(int i=10;i<20;i++) if(highs[i]>h1) h1=highs[i];
   for(int i=20;i<30;i++) if(highs[i]>h2) h2=highs[i];
   if(h1==0) return false;
   return (MathAbs(h1-h2)/h1 < 0.005);
}

bool CheckVolume(string direction)
{
   long volBuf[];
   ArraySetAsSeries(volBuf, true);
   if(CopyTickVolume(_Symbol, PERIOD_H1, 0, VolumePeriod+1, volBuf) < VolumePeriod+1) return false;
   double avgVol=0;
   for(int i=1;i<=VolumePeriod;i++) avgVol+=(double)volBuf[i];
   avgVol/=VolumePeriod;
   bool volConfirms=(double)volBuf[0]>=avgVol*VolumeMultiple;
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_H1, 0, 2, rates) < 2) return false;
   if(direction=="BUY") return (volConfirms && rates[0].close>rates[0].open);
   return (volConfirms && rates[0].close<rates[0].open);
}

bool CheckRSI(string direction)
{
   double rsiBuf[];
   ArraySetAsSeries(rsiBuf, true);
   if(CopyBuffer(rsiHandle, 0, 0, 3, rsiBuf) < 3) return false;
   double rsi=rsiBuf[0], rsiPrev=rsiBuf[1];
   if(direction=="BUY")
      return ((rsiPrev<RSI_OS && rsi>RSI_OS)||(rsi>50 && rsi>rsiPrev));
   return ((rsiPrev>RSI_OB && rsi<RSI_OB)||(rsi<50 && rsi<rsiPrev));
}

bool CheckMACD(string direction)
{
   double macdMain[], macdSignal[];
   ArraySetAsSeries(macdMain,   true);
   ArraySetAsSeries(macdSignal, true);
   if(CopyBuffer(macdHandle, 0, 0, 3, macdMain)   < 3) return false;
   if(CopyBuffer(macdHandle, 1, 0, 3, macdSignal) < 3) return false;
   double macd=macdMain[0], signal=macdSignal[0], macdPrev=macdMain[1];
   if(direction=="BUY")
   {
      bool crossUp   =(macdPrev<macdSignal[1] && macd>signal);
      bool aboveZero =(macd>0 && macd>macdPrev);
      return (crossUp||aboveZero);
   }
   bool crossDown =(macdPrev>macdSignal[1] && macd<signal);
   bool belowZero =(macd<0 && macd<macdPrev);
   return (crossDown||belowZero);
}

bool CheckADX(string direction)
{
   double adxBuf[], diPlus[], diMinus[];
   ArraySetAsSeries(adxBuf,  true);
   ArraySetAsSeries(diPlus,  true);
   ArraySetAsSeries(diMinus, true);
   if(CopyBuffer(adxHandle, 0, 0, 3, adxBuf)  < 3) return false;
   if(CopyBuffer(adxHandle, 1, 0, 3, diPlus)  < 3) return false;
   if(CopyBuffer(adxHandle, 2, 0, 3, diMinus) < 3) return false;
   double adx=adxBuf[0], dip=diPlus[0], dim=diMinus[0];
   if(adx < ADX_MinLevel) return false;
   if(direction=="BUY") return (dip>dim);
   return (dim>dip);
}