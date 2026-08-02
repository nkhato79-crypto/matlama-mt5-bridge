//+------------------------------------------------------------------+
//|                                           PropFirmGuard.mqh      |
//|                                       Matlama Tech © 2026        |
//|  Prop firm compliance layer — FXIFY rules enforced across all    |
//|  EAs via MT5 Global Variables (shared state).                    |
//|                                                                   |
//|  Every EA #includes this and calls:                               |
//|    PropGuardInit()     — in OnInit                                |
//|    PropGuardCanTrade() — before every entry (returns false=block) |
//|    PropGuardOnTrade()  — after opening a position                 |
//|    PropGuardOnTick()   — in OnTick for weekend close + drawdown  |
//+------------------------------------------------------------------+
#property copyright "Matlama Tech 2026"
#property strict

#include <Trade\Trade.mqh>

//--- Prop firm inputs (override per-EA if needed, but defaults are FXIFY-safe)
input double   PF_DailyDrawdownPct   = 4.0;    // max daily loss as % of STARTING daily balance (FXIFY=5%, we use 4% buffer)
input double   PF_MaxDrawdownPct     = 8.0;    // max overall loss as % of INITIAL balance (FXIFY=10%, we use 8% buffer)
input int      PF_MaxTotalPositions  = 3;      // max simultaneous positions across ALL EAs
input int      PF_MaxDailyTrades     = 12;     // max total trades per day across ALL EAs
input double   PF_MaxRiskPerTrade    = 0.5;    // cap risk % per individual trade
input int      PF_FridayCutoffHour   = 20;     // close all positions Friday at this UTC hour (0=disabled)
input bool     PF_Enabled            = true;   // master switch

//--- Global Variable keys (shared across all EAs on this terminal)
string GV_INITIAL_BALANCE;
string GV_DAILY_START_BALANCE;
string GV_DAILY_RESET_DAY;
string GV_HIGH_WATER_MARK;
string GV_TOTAL_POSITIONS;
string GV_DAILY_TRADE_COUNT;
string GV_DAILY_TRADE_DAY;
string GV_HALTED;

bool   _pfInitialized = false;


void PropGuardInit()
{
   string prefix = "PF_GUARD_";
   GV_INITIAL_BALANCE     = prefix + "InitBal";
   GV_DAILY_START_BALANCE = prefix + "DailyBal";
   GV_DAILY_RESET_DAY     = prefix + "DailyDay";
   GV_HIGH_WATER_MARK     = prefix + "HWM";
   GV_TOTAL_POSITIONS     = prefix + "TotalPos";
   GV_DAILY_TRADE_COUNT   = prefix + "DailyTrades";
   GV_DAILY_TRADE_DAY     = prefix + "TradeDay";
   GV_HALTED              = prefix + "HALTED";

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(!GlobalVariableCheck(GV_INITIAL_BALANCE) || GlobalVariableGet(GV_INITIAL_BALANCE) <= 0)
   {
      GlobalVariableSet(GV_INITIAL_BALANCE, balance);
      Print("[PropGuard] Initial balance set: ", balance);
   }

   if(!GlobalVariableCheck(GV_HIGH_WATER_MARK) || GlobalVariableGet(GV_HIGH_WATER_MARK) < balance)
   {
      GlobalVariableSet(GV_HIGH_WATER_MARK, balance);
   }

   _ResetDailyIfNeeded();

   _pfInitialized = true;
   Print("[PropGuard] FXIFY mode ON | Daily DD cap: ", PF_DailyDrawdownPct,
         "% | Max DD cap: ", PF_MaxDrawdownPct, "% | Max positions: ", PF_MaxTotalPositions,
         " | Friday cutoff: ", PF_FridayCutoffHour, "h UTC");
}


void _ResetDailyIfNeeded()
{
   MqlDateTime now;
   TimeToStruct(TimeGMT(), now);
   int today = now.day;

   double storedDay = 0;
   if(GlobalVariableCheck(GV_DAILY_RESET_DAY))
      storedDay = GlobalVariableGet(GV_DAILY_RESET_DAY);

   if((int)storedDay != today)
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      GlobalVariableSet(GV_DAILY_START_BALANCE, balance);
      GlobalVariableSet(GV_DAILY_RESET_DAY, (double)today);
      GlobalVariableSet(GV_DAILY_TRADE_COUNT, 0);
      GlobalVariableSet(GV_DAILY_TRADE_DAY, (double)today);
      GlobalVariableSet(GV_HALTED, 0);

      if(balance > GlobalVariableGet(GV_HIGH_WATER_MARK))
         GlobalVariableSet(GV_HIGH_WATER_MARK, balance);

      Print("[PropGuard] Daily reset | Start balance: ", balance);
   }
}


bool _IsHalted()
{
   if(GlobalVariableCheck(GV_HALTED) && GlobalVariableGet(GV_HALTED) > 0)
      return true;
   return false;
}


void _HaltTrading(string reason)
{
   GlobalVariableSet(GV_HALTED, 1);
   Print("[PropGuard] *** TRADING HALTED: ", reason, " ***");
   Alert("[PropGuard] TRADING HALTED: ", reason);
}


bool _CheckDailyDrawdown()
{
   double dailyStart = GlobalVariableGet(GV_DAILY_START_BALANCE);
   if(dailyStart <= 0) return true;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double loss   = dailyStart - equity;
   double lossPct = (loss / dailyStart) * 100.0;

   if(lossPct >= PF_DailyDrawdownPct)
   {
      _HaltTrading(StringFormat("Daily drawdown %.2f%% reached (limit %.1f%%)", lossPct, PF_DailyDrawdownPct));
      return false;
   }

   if(lossPct >= PF_DailyDrawdownPct * 0.80)
   {
      Print("[PropGuard] WARNING: Daily DD at ", DoubleToString(lossPct, 2),
            "% — approaching limit of ", DoubleToString(PF_DailyDrawdownPct, 1), "%");
   }

   return true;
}


bool _CheckMaxDrawdown()
{
   double initial = GlobalVariableGet(GV_INITIAL_BALANCE);
   if(initial <= 0) return true;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double loss   = initial - equity;
   double lossPct = (loss / initial) * 100.0;

   if(lossPct >= PF_MaxDrawdownPct)
   {
      _HaltTrading(StringFormat("Max drawdown %.2f%% reached (limit %.1f%%)", lossPct, PF_MaxDrawdownPct));
      return false;
   }

   if(lossPct >= PF_MaxDrawdownPct * 0.75)
   {
      Print("[PropGuard] WARNING: Total DD at ", DoubleToString(lossPct, 2),
            "% — approaching limit of ", DoubleToString(PF_MaxDrawdownPct, 1), "%");
   }

   return true;
}


int _CountAllPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) > 0)
         count++;
   }
   return count;
}


int _GetDailyTradeCount()
{
   if(!GlobalVariableCheck(GV_DAILY_TRADE_COUNT))
      return 0;

   MqlDateTime now;
   TimeToStruct(TimeGMT(), now);
   if(GlobalVariableCheck(GV_DAILY_TRADE_DAY) && (int)GlobalVariableGet(GV_DAILY_TRADE_DAY) != now.day)
   {
      GlobalVariableSet(GV_DAILY_TRADE_COUNT, 0);
      GlobalVariableSet(GV_DAILY_TRADE_DAY, (double)now.day);
      return 0;
   }

   return (int)GlobalVariableGet(GV_DAILY_TRADE_COUNT);
}


bool PropGuardCanTrade()
{
   if(!PF_Enabled || !_pfInitialized)
      return true;

   _ResetDailyIfNeeded();

   if(_IsHalted())
   {
      return false;
   }

   if(!_CheckDailyDrawdown())
      return false;

   if(!_CheckMaxDrawdown())
      return false;

   int openPos = _CountAllPositions();
   if(openPos >= PF_MaxTotalPositions)
   {
      Print("[PropGuard] Blocked: ", openPos, " positions open (max ", PF_MaxTotalPositions, ")");
      return false;
   }

   int dailyTrades = _GetDailyTradeCount();
   if(dailyTrades >= PF_MaxDailyTrades)
   {
      Print("[PropGuard] Blocked: ", dailyTrades, " trades today (max ", PF_MaxDailyTrades, ")");
      return false;
   }

   return true;
}


double PropGuardClampRisk(double requestedRiskPct)
{
   if(!PF_Enabled) return requestedRiskPct;
   if(requestedRiskPct > PF_MaxRiskPerTrade)
   {
      Print("[PropGuard] Risk clamped: ", requestedRiskPct, "% -> ", PF_MaxRiskPerTrade, "%");
      return PF_MaxRiskPerTrade;
   }
   return requestedRiskPct;
}


void PropGuardOnTrade()
{
   if(!PF_Enabled || !_pfInitialized) return;

   double count = 0;
   if(GlobalVariableCheck(GV_DAILY_TRADE_COUNT))
      count = GlobalVariableGet(GV_DAILY_TRADE_COUNT);
   GlobalVariableSet(GV_DAILY_TRADE_COUNT, count + 1);
}


void _CloseAllPositions(string reason)
{
   CTrade closer;
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         closer.PositionClose(ticket);
         closed++;
      }
   }
   if(closed > 0)
      Print("[PropGuard] Closed ", closed, " positions: ", reason);
}


void _CheckWeekendClose()
{
   if(PF_FridayCutoffHour <= 0) return;

   MqlDateTime now;
   TimeToStruct(TimeGMT(), now);

   if(now.day_of_week == 5 && now.hour >= PF_FridayCutoffHour)
   {
      _CloseAllPositions("Friday cutoff — no weekend holding");
   }
}


void _EmergencyDrawdownClose()
{
   double initial = GlobalVariableGet(GV_INITIAL_BALANCE);
   double dailyStart = GlobalVariableGet(GV_DAILY_START_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(initial > 0)
   {
      double totalLossPct = ((initial - equity) / initial) * 100.0;
      if(totalLossPct >= PF_MaxDrawdownPct)
      {
         _CloseAllPositions(StringFormat("EMERGENCY — max DD %.2f%% hit", totalLossPct));
         _HaltTrading(StringFormat("Max drawdown %.2f%% — all positions closed", totalLossPct));
         return;
      }
   }

   if(dailyStart > 0)
   {
      double dailyLossPct = ((dailyStart - equity) / dailyStart) * 100.0;
      if(dailyLossPct >= PF_DailyDrawdownPct)
      {
         _CloseAllPositions(StringFormat("EMERGENCY — daily DD %.2f%% hit", dailyLossPct));
         _HaltTrading(StringFormat("Daily drawdown %.2f%% — all positions closed", dailyLossPct));
      }
   }
}


void PropGuardOnTick()
{
   if(!PF_Enabled || !_pfInitialized) return;

   _ResetDailyIfNeeded();
   _CheckWeekendClose();
   _EmergencyDrawdownClose();

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double hwm = GlobalVariableGet(GV_HIGH_WATER_MARK);
   if(balance > hwm)
      GlobalVariableSet(GV_HIGH_WATER_MARK, balance);
}


string PropGuardStatus()
{
   if(!PF_Enabled) return "PropGuard DISABLED";

   double initial    = GlobalVariableGet(GV_INITIAL_BALANCE);
   double dailyStart = GlobalVariableGet(GV_DAILY_START_BALANCE);
   double hwm        = GlobalVariableGet(GV_HIGH_WATER_MARK);
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);

   double dailyDD = (dailyStart > 0) ? ((dailyStart - equity) / dailyStart * 100.0) : 0;
   double totalDD = (initial > 0)    ? ((initial - equity) / initial * 100.0) : 0;

   return StringFormat(
      "PropGuard | Eq:%.2f Bal:%.2f | DailyDD:%.2f%%/%.1f%% | TotalDD:%.2f%%/%.1f%% | Pos:%d/%d | Trades:%d/%d | %s",
      equity, balance,
      dailyDD, PF_DailyDrawdownPct,
      totalDD, PF_MaxDrawdownPct,
      _CountAllPositions(), PF_MaxTotalPositions,
      _GetDailyTradeCount(), PF_MaxDailyTrades,
      _IsHalted() ? "HALTED" : "ACTIVE"
   );
}
