"""
Matlama Orchestrator v2 - Institutional Decision Engine
-------------------------------------------------------
Central policy layer for Matlama Quant Ecosystem.

IMPORTANT ARCHITECTURE NOTE (v2.1 correction):
Each strategy (MatlamaQuant, MatlamaBridgeV3, MatlamaBridgeHFT,
MatlamaScalper) has its OWN dedicated model, trained on ITS OWN
strategy-specific features. These feature spaces are not comparable
across strategies (e.g. BridgeV3's buy_score/sell_score mean nothing
to the Quant model, and vice versa) so there is no cross-model
ensemble blending here — each request is scored only against the one
model that matches its "strategy" field. Regime detection, the risk
filter, the adaptive threshold, and trade memory are shared/generic
across all strategies, since those operate on market-level conditions
rather than strategy-internal features.

Responsibilities:
- Regime detection (Trend / Range / Crisis / News / Mixed)
- Per-strategy dedicated model scoring (Quant / BridgeV3 / HFT / Scalper)
- Trade memory tracking (win-rate + drawdown adaptation), overall and
  per-strategy
- Risk-conditioned threshold adjustment
- Final trade authorization (BUY / SELL / HOLD)

Exposes:
POST /decision_v2      (requires "strategy": "QUANT"|"MBV3"|"HFT"|"SCALPER")
POST /report_trade     (feedback loop training)
GET  /health           (status/monitoring)

Runs: Flask (localhost:7000)
"""

from flask import Flask, request, jsonify
from functools import wraps
import numpy as np
import joblib
import json
import os
import logging
from collections import deque
from datetime import datetime
import threading

# =========================================================
# APP INIT
# =========================================================
app = Flask(__name__)

BASE_DIR = os.getenv("MODEL_DIR", r"C:\Matlama\model")
LOG_DIR = os.getenv("LOG_DIR", r"C:\Matlama\logs")
MEMORY_FILE = os.path.join(LOG_DIR, "trade_memory.json")
API_KEY = os.getenv("ORCH_API_KEY", "")
os.makedirs(LOG_DIR, exist_ok=True)

logging.basicConfig(
    filename=os.path.join(LOG_DIR, "orchestrator_v2.log"),
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s"
)
logger = logging.getLogger("orchestrator_v2")


def require_api_key(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not API_KEY:
            return f(*args, **kwargs)
        auth = request.headers.get("Authorization", "")
        if auth == f"Bearer {API_KEY}":
            return f(*args, **kwargs)
        return jsonify({"error": "Unauthorized"}), 401
    return decorated


def load_pair(model_name, scaler_name, label):
    """Load a (model, scaler) pair; degrade gracefully if not yet trained."""
    try:
        model  = joblib.load(os.path.join(BASE_DIR, model_name))
        scaler = joblib.load(os.path.join(BASE_DIR, scaler_name))
        logger.info(f"{label} model loaded OK")
        return model, scaler, True
    except FileNotFoundError as e:
        logger.warning(f"{label} model not found, strategy will run HOLD-only: {e}")
        return None, None, False


# Each strategy's own dedicated model. None of these are blended together —
# a request for one strategy is only ever scored against its own model.
quant_model,   quant_scaler,   QUANT_AVAILABLE   = load_pair("quant_model.pkl",   "quant_scaler.pkl",   "QUANT")
mbv3_model,    mbv3_scaler,    MBV3_AVAILABLE    = load_pair("rf_model.pkl",      "scaler.pkl",         "MBV3 (BridgeV3)")
hft_model,     hft_scaler,     HFT_AVAILABLE     = load_pair("hft_model.pkl",     "hft_scaler.pkl",     "HFT")
scalper_model, scalper_scaler, SCALPER_AVAILABLE = load_pair("scalper_model.pkl", "scalper_scaler.pkl", "SCALPER")

STRATEGIES = {
    "QUANT":   {"model": quant_model,   "scaler": quant_scaler,   "available": QUANT_AVAILABLE,
                # Real, pre-trade-computable features only. duration_min is
                # deliberately excluded — it's only known after a trade
                # closes, so it can never be supplied at decision time.
                "feature_order": ["fib_level", "velocity", "volume_ratio", "rsi_accel", "signal_score"]},
    "MBV3":    {"model": mbv3_model,    "scaler": mbv3_scaler,    "available": MBV3_AVAILABLE,
                "feature_order": ["buy_score", "sell_score", "signal_score"]},
    "HFT":     {"model": hft_model,     "scaler": hft_scaler,     "available": HFT_AVAILABLE,
                "feature_order": ["wick_pips", "momentum_pips", "volume_ratio", "rsi"]},
    "SCALPER": {"model": scalper_model, "scaler": scalper_scaler, "available": SCALPER_AVAILABLE,
                "feature_order": ["ema_diff_pips", "rsi", "momentum_pips"]},
}


# =========================================================
# TRADE MEMORY SYSTEM
# =========================================================
class TradeMemory:
    def __init__(self, maxlen=300, persist_path=None):
        self.trades = deque(maxlen=maxlen)
        self._persist_path = persist_path
        self._lock = threading.Lock()
        self._load()

    def _load(self):
        if self._persist_path and os.path.exists(self._persist_path):
            try:
                with open(self._persist_path, "r") as f:
                    data = json.load(f)
                for t in data:
                    self.trades.append(t)
                logger.info(f"Loaded {len(self.trades)} trades from disk")
            except Exception as e:
                logger.warning(f"Could not load trade memory: {e}")

    def _save(self):
        if not self._persist_path:
            return
        try:
            with open(self._persist_path, "w") as f:
                json.dump(list(self.trades), f)
        except Exception as e:
            logger.warning(f"Could not persist trade memory: {e}")

    def add(self, trade):
        """
        trade = {
            "strategy": "QUANT",
            "regime": "TREND",
            "result": 1 or 0,
            "score": float
        }
        """
        with self._lock:
            self.trades.append(trade)
            self._save()

    def win_rate(self, regime=None, strategy=None):
        data = list(self.trades)

        if regime:
            data = [t for t in data if t["regime"] == regime]
        if strategy:
            data = [t for t in data if t.get("strategy") == strategy]

        if len(data) == 0:
            return 0.5

        wins = sum(t["result"] for t in data)
        return wins / len(data)

    def drawdown_factor(self, strategy=None):
        data = list(self.trades)
        if strategy:
            data = [t for t in data if t.get("strategy") == strategy]

        if len(data) == 0:
            return 1.0

        losses = sum(1 for t in data if t["result"] == 0)
        ratio = losses / len(data)

        # clamp between 0.5 and 1.0
        return max(0.5, 1.0 - ratio)

    def streak(self, strategy=None):
        """Positive int = current win streak, negative int = current loss streak."""
        data = list(self.trades)
        if strategy:
            data = [t for t in data if t.get("strategy") == strategy]
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


memory = TradeMemory(persist_path=MEMORY_FILE)


# =========================================================
# REGIME ENGINE (shared across all strategies)
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
    i.e. classes_ == [0, 1] where 1 = BUY. If a model was trained with
    a different label scheme, adjust the proba indexing below.
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
# ADAPTIVE THRESHOLD (per-strategy, since each has its own memory)
# =========================================================
# Per-strategy base threshold. QUANT was moderately loosened (0.30 -> 0.22)
# on 2026-07-13 after adding Layer 6/7 (Sweep+FVG) to MatlamaQuant.mq5 —
# the extra confluence layers provide independent confirmation, justifying
# a lower ML confidence bar for QUANT specifically. Other strategies are
# left at the original 0.30 baseline.
BASE_THRESHOLDS = {
    "QUANT": 0.22,
}
BASE_THRESHOLD_DEFAULT = 0.30


def adaptive_threshold(regime, strategy):
    """
    Threshold rises when recent performance (in this regime, for this
    strategy) is poor, and falls when performance is strong. Also widens
    automatically during a losing streak, tightens on a winning streak.
    """
    base = BASE_THRESHOLDS.get(strategy, BASE_THRESHOLD_DEFAULT)

    wr = memory.win_rate(regime=regime, strategy=strategy)
    dd = memory.drawdown_factor(strategy=strategy)
    streak = memory.streak(strategy=strategy)

    wr_adjustment = (0.5 - wr) * 0.4
    dd_adjustment = (1.0 - dd) * 0.3

    streak_adjustment = 0.0
    if streak <= -3:
        streak_adjustment = 0.05
    elif streak >= 3:
        streak_adjustment = -0.03

    threshold = base + wr_adjustment + dd_adjustment + streak_adjustment
    return float(np.clip(threshold, 0.15, 0.75))


# =========================================================
# RISK FILTER (shared across all strategies)
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
@require_api_key
def decision_v2():
    f = request.get_json(force=True) or {}

    strategy = f.get("strategy", "").upper()
    if strategy not in STRATEGIES:
        return jsonify({
            "decision": "HOLD",
            "error": f"unknown or missing 'strategy' field: {strategy!r}. "
                     f"Must be one of {list(STRATEGIES.keys())}",
        }), 400

    cfg = STRATEGIES[strategy]
    regime = detect_regime(f)

    score = score_model(cfg["model"], cfg["scaler"], f, cfg["feature_order"])

    passed, reason = risk_filter(f, regime)
    threshold = adaptive_threshold(regime, strategy)

    if not cfg["available"]:
        decision = "HOLD"
    elif not passed:
        decision = "HOLD"
    elif score >= threshold:
        decision = "BUY"
    elif score <= -threshold:
        decision = "SELL"
    else:
        decision = "HOLD"

    response = {
        "decision": decision,
        "confidence": round(abs(score), 4),
        "ensemble_score": round(score, 4),  # kept for EA compatibility; not actually an ensemble anymore
        "regime": regime,
        "strategy": strategy,
        "model_available": cfg["available"],
        "threshold_used": round(threshold, 4),
        "risk_check": {"passed": passed, "reason": reason},
        "memory_stats": {
            "win_rate_strategy": round(memory.win_rate(strategy=strategy), 4),
            "win_rate_regime": round(memory.win_rate(regime=regime, strategy=strategy), 4),
            "drawdown_factor": round(memory.drawdown_factor(strategy=strategy), 4),
            "streak": memory.streak(strategy=strategy),
        },
        "timestamp": datetime.utcnow().isoformat() + "Z",
    }

    logger.info(f"DECISION {response}")
    return jsonify(response)


@app.route("/report_trade", methods=["POST"])
@require_api_key
def report_trade():
    f = request.get_json(force=True) or {}

    trade = {
        "strategy": f.get("strategy", "UNKNOWN").upper(),
        "regime": f.get("regime", "MIXED"),
        "result": int(f.get("result", 0)),   # 1 = win, 0 = loss
        "score": float(f.get("score", 0.0)),
    }
    memory.add(trade)

    logger.info(f"TRADE_REPORTED {trade}")
    return jsonify({
        "status": "recorded",
        "win_rate_strategy": round(memory.win_rate(strategy=trade["strategy"]), 4),
        "win_rate_overall": round(memory.win_rate(), 4),
        "drawdown_factor": round(memory.drawdown_factor(strategy=trade["strategy"]), 4),
        "streak": memory.streak(strategy=trade["strategy"]),
    })


@app.route("/health", methods=["GET"])
def health():
    availability = {name: cfg["available"] for name, cfg in STRATEGIES.items()}
    all_ok = all(availability.values())
    missing = [name for name, ok in availability.items() if not ok]

    return jsonify({
        "status": "ok" if all_ok else "degraded",
        "models_loaded": availability,
        "note": None if all_ok else f"Missing models for: {missing} — those strategies will HOLD until trained",
        "trade_memory_size": len(memory.trades),
        "timestamp": datetime.utcnow().isoformat() + "Z",
    })


# =========================================================
# HEARTBEAT / WATCHDOG
# =========================================================
_heartbeat_lock = threading.Lock()
_last_heartbeat = datetime.utcnow()


def _update_heartbeat():
    global _last_heartbeat
    with _heartbeat_lock:
        _last_heartbeat = datetime.utcnow()


def _get_heartbeat():
    with _heartbeat_lock:
        return _last_heartbeat


@app.before_request
def _touch_heartbeat():
    _update_heartbeat()


@app.route("/heartbeat", methods=["GET"])
def heartbeat():
    last = _get_heartbeat()
    age = (datetime.utcnow() - last).total_seconds()
    return jsonify({
        "alive": True,
        "last_activity": last.isoformat() + "Z",
        "idle_seconds": round(age, 1),
        "uptime_seconds": round((datetime.utcnow() - _startup_time).total_seconds(), 1),
    })


_startup_time = datetime.utcnow()


# =========================================================
# MAIN
# =========================================================
if __name__ == "__main__":
    logger.info("Matlama Orchestrator v2 starting on port 7000")
    app.run(host="0.0.0.0", port=7000, debug=False)
