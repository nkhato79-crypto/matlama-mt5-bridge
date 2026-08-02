"""
Matlama Tick Scalper Engine - ML Trainer (VWAP Mean Reversion)
Trains on tick_scalper_trades.csv (MatlamaTickScalper EA output)
Features: vwap_deviation, rsi, adx, spread_pips, vwap_slope
Derives result from profit > 0

Saves to C:\\Matlama\\model\\tick_scalper_model.pkl
Task Scheduler: Matlama_TickScalperEngine (daily, e.g. 6:00 AM)
"""

import json
import logging
import os
from datetime import datetime

import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import GradientBoostingClassifier, RandomForestClassifier
from sklearn.metrics import accuracy_score, classification_report
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import StandardScaler

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BASE_DIR = r"C:\Matlama"
MODEL_DIR = os.path.join(BASE_DIR, "model")
LOG_DIR = os.path.join(BASE_DIR, "logs")
STATE_FILE = os.path.join(MODEL_DIR, "tick_scalper_train_state.json")

MT5_FILES = (
    r"C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal"
    r"\5A08E185CE336B177334803F286A1E5F\MQL5\Files"
)
TRADES_CSV = os.path.join(MT5_FILES, "tick_scalper_trades.csv")

MIN_TRADES = 50
RETRAIN_INTERVAL_H = 24

FEATURE_COLS = [
    "vwap_deviation",
    "rsi",
    "adx",
    "spread_pips",
    "vwap_slope",
]

os.makedirs(MODEL_DIR, exist_ok=True)
os.makedirs(LOG_DIR, exist_ok=True)

logging.basicConfig(
    filename=os.path.join(LOG_DIR, "tick_scalper_engine.log"),
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("tick_scalper_engine")


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------
def load_trades():
    if not os.path.exists(TRADES_CSV):
        logger.warning("tick_scalper_trades.csv not found at %s", TRADES_CSV)
        return None

    try:
        df = pd.read_csv(TRADES_CSV)
    except Exception:
        try:
            df = pd.read_csv(TRADES_CSV, sep=r'\s+', engine='python')
        except Exception as e:
            logger.error("Failed to read CSV: %s", e)
            return None

    if "profit" not in df.columns:
        logger.error("No profit column found")
        return None

    df["result"] = (df["profit"] > 0).astype(int)

    available = [c for c in FEATURE_COLS if c in df.columns]
    if len(available) < 2:
        logger.error("Not enough feature columns. Available: %s", list(df.columns))
        return None

    df = df.dropna(subset=available + ["result"])
    logger.info("Loaded %d tick-scalper trades. Win rate: %.1f%%",
                len(df), df["result"].mean() * 100)
    return df


# ---------------------------------------------------------------------------
# State management
# ---------------------------------------------------------------------------
def get_state():
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE) as f:
                return json.load(f)
        except Exception:
            pass
    return {"trade_count": 0, "last_run": None}


def save_state(count):
    with open(STATE_FILE, "w") as f:
        json.dump({
            "trade_count": count,
            "last_run": datetime.utcnow().isoformat() + "Z"
        }, f, indent=2)


def should_retrain(current, state):
    if current < MIN_TRADES:
        logger.info("Only %d trades (need %d)", current, MIN_TRADES)
        return False
    if state["last_run"] is None:
        return True
    try:
        last = datetime.fromisoformat(state["last_run"].replace("Z", ""))
        hrs = (datetime.utcnow() - last).total_seconds() / 3600
        if hrs < RETRAIN_INTERVAL_H:
            logger.info("%.1f hours since last train", hrs)
            return False
    except Exception:
        pass
    return True


# ---------------------------------------------------------------------------
# Training — GBM + RF, pick best
# ---------------------------------------------------------------------------
def train_model(df):
    available = [c for c in FEATURE_COLS if c in df.columns]
    logger.info("Features: %s", available)

    X = df[available].fillna(0).values
    y = df["result"].values

    if len(set(y)) < 2:
        raise ValueError("Need both wins and losses to train")

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42, stratify=y
    )

    scaler = StandardScaler()
    X_tr = scaler.fit_transform(X_train)
    X_te = scaler.transform(X_test)

    rf = RandomForestClassifier(
        n_estimators=300, max_depth=6, min_samples_leaf=3,
        class_weight="balanced", random_state=42, n_jobs=-1,
    )
    rf.fit(X_tr, y_train)
    rf_acc = accuracy_score(y_test, rf.predict(X_te))

    gbm = GradientBoostingClassifier(
        n_estimators=200, max_depth=3, learning_rate=0.05,
        subsample=0.8, random_state=42,
    )
    gbm.fit(X_tr, y_train)
    gbm_acc = accuracy_score(y_test, gbm.predict(X_te))

    logger.info("RF accuracy:  %.3f", rf_acc)
    logger.info("GBM accuracy: %.3f", gbm_acc)

    if gbm_acc >= rf_acc:
        model, best_acc, model_type = gbm, gbm_acc, "GradientBoosting"
    else:
        model, best_acc, model_type = rf, rf_acc, "RandomForest"

    logger.info("Selected: %s | Accuracy: %.3f", model_type, best_acc)
    logger.info("\n%s", classification_report(y_test, model.predict(X_te), zero_division=0))

    model.matlama_threshold_ = 0.60
    model.matlama_feature_names_ = available
    model.matlama_trained_at_ = datetime.utcnow().isoformat() + "Z"
    model.matlama_accuracy_ = best_acc
    model.matlama_win_rate_ = float(df["result"].mean())
    model.matlama_model_type_ = model_type

    return model, scaler, best_acc


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    logger.info("=== tick_scalper_engine.py started ===")

    df = load_trades()
    if df is None or df.empty:
        logger.warning("No tick-scalper trade data — exiting")
        return

    state = get_state()
    current = len(df)

    if not should_retrain(current, state):
        return

    try:
        model, scaler, acc = train_model(df)
    except Exception as e:
        logger.error("Training failed: %s", e)
        return

    joblib.dump(model, os.path.join(MODEL_DIR, "tick_scalper_model.pkl"))
    joblib.dump(scaler, os.path.join(MODEL_DIR, "tick_scalper_scaler.pkl"))
    save_state(current)

    logger.info("Tick scalper model saved | Trades=%d | Acc=%.3f | WinRate=%.1f%%",
                current, acc, model.matlama_win_rate_ * 100)
    logger.info("=== tick_scalper_engine.py finished ===")


if __name__ == "__main__":
    main()
