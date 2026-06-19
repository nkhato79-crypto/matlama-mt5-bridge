//+------------------------------------------------------------------+
//|                                              MatlamaBridge.mq5   |
//|                                         Matlama Tech © 2026      |
//|                              matlama-mt5-bridge.onrender.com      |
//+------------------------------------------------------------------+
#property copyright "Matlama Tech 2026"
#property version   "1.00"
#property strict

//--- Input Parameters
input string   RenderURL    = "https://matlama-mt5-bridge.onrender.com";
input string   APIKey       = "Yu4minawena!";
input string   Symbol_      = "GOLD";
input double   LotSize      = 0.01;
input int      SL_Pips      = 50;
input int      TP_Pips      = 100;
input int      Slippage     = 10;
input int      PollSeconds  = 30;       // How often to check for signals
input int      MagicNumber  = 20250101;
input bool     AutoTrade    = false;    // Set true to enable auto trading

//--- Global Variables
datetime       LastCheck    = 0;
string         LastSignal   = "";

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("MatlamaBridge EA started");
   Print("Render URL: ", RenderURL);
   Print("Auto Trade: ", AutoTrade ? "ENABLED" : "DISABLED");
   Print("Symbol: ", Symbol_);
   Print("Lot Size: ", LotSize);
   
   // Add Render URL to allowed URLs
   // Note: Add https://matlama-mt5-bridge.onrender.com to 
   // Tools > Options > Expert Advisors > Allow WebRequest for listed URL
   
   EventSetTimer(PollSeconds);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("MatlamaBridge EA stopped");
}

//+------------------------------------------------------------------+
//| Timer - polls Render for signals                                  |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(!AutoTrade)
      return;
      
   CheckSignal();
}

//+------------------------------------------------------------------+
//| Check signal from Render bridge                                   |
//+------------------------------------------------------------------+
void CheckSignal()
{
   string headers = "Content-Type: application/json\r\nAuthorization: Bearer " + APIKey;
   string body    = "{\"direction\":\"BUY\"}";  // Will check both directions
   char   post[], result[];
   string resultHeaders;
   
   // Check BUY signal
   StringToCharArray(body, post, 0, StringLen(body));
   ArrayResize(post, StringLen(body));
   
   int res = WebRequest(
      "POST",
      RenderURL + "/signal",
      headers,
      5000,
      post,
      result,
      resultHeaders
   );
   
   if(res == 200)
   {
      string response = CharArrayToString(result);
      Print("BUY Signal response: ", response);
      
      // Parse qualified field
      if(StringFind(response, "\"qualified\":true") >= 0)
      {
         Print("BUY signal QUALIFIED - executing trade");
         ExecuteTrade(ORDER_TYPE_BUY);
         return;
      }
   }
   
   // Check SELL signal
   body = "{\"direction\":\"SELL\"}";
   StringToCharArray(body, post, 0, StringLen(body));
   ArrayResize(post, StringLen(body));
   
   res = WebRequest(
      "POST",
      RenderURL + "/signal",
      headers,
      5000,
      post,
      result,
      resultHeaders
   );
   
   if(res == 200)
   {
      string response = CharArrayToString(result);
      Print("SELL Signal response: ", response);
      
      if(StringFind(response, "\"qualified\":true") >= 0)
      {
         Print("SELL signal QUALIFIED - executing trade");
         ExecuteTrade(ORDER_TYPE_SELL);
      }
   }
}

//+------------------------------------------------------------------+
//| Execute trade                                                     |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE orderType)
{
   // Check if we already have an open position
   if(HasOpenPosition())
   {
      Print("Already have open position - skipping");
      return;
   }
   
   MqlTradeRequest  request = {};
   MqlTradeResult   result  = {};
   
   double price, sl, tp;
   double point = SymbolInfoDouble(Symbol_, SYMBOL_POINT);
   double pip   = point * 10;
   
   if(orderType == ORDER_TYPE_BUY)
   {
      price = SymbolInfoDouble(Symbol_, SYMBOL_ASK);
      sl    = price - SL_Pips * pip;
      tp    = price + TP_Pips * pip;
   }
   else
   {
      price = SymbolInfoDouble(Symbol_, SYMBOL_BID);
      sl    = price + SL_Pips * pip;
      tp    = price - TP_Pips * pip;
   }
   
   request.action    = TRADE_ACTION_DEAL;
   request.symbol    = Symbol_;
   request.volume    = LotSize;
   request.type      = orderType;
   request.price     = price;
   request.sl        = NormalizeDouble(sl, (int)SymbolInfoInteger(Symbol_, SYMBOL_DIGITS));
   request.tp        = NormalizeDouble(tp, (int)SymbolInfoInteger(Symbol_, SYMBOL_DIGITS));
   request.deviation = Slippage;
   request.magic     = MagicNumber;
   request.comment   = "matlama-ea";
   request.type_time = ORDER_TIME_GTC;
   request.type_filling = ORDER_FILLING_IOC;
   
   bool sent = OrderSend(request, result);
   
   if(sent && result.retcode == TRADE_RETCODE_DONE)
   {
      Print("Trade executed: ", 
            orderType == ORDER_TYPE_BUY ? "BUY" : "SELL",
            " | Ticket: ", result.order,
            " | Price: ", price,
            " | SL: ", sl,
            " | TP: ", tp);
            
      // Report back to Render
      ReportTrade(result.order, orderType, price);
   }
   else
   {
      Print("Trade FAILED: ", result.retcode, " - ", result.comment);
   }
}

//+------------------------------------------------------------------+
//| Check if we have an open position                                 |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) == Symbol_ && 
         PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Report trade back to Render                                       |
//+------------------------------------------------------------------+
void ReportTrade(ulong ticket, ENUM_ORDER_TYPE orderType, double price)
{
   string headers = "Content-Type: application/json\r\nAuthorization: Bearer " + APIKey;
   string body    = StringFormat(
      "{\"ticket\":%d,\"direction\":\"%s\",\"price\":%.2f,\"source\":\"mt5-ea\"}",
      ticket,
      orderType == ORDER_TYPE_BUY ? "BUY" : "SELL",
      price
   );
   
   char post[], result[];
   string resultHeaders;
   StringToCharArray(body, post, 0, StringLen(body));
   ArrayResize(post, StringLen(body));
   
   WebRequest("POST", RenderURL + "/health", headers, 3000, post, result, resultHeaders);
}

//+------------------------------------------------------------------+
//| Manual signal check on chart click                               |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long& lparam, const double& dparam, const string& sparam)
{
   if(id == CHARTEVENT_KEYDOWN)
   {
      if(lparam == 83) // 'S' key - check signal manually
      {
         Print("Manual signal check triggered");
         CheckSignal();
      }
      if(lparam == 67) // 'C' key - close all positions
      {
         CloseAllPositions();
      }
   }
}

//+------------------------------------------------------------------+
//| Close all open positions                                          |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == Symbol_ && 
         PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         MqlTradeRequest  request = {};
         MqlTradeResult   result  = {};
         
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         
         request.action   = TRADE_ACTION_DEAL;
         request.symbol   = Symbol_;
         request.volume   = PositionGetDouble(POSITION_VOLUME);
         request.type     = posType == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         request.position = ticket;
         request.price    = posType == POSITION_TYPE_BUY ? 
                           SymbolInfoDouble(Symbol_, SYMBOL_BID) : 
                           SymbolInfoDouble(Symbol_, SYMBOL_ASK);
         request.deviation = Slippage;
         request.magic    = MagicNumber;
         request.comment  = "matlama-close";
         request.type_time = ORDER_TIME_GTC;
         request.type_filling = ORDER_FILLING_IOC;
         
         bool sent = OrderSend(request, result);
         if(sent && result.retcode == TRADE_RETCODE_DONE)
            Print("Position closed: ", ticket, " | PnL: ", PositionGetDouble(POSITION_PROFIT));
         else
            Print("Close FAILED: ", result.retcode);
      }
   }
}

//+------------------------------------------------------------------+
//| OnTick - just keeps EA alive                                     |
//+------------------------------------------------------------------+
void OnTick()
{
   // EA stays alive on ticks
   // Trading logic runs on timer
}
//+------------------------------------------------------------------+
