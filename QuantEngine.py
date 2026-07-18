"""
Matlama Quant Engine — ML Trainer
Trains on quant_trades.csv (MatlamaQuant EA output)
Features: fib_level, velocity, volume_ratio, rsi_accel, signal_score
Derives result from profit > 0
Saves to C:\\Matlama\\model\\quant_model.pkl
Serves via Flask /quant_threshold endpoint

Task Scheduler: Matlama_QuantEngine (daily 4:00 AM)
"""

import json
import logging
import os
from datetime import datetime

import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier, GradientBoostingClassifier
from sklearn.metrics import accuracy_score, classification_report
from sklearn.model_selection import train_test_split, cross_val_score
from sklearn.preprocessing import StandardScaler

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BASE_DIR    = r"C:\Matlama"
MODEL_DIR   = os.path.join(BASE_DIR, "model")
LOG_DIR     = os.path.join(BASE_DIR, "logs")
STATE_FILE  = os.path.join(MODEL_DIR, "quant_train_state.json")

MT5_FILES = (
    r"C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal"
    r"\5A08E185CE336B177334803F286A1E5F\MQL5\Files"
)
TRADES_CSV = os.path.join(MT5_FILES, "quant_trades.csv")

MIN_TRADES          = 50
RETRAIN_INTERVAL_H  = 24

# Quant-specific feature columns.
# duration_min intentionally excluded — it's only known after a trade
# closes, so it can never be supplied to the model at real-time decision
# time. Kept in the CSV itself for record-keeping, just not used to train.
FEATURE_COLS = [
    "fib_level",       # which Fibonacci level triggered the trade
    "velocity",        # pips per 3 M1 candles at entry
    "volume_ratio",    # volume surge ratio at entry
    "rsi_accel",       # RSI acceleration at entry
    "signal_score",    # number of confirmation layers active at entry (0-5)
]

os.makedirs(MODEL_DIR, exist_ok=True)
os.makedirs(LOG_DIR,   exist_ok=True)

logging.basicConfig(
    filename=os.path.join(LOG_DIR, "quant_engine.log"),
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("quant_engine")


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------
def load_trades():
    if not os.path.exists(TRADES_CSV):
        logger.warning("quant_trades.csv not found at %s", TRADES_CSV)
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

    # Derive result
    df["result"] = (df["profit"] > 0).astype(int)

    available = [c for c in FEATURE_COLS if c in df.columns]
    df = df.dropna(subset=available + ["result"])

    logger.info("Loaded %d quant trades. Win rate: %.1f%%",
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
        hrs  = (datetime.utcnow() - last).total_seconds() / 3600
        if hrs < RETRAIN_INTERVAL_H:
            logger.info("%.1f hours since last train", hrs)
            return False
    except Exception:
        pass
    return True


# ---------------------------------------------------------------------------
# Training — uses both RF and GBM, picks best
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
    X_tr   = scaler.fit_transform(X_train)
    X_te   = scaler.transform(X_test)

    # Random Forest
    rf = RandomForestClassifier(
        n_estimators=300,
        max_depth=6,
        min_samples_leaf=3,
        class_weight="balanced",
        random_state=42,
        n_jobs=-1,
    )
    rf.fit(X_tr, y_train)
    rf_acc = accuracy_score(y_test, rf.predict(X_te))

    # Gradient Boosting (Medallion-inspired — ensemble of weak learners)
    gbm = GradientBoostingClassifier(
        n_estimators=200,
        max_depth=3,
        learning_rate=0.05,
        subsample=0.8,
        random_state=42,
    )
    gbm.fit(X_tr, y_train)
    gbm_acc = accuracy_score(y_test, gbm.predict(X_te))

    logger.info("RF accuracy:  %.3f", rf_acc)
    logger.info("GBM accuracy: %.3f", gbm_acc)

    # Pick best model
    if gbm_acc >= rf_acc:
        model    = gbm
        best_acc = gbm_acc
        model_type = "GradientBoosting"
    else:
        model    = rf
        best_acc = rf_acc
        model_type = "RandomForest"

    logger.info("Selected: %s | Accuracy: %.3f", model_type, best_acc)
    logger.info("\n%s", classification_report(y_test, model.predict(X_te), zero_division=0))

    # Store metadata
    model.matlama_threshold_    = 0.60
    model.matlama_feature_names_ = available
    model.matlama_trained_at_   = datetime.utcnow().isoformat() + "Z"
    model.matlama_accuracy_     = best_acc
    model.matlama_win_rate_     = float(df["result"].mean())
    model.matlama_model_type_   = model_type

    return model, scaler, best_acc


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    logger.info("=== quant_engine.py started ===")

    df = load_trades()
    if df is None or df.empty:
        logger.warning("No quant trade data — exiting")
        return

    state   = get_state()
    current = len(df)

    if not should_retrain(current, state):
        return

    try:
        model, scaler, acc = train_model(df)
    except Exception as e:
        logger.error("Training failed: %s", e)
        return

    joblib.dump(model,  os.path.join(MODEL_DIR, "quant_model.pkl"))
    joblib.dump(scaler, os.path.join(MODEL_DIR, "quant_scaler.pkl"))
    save_state(current)

    logger.info("Quant model saved | Trades=%d | Acc=%.3f | WinRate=%.1f%%",
                current, acc, model.matlama_win_rate_ * 100)
    logger.info("=== quant_engine.py finished ===")


if __name__ == "__main__":
    main()
