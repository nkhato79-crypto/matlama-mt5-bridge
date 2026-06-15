"""
Matlama MT5 Bridge - VPS Component
Runs on Windows VPS (173.225.110.145)
Connects directly to MetaTrader5 and exposes HTTP endpoints
Called by the Render.com bridge (matlama-mt5-bridge.onrender.com)
"""

import os
import logging
from datetime import datetime, timedelta
from functools import wraps

import MetaTrader5 as mt5
from flask import Flask, request, jsonify

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger(__name__)

app = Flask(__name__)

# ── Config ─────────────────────────────────────────────────────────────────
MT5_LOGIN    = int(os.getenv("MT5_LOGIN", 0))
MT5_PASSWORD = os.getenv("MT5_PASSWORD", "")
MT5_SERVER   = os.getenv("MT5_SERVER", "FXPro-MT5")
API_KEY      = os.getenv("API_KEY", "Yu4minawena#XAU2025!")
SYMBOL       = "XAUUSD"
LOT_SIZE     = float(os.getenv("LOT_SIZE", 0.01))
MAGIC        = 20250101
SLIPPAGE     = 10

TIMEFRAME_MAP = {
    "M1":  mt5.TIMEFRAME_M1,
    "M5":  mt5.TIMEFRAME_M5,
    "M15": mt5.TIMEFRAME_M15,
    "M30": mt5.TIMEFRAME_M30,
    "H1":  mt5.TIMEFRAME_H1,
    "H4":  mt5.TIMEFRAME_H4,
    "D1":  mt5.TIMEFRAME_D1,
}

# ── Auth ───────────────────────────────────────────────────────────────────
def require_api_key(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        auth = request.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or auth[7:] != API_KEY:
            return jsonify({"error": "Unauthorized"}), 401
        return f(*args, **kwargs)
    return decorated

# ── MT5 ────────────────────────────────────────────────────────────────────
def connect_mt5():
    if not mt5.initialize(login=MT5_LOGIN, password=MT5_PASSWORD, server=MT5_SERVER):
        log.error(f"MT5 init failed: {mt5.last_error()}")
        return False
    log.info(f"MT5 connected: Account {MT5_LOGIN}")
    return True

def ensure_connected():
    if mt5.terminal_info() is None:
        return connect_mt5()
    return True

# ── Routes ─────────────────────────────────────────────────────────────────

@app.route("/health", methods=["GET"])
def health():
    connected = ensure_connected()
    info = mt5.account_info() if connected else None
    return jsonify({
        "status":  "ok" if connected else "disconnected",
        "balance": float(info.balance) if info else None,
        "equity":  float(info.equity)  if info else None,
        "profit":  float(info.profit)  if info else None,
        "timestamp": datetime.utcnow().isoformat(),
    })

@app.route("/rates", methods=["GET"])
def rates():
    if not ensure_connected():
        return jsonify({"error": "MT5 not connected"}), 503

    symbol       = request.args.get("symbol", SYMBOL)
    timeframe_str = request.args.get("timeframe", "H1")
    count        = int(request.args.get("count", 20))
    timeframe    = TIMEFRAME_MAP.get(timeframe_str, mt5.TIMEFRAME_H1)

    data = mt5.copy_rates_from_pos(symbol, timeframe, 0, count)
    if data is None:
        return jsonify({"error": f"Failed to get rates: {mt5.last_error()}"}), 500

    return jsonify({
        "symbol":    symbol,
        "timeframe": timeframe_str,
        "count":     len(data),
        "rates": [
            {
                "time":   int(r["time"]),
                "open":   float(r["open"]),
                "high":   float(r["high"]),
                "low":    float(r["low"]),
                "close":  float(r["close"]),
                "volume": int(r["tick_volume"]),
            }
            for r in data
        ],
    })

@app.route("/trade", methods=["POST"])
@require_api_key
def trade():
    if not ensure_connected():
        return jsonify({"error": "MT5 not connected"}), 503

    data      = request.get_json() or {}
    direction = data.get("direction", "").upper()
    lot       = float(data.get("lot", LOT_SIZE))
    sl_pips   = int(data.get("sl_pips", 50))
    tp_pips   = int(data.get("tp_pips", 100))

    if direction not in ("BUY", "SELL"):
        return jsonify({"error": "direction must be BUY or SELL"}), 400

    order_type = mt5.ORDER_TYPE_BUY if direction == "BUY" else mt5.ORDER_TYPE_SELL
    tick       = mt5.symbol_info_tick(SYMBOL)
    price      = tick.ask if direction == "BUY" else tick.bid
    pip        = mt5.symbol_info(SYMBOL).point * 10
    sl         = price - sl_pips * pip if direction == "BUY" else price + sl_pips * pip
    tp         = price + tp_pips * pip if direction == "BUY" else price - tp_pips * pip

    req = {
        "action":       mt5.TRADE_ACTION_DEAL,
        "symbol":       SYMBOL,
        "volume":       lot,
        "type":         order_type,
        "price":        price,
        "sl":           round(sl, 2),
        "tp":           round(tp, 2),
        "deviation":    SLIPPAGE,
        "magic":        MAGIC,
        "comment":      "matlama-bridge",
        "type_time":    mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_IOC,
    }

    result = mt5.order_send(req)
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        return jsonify({"error": result.comment, "retcode": result.retcode}), 500

    log.info(f"Order placed: {direction} {lot} @ {price} | Ticket: {result.order}")
    return jsonify({
        "ticket":    result.order,
        "direction": direction,
        "lot":       lot,
        "price":     price,
        "sl":        round(sl, 2),
        "tp":        round(tp, 2),
    })

@app.route("/close", methods=["POST"])
@require_api_key
def close():
    if not ensure_connected():
        return jsonify({"error": "MT5 not connected"}), 503

    data   = request.get_json() or {}
    ticket = data.get("ticket")
    positions = mt5.positions_get(symbol=SYMBOL)

    if not positions:
        return jsonify({"message": "No open positions"})

    results = []
    for pos in positions:
        if ticket and pos.ticket != ticket:
            continue
        close_type = mt5.ORDER_TYPE_SELL if pos.type == 0 else mt5.ORDER_TYPE_BUY
        tick  = mt5.symbol_info_tick(SYMBOL)
        price = tick.bid if pos.type == 0 else tick.ask
        req = {
            "action":       mt5.TRADE_ACTION_DEAL,
            "symbol":       SYMBOL,
            "volume":       pos.volume,
            "type":         close_type,
            "position":     pos.ticket,
            "price":        price,
            "deviation":    SLIPPAGE,
            "magic":        MAGIC,
            "comment":      "matlama-close",
            "type_time":    mt5.ORDER_TIME_GTC,
            "type_filling": mt5.ORDER_FILLING_IOC,
        }
        r = mt5.order_send(req)
        results.append({
            "ticket":  pos.ticket,
            "success": r.retcode == mt5.TRADE_RETCODE_DONE,
            "pnl":     pos.profit,
        })

    return jsonify({"closed": results})

@app.route("/positions", methods=["GET"])
@require_api_key
def positions():
    if not ensure_connected():
        return jsonify({"error": "MT5 not connected"}), 503

    pos = mt5.positions_get(symbol=SYMBOL)
    if not pos:
        return jsonify({"positions": []})

    return jsonify({
        "positions": [
            {
                "ticket":     p.ticket,
                "type":       "BUY" if p.type == 0 else "SELL",
                "volume":     p.volume,
                "open_price": p.price_open,
                "sl":         p.sl,
                "tp":         p.tp,
                "profit":     p.profit,
                "open_time":  datetime.utcfromtimestamp(p.time).isoformat(),
            }
            for p in pos
        ]
    })

@app.route("/history", methods=["GET"])
@require_api_key
def history():
    if not ensure_connected():
        return jsonify({"error": "MT5 not connected"}), 503

    days      = int(request.args.get("days", 7))
    date_from = datetime.utcnow() - timedelta(days=days)
    deals     = mt5.history_deals_get(date_from, datetime.utcnow(), group=f"*{SYMBOL}*")

    if not deals:
        return jsonify({"deals": [], "total_trades": 0, "win_rate": 0, "total_pnl": 0})

    closed = [d for d in deals if d.entry == 1]
    wins   = sum(1 for d in closed if d.profit > 0)
    total  = len(closed)

    return jsonify({
        "period_days":   days,
        "total_trades":  total,
        "wins":          wins,
        "losses":        total - wins,
        "win_rate":      round(wins / total * 100, 1) if total else 0,
        "total_pnl":     round(sum(d.profit for d in closed), 2),
        "deals": [
            {
                "ticket": d.order,
                "type":   "BUY" if d.type == 0 else "SELL",
                "volume": d.volume,
                "price":  d.price,
                "profit": d.profit,
                "time":   datetime.utcfromtimestamp(d.time).isoformat(),
            }
            for d in closed
        ],
    })

# ── Start ──────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    if not connect_mt5():
        log.warning("MT5 not connected on startup — will retry on first request")
    app.run(host="0.0.0.0", port=5000, debug=False)
