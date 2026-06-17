    import os
import logging
from datetime import datetime
from functools import wraps
from flask import Flask, request, jsonify
from dotenv import load_dotenv
import requests as http_requests

load_dotenv()
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger(__name__)
app = Flask(__name__)

MT5_VPS_URL = os.getenv("MT5_VPS_URL", "")
API_KEY = os.getenv("API_KEY", "")
SYMBOL = os.getenv("SYMBOL", "XAUUSD")
LOT_SIZE = float(os.getenv("LOT_SIZE", 0.01))
COT_BIAS = os.getenv("COT_BIAS", "NEUTRAL").upper()
DEALER_GAMMA = float(os.getenv("DEALER_GAMMA", 0))

def require_api_key(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        auth = request.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or auth[7:] != API_KEY:
            return jsonify({"error": "Unauthorized"}), 401
        return f(*args, **kwargs)
    return decorated

def call_vps(endpoint, method="GET", data=None):
    try:
        url = f"{MT5_VPS_URL}{endpoint}"
        if method == "POST":
            resp = http_requests.post(url, json=data, timeout=15)
        else:
            resp = http_requests.get(url, timeout=15)
        return resp.json()
    except Exception as e:
        return {"error": str(e)}

def check_cot(direction):
    if COT_BIAS == "NEUTRAL":
        return True
    return COT_BIAS == direction

def check_gamma(direction):
    if direction == "BUY":
        return DEALER_GAMMA <= 0
    return DEALER_GAMMA >= 0

def check_structure(direction):
    data = call_vps(f"/rates?symbol={SYMBOL}&timeframe=H1&count=20")
    if "error" in data or not data.get("rates"):
        return False
    rates = data["rates"]
    highs = [r["high"] for r in rates]
    lows = [r["low"] for r in rates]
    if direction == "BUY":
        return highs[-1] > highs[-5] and lows[-1] > lows[-5]
    return highs[-1] < highs[-5] and lows[-1] < lows[-5]

def check_price_action(direction):
    data = call_vps(f"/rates?symbol={SYMBOL}&timeframe=H1&count=3")
    if "error" in data or not data.get("rates"):
        return False
    last = data["rates"][-1]
    body = abs(last["close"] - last["open"])
    wick_up = last["high"] - max(last["close"], last["open"])
    wick_down = min(last["close"], last["open"]) - last["low"]
    if direction == "BUY":
        return last["close"] > last["open"] and wick_down < body
    return last["close"] < last["open"] and wick_up < body

def check_patterns(direction):
    data = call_vps(f"/rates?symbol={SYMBOL}&timeframe=H4&count=30")
    if "error" in data or not data.get("rates"):
        return False
    rates = data["rates"]
    lows = [r["low"] for r in rates]
    highs = [r["high"] for r in rates]
    if direction == "BUY":
        l1, l2 = min(lows[-15:-5]), min(lows[-5:])
        return abs(l1 - l2) / l1 < 0.005
    h1, h2 = max(highs[-15:-5]), max(highs[-5:])
    return abs(h1 - h2) / h1 < 0.005

def evaluate_signal(direction):
    layers = {
        "cot_cftc": check_cot(direction),
        "dealer_gamma": check_gamma(direction),
        "market_structure": check_structure(direction),
        "price_action": check_price_action(direction),
        "chart_patterns": check_patterns(direction),
    }
    score = sum(layers.values())
    return {"layers": layers, "score": score, "threshold": 4, "qualified": score >= 4, "direction": direction}

@app.route("/health")
def health():
    return jsonify({"status": "ok", "symbol": SYMBOL, "timestamp": datetime.utcnow().isoformat()})

@app.route("/mcp", methods=["GET", "POST"])
def mcp():
    return jsonify({"protocolVersion": "2024-11-05", "capabilities": {}, "serverInfo": {"name": "matlama-mt5-bridge", "version": "2.0.0"}})

@app.route("/signal", methods=["POST"])
@require_api_key
def signal():
    data = request.get_json() or {}
    direction = data.get("direction", "").upper()
    if direction not in ("BUY", "SELL"):
        return jsonify({"error": "direction must be BUY or SELL"}), 400
    return jsonify(evaluate_signal(direction))

@app.route("/hft_signal", methods=["POST"])
@require_api_key
def hft_signal():
    data = request.get_json() or {}
    market = data.get("market_data", {})

    price          = market.get("price", 0)
    spread         = market.get("spread", 0)
    volume         = market.get("volume", 0)
    price_velocity = market.get("price_velocity", 0)
    atr            = market.get("atr", 1)

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
        return jsonify({
            "signal": "FLASH_CRASH",
            "qualified": True,
            "confidence": 90,
            "spoofing_score": round(spoofing_score),
            "momentum_score": round(momentum_score)
        })

    if spoofing_score > spoof_thresh and momentum_score > mom_thresh * 0.9:
        return jsonify({
            "signal": "SELL_RALLY",
            "qualified": True,
            "confidence": round(confidence),
            "spoofing_score": round(spoofing_score),
            "momentum_score": round(momentum_score),
            "vol_regime": round(vol_pct, 2)
        })

    if spoofing_score > 65 and price < 3200:
        return jsonify({
            "signal": "BUY_SUPPORT",
            "qualified": True,
            "confidence": 72,
            "spoofing_score": round(spoofing_score),
            "momentum_score": round(momentum_score)
        })

    return jsonify({
        "signal": "NO_SIGNAL",
        "qualified": False,
        "confidence": round(confidence),
        "spoofing_score": round(spoofing_score),
        "momentum_score": round(momentum_score),
        "vol_regime": round(vol_pct, 2)
    })

@app.route("/trade", methods=["POST"])
@require_api_key
def trade():
    data = request.get_json() or {}
    direction = data.get("direction", "").upper()
    if direction not in ("BUY", "SELL"):
        return jsonify({"error": "direction must be BUY or SELL"}), 400
    if not data.get("skip_signal_check"):
        sig = evaluate_signal(direction)
        if not sig["qualified"]:
            return jsonify({"executed": False, "reason": "Signal did not meet 4/5 threshold", "signal": sig})
    result = call_vps("/trade", method="POST", data={"direction": direction, "lot": data.get("lot", LOT_SIZE), "sl_pips": data.get("sl_pips", 50), "tp_pips": data.get("tp_pips", 100)})
    return jsonify({"executed": True, **result})

@app.route("/close", methods=["POST"])
@require_api_key
def close():
    return jsonify(call_vps("/close", method="POST", data=request.get_json() or {}))

@app.route("/positions")
@require_api_key
def positions():
    return jsonify(call_vps("/positions"))

@app.route("/history")
@require_api_key
def history():
    return jsonify(call_vps(f"/history?days={request.args.get('days', 7)}"))

@app.route("/cmd", methods=["POST"])
@require_api_key
def cmd():
    data = request.get_json() or {}
    command = data.get("cmd", "").upper()
    log.info(f"CMD: {command}")
    if command in ("BUY", "SELL"):
        sig = evaluate_signal(command)
        if not sig["qualified"]:
            return jsonify({"executed": False, "cmd": command, "reason": "Signal did not meet 4/5 threshold"})
        result = call_vps("/trade", method="POST", data={"direction": command, "lot": data.get("lot", LOT_SIZE)})
        return jsonify({"executed": True, "cmd": command, **result})
    elif command in ("CLOSE", "CLOSE_ALL", "FLAT"):
        return jsonify(call_vps("/close", method="POST", data={}))
    elif command == "STATUS":
        return jsonify(call_vps("/positions"))
    return jsonify({"error": f"Unknown command: {command}"}), 400

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", 5000)))
