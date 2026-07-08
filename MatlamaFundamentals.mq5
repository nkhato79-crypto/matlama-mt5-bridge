//+------------------------------------------------------------------+
//|                                        MatlamaFundamentals.mq5   |
//|                                          Matlama Tech 2026       |
//+------------------------------------------------------------------+
#property copyright "Matlama Tech 2026"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Fundamental Bias inputs (update weekly)
input string FedBias          = "DOVISH";  // DOVISH or HAWKISH
input string InflationBias    = "HIGH";    // HIGH or LOW
input string GeopoliticalRisk = "HIGH";    // HIGH or LOW
input string DXYTrend         = "DOWN";    // DOWN or UP
input string YieldTrend       = "DOWN";    // DOWN or UP

//--- News block settings
input int    NewsBlockMins    = 30;        // Block trades X mins before HIGH news
input int    MagicMB          = 20260101;  // matlamaBridgeV3
input int    MagicScalp       = 20260103;  // MatlamaScalper
input int    MagicQuant       = 20260201;  // MatlamaQuant
input int    MagicHFT         = 20260102;  // MatlamaBridgeHFT

//--- News Calendar (update weekly, times in UTC)
//--- Format: "YYYY.MM.DD HH:MM|NAME|HIGH or LOW"
input string News1  = "2026.06.27 12:30|US Core PCE|HIGH";
input string News2  = "2026.07.01 12:30|US NFP|HIGH";
input string News3  = "2026.07.02 18:00|Fed Speech|HIGH";
input string News4  = "2026.07.08 12:30|US CPI|HIGH";
input string News5  = "";
input string News6  = "";
input string News7  = "";
input string News8  = "";
input string News9  = "";
input string News10 = "";

//--- Globals
datetime lastCheck = 0;
string   fundBias  = "NEUTRAL";
double   fundScore = 0;

//+------------------------------------------------------------------+
void CalcBias()
{
   double s = 0;
   if(FedBias          == "DOVISH") s += 1; else s -= 1;
   if(InflationBias    == "HIGH")   s += 1; else s -= 1;
   if(GeopoliticalRisk == "HIGH")   s += 1; else s -= 1;
   if(DXYTrend         == "DOWN")   s += 1; else s -= 1;
   if(YieldTrend       == "DOWN")   s += 1; else s -= 1;
   fundScore = s;
   if(s >= 3)       fundBias = "BUY";
   else if(s <= -3) fundBias = "SELL";
   else             fundBias = "NEUTRAL";
}

//+------------------------------------------------------------------+
bool IsHighNewsClose()
{
   string arr[10];
   arr[0]=News1; arr[1]=News2; arr[2]=News3; arr[3]=News4; arr[4]=News5;
   arr[5]=News6; arr[6]=News7; arr[7]=News8; arr[8]=News9; arr[9]=News10;

   for(int i = 0; i < 10; i++)
   {
      if(arr[i] == "") continue;
      string parts[];
      if(StringSplit(arr[i], '|', parts) < 3) continue;
      if(parts[2] != "HIGH") continue;
      datetime t = StringToTime(parts[0]);
      int mins   = (int)(t - TimeCurrent()) / 60;
      if(mins >= 0 && mins <= NewsBlockMins)
      {
         Print("NEWS BLOCK | ", parts[1], " in ", mins, " mins");
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
void CloseByMagic(int magic)
{
   CTrade trade;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && (int)PositionGetInteger(POSITION_MAGIC) == magic)
         trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   CalcBias();
   Print("=== MatlamaFundamentals v1 initialized ===");
   Print("Bias: ", fundBias, " | Score: ", fundScore, "/5");
   Print("Fed:", FedBias, " Inflation:", InflationBias,
         " GeoRisk:", GeopoliticalRisk, " DXY:", DXYTrend,
         " Yields:", YieldTrend);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("MatlamaFundamentals stopped.");
}

//+------------------------------------------------------------------+
void OnTick()
{
   if((TimeCurrent() - lastCheck) < 60) return;
   lastCheck = TimeCurrent();

   // Check for news block
   if(IsHighNewsClose())
   {
      CloseByMagic(MagicMB);
      CloseByMagic(MagicScalp);
      CloseByMagic(MagicQuant);
      CloseByMagic(MagicHFT);
      return;
   }

   // Log status every hour
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.min == 0)
      Print("Fundamentals | Bias:", fundBias, " Score:", fundScore, "/5");
}
