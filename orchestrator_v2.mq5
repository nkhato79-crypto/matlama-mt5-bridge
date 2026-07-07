"""
Matlama Orchestrator v2 — Institutional Decision Engine
-------------------------------------------------------
Central policy layer for Matlama Quant Ecosystem.

Responsibilities:
- Regime detection (Trend / Range / Crisis / News)
- Ensemble model scoring (Quant + Bridge)
- Trade memory tracking (win-rate + drawdown adaptation)
- Risk-conditioned threshold adjustment
- Final trade authorization (BUY / SELL / NO_TRADE)

Exposes:
POST /decision_v2
POST /report_trade   (for feedback loop training)

Runs: Flask (localhost:7000)
"""

from flask import Flask, request, jsonify
import numpy as np
import joblib
import os
from collections import deque
from datetime import datetime

# =========================================================
# APP INIT
# =========================================================
app = Flask(__name__)

BASE_DIR = r"C:\Matlama\model"

# Load models
quant_model  = joblib.load(os.path.join(BASE_DIR, "quant_model.pkl"))
quant_scaler = joblib.load(os.path.join(BASE_DIR, "quant_scaler.pkl"))

mbv3_model   = joblib.load(os.path.join(BASE_DIR, "rf_model.pkl"))
mbv3_scaler  = joblib.load(os.path.join(BASE_DIR, "scaler.pkl"))


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
def score_model(model, scaler, features, order