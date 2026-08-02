"""
Matlama HFT Engine - ML Trainer
Trains a Random Forest classifier on logged trade history
(hft_trades.csv, written by MatlamaBridgeHFT.mq5 into the MT5 sandbox
Files folder).

CSV Schema:
ticket, symbol, type, open_time, close_time, open_price, close_price,
volume, profit, swap, commission, duration_min, wick_pips, momentum_pips,
volume_ratio, rsi

Result is derived from profit > 0 (win=1, loss=0).

duration_min is logged for record-keeping but excluded from FEATURE_COLS
— it's only known after a trade closes, so it can never be supplied to
the model at real-time decision time.

Retrains on a 24-hour cycle, only if at least 50 closed trades are available.
Saves model + scaler to C:\\Matlama\\model\\ as hft_model.pkl / hft_scaler.pkl,
which the orchestrator loads for the "HFT" strategy.

Run manually: python hft_engine.py
Task Scheduler: Matlama_HFTEngine (daily, e.g. 5:00 AM)
"""

import json
import logging
import os
from datetime import datetime

import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score, classification_report
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import StandardScaler

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BASE_DIR = r"C:\Matlama"
MODEL_DIR = os.path.join(BASE_DIR, "model")
LOG_DIR = os.path.join(BASE_DIR, "logs")
STATE_FILE = os.path.join(MODEL_DIR, "hft_train_state.json")

MT5_SANDBOX_FILES = (
    r"C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal"
    r"\5A08E185CE336B177334803F286A1E5F\MQL5\Files"
)
TRADES_CSV = os.path.join(MT5_SANDBOX_FILES, "hft_trades.csv")

MIN_TRADES_TO_TRAIN = 50
RETRAIN_INTERVAL_HOURS = 24

FEATURE_COLS = ["wick_pips", "momentum_pips", "volume_ratio", "rsi"]

os.makedirs(MODEL_DIR, exist_ok=True)
os.makedirs(LOG_DIR, exist_ok=True)

logging.basicConfig(
    filename=os.path.join(LOG_DIR, "hft_engine.log"),
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("hft_engine")


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------
def load_trades():
    if not os.path.exists(TRADES_CSV):
        logger.warning("Trades CSV not found at %s", TRADES_CSV)
        return None

    try:
        df = pd.read_csv(TRADES_CSV)
    except Exception:
        try:
            df = pd.read_csv(TRADES_CSV, sep=r'\s+', engine='python')
        except Exception as e:
            logger.error("Failed to read trades CSV: %s", e)
            return None

    if "profit" not in df.columns:
        logger.error("No 'profit' column found in CSV — cannot derive result")
        return None

    df["result"] = (df["profit"] > 0).astype(int)

    available_features = [c for c in FEATURE_COLS if c in df.columns]
    if len(available_features) < 2:
        logger.error("Not enough feature columns found. Available: %s", list(df.columns))
        return None

    df = df.dropna(subset=available_features + ["result"])
    logger.info("Loaded %d trades from CSV. Win rate: %.1f%%",
                len(df), df["result"].mean() * 100)
    return df


# ---------------------------------------------------------------------------
# State management
# ---------------------------------------------------------------------------
def get_last_trained_count():
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r") as f:
                state = json.load(f)
            return state.get("trade_count", 0), state.get("last_run")
        except Exception:
            return 0, None
    return 0, None


def save_state(trade_count):
    state = {
        "trade_count": trade_count,
        "last_run": datetime.utcnow().isoformat() + "Z",
    }
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)


def should_retrain(current_count, last_count, last_run):
    if current_count < MIN_TRADES_TO_TRAIN:
        logger.info("Only %d trades (need %d) — skipping", current_count, MIN_TRADES_TO_TRAIN)
        return False

    if last_run is None:
        return True

    new_trades = current_count - last_count
    if new_trades >= MIN_TRADES_TO_TRAIN:
        return True

    try:
        last_dt = datetime.fromisoformat(last_run.replace("Z", ""))
        hours_elapsed = (datetime.utcnow() - last_dt).total_seconds() / 3600
        if hours_elapsed < RETRAIN_INTERVAL_HOURS:
            logger.info("Only %.1f hours since last train — skipping", hours_elapsed)
            return False
    except Exception:
        pass

    return True


# ---------------------------------------------------------------------------
# Training
# ---------------------------------------------------------------------------
def train_model(df):
    available_features = [c for c in FEATURE_COLS if c in df.columns]
    logger.info("Training on features: %s", available_features)

    X = df[available_features].fillna(0).values
    y = df["result"].values

    if len(set(y)) < 2:
        raise ValueError("Only one class present in training data — need both wins and losses")

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42, stratify=y
    )

    scaler = StandardScaler()
    X_train_s = scaler.fit_transform(X_train)
    X_test_s = scaler.transform(X_test)

    model = RandomForestClassifier(
        n_estimators=200,
        max_depth=6,
        min_samples_leaf=3,
        class_weight="balanced",
        random_state=42,
        n_jobs=-1,
    )
    model.fit(X_train_s, y_train)

    y_pred = model.predict(X_test_s)
    acc = accuracy_score(y_test, y_pred)
    report = classification_report(y_test, y_pred, zero_division=0)

    logger.info("Test accuracy: %.3f", acc)
    logger.info("Classification report:\n%s", report)

    model.matlama_threshold_ = 0.55
    model.matlama_feature_names_ = available_features
    model.matlama_trained_at_ = datetime.utcnow().isoformat() + "Z"
    model.matlama_accuracy_ = acc
    model.matlama_win_rate_ = float(df["result"].mean())

    return model, scaler, acc


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    logger.info("=== hft_engine.py started ===")

    df = load_trades()
    if df is None or df.empty:
        logger.warning("No usable trade data — exiting")
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

    joblib.dump(model, os.path.join(MODEL_DIR, "hft_model.pkl"))
    joblib.dump(scaler, os.path.join(MODEL_DIR, "hft_scaler.pkl"))
    save_state(current_count)

    logger.info("Model saved. Trades=%d, Accuracy=%.3f, WinRate=%.1f%%",
                current_count, acc, model.matlama_win_rate_ * 100)
    logger.info("=== hft_engine.py finished ===")


if __name__ == "__main__":
    main()
