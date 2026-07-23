//+------------------------------------------------------------------+
//| MatlamaMonitor.mq5                                                |
//| Consolidates trade logs from all Matlama EAs into one summary.    |
//| Run manually (drag onto any chart, or double-click in Navigator)  |
//| whenever you want a single-glance status instead of checking 5    |
//| separate Experts logs.                                            |
//|                                                                    |
//| Reads the CSV files each EA already writes to MQL5\Files:          |
//|   quant_trades.csv     (MatlamaQuant)                              |
//|   bridgev3_trades.csv  (matlamabridgeV3)                           |
//|   hft_trades.csv       (MatlamaBridgeHFT)                          |
//|   scalper_trades.csv   (MatlamaScalper)                            |
//| MatlamaFundamentals currently writes no CSV log -- flagged below   |
//| as a gap, not silently skipped.                                    |
//+------------------------------------------------------------------+
#property copyright "Matlama Tech 2026"
#property version   "1.00"
#property script_show_inputs

input bool WriteSummaryCSV = true;   // also write monitor_summary.csv to Files folder

struct EAStats
{
   string name;
   string file;
   bool   found;
   int    trades;
   int    wins;
   double totalProfit;
   double bestTrade;
   double worstTrade;
   datetime lastCloseTime;
};

//+------------------------------------------------------------------+
void ReadEACsv(string file, string eaName, EAStats &s)
{
   s.name = eaName;
   s.file = file;
   s.found = false;
   s.trades = 0;
   s.wins = 0;
   s.totalProfit = 0.0;
   s.bestTrade = -1e9;
   s.worstTrade = 1e9;
   s.lastCloseTime = 0;

   int handle = FileOpen(file, FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ',');
   if(handle == INVALID_HANDLE)
      return; // not found -- EA may not have logged any trades yet, or file not present

   s.found = true;
   bool headerSkipped = false;

   while(!FileIsEnding(handle))
   {
      string ticket = FileReadString(handle);

      if(!headerSkipped)
      {
         // this is the header row's first field ("ticket") -- discard the
         // rest of the header row, then start fresh on the next iteration
         while(!FileIsLineEnding(handle) && !FileIsEnding(handle))
            FileReadString(handle);
         headerSkipped = true;
         continue;
      }

      if(ticket == "") break;

      string symbol   = FileReadString(handle);
      string type     = FileReadString(handle);
      string openTime = FileReadString(handle);
      string closeTimeStr = FileReadString(handle);
      string openPrice    = FileReadString(handle);
      string closePrice   = FileReadString(handle);
      string volume       = FileReadString(handle);
      double profit        = StringToDouble(FileReadString(handle));
      string swap          = FileReadString(handle);
      string commission    = FileReadString(handle);
      string durationMin   = FileReadString(handle);

      // consume any remaining strategy-specific columns on this line
      while(!FileIsLineEnding(handle) && !FileIsEnding(handle))
         FileReadString(handle);

      s.trades++;
      s.totalProfit += profit;
      if(profit > 0) s.wins++;
      if(profit > s.bestTrade)  s.bestTrade  = profit;
      if(profit < s.worstTrade) s.worstTrade = profit;

      datetime ct = StringToTime(closeTimeStr);
      if(ct > s.lastCloseTime) s.lastCloseTime = ct;
   }

   FileClose(handle);
}

//+------------------------------------------------------------------+
void PrintEAStats(EAStats &s)
{
   Print("=========================================");
   Print(s.name, " (", s.file, ")");
   if(!s.found)
   {
      Print("  No CSV log file found yet. Either no trades have closed,");
      Print("  or (for MatlamaFundamentals) this EA doesn't write one --");
      Print("  check its Experts log directly instead.");
      return;
   }
   if(s.trades == 0)
   {
      Print("  CSV found but 0 trades logged yet.");
      return;
   }
   double winRate = 100.0 * s.wins / s.trades;
   Print("  Trades:      ", s.trades);
   Print("  Win rate:    ", DoubleToString(winRate, 1), "%");
   Print("  Total P&L:   ", DoubleToString(s.totalProfit, 2));
   Print("  Best trade:  ", DoubleToString(s.bestTrade, 2));
   Print("  Worst trade: ", DoubleToString(s.worstTrade, 2));
   Print("  Last close:  ", TimeToString(s.lastCloseTime, TIME_DATE|TIME_MINUTES));
}

//+------------------------------------------------------------------+
void WriteSummaryFile(EAStats &all[], int count)
{
   int handle = FileOpen("monitor_summary.csv", FILE_WRITE|FILE_CSV|FILE_ANSI);
   if(handle == INVALID_HANDLE)
   {
      Print("ERROR: could not write monitor_summary.csv");
      return;
   }
   FileWrite(handle, "ea_name", "csv_found", "trades", "win_rate_pct",
             "total_pnl", "best_trade", "worst_trade", "last_close_time");
   for(int i = 0; i < count; i++)
   {
      EAStats s = all[i];
      double winRate = (s.trades > 0) ? 100.0 * s.wins / s.trades : 0.0;
      FileWrite(handle, s.name, (s.found ? "yes" : "no"), s.trades,
                DoubleToString(winRate, 1),
                DoubleToString(s.totalProfit, 2),
                DoubleToString((s.trades > 0 ? s.bestTrade : 0), 2),
                DoubleToString((s.trades > 0 ? s.worstTrade : 0), 2),
                TimeToString(s.lastCloseTime, TIME_DATE|TIME_MINUTES));
   }
   FileClose(handle);
   Print("Wrote consolidated summary to MQL5\\Files\\monitor_summary.csv");
}

//+------------------------------------------------------------------+
void OnStart()
{
   Print("###########################################");
   Print("###  MATLAMA ECOSYSTEM MONITOR  ###");
   Print("###  Run time: ", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), "  ###");
   Print("###########################################");

   EAStats stats[6];
   ReadEACsv("quant_trades.csv",    "MatlamaQuant",       stats[0]);
   ReadEACsv("bridgev3_trades.csv", "matlamabridgeV3",    stats[1]);
   ReadEACsv("hft_trades.csv",      "MatlamaBridgeHFT",   stats[2]);
   ReadEACsv("scalper_trades.csv",  "MatlamaScalper",     stats[3]);
   ReadEACsv("looper_trades.csv",   "MatlamaLooper",      stats[4]);
   // MatlamaFundamentals: no CSV file exists in the current codebase.
   stats[5].name = "MatlamaFundamentals";
   stats[5].file = "(none)";
   stats[5].found = false;
   stats[5].trades = 0;

   double portfolioTotal = 0.0;
   int portfolioTrades = 0;

   for(int i = 0; i < 6; i++)
   {
      PrintEAStats(stats[i]);
      portfolioTotal += stats[i].totalProfit;
      portfolioTrades += stats[i].trades;
   }

   Print("=========================================");
   Print("PORTFOLIO TOTAL: ", portfolioTrades, " trades, P&L = ", DoubleToString(portfolioTotal, 2));
   Print("=========================================");

   if(WriteSummaryCSV)
      WriteSummaryFile(stats, 6);
}
//+------------------------------------------------------------------+
