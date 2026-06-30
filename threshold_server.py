"""
Matlama Gold Trading - ML Threshold Server
Flask server running on localhost:6000
Serves dynamic trading thresholds to MQL5 EAs (MatlamaBridgeV3, MatlamaScalper,
MatlamaFundamentals, MatlamaBridgeHFT) based on the trained Random Forest model.

Run manually with: python threshold_server.py
Deployed via Task Scheduler as: Matlama_ThresholdServer
"""

import json
import logging
import os
from datetime import datetime

import joblib
import numpy as np
from flask import Flask, jsonify, request

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BASE_DIR = r"C:\Matlama"
MODEL_PATH = os.path.join(BASE_DIR, "model", "rf_model.pkl")
SCALER_PATH = os.path.join(BASE_DIR, "model", "scaler.pkl")
LOG_PATH = os.path.join(BASE_DIR, "logs", "threshold_server.log")
DEFAULT_THRESHOLD = 0.55  # fallback confidence threshold if model unavailable

os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)

logging.basicConfig(
    filename=LOG_PATH,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("threshold_server")

app = Flask(__name__)

# ---------------------------------------------------------------------------
# Model loading (lazy, with hot-reload support)
# ---------------------------------------------------------------------------
_model = None
_scaler = None
_model_mtime = None


def load_model_if_updated():
    """Reload the model from disk if it has changed since last load.
    This lets ml_trainer.py retrain in the background and threshold_server.py
    pick up the new model without needing a restart."""
    global _model, _scaler, _model_mtime

    if not os.path.exists(MODEL_PATH):
        logger.warning("Model file not found at %s — using default threshold", MODEL_PATH)
        return False

    mtime = os.path.getmtime(MODEL_PATH)
    if _model is not None and mtime == _model_mtime:
        return True  # already current

    try:
        _model = joblib.load(MODEL_PATH)
        if os.path.exists(SCALER_PATH):
            _scaler = joblib.load(SCALER_PATH)
        _model_mtime = mtime
        logger.info("Model reloaded (mtime=%s)", datetime.fromtimestamp(mtime))
        return True
    except Exception as e:
        logger.error("Failed to load model: %s", e)
        return False


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.route("/", methods=["GET"])
def health():
    """Simple health check used by EAs to confirm the server is reachable."""
    model_ok = load_model_if_updated()
    return jsonify({
        "status": "ok",
        "model_loaded": model_ok,
        "timestamp": datetime.utcnow().isoformat() + "Z",
    })


@app.route("/threshold", methods=["GET"])
def get_threshold():
    """Returns the current confidence threshold for a given EA / signal type.
    Query params:
        ea       - e.g. MatlamaBridgeV3 / MatlamaScalper / MatlamaBridgeHFT
        symbol   - e.g. XAUUSD
    """
    ea = request.args.get("ea", "default")
    symbol = request.args.get("symbol", "XAUUSD")

    model_ok = load_model_if_updated()
    threshold = DEFAULT_THRESHOLD

    if model_ok and hasattr(_model, "predict_proba"):
        # If the model supports it, we could derive a dynamic threshold from
        # recent prediction confidence distribution. For now we expose the
        # model's calibrated decision threshold if stored, else default.
        threshold = getattr(_model, "matlama_threshold_", DEFAULT_THRESHOLD)

    logger.info("Threshold requested by %s for %s -> %.3f", ea, symbol, threshold)
    return jsonify({
        "ea": ea,
        "symbol": symbol,
        "threshold": threshold,
        "model_loaded": model_ok,
    })


@app.route("/predict", methods=["POST"])
def predict():
    """Accepts a feature vector from an EA and returns a trade confidence score.
    Expected JSON body: {"features": [f1, f2, f3, ...]}
    """
    model_ok = load_model_if_updated()
    if not model_ok:
        return jsonify({"error": "model not available", "confidence": None}), 503

    data = request.get_json(force=True, silent=True) or {}
    features = data.get("features")
    if not features:
        return jsonify({"error": "missing 'features' array"}), 400

    try:
        X = np.array(features).reshape(1, -1)
        if _scaler is not None:
            X = _scaler.transform(X)
        proba = _model.predict_proba(X)[0]
        confidence = float(np.max(proba))
        prediction = int(_model.predict(X)[0])

        logger.info("Predict request: pred=%s conf=%.3f", prediction, confidence)
        return jsonify({
            "prediction": prediction,
            "confidence": confidence,
        })
    except Exception as e:
        logger.error("Prediction failed: %s", e)
        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    logger.info("Starting Matlama Threshold Server on http://localhost:6000")
    load_model_if_updated()
    app.run(host="127.0.0.1", port=6000, debug=False)
