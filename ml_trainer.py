"""
Matlama Gold Trading - ML Trainer
Trains a Random Forest classifier on logged trade history (hft_trades.csv,
written by the MQL5 EAs into the MT5 sandbox Files folder).

Retrains on a 24-hour cycle, only if at least 50 new closed trades are
available since the last training run. Saves model + scaler to
C:\\Matlama\\model\\ where threshold_server.py picks it up automatically.

Run manually with: python ml_trainer.py
Deployed via Task Scheduler as: Matlama_MLTrainer (run daily)
"""

import logging
import os
import time
from datetime import datetime

import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import accuracy_score, classification_report

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BASE_DIR = r"C:\Matlama"
MODEL_DIR = os.path.join(BASE_DIR, "model")
LOG_DIR = os.path.join(BASE_DIR, "logs")
STATE_FILE = os.path.join(MODEL_DIR, "last_train_state.json")

# Path to the CSV written by the EAs into the MT5 sandbox Files folder.
# Update the terminal hash below if your MT5 install path differs.
MT5_SANDBOX_FILES = (
    r"C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal"
    r"\D0E8209F77C8CF37AD8BF550E51FF075\MQL5\Files"
)
TRADES_CSV = os.path.join(MT5_SANDBOX_FILES, "hft_trades.csv")

MIN_TRADES_TO_TRAIN = 50
RETRAIN_INTERVAL_HOURS = 24

os.makedirs(MODEL_DIR, exist_ok=True)
os.makedirs(LOG_DIR, exist_ok=True)

logging.basicConfig(
    filename=os.path.join(LOG_DIR, "ml_trainer.log"),
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("ml_trainer")

# ---------------------------------------------------------------------------
# MBV3 trade history schema
# ---------------------------------------------------------------------------
# Columns expected in hft_trades.csv, matching MatlamaBridgeV3's 9-layer
# signal engine output plus trade outcome. Adjust if your EA's CSV writer
# uses different column names/order.
EXPECTED_COLUMNS = [
    "timestamp", "symbol", "magic_number", "direction",
    "layer1_trend", "layer2_momentum", "layer3_volatility",
    "layer4_volume", "layer5_structure", "layer6_session",
    "layer7_news_filter", "layer8_correlation", "layer9_manipulation",
    "entry_price", "exit_price", "sl", "tp",
    "profit", "result",  # result: 1 = win, 0 = loss
]


def load_trades():
    if not os.path.exists(TRADES_CSV):
        logger.warning("Trades CSV not found at %s", TRADES_CSV)
        return None

    try:
        df = pd.read_csv(TRADES_CSV)
    except Exception as e:
        logger.error("Failed to read trades CSV: %s", e)
        return None

    missing = [c for c in EXPECTED_COLUMNS if c not in df.columns]
    if missing:
        logger.warning("CSV missing expected columns: %s", missing)

    # Only use closed trades with a known result
    if "result" in df.columns:
        df = df.dropna(subset=["result"])

    return df


def get_last_trained_count():
    if os.path.exists(STATE_FILE):
        try:
            import json
            with open(STATE_FILE, "r") as f:
                state = json.load(f)
            return state.get("trade_count", 0), state.get("last_run")
        except Exception:
            return 0, None
    return 0, None


def save_state(trade_count):
    import json
    state = {
        "trade_count": trade_count,
        "last_run": datetime.utcnow().isoformat() + "Z",
    }
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)


def should_retrain(current_count, last_count, last_run):
    if current_count < MIN_TRADES_TO_TRAIN:
        logger.info("Only %d trades logged (need %d) — skipping training",
                     current_count, MIN_TRADES_TO_TRAIN)
        return False

    if last_run is None:
        return True

    if (current_count - last_count) < MIN_TRADES_TO_TRAIN:
        # Not enough *new* trades since last run, check time interval instead
        try:
            last_dt = datetime.fromisoformat(last_run.replace("Z", ""))
            hours_elapsed = (datetime.utcnow() - last_dt).total_seconds() / 3600
            if hours_elapsed < RETRAIN_INTERVAL_HOURS:
                logger.info("Only %.1f hours since last train (need %d) — skipping",
                             hours_elapsed, RETRAIN_INTERVAL_HOURS)
                return False
        except Exception:
            pass

    return True


def build_features(df):
    feature_cols = [
        "layer1_trend", "layer2_momentum", "layer3_volatility",
        "layer4_volume", "layer5_structure", "layer6_session",
        "layer7_news_filter", "layer8_correlation", "layer9_manipulation",
    ]
    available = [c for c in feature_cols if c in df.columns]
    if len(available) < 3:
        raise ValueError(
            f"Not enough feature columns present in CSV. Found: {available}"
        )
    X = df[available].fillna(0).values
    y = df["result"].astype(int).values
    return X, y, available


def train_model(df):
    X, y, feature_names = build_features(df)

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42, stratify=y if len(set(y)) > 1 else None
    )

    scaler = StandardScaler()
    X_train_scaled = scaler.fit_transform(X_train)
    X_test_scaled = scaler.transform(X_test)

    model = RandomForestClassifier(
        n_estimators=200,
        max_depth=8,
        min_samples_leaf=5,
        class_weight="balanced",
        random_state=42,
        n_jobs=-1,
    )
    model.fit(X_train_scaled, y_train)

    y_pred = model.predict(X_test_scaled)
    acc = accuracy_score(y_test, y_pred)
    report = classification_report(y_test, y_pred, zero_division=0)

    logger.info("Training complete. Test accuracy: %.3f", acc)
    logger.info("Classification report:\n%s", report)
    logger.info("Feature columns used: %s", feature_names)

    # Store a calibrated decision threshold on the model object for the
    # threshold_server to read back later.
    model.matlama_threshold_ = 0.55
    model.matlama_feature_names_ = feature_names
    model.matlama_trained_at_ = datetime.utcnow().isoformat() + "Z"
    model.matlama_accuracy_ = acc

    return model, scaler, acc


def main():
    logger.info("=== ml_trainer.py run started ===")

    df = load_trades()
    if df is None or df.empty:
        logger.warning("No trade data available — exiting without training")
        return

    current_count = len(df)
    last_count, last_run = get_last_trained_count()

    if not should_retrain(current_count, last_count, last_run):
        return

    try:
        model, scaler, acc = train_model(df)
    except Exception as e:
        logger.error("Training failed: %s", e)
        return

    joblib.dump(model, os.path.join(MODEL_DIR, "rf_model.pkl"))
    joblib.dump(scaler, os.path.join(MODEL_DIR, "scaler.pkl"))
    save_state(current_count)

    logger.info(
        "Model saved. Trained on %d trades, test accuracy %.3f",
        current_count, acc,
    )
    logger.info("=== ml_trainer.py run finished ===")


if __name__ == "__main__":
    main()
