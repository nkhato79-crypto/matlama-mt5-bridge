"""
Matlama Orchestrator v2 - Institutional Decision Engine
-------------------------------------------------------
Central policy layer for Matlama Quant Ecosystem.

Responsibilities:
- Regime detection (Trend / Range / Crisis / News / Mixed)
- Ensemble model scoring (Quant + Bridge/RF)
- Trade memory tracking (win-rate + drawdown adaptation)
- Risk-conditioned threshold adjustment
- Final trade authorization (BUY / SELL / HOLD)

Exposes:
POST /decision_v2
POST /report_trade   (feedback loop training)
GET  /health         (status/monitoring)

Runs: Flask (localhost:7000)
"""

from flask import Flask, request, jsonify
import numpy as np
import joblib
import os
import logging
from collections import deque
from datetime import datetime

# =========================================================
# APP INIT
# =========================================================
app = Flask(__name__)

BASE_DIR = r"C:\Matlama\model"
LOG_DIR = r"C:\Matlama\logs"
os.makedirs(LOG_DIR, exist_ok=True)

logging.basicConfig(
    filename=os.path.join(LOG_DIR, "orchestrator_v2.log"),
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s"
)
logger = logging.getLogger("orchestrator_v2")

# Load models — Quant model is optional; if not yet trained/saved, the
# orchestrator degrades gracefully to RF-only scoring rather than crashing.
QUANT_AVAILABLE = True
try:
    quant_model  = joblib.load(os.path.join(BASE_DIR, "quant_model.pkl"))
    quant_scaler = joblib.load(os.path.join(BASE_DIR, "quant_scaler.pkl"))
except FileNotFoundError as e:
    logger.warning(f"Quant model not found, running RF-only: {e}")
    quant_model  = None
    quant_scaler = None
    QUANT_AVAILABLE = False

mbv3_model   = joblib.load(os.path.join(BASE_DIR, "rf_model.pkl"))
mbv3_scaler  = joblib.load(os.path.join(BASE_DIR, "scaler.pkl"))

# Feature order expected by each model. Adjust to match your actual
# training column order (this MUST match how quant_model / rf_model
# were fit, or scaling will silently corrupt predictions).
QUANT_FEATURE_ORDER = [
    "price", "spread", "atr", "adx", "volatility",
    "momentum", "volume", "rsi"
]
MBV3_FEATURE_ORDER = [
    "price", "spread", "atr", "adx", "volatility",
    "ema_fast", "ema_slow", "rsi", "volume"
]

# =========================================================
# TRADE MEMORY SYSTEM
# =========================================================
class TradeMemory:
    def __init__(self, maxlen=300):
        self.trades = deque(maxlen=maxlen)

    def add(self, trade):
        """
        trade = {
            "regime": "TREND",
            "result": 1 or 0,
            "score": float
        }
        """
        self.trades.append(trade)

    def win_rate(self, regime=None):
        data = list(self.trades)

        if regime:
            data = [t for t in data if t["regime"] == regime]

        if len(data) == 0:
            return 0.5

        wins = sum(t["result"] for t in data)
        return wins / len(data)

    def drawdown_factor(self):
        if len(self.trades) == 0:
            return 1.0

        losses = sum(1 for t in self.trades if t["result"] == 0)
        ratio = losses / len(self.trades)

        # clamp between 0.5 and 1.0
        return max(0.5, 1.0 - ratio)

    def streak(self):
        """Positive int = current win streak, negative int = current loss streak."""
        data = list(self.trades)
        if not data:
            return 0

        last_result = data[-1]["result"]
        count = 0
        for t in reversed(data):
            if t["result"] == last_result:
                count += 1
            else:
                break
        return count if last_result == 1 else -count


memory = TradeMemory()


# =========================================================
# REGIME ENGINE
# =========================================================
def detect_regime(f):
    atr = f.get("atr", 0)
    adx = f.get("adx", 0)
    volatility = f.get("volatility", 0)

    if f.get("news_risk", 0) == 1:
        return "NEWS"

    if atr > 25 and adx > 25:
        return "TREND"

    if volatility < 0.4:
        return "RANGE"

    if atr > 40 and volatility > 0.8:
        return "CRISIS"

    return "MIXED"


# =========================================================
# MODEL SCORING
# =========================================================
def score_model(model, scaler, features, order):
    """
    Build a feature vector in the required order, scale it, and
    return a directional confidence score in [-1, 1]:
      +1  => strong BUY conviction
      -1  => strong SELL conviction
       0  => neutral

    Assumes model.predict_proba exists and class order is [SELL, BUY]
    i.e. classes_ == [0, 1] where 1 = BUY. If your models were trained
    with a different label scheme, adjust the proba indexing below.
    """
    if model is None or scaler is None:
        return 0.0

    try:
        vector = np.array([[features.get(k, 0.0) for k in order]])
        scaled = scaler.transform(vector)

        proba = model.predict_proba(scaled)[0]  # [P(SELL), P(BUY)]
        p_buy = proba[1] if len(proba) > 1 else proba[0]

        # Convert probability to a signed confidence score
        score = (p_buy - 0.5) * 2  # maps 0..1 -> -1..1
        return float(np.clip(score, -1.0, 1.0))

    except Exception as e:
        logger.error(f"score_model failed: {e}")
        return 0.0


# =========================================================
# ENSEMBLE + ADAPTIVE THRESHOLD
# =========================================================
# Base model weights, re-balanced per regime. Trend-following regimes
# lean on the Bridge RF (structure/momentum), range/mixed lean on Quant
# (mean-reversion / pressure-point logic).
REGIME_WEIGHTS = {
    "TREND":  {"quant": 0.35, "mbv3": 0.65},
    "RANGE":  {"quant": 0.65, "mbv3": 0.35},
    "CRISIS": {"quant": 0.50, "mbv3": 0.50},
    "NEWS":   {"quant": 0.50, "mbv3": 0.50},
    "MIXED":  {"quant": 0.50, "mbv3": 0.50},
}

BASE_THRESHOLD = 0.30  # minimum |ensemble_score| required to authorize a trade


def compute_ensemble(quant_score, mbv3_score, regime):
    if not QUANT_AVAILABLE:
        return float(np.clip(mbv3_score, -1.0, 1.0))

    weights = REGIME_WEIGHTS.get(regime, {"quant": 0.5, "mbv3": 0.5})
    ensemble = (quant_score * weights["quant"]) + (mbv3_score * weights["mbv3"])
    return float(np.clip(ensemble, -1.0, 1.0))


def adaptive_threshold(regime):
    """
    Threshold rises when recent performance in this regime is poor
    (fewer trades get through) and falls when performance is strong.
    Also widens automatically during a losing streak, tightens on a
    winning streak, as an extra layer of aggressiveness control.
    """
    wr = memory.win_rate(regime)
    dd = memory.drawdown_factor()
    streak = memory.streak()

    # wr=0.5 -> no adjustment; wr>0.5 lowers threshold (more permissive);
    # wr<0.5 raises threshold (more conservative)
    wr_adjustment = (0.5 - wr) * 0.4

    # drawdown_factor in [0.5, 1.0]; lower dd (worse drawdown) raises threshold
    dd_adjustment = (1.0 - dd) * 0.3

    # losing streak of 3+ adds extra caution; winning streak of 3+ loosens slightly
    streak_adjustment = 0.0
    if streak <= -3:
        streak_adjustment = 0.05
    elif streak >= 3:
        streak_adjustment = -0.03

    threshold = BASE_THRESHOLD + wr_adjustment + dd_adjustment + streak_adjustment
    return float(np.clip(threshold, 0.15, 0.75))


# =========================================================
# RISK FILTER
# =========================================================
def risk_filter(f, regime):
    """
    Returns (passed: bool, reason: str). A failed risk filter forces
    HOLD regardless of model confidence.
    """
    spread = f.get("spread", 0)
    max_spread = f.get("max_spread", 3.0)

    if spread > max_spread:
        return False, f"spread {spread} exceeds max_spread {max_spread}"

    if regime == "NEWS" and not f.get("allow_news_trading", False):
        return False, "news_risk active and news trading disabled"

    if regime == "CRISIS" and not f.get("allow_crisis_trading", False):
        return False, "crisis regime and crisis trading disabled"

    equity = f.get("equity")
    balance = f.get("balance")
    if equity is not None and balance is not None and balance > 0:
        drawdown_pct = 1 - (equity / balance)
        max_dd_pct = f.get("max_account_drawdown_pct", 0.20)
        if drawdown_pct > max_dd_pct:
            return False, f"account drawdown {drawdown_pct:.2%} exceeds max {max_dd_pct:.2%}"

    return True, "ok"


# =========================================================
# ROUTES
# =========================================================
@app.route("/decision_v2", methods=["POST"])
def decision_v2():
    f = request.get_json(force=True) or {}

    regime = detect_regime(f)

    quant_score = score_model(quant_model, quant_scaler, f, QUANT_FEATURE_ORDER)
    mbv3_score = score_model(mbv3_model, mbv3_scaler, f, MBV3_FEATURE_ORDER)
    ensemble_score = compute_ensemble(quant_score, mbv3_score, regime)

    passed, reason = risk_filter(f, regime)
    threshold = adaptive_threshold(regime)

    if not passed:
        decision = "HOLD"
    elif ensemble_score >= threshold:
        decision = "BUY"
    elif ensemble_score <= -threshold:
        decision = "SELL"
    else:
        decision = "HOLD"

    response = {
        "decision": decision,
        "confidence": round(abs(ensemble_score), 4),
        "ensemble_score": round(ensemble_score, 4),
        "regime": regime,
        "threshold_used": round(threshold, 4),
        "model_scores": {
            "quant": round(quant_score, 4),
            "mbv3": round(mbv3_score, 4),
        },
        "risk_check": {"passed": passed, "reason": reason},
        "memory_stats": {
            "win_rate_regime": round(memory.win_rate(regime), 4),
            "win_rate_overall": round(memory.win_rate(), 4),
            "drawdown_factor": round(memory.drawdown_factor(), 4),
            "streak": memory.streak(),
        },
        "timestamp": datetime.utcnow().isoformat() + "Z",
    }

    logger.info(f"DECISION {response}")
    return jsonify(response)


@app.route("/report_trade", methods=["POST"])
def report_trade():
    f = request.get_json(force=True) or {}

    trade = {
        "regime": f.get("regime", "MIXED"),
        "result": int(f.get("result", 0)),   # 1 = win, 0 = loss
        "score": float(f.get("score", 0.0)),
    }
    memory.add(trade)

    logger.info(f"TRADE_REPORTED {trade}")
    return jsonify({
        "status": "recorded",
        "win_rate_overall": round(memory.win_rate(), 4),
        "win_rate_regime": round(memory.win_rate(trade["regime"]), 4),
        "drawdown_factor": round(memory.drawdown_factor(), 4),
        "streak": memory.streak(),
    })


@app.route("/health", methods=["GET"])
def health():
    return jsonify({
        "status": "ok" if QUANT_AVAILABLE else "degraded",
        "models_loaded": {
            "quant_model": QUANT_AVAILABLE,
            "mbv3_model": mbv3_model is not None,
        },
        "note": None if QUANT_AVAILABLE else "Quant model not found — running RF-only",
        "trade_memory_size": len(memory.trades),
        "timestamp": datetime.utcnow().isoformat() + "Z",
    })


# =========================================================
# MAIN
# =========================================================
if __name__ == "__main__":
    logger.info("Matlama Orchestrator v2 starting on port 7000")
    app.run(host="0.0.0.0", port=7000, debug=False)
