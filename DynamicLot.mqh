//+------------------------------------------------------------------+
//|                                              DynamicLot.mqh      |
//|                                        Matlama Tech © 2026       |
//|  Shared position sizing: risk a fixed % of equity per trade.     |
//+------------------------------------------------------------------+
#property copyright "Matlama Tech 2026"
#property strict

double CalcDynamicLot(string symbol, double sl_pips, double risk_pct, double fallback_lot)
{
   if(risk_pct <= 0 || sl_pips <= 0)
      return fallback_lot;

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_amt  = equity * risk_pct / 100.0;
   double tick_val  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(symbol, SYMBOL_POINT);

   if(tick_val <= 0 || tick_size <= 0 || point <= 0)
      return fallback_lot;

   double pip_size   = point * 10;
   double sl_points  = sl_pips * pip_size;
   double value_per_lot_per_point = tick_val / tick_size;
   double loss_per_lot = sl_points * value_per_lot_per_point;

   if(loss_per_lot <= 0)
      return fallback_lot;

   double lot = risk_amt / loss_per_lot;

   double min_lot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(lot_step > 0)
      lot = MathFloor(lot / lot_step) * lot_step;

   if(lot < min_lot) lot = min_lot;
   if(lot > max_lot) lot = max_lot;

   return NormalizeDouble(lot, 2);
}
