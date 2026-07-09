//+------------------------------------------------------------------+
//|                                        OrchestratorClient.mqh    |
//|                                      Matlama Tech (c) 2026       |
//|   Shared client for the Matlama Orchestrator v2 decision engine  |
//|   (Flask, localhost:7000 by default). Include this in any EA     |
//|   that should be gated/overridden by the orchestrator.           |
//|                                                                    |
//|   SETUP REQUIRED IN MT5:                                          |
//|   Tools > Options > Expert Advisors > check "Allow WebRequest     |
//|   for listed URL" and add: http://127.0.0.1:7000                  |
//|   (WebRequest to localhost still requires this whitelist entry.)  |
//+------------------------------------------------------------------+
#property strict

//--- Decision result returned by /decision_v2
struct OrchDecision
{
   string decision;        // "BUY" / "SELL" / "HOLD"
   double confidence;
   double ensemble_score;
   string regime;
   bool   valid;           // false if the request/parse failed — treat as HOLD
};

//+------------------------------------------------------------------+
//| Minimal JSON helpers (flat objects only, no nested arrays)       |
//+------------------------------------------------------------------+
string OrchJsonGetString(string json, string key)
{
   string pattern = "\"" + key + "\":\"";
   int pos = StringFind(json, pattern);
   if(pos < 0) return "";
   int start = pos + StringLen(pattern);
   int end   = StringFind(json, "\"", start);
   if(end < 0) return "";
   return StringSubstr(json, start, end - start);
}

double OrchJsonGetDouble(string json, string key)
{
   string pattern = "\"" + key + "\":";
   int pos = StringFind(json, pattern);
   if(pos < 0) return 0.0;
   int start = pos + StringLen(pattern);
   int len   = StringLen(json);
   int end   = start;
   while(end < len)
   {
      ushort c = StringGetCharacter(json, end);
      if(c == ',' || c == '}') break;
      end++;
   }
   string sub = StringSubstr(json, start, end - start);
   return StringToDouble(sub);
}

//+------------------------------------------------------------------+
//| Build the JSON payload for /decision_v2                          |
//+------------------------------------------------------------------+
string OrchBuildPayload(string strategy,
                         double price, double spread, double atr, double adx,
                         double volatility, double momentum, double volume,
                         double rsi, double ema_fast, double ema_slow,
                         int news_risk, double max_spread,
                         bool allow_news_trading, bool allow_crisis_trading,
                         double max_account_drawdown_pct,
                         string extra_fields = "")
{
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   string json = "{";
   json += "\"strategy\":\"" + strategy + "\",";
   json += "\"price\":"      + DoubleToString(price, 5)      + ",";
   json += "\"spread\":"     + DoubleToString(spread, 5)     + ",";
   json += "\"atr\":"        + DoubleToString(atr, 5)        + ",";
   json += "\"adx\":"        + DoubleToString(adx, 5)        + ",";
   json += "\"volatility\":" + DoubleToString(volatility, 5) + ",";
   json += "\"momentum\":"   + DoubleToString(momentum, 5)   + ",";
   json += "\"volume\":"     + DoubleToString(volume, 2)     + ",";
   json += "\"rsi\":"        + DoubleToString(rsi, 3)        + ",";
   json += "\"ema_fast\":"   + DoubleToString(ema_fast, 5)   + ",";
   json += "\"ema_slow\":"   + DoubleToString(ema_slow, 5)   + ",";
   json += "\"news_risk\":"  + (string)news_risk             + ",";
   json += "\"equity\":"     + DoubleToString(equity, 2)     + ",";
   json += "\"balance\":"    + DoubleToString(balance, 2)    + ",";
   json += "\"max_spread\":" + DoubleToString(max_spread, 2) + ",";
   json += "\"allow_news_trading\":"   + (allow_news_trading   ? "true" : "false") + ",";
   json += "\"allow_crisis_trading\":" + (allow_crisis_trading ? "true" : "false") + ",";
   json += "\"max_account_drawdown_pct\":" + DoubleToString(max_account_drawdown_pct, 3);
   if(extra_fields != "") json += "," + extra_fields;
   json += "}";
   return json;
}

//+------------------------------------------------------------------+
//| Call /decision_v2 — returns parsed OrchDecision                  |
//+------------------------------------------------------------------+
OrchDecision OrchGetDecision(string server_url, string payload)
{
   OrchDecision result;
   result.decision       = "HOLD";
   result.confidence     = 0.0;
   result.ensemble_score = 0.0;
   result.regime         = "UNKNOWN";
   result.valid          = false;

   char   post[], reply[];
   string reply_headers;
   StringToCharArray(payload, post, 0, StringLen(payload));

   ResetLastError();
   int res = WebRequest("POST", server_url, "Content-Type: application/json\r\n",
                         3000, post, reply, reply_headers);

   if(res == -1)
   {
      int err = GetLastError();
      Print("ORCH ERROR | WebRequest failed. Code:", err,
            " — check Tools>Options>Expert Advisors>Allow WebRequest for: ", server_url);
      return result;
   }

   string response = CharArrayToString(reply);
   if(StringLen(response) == 0)
   {
      Print("ORCH ERROR | Empty response from ", server_url);
      return result;
   }

   result.decision       = OrchJsonGetString(response, "decision");
   result.confidence     = OrchJsonGetDouble(response, "confidence");
   result.ensemble_score = OrchJsonGetDouble(response, "ensemble_score");
   result.regime         = OrchJsonGetString(response, "regime");

   if(result.decision == "") result.decision = "HOLD";
   result.valid = true;

   return result;
}

//+------------------------------------------------------------------+
//| Report a closed trade back to /report_trade for the feedback loop|
//+------------------------------------------------------------------+
void OrchReportTrade(string report_url, string strategy, string regime, int win, double score)
{
   if(regime == "" ) regime = "MIXED";

   string json = "{";
   json += "\"strategy\":\"" + strategy + "\",";
   json += "\"regime\":\"" + regime + "\",";
   json += "\"result\":"   + (string)win + ",";
   json += "\"score\":"    + DoubleToString(score, 4);
   json += "}";

   char   post[], reply[];
   string reply_headers;
   StringToCharArray(json, post, 0, StringLen(json));

   ResetLastError();
   int res = WebRequest("POST", report_url, "Content-Type: application/json\r\n",
                         3000, post, reply, reply_headers);

   if(res == -1)
      Print("ORCH ERROR | report_trade failed. Code:", GetLastError());
   else
      Print("ORCH | Trade reported | Regime:", regime, " Result:", win);
}

//+------------------------------------------------------------------+
//| Volatility — stdev of pct returns over `period` candles, x100    |
//+------------------------------------------------------------------+
double OrchCalcVolatility(string symbol, ENUM_TIMEFRAMES tf, int period)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(symbol, tf, 0, period + 1, rates) < period + 1) return 0.0;

   double returns[];
   ArrayResize(returns, period);
   for(int i = 0; i < period; i++)
   {
      if(rates[i + 1].close == 0) { returns[i] = 0; continue; }
      returns[i] = (rates[i].close - rates[i + 1].close) / rates[i + 1].close;
   }

   double mean = 0;
   for(int i = 0; i < period; i++) mean += returns[i];
   mean /= period;

   double variance = 0;
   for(int i = 0; i < period; i++) variance += MathPow(returns[i] - mean, 2);
   variance /= period;

   return MathSqrt(variance) * 100.0;
}

//+------------------------------------------------------------------+
//| Momentum — pct price change over `lookback` candles              |
//+------------------------------------------------------------------+
double OrchCalcMomentum(string symbol, ENUM_TIMEFRAMES tf, int lookback)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(symbol, tf, 0, lookback + 1, rates) < lookback + 1) return 0.0;
   if(rates[lookback].close == 0) return 0.0;
   return ((rates[0].close - rates[lookback].close) / rates[lookback].close) * 100.0;
}
