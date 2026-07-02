"""
Matlama Gold Trading — ML Threshold Server v2
Serves both MatlamaBridgeV3 and MatlamaQuant thresholds
Endpoints:
  GET /                    — health check
  GET /threshold           — MatlamaBridgeV3 threshold
  GET /quant_threshold     — MatlamaQuant threshold
  POST /predict            — MatlamaBridgeV3 prediction
  POST /quant_predict      — MatlamaQuant prediction

Flask on localhost:6000
Task Scheduler: Matlama_ThresholdServer (on startup)
API Key: Yu4minawena!
"""

import json
import logging
import os
from datetime import datetime, timezone

import joblib
import numpy as np
from flask import Flask, jsonify, request

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BASE_DIR     = r"C:\Matlama"
MODEL_DIR    = os.path.join(BASE_DIR, "model")
LOG_DIR      = os.path.join(BASE_DIR, "logs")
API_KEY      = "Yu4minawena!"

# MBV3 model paths
MODEL_PATH   = os.path.join(MODEL_DIR, "rf_model.pkl")
SCALER_PATH  = os.path.join(MODEL_DIR, "scaler.pkl")

# MatlamaQuant model paths
QUANT_MODEL_PATH  = os.path.join(MODEL_DIR, "quant_model.pkl")
QUANT_SCALER_PATH = os.path.join(MODEL_DIR, "quant_scaler.pkl")

DEFAULT_THRESHOLD       = 0.55
QUANT_DEFAULT_THRESHOLD = 0.60

os.makedirs(LOG_DIR, exist_ok=True)

logging.basicConfig(
    filename=os.path.join(LOG_DIR, "threshold_server.log"),
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("threshold_server")

app = Flask(__name__)

# ---------------------------------------------------------------------------
# Model store — lazy load with hot reload
# ---------------------------------------------------------------------------
_models = {
    "mbv3":  {"model": None, "scaler": None, "mtime": None,
               "path": MODEL_PATH,  "scaler_path": SCALER_PATH},
    "quant": {"model": None, "scaler": None, "mtime": None,
               "path": QUANT_MODEL_PATH, "scaler_path": QUANT_SCALER_PATH},
}


def load_model(key):
    store = _models[key]
    if not os.path.exists(store["path"]):
        return False
    mtime = os.path.getmtime(store["path"])
    if store["model"] is not None and mtime == store["mtime"]:
        return True
    try:
        store["model"]  = joblib.load(store["path"])
        if os.path.exists(store["scaler_path"]):
            store["scaler"] = joblib.load(store["scaler_path"])
        store["mtime"] = mtime
        logger.info("Model [%s] reloaded (mtime=%s)", key,
                    datetime.fromtimestamp(mtime))
        return True
    except Exception as e:
        logger.error("Failed to load model [%s]: %s", key, e)
        return False


def check_api_key():
    key = request.headers.get("X-API-Key") or request.args.get("api_key")
    return key == API_KEY


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.route("/", methods=["GET"])
def health():
    mbv3_ok  = load_model("mbv3")
    quant_ok = load_model("quant")
    return jsonify({
        "status": "ok",
        "mbv3_model_loaded":  mbv3_ok,
        "quant_model_loaded": quant_ok,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    })


@app.route("/threshold", methods=["GET"])
def get_threshold():
    ea     = request.args.get("ea", "MatlamaBridgeV3")
    symbol = request.args.get("symbol", "GOLD")
    ok     = load_model("mbv3")
    thresh = DEFAULT_THRESHOLD
    if ok and hasattr(_models["mbv3"]["model"], "matlama_threshold_"):
        thresh = _models["mbv3"]["model"].matlama_threshold_
    logger.info("MBV3 threshold → %s for %s: %.3f", ea, symbol, thresh)
    return jsonify({"ea": ea, "symbol": symbol, "threshold": thresh,
                    "model_loaded": ok})


@app.route("/quant_threshold", methods=["GET"])
def get_quant_threshold():
    symbol = request.args.get("symbol", "GOLD")
    ok     = load_model("quant")
    thresh = QUANT_DEFAULT_THRESHOLD
    if ok and hasattr(_models["quant"]["model"], "matlama_threshold_"):
        thresh = _models["quant"]["model"].matlama_threshold_
    acc = None
    wr  = None
    if ok:
        m = _models["quant"]["model"]
        acc = getattr(m, "matlama_accuracy_",  None)
        wr  = getattr(m, "matlama_win_rate_",  None)
    logger.info("Quant threshold → %s: %.3f", symbol, thresh)
    return jsonify({
        "ea": "MatlamaQuant",
        "symbol": symbol,
        "threshold": thresh,
        "model_loaded": ok,
        "accuracy": acc,
        "win_rate": wr,
    })


@app.route("/predict", methods=["POST"])
def predict():
    ok = load_model("mbv3")
    if not ok:
        return jsonify({"error": "MBV3 model not available"}), 503
    data     = request.get_json(force=True, silent=True) or {}
    features = data.get("features")
    if not features:
        return jsonify({"error": "missing features"}), 400
    try:
        X = np.array(features).reshape(1, -1)
        if _models["mbv3"]["scaler"] is not None:
            X = _models["mbv3"]["scaler"].transform(X)
        proba      = _models["mbv3"]["model"].predict_proba(X)[0]
        confidence = float(np.max(proba))
        prediction = int(_models["mbv3"]["model"].predict(X)[0])
        return jsonify({"prediction": prediction, "confidence": confidence})
    except Exception as e:
        logger.error("MBV3 predict error: %s", e)
        return jsonify({"error": str(e)}), 500


@app.route("/quant_predict", methods=["POST"])
def quant_predict():
    ok = load_model("quant")
    if not ok:
        return jsonify({"error": "Quant model not available"}), 503
    data     = request.get_json(force=True, silent=True) or {}
    features = data.get("features")
    if not features:
        return jsonify({"error": "missing features"}), 400
    try:
        X = np.array(features).reshape(1, -1)
        if _models["quant"]["scaler"] is not None:
            X = _models["quant"]["scaler"].transform(X)
        proba      = _models["quant"]["model"].predict_proba(X)[0]
        confidence = float(np.max(proba))
        prediction = int(_models["quant"]["model"].predict(X)[0])
        return jsonify({"prediction": prediction, "confidence": confidence})
    except Exception as e:
        logger.error("Quant predict error: %s", e)
        return jsonify({"error": str(e)}), 500


# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    logger.info("Starting Matlama Threshold Server v2 on http://localhost:6000")
    load_model("mbv3")
    load_model("quant")
    app.run(host="127.0.0.1", port=6000, debug=False)
