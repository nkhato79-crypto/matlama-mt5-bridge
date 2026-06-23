import os
import logging
from datetime import datetime
from functools import wraps
from flask import Flask, request, jsonify
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger(__name__)

app = Flask(__name__)

API_KEY        = os.getenv("API_KEY", "Yu4minawena!")
DEFAULT_SYMBOL = os.getenv("SYMBOL", "XAUUSD")
LOT_SIZE       = float(os.getenv("LOT_SIZE", 0.01))
COT_BIAS       = os.getenv("COT_BIAS", "NEUTRAL").upper()
DEALER_GAMMA   = float(os.getenv("DEALER_GAMMA", 0))

# ── Data fetch ─────────────────────────────────────────────────────────────

def get_rates(period="5d", interval="1h"):
    try:
        import yfinance as yf
        import pandas as pd
        ticker = yf.Ticker("GC=F")
        df = ticker.history(period=period, interval=interval, auto_adjust=True)
        if df is None or df.empty:
            log.warning("Empty dataframe from yfinance")
            return None
        # ticker.history() returns simple string columns
        df.columns = [str(c).lower() for c in df.columns]
        required = {"open", "high", "low", "close"}
        if not required.issubset(set(df.columns)):
            log.error(f"Missing columns: {df.columns.tolist()}")
            return None
        return df.dropna()
    except Exception as e:
        log.error(f"get_rates error: {e}")
        return None

# ── Auth ───────────────────────────────────────────────────────────────────

def require_api_key(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        auth = request.headers.get("Authorization", "")
        key  = request.args.get("api_key", "")
        if auth == f"Bearer {API_KEY}" or key == API_KEY:
            return f(*args, **kwargs)
        return jsonify({"error": "Unauthorized"}), 401
    return decorated

# ── Signal layers ──────────────────────────────────────────────────────────

def layer_cot(direction):
    if COT_BIAS == "NEUTRAL":
        return True
    return COT_BIAS == direction

def layer_gamma(direction):
    return DEALER_GAMMA <= 0 if direction == "BUY" else DEALER_GAMMA >= 0

def layer_structure(direction, df):
    if df is None or len(df) < 10:
        return False
    recent = df.tail(5)
    prior  = df.iloc[-10:-5]
    if direction == "BUY":
        return (float(recent["high"].max()) > float(prior["high"].max()) and
                float(recent["low"].min())  > float(prior["low"].min()))
    return (float(recent["high"].max()) < float(prior["high"].max()) and
            float(recent["low"].min())  < float(prior["low"].min()))

def layer_price_action(direction, df):
    if df is None or len(df) < 2:
        return False
    last      = df.iloc[-1]
    close     = float(last["close"])
    open_     = float(last["open"])
    high      = float(last["high"])
    low       = float(last["low"])
    body      = abs(close - open_)
    wick_up   = high - max(close, open_)
    wick_down = min(close, open_) - low
    if body == 0:
        return False
    if direction == "BUY":
        return close > open_ and wick_down < body * 0.5
    return close < open_ and wick_up < body * 0.5

def layer_patterns(direction, df):
    if df is None or len(df) < 20:
        return False
    lows  = [float(x) for x in df["low"].values]
    highs = [float(x) for x in df["high"].values]
    if direction == "BUY":
        l1 = min(lows[-20:-10])
        l2 = min(lows[-10:])
        return l1 > 0 and abs(l1 - l2) / l1 < 0.005
    h1 = max(highs[-20:-10])
    h2 = max(highs[-10:])
    return h1 > 0 and abs(h1 - h2) / h1 < 0.005

def evaluate_signal(direction):
    direction = direction.upper()
    df_h1 = get_rates(period="5d",  interval="1h")
    df_h4 = get_rates(period="30d", interval="4h")

    layers = {
        "cot_cftc":         layer_cot(direction),
        "dealer_gamma":     layer_gamma(direction),
        "market_structure": layer_structure(direction, df_h1),
        "price_action":     layer_price_action(direction, df_h1),
        "chart_patterns":   layer_patterns(direction, df_h4),
    }
    score = sum(layers.values())
    price = float(df_h1["close"].iloc[-1]) if df_h1 is not None and len(df_h1) > 0 else 0

    return {
        "direction":  direction,
        "symbol":     "XAUUSD",
        "layers":     {k: bool(v) for k, v in layers.items()},
        "score":      score,
        "threshold":  3,
        "qualified":  score >= 3,
        "action":     direction if score >= 3 else "HOLD",
        "confidence": int((score / 5) * 100),
        "price":      price,
        "timestamp":  datetime.utcnow().isoformat(),
    }

# ── Routes ─────────────────────────────────────────────────────────────────

@app.route("/health")
def health():
    return jsonify({
        "status":       "ok",
        "symbol":       DEFAULT_SYMBOL,
        "cot_bias":     COT_BIAS,
        "dealer_gamma": DEALER_GAMMA,
        "timestamp":    datetime.utcnow().isoformat()
    })

@app.route("/mcp", methods=["GET", "POST"])
def mcp():
    return jsonify({
        "protocolVersion": "2024-11-05",
        "capabilities":    {},
        "serverInfo":      {"name": "matlama-mt5-bridge", "version": "3.2.0"}
    })

@app.route("/signal", methods=["GET", "POST"])
def signal():
    if request.method == "GET":
        symbol    = request.args.get("symbol", DEFAULT_SYMBOL)
        direction = request.args.get("direction", None)
    else:
        data      = request.get_json() or {}
        symbol    = data.get("symbol", DEFAULT_SYMBOL)
        direction = data.get("direction", None)

    log.info(f"Signal | symbol={symbol} direction={direction}")

    if direction:
        direction = direction.upper()
        if direction not in ("BUY", "SELL"):
            return jsonify({"error": "direction must be BUY or SELL"}), 400
        return jsonify(evaluate_signal(direction))

    buy  = evaluate_signal("BUY")
    sell = evaluate_signal("SELL")
    result = buy if buy["score"] >= sell["score"] else sell
    result["buy_score"]  = buy["score"]
    result["sell_score"] = sell["score"]
    return jsonify(result)

@app.route("/hft_signal", methods=["POST"])
@require_api_key
def hft_signal():
    data           = request.get_json() or {}
    market         = data.get("market_data", {})
    price          = float(market.get("price", 0))
    spread         = float(market.get("spread", 0))
    volume         = float(market.get("volume", 0))
    price_velocity = float(market.get("price_velocity", 0))
    atr            = float(market.get("atr", 1)) or 1

    vol_pct = (atr / price * 100) if price else 2.0
    if vol_pct < 1.5:   spoof_thresh, mom_thresh = 65, 80
    elif vol_pct < 2.5: spoof_thresh, mom_thresh = 60, 70
    elif vol_pct < 3.5: spoof_thresh, mom_thresh = 55, 65
    else:               spoof_thresh, mom_thresh = 50, 60

    momentum_score = min(100, price_velocity * 15)
    normal_spread  = atr * 0.05
    spread_ratio   = (spread / normal_spread) if normal_spread else 1
    spoofing_score = min(100, spread_ratio * 40 + (volume / 1000) * 10)
    flash_crash    = price_velocity > 8 and volume > 5000
    confidence     = (spoofing_score + momentum_score) / 2

    if flash_crash:
        return jsonify({"signal": "FLASH_CRASH", "qualified": True, "confidence": 90,
                        "spoofing_score": round(spoofing_score), "momentum_score": round(momentum_score)})
    if spoofing_score > spoof_thresh and momentum_score > mom_thresh * 0.9:
        return jsonify({"signal": "SELL_RALLY", "qualified": True, "confidence": round(confidence),
                        "spoofing_score": round(spoofing_score), "momentum_score": round(momentum_score)})
    if spoofing_score > 65 and price < 3200:
        return jsonify({"signal": "BUY_SUPPORT", "qualified": True, "confidence": 72,
                        "spoofing_score": round(spoofing_score), "momentum_score": round(momentum_score)})
    return jsonify({"signal": "NO_SIGNAL", "qualified": False, "confidence": round(confidence),
                    "spoofing_score": round(spoofing_score), "momentum_score": round(momentum_score)})

@app.route("/cmd", methods=["POST"])
@require_api_key
def cmd():
    data    = request.get_json() or {}
    command = data.get("cmd", "").upper()
    log.info(f"CMD: {command}")
    if command in ("BUY", "SELL"):
        sig = evaluate_signal(command)
        return jsonify({"executed": sig["qualified"], "cmd": command, "signal": sig,
                        "reason": "Signal qualified" if sig["qualified"] else "Score below 4/5 threshold"})
    return jsonify({"error": f"Unknown command: {command}"}), 400

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", 5000)))
