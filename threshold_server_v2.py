"""
Matlama Gold Trading — ML Threshold Server v3
Production-ready with Waitress WSGI server
Serves both MatlamaBridgeV3 and MatlamaQuant thresholds

Endpoints:
  GET /                    — health check
  GET /threshold           — MatlamaBridgeV3 threshold
  GET /quant_threshold     — MatlamaQuant threshold
  POST /predict            — MatlamaBridgeV3 prediction
  POST /quant_predict      — MatlamaQuant prediction

Runs on localhost:6000 via Waitress (production WSGI)
Task Scheduler: Matlama_ThresholdServer (on startup, SYSTEM)
"""

import json
import logging
import os
import threading
from datetime import datetime, timezone
from functools import wraps

import joblib
import numpy as np
from flask import Flask, jsonify, request
from waitress import serve

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BASE_DIR    = r"C:\Matlama"
MODEL_DIR   = os.path.join(BASE_DIR, "model")
LOG_DIR     = os.path.join(BASE_DIR, "logs")

MODEL_PATH        = os.path.join(MODEL_DIR, "rf_model.pkl")
SCALER_PATH       = os.path.join(MODEL_DIR, "scaler.pkl")
QUANT_MODEL_PATH  = os.path.join(MODEL_DIR, "quant_model.pkl")
QUANT_SCALER_PATH = os.path.join(MODEL_DIR, "quant_scaler.pkl")

DEFAULT_THRESHOLD       = 0.55
QUANT_DEFAULT_THRESHOLD = 0.60
API_KEY = os.getenv("THRESHOLD_API_KEY", "")

os.makedirs(LOG_DIR, exist_ok=True)

_model_lock = threading.Lock()

logging.basicConfig(
    filename=os.path.join(LOG_DIR, "threshold_server.log"),
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("threshold_server")

app = Flask(__name__)


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


# ---------------------------------------------------------------------------
# Model store — lazy load with hot reload
# ---------------------------------------------------------------------------
_models = {
    "mbv3": {
        "model":       None,
        "scaler":      None,
        "mtime":       None,
        "path":        MODEL_PATH,
        "scaler_path": SCALER_PATH,
    },
    "quant": {
        "model":       None,
        "scaler":      None,
        "mtime":       None,
        "path":        QUANT_MODEL_PATH,
        "scaler_path": QUANT_SCALER_PATH,
    },
}


def load_model(key):
    store = _models[key]
    if not os.path.exists(store["path"]):
        return False
    mtime = os.path.getmtime(store["path"])
    if store["model"] is not None and mtime == store["mtime"]:
        return True
    with _model_lock:
        if store["model"] is not None and mtime == store["mtime"]:
            return True
        try:
            model = joblib.load(store["path"])
            scaler = None
            if os.path.exists(store["scaler_path"]):
                scaler = joblib.load(store["scaler_path"])
            store["model"] = model
            store["scaler"] = scaler
            store["mtime"] = mtime
            logger.info("Model [%s] reloaded (mtime=%s)", key,
                        datetime.fromtimestamp(mtime))
            return True
        except Exception as e:
            logger.error("Failed to load model [%s]: %s", key, e)
            return False


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.route("/", methods=["GET"])
def health():
    mbv3_ok  = load_model("mbv3")
    quant_ok = load_model("quant")
    return jsonify({
        "status":             "ok",
        "mbv3_model_loaded":  mbv3_ok,
        "quant_model_loaded": quant_ok,
        "timestamp":          datetime.now(timezone.utc).isoformat(),
    })


@app.route("/threshold", methods=["GET"])
def get_threshold():
    ea     = request.args.get("ea", "MatlamaBridgeV3")
    symbol = request.args.get("symbol", "GOLD")
    ok     = load_model("mbv3")
    thresh = DEFAULT_THRESHOLD
    if ok and hasattr(_models["mbv3"]["model"], "matlama_threshold_"):
        thresh = _models["mbv3"]["model"].matlama_threshold_
    logger.info("MBV3 threshold request | ea=%s symbol=%s threshold=%.3f",
                ea, symbol, thresh)
    return jsonify({
        "ea":           ea,
        "symbol":       symbol,
        "threshold":    thresh,
        "model_loaded": ok,
    })


@app.route("/quant_threshold", methods=["GET"])
def get_quant_threshold():
    symbol = request.args.get("symbol", "GOLD")
    ok     = load_model("quant")
    thresh = QUANT_DEFAULT_THRESHOLD
    acc    = None
    wr     = None
    if ok:
        m      = _models["quant"]["model"]
        thresh = getattr(m, "matlama_threshold_", QUANT_DEFAULT_THRESHOLD)
        acc    = getattr(m, "matlama_accuracy_",  None)
        wr     = getattr(m, "matlama_win_rate_",  None)
    logger.info("Quant threshold request | symbol=%s threshold=%.3f", symbol, thresh)
    return jsonify({
        "ea":           "MatlamaQuant",
        "symbol":       symbol,
        "threshold":    thresh,
        "model_loaded": ok,
        "accuracy":     acc,
        "win_rate":     wr,
    })


@app.route("/predict", methods=["POST"])
@require_api_key
def predict():
    ok = load_model("mbv3")
    if not ok:
        return jsonify({"error": "MBV3 model not available"}), 503
    data     = request.get_json(force=True, silent=True) or {}
    features = data.get("features")
    if not features:
        return jsonify({"error": "missing features array"}), 400
    try:
        X = np.array(features).reshape(1, -1)
        if _models["mbv3"]["scaler"] is not None:
            X = _models["mbv3"]["scaler"].transform(X)
        proba      = _models["mbv3"]["model"].predict_proba(X)[0]
        confidence = float(np.max(proba))
        prediction = int(_models["mbv3"]["model"].predict(X)[0])
        logger.info("MBV3 predict | pred=%d conf=%.3f", prediction, confidence)
        return jsonify({"prediction": prediction, "confidence": confidence})
    except Exception as e:
        logger.error("MBV3 predict error: %s", e)
        return jsonify({"error": str(e)}), 500


@app.route("/quant_predict", methods=["POST"])
@require_api_key
def quant_predict():
    ok = load_model("quant")
    if not ok:
        return jsonify({"error": "Quant model not available"}), 503
    data     = request.get_json(force=True, silent=True) or {}
    features = data.get("features")
    if not features:
        return jsonify({"error": "missing features array"}), 400
    try:
        X = np.array(features).reshape(1, -1)
        if _models["quant"]["scaler"] is not None:
            X = _models["quant"]["scaler"].transform(X)
        proba      = _models["quant"]["model"].predict_proba(X)[0]
        confidence = float(np.max(proba))
        prediction = int(_models["quant"]["model"].predict(X)[0])
        logger.info("Quant predict | pred=%d conf=%.3f", prediction, confidence)
        return jsonify({"prediction": prediction, "confidence": confidence})
    except Exception as e:
        logger.error("Quant predict error: %s", e)
        return jsonify({"error": str(e)}), 500


# ---------------------------------------------------------------------------
# Start — Waitress production WSGI server
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    logger.info("Starting Matlama Threshold Server v3 (Waitress) on localhost:6000")
    load_model("mbv3")
    load_model("quant")
    logger.info("Models loaded. Serving...")
    serve(app, host="127.0.0.1", port=6000, threads=4)
