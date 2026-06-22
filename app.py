import os
import logging
from datetime import datetime
from functools import wraps
from flask import Flask, request, jsonify
from dotenv import load_dotenv
import yfinance as yf
import pandas as pd
import numpy as np

load_dotenv()

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger(__name__)

app = Flask(__name__)

API_KEY      = os.getenv("API_KEY", "Yu4minawena!")
DEFAULT_SYMBOL = os.getenv("SYMBOL", "XAUUSD")
LOT_SIZE     = float(os.getenv("LOT_SIZE", 0.01))
COT_BIAS     = os.getenv("COT_BIAS", "NEUTRAL").upper()   # BUY / SELL / NEUTRAL
DEALER_GAMMA = float(os.getenv("DEALER_GAMMA", 0))

# ── Helpers ────────────────────────────────────────────────────────────────

def normalise_symbol(symbol: str) -> str:
    """Accept GOLD or XAUUSD, always return yfinance ticker."""
    s = symbol.upper().strip()
    return "GC=F" if s in ("GOLD", "XAUUSD", "GC=F") else s

def get_rates(symbol: str, period: str = "5d", interval: str = "1h") -> pd.DataFrame:
    ticker = normalise_symbol(symbol)
    df = yf.download(ticker, period=period, interval=interval,
                     progress=False, auto_adjust=True)
    if df.empty:
        raise ValueError(f"No data returned for {ticker}")
    df.columns = [c.lower() for c in df.columns]
    return df

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

def layer_cot(direction: str) -> bool:
    """COT/CFTC bias (set via env var COT_BIAS=BUY|SELL|NEUTRAL)."""
    if COT_BIAS == "NEUTRAL":
        return True
    return COT_BIAS == direction

def layer_gamma(direction: str) -> bool:
    """Dealer gamma proxy — negative gamma = dealers amplify moves."""
    if direction == "BUY":
        return DEALER_GAMMA <= 0
    return DEALER_GAMMA >= 0

def layer_structure(direction: str, df: pd.DataFrame) -> bool:
    """Higher highs / lower lows over last 20 H1 bars."""
    if len(df) < 10:
        return False
    recent = df.tail(5)
    prior  = df.iloc[-10:-5]
    if direction == "BUY":
        return (recent["high"].max() > prior["high"].max() and
                recent["low"].min()  > prior["low"].min())
    return (recent["high"].max() < prior["high"].max() and
            recent["low"].min()  < prior["low"].min())

def layer_price_action(direction: str, df: pd.DataFrame) -> bool:
    """Last candle body vs wick — momentum candle check."""
    if len(df) < 2:
        return False
    last = df.iloc[-1]
    body      = abs(last["close"] - last["open"])
    wick_up   = last["high"]  - max(last["close"], last["open"])
    wick_down = min(last["close"], last["open"]) - last["low"]
    if body == 0:
        return False
    if direction == "BUY":
        return last["close"] > last["open"] and wick_down < body * 0.5
    return last["close"] < last["open"] and wick_up < body * 0.5

def layer_patterns(direction: str, df_h4: pd.DataFrame) -> bool:
    """Double bottom / double top on H4 (within 0.5% tolerance)."""
    if len(df_h4) < 20:
        return False
    lows  = df_h4["low"].values
    highs = df_h4["high"].values
    if direction == "BUY":
        l1 = lows[-20:-10].min()
        l2 = lows[-10:].min()
        return l1 > 0 and abs(l1 - l2) / l1 < 0.005
    h1 = highs[-20:-10].max()
    h2 = highs[-10:].max()
    return h1 > 0 and abs(h1 - h2) / h1 < 0.005

def evaluate_signal(direction: str, symbol: str) -> dict:
    direction = direction.upper()
    try:
        df_h1  = get_rates(symbol, period="5d",  interval="1h")
        df_h4  = get_rates(symbol, period="30d", interval="4h")
    except Exception as e:
        log.error(f"Data fetch error: {e}")
        return {
            "direction": direction, "symbol": symbol,
            "score": 0, "threshold": 4, "qualified": False,
            "action": "HOLD", "confidence": 0,
            "error": str(e), "layers": {}
        }

    layers = {
        "cot_cftc":         layer_cot(direction),
        "dealer_gamma":     layer_gamma(direction),
        "market_structure": layer_structure(direction, df_h1),
        "price_action":     layer_price_action(direction, df_h1),
        "chart_patterns":   layer_patterns(direction, df_h4),
    }
    score = sum(layers.values())
    return {
        "direction": direction,
        "symbol":    symbol,
        "layers":    {k: bool(v) for k, v in layers.items()},
        "score":     score,
        "threshold": 4,
        "qualified": score >= 4,
        "action":    direction if score >= 4 else "HOLD",
        "confidence": int((score / 5) * 100),
        "price":     float(df_h1["close"].iloc[-1]),
        "timestamp": datetime.utcnow().isoformat(),
    }

# ── Routes ─────────────────────────────────────────────────────────────────

@app.route("/health")
def health():
    return jsonify({
        "status": "ok",
        "symbol": DEFAULT_SYMBOL,
        "cot_bias": COT_BIAS,
        "dealer_gamma": DEALER_GAMMA,
        "timestamp": datetime.utcnow().isoformat()
    })

@app.route("/mcp", methods=["GET", "POST"])
def mcp():
    return jsonify({
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "serverInfo": {"name": "matlama-mt5-bridge", "version": "3.0.0"}
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

    # Normalise
    if symbol.upper() in ("GOLD", "XAUUSD"):
        symbol = "XAUUSD"

    log.info(f"Signal request | symbol={symbol} direction={direction}")

    if direction:
        direction = direction.upper()
        if direction not in ("BUY", "SELL"):
            return jsonify({"error": "direction must be BUY or SELL"}), 400
        return jsonify(evaluate_signal(direction, symbol))

    # Auto-select best direction
    buy  = evaluate_signal("BUY",  symbol)
    sell = evaluate_signal("SELL", symbol)

    if buy["score"] >= sell["score"]:
        result = buy
    else:
        result = sell

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

    if vol_pct < 1.5:
        spoof_thresh, mom_thresh = 65, 80
    elif vol_pct < 2.5:
        spoof_thresh, mom_thresh = 60, 70
    elif vol_pct < 3.5:
        spoof_thresh, mom_thresh = 55, 65
    else:
        spoof_thresh, mom_thresh = 50, 60

    momentum_score = min(100, price_velocity * 15)
    normal_spread  = atr * 0.05
    spread_ratio   = (spread / normal_spread) if normal_spread else 1
    spoofing_score = min(100, spread_ratio * 40 + (volume / 1000) * 10)
    flash_crash    = price_velocity > 8 and volume > 5000
    confidence     = (spoofing_score + momentum_score) / 2

    if flash_crash:
        return jsonify({"signal": "FLASH_CRASH", "qualified": True,
                        "confidence": 90,
                        "spoofing_score": round(spoofing_score),
                        "momentum_score": round(momentum_score)})

    if spoofing_score > spoof_thresh and momentum_score > mom_thresh * 0.9:
        return jsonify({"signal": "SELL_RALLY", "qualified": True,
                        "confidence": round(confidence),
                        "spoofing_score": round(spoofing_score),
                        "momentum_score": round(momentum_score),
                        "vol_regime": round(vol_pct, 2)})

    if spoofing_score > 65 and price < 3200:
        return jsonify({"signal": "BUY_SUPPORT", "qualified": True,
                        "confidence": 72,
                        "spoofing_score": round(spoofing_score),
                        "momentum_score": round(momentum_score)})

    return jsonify({"signal": "NO_SIGNAL", "qualified": False,
                    "confidence": round(confidence),
                    "spoofing_score": round(spoofing_score),
                    "momentum_score": round(momentum_score),
                    "vol_regime": round(vol_pct, 2)})

@app.route("/cmd", methods=["POST"])
@require_api_key
def cmd():
    data      = request.get_json() or {}
    command   = data.get("cmd", "").upper()
    symbol    = data.get("symbol", DEFAULT_SYMBOL)
    log.info(f"CMD: {command} | symbol={symbol}")

    if command in ("BUY", "SELL"):
        sig = evaluate_signal(command, symbol)
        return jsonify({"executed": sig["qualified"], "cmd": command,
                        "signal": sig,
                        "reason": "Signal qualified" if sig["qualified"]
                                  else "Score below 4/5 threshold"})

    return jsonify({"error": f"Unknown command: {command}"}), 400

if __name__ == "__main__":
    port = int(os.getenv("PORT", 5000))
    app.run(host="0.0.0.0", port=port)
