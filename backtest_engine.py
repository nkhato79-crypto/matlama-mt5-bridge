"""
Matlama Quant Ecosystem — Portfolio Backtesting Engine
======================================================
Replicates the full strategy pipeline in Python:
  Strategies → Orchestrator logic → Trade execution → ML feedback loop

Data sources (tried in order):
  1. Real XAUUSD via yfinance (works on VPS with internet)
  2. Synthetic gold data matching XAUUSD statistical properties

Run:
  python backtest_engine.py                   # default 6-month backtest
  python backtest_engine.py --months 12       # 12-month backtest
  python backtest_engine.py --strategies QUANT,SCALPER  # specific strategies
  python backtest_engine.py --lot-mode dynamic          # test dynamic sizing

Outputs:
  C:\\Matlama\\backtest\\  (VPS) or ./backtest_results/ (elsewhere)
    equity_curve.csv
    trade_log.csv
    performance_report.txt
    strategy_breakdown.csv
"""

import argparse
import json
import logging
import math
import os
import sys
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Optional

import numpy as np
import pandas as pd

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
IS_VPS = os.path.exists(r"C:\Matlama")
OUTPUT_DIR = r"C:\Matlama\backtest" if IS_VPS else os.path.join(
    os.path.dirname(__file__), "backtest_results"
)
os.makedirs(OUTPUT_DIR, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(os.path.join(OUTPUT_DIR, "backtest.log"), mode="w"),
    ],
)
log = logging.getLogger("backtest")

SPREAD_PIPS = 2.5
SLIPPAGE_PIPS = 0.5
POINT = 0.01  # XAUUSD: 1 pip = $0.01 price movement, $0.10 per 0.01 lot
PIP_VALUE_PER_LOT = 10.0  # $10 per pip per 1.0 standard lot


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------
@dataclass
class Bar:
    time: datetime
    open: float
    high: float
    low: float
    close: float
    volume: float


@dataclass
class Trade:
    ticket: int
    strategy: str
    direction: str  # BUY or SELL
    open_time: datetime
    open_price: float
    sl: float
    tp: float
    lots: float
    close_time: Optional[datetime] = None
    close_price: Optional[float] = None
    profit: Optional[float] = None
    close_reason: str = ""
    regime: str = "MIXED"
    features: dict = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Data loading / generation
# ---------------------------------------------------------------------------
def load_real_data(months: int) -> Optional[pd.DataFrame]:
    try:
        import yfinance as yf
        end = datetime.now()
        start = end - timedelta(days=months * 30)
        df = yf.download("GC=F", start=start, end=end, interval="1h", progress=False)
        if len(df) < 100:
            return None
        df.columns = [c[0].lower() if isinstance(c, tuple) else c.lower() for c in df.columns]
        df = df.rename(columns={"adj close": "close"})
        df = df[["open", "high", "low", "close", "volume"]].dropna()
        log.info(f"Loaded {len(df)} real H1 bars from yfinance")
        return df
    except Exception as e:
        log.info(f"yfinance unavailable ({e}), using synthetic data")
        return None


def generate_synthetic_gold(months: int) -> pd.DataFrame:
    """
    Generate realistic XAUUSD H1 data using a mean-reverting jump-diffusion
    model calibrated to gold's actual statistical properties.
    """
    np.random.seed(42)
    hours = months * 22 * 24  # ~22 trading days/month, 24 hours/day

    # Gold statistical properties (annualized)
    annual_vol = 0.18        # ~18% annual volatility
    hourly_vol = annual_vol / math.sqrt(252 * 24)
    mean_reversion = 0.001   # slight mean reversion
    jump_prob = 0.005        # 0.5% chance of a jump per hour
    jump_size = 0.003        # 0.3% jump magnitude

    # Start near recent gold levels
    price = 2650.0
    prices = []
    volumes = []

    start_time = datetime.now() - timedelta(hours=hours)
    times = []

    for i in range(hours):
        t = start_time + timedelta(hours=i)
        hour = t.hour
        weekday = t.weekday()

        # Skip weekends
        if weekday >= 5:
            continue

        # Session-based volatility multiplier
        if 8 <= hour < 16:      # London
            vol_mult = 1.3
            vol_base = 5000
        elif 13 <= hour < 21:   # NY overlap + NY
            vol_mult = 1.5
            vol_base = 7000
        elif 0 <= hour < 8:     # Asia
            vol_mult = 0.7
            vol_base = 2000
        else:
            vol_mult = 0.5
            vol_base = 1000

        # Price evolution
        drift = -mean_reversion * (price - 2650) / 2650
        noise = np.random.normal(0, hourly_vol * vol_mult)

        # Occasional jumps (news, data releases)
        if np.random.random() < jump_prob:
            noise += np.random.choice([-1, 1]) * jump_size

        ret = drift + noise

        # Generate OHLC from return
        close = price * (1 + ret)
        intra_vol = abs(ret) + hourly_vol * vol_mult * 0.5
        high = max(price, close) * (1 + abs(np.random.normal(0, intra_vol * 0.3)))
        low = min(price, close) * (1 - abs(np.random.normal(0, intra_vol * 0.3)))

        volume = max(100, int(vol_base * (1 + np.random.normal(0, 0.5))))

        prices.append({
            "time": t,
            "open": round(price, 2),
            "high": round(high, 2),
            "low": round(low, 2),
            "close": round(close, 2),
            "volume": volume,
        })

        price = close
        times.append(t)

    df = pd.DataFrame(prices)
    df.set_index("time", inplace=True)
    log.info(
        f"Generated {len(df)} synthetic H1 bars | "
        f"Price range: ${df['low'].min():.0f} - ${df['high'].max():.0f}"
    )
    return df


# ---------------------------------------------------------------------------
# Technical indicators (vectorized)
# ---------------------------------------------------------------------------
class Indicators:
    @staticmethod
    def ema(series: pd.Series, period: int) -> pd.Series:
        return series.ewm(span=period, adjust=False).mean()

    @staticmethod
    def sma(series: pd.Series, period: int) -> pd.Series:
        return series.rolling(period).mean()

    @staticmethod
    def rsi(series: pd.Series, period: int = 14) -> pd.Series:
        delta = series.diff()
        gain = delta.clip(lower=0).rolling(period).mean()
        loss = (-delta.clip(upper=0)).rolling(period).mean()
        rs = gain / loss.replace(0, np.nan)
        return 100 - (100 / (1 + rs))

    @staticmethod
    def atr(high: pd.Series, low: pd.Series, close: pd.Series, period: int = 14) -> pd.Series:
        tr1 = high - low
        tr2 = (high - close.shift(1)).abs()
        tr3 = (low - close.shift(1)).abs()
        tr = pd.concat([tr1, tr2, tr3], axis=1).max(axis=1)
        return tr.rolling(period).mean()

    @staticmethod
    def adx(high: pd.Series, low: pd.Series, close: pd.Series, period: int = 14) -> pd.Series:
        up = high.diff()
        down = -low.diff()
        plus_dm = np.where((up > down) & (up > 0), up, 0)
        minus_dm = np.where((down > up) & (down > 0), down, 0)
        atr = Indicators.atr(high, low, close, period)
        plus_di = 100 * pd.Series(plus_dm, index=high.index).rolling(period).mean() / atr
        minus_di = 100 * pd.Series(minus_dm, index=high.index).rolling(period).mean() / atr
        dx = 100 * (plus_di - minus_di).abs() / (plus_di + minus_di).replace(0, np.nan)
        return dx.rolling(period).mean()

    @staticmethod
    def vwap(high: pd.Series, low: pd.Series, close: pd.Series,
             volume: pd.Series, period: int = 20) -> tuple:
        typical = (high + low + close) / 3
        cum_vol = volume.rolling(period).sum()
        cum_tp_vol = (typical * volume).rolling(period).sum()
        vwap = cum_tp_vol / cum_vol.replace(0, np.nan)
        # Standard deviation bands
        dev = ((typical - vwap) ** 2 * volume).rolling(period).sum() / cum_vol.replace(0, np.nan)
        std = np.sqrt(dev)
        return vwap, std

    @staticmethod
    def macd(series: pd.Series, fast: int = 12, slow: int = 26, signal: int = 9):
        ema_fast = series.ewm(span=fast, adjust=False).mean()
        ema_slow = series.ewm(span=slow, adjust=False).mean()
        macd_line = ema_fast - ema_slow
        signal_line = macd_line.ewm(span=signal, adjust=False).mean()
        histogram = macd_line - signal_line
        return macd_line, signal_line, histogram

    @staticmethod
    def bollinger(series: pd.Series, period: int = 20, num_std: float = 2.0):
        mid = series.rolling(period).mean()
        std = series.rolling(period).std()
        upper = mid + num_std * std
        lower = mid - num_std * std
        return upper, mid, lower

    @staticmethod
    def volatility(close: pd.Series, period: int = 20) -> pd.Series:
        returns = close.pct_change()
        return returns.rolling(period).std() * 100

    @staticmethod
    def momentum(close: pd.Series, lookback: int = 5) -> pd.Series:
        return close.pct_change(lookback) * 100

    @staticmethod
    def swing_highs(high: pd.Series, lookback: int = 10) -> pd.Series:
        return high.rolling(lookback).max()

    @staticmethod
    def swing_lows(low: pd.Series, lookback: int = 10) -> pd.Series:
        return low.rolling(lookback).min()


# ---------------------------------------------------------------------------
# Strategy implementations (Python equivalents of MQL5 logic)
# ---------------------------------------------------------------------------
class BaseStrategy:
    def __init__(self, tag: str, max_trades_per_day: int = 5,
                 max_daily_loss: float = 50.0, max_hold_hours: int = 4):
        self.tag = tag
        self.max_trades_per_day = max_trades_per_day
        self.max_daily_loss = max_daily_loss
        self.max_hold_hours = max_hold_hours
        self.daily_trades = 0
        self.current_day = -1

    def compute_features(self, idx: int, df: pd.DataFrame, ind: dict) -> dict:
        raise NotImplementedError

    def compute_sl_tp(self, direction: str, price: float, atr: float,
                      features: dict) -> tuple:
        raise NotImplementedError

    def reset_daily(self, day: int):
        if day != self.current_day:
            self.current_day = day
            self.daily_trades = 0


class ScalperStrategy(BaseStrategy):
    """EMA cross + RSI confirmation (MatlamaScalper)"""
    def __init__(self):
        super().__init__("SCALPER", max_trades_per_day=3, max_hold_hours=4)
        self.sl_pips = 15
        self.tp_pips = 20

    def compute_features(self, idx, df, ind):
        return {
            "ema_diff_pips": (ind["ema8"].iloc[idx] - ind["ema21"].iloc[idx]) / POINT,
            "momentum_pips": ind["momentum"].iloc[idx],
            "rsi": ind["rsi"].iloc[idx],
        }

    def generate_signal(self, idx, df, ind, features):
        ema8 = ind["ema8"].iloc[idx]
        ema21 = ind["ema21"].iloc[idx]
        rsi = features["rsi"]

        if np.isnan(ema8) or np.isnan(ema21) or np.isnan(rsi):
            return None

        prev_ema8 = ind["ema8"].iloc[idx - 1] if idx > 0 else ema8
        prev_ema21 = ind["ema21"].iloc[idx - 1] if idx > 0 else ema21

        # EMA cross
        if prev_ema8 <= prev_ema21 and ema8 > ema21 and rsi < 65:
            return "BUY"
        if prev_ema8 >= prev_ema21 and ema8 < ema21 and rsi > 35:
            return "SELL"
        return None

    def compute_sl_tp(self, direction, price, atr, features):
        if direction == "BUY":
            sl = price - self.sl_pips * POINT
            tp = price + self.tp_pips * POINT
        else:
            sl = price + self.sl_pips * POINT
            tp = price - self.tp_pips * POINT
        return sl, tp


class QuantStrategy(BaseStrategy):
    """Fibonacci pressure + velocity (MatlamaQuant, simplified)"""
    def __init__(self):
        super().__init__("QUANT", max_trades_per_day=5, max_hold_hours=4)

    def compute_features(self, idx, df, ind):
        close = df["close"].iloc[idx]
        swing_hi = ind["swing_hi"].iloc[idx]
        swing_lo = ind["swing_lo"].iloc[idx]
        rng = swing_hi - swing_lo if swing_hi != swing_lo else 1.0

        # Fibonacci level proximity
        fib_levels = [0.236, 0.382, 0.5, 0.618, 0.786]
        min_dist = float("inf")
        nearest_fib = 0.5
        for fl in fib_levels:
            fib_price = swing_lo + rng * fl
            dist = abs(close - fib_price) / POINT
            if dist < min_dist:
                min_dist = dist
                nearest_fib = fl

        # Velocity: price change over 3 bars
        velocity = 0
        if idx >= 3:
            velocity = abs(df["close"].iloc[idx] - df["close"].iloc[idx - 3]) / POINT

        rsi = ind["rsi"].iloc[idx]
        prev_rsi = ind["rsi"].iloc[idx - 1] if idx > 0 else rsi
        rsi_accel = rsi - prev_rsi

        vol_avg = df["volume"].rolling(20).mean().iloc[idx]
        vol_ratio = df["volume"].iloc[idx] / vol_avg if vol_avg > 0 else 1.0

        # Signal score (simplified from the 7-layer system)
        score = 0
        if min_dist < 30:   score += 2  # near a Fib level
        if velocity > 5:    score += 1  # directional velocity
        if vol_ratio > 1.5: score += 1  # volume surge
        if rsi_accel > 0 and close > ind["ema21"].iloc[idx]: score += 1
        if rsi_accel < 0 and close < ind["ema21"].iloc[idx]: score += 1

        return {
            "fib_level": nearest_fib,
            "velocity": velocity,
            "volume_ratio": vol_ratio,
            "rsi_accel": rsi_accel,
            "signal_score": score,
        }

    def generate_signal(self, idx, df, ind, features):
        if features["signal_score"] < 3:
            return None
        close = df["close"].iloc[idx]
        ema = ind["ema21"].iloc[idx]
        if np.isnan(ema):
            return None
        if close > ema and features["rsi_accel"] > 0:
            return "BUY"
        if close < ema and features["rsi_accel"] < 0:
            return "SELL"
        return None

    def compute_sl_tp(self, direction, price, atr, features):
        sl_dist = max(atr * 1.5, 10 * POINT)
        tp_dist = max(atr * 3.0, 20 * POINT)
        if direction == "BUY":
            return price - sl_dist, price + tp_dist
        return price + sl_dist, price - tp_dist


class HFTStrategy(BaseStrategy):
    """Stop-hunt + momentum burst detection (MatlamaBridgeHFT, simplified)"""
    def __init__(self):
        super().__init__("HFT", max_trades_per_day=5, max_hold_hours=2)
        self.sl_pips = 30
        self.tp_pips = 60

    def compute_features(self, idx, df, ind):
        bar = df.iloc[idx]
        wick_up = (bar["high"] - max(bar["open"], bar["close"])) / POINT
        wick_dn = (min(bar["open"], bar["close"]) - bar["low"]) / POINT
        wick_pips = max(wick_up, wick_dn)

        momentum_pips = 0
        if idx >= 3:
            momentum_pips = abs(df["close"].iloc[idx] - df["close"].iloc[idx - 3]) / POINT

        vol_avg = df["volume"].rolling(20).mean().iloc[idx]
        vol_ratio = df["volume"].iloc[idx] / vol_avg if vol_avg > 0 else 1.0

        return {
            "wick_pips": wick_pips,
            "momentum_pips": momentum_pips,
            "volume_ratio": vol_ratio,
            "rsi": ind["rsi"].iloc[idx],
        }

    def generate_signal(self, idx, df, ind, features):
        bar = df.iloc[idx]
        # Stop hunt: large wick piercing swing level then reversal
        wick_up = (bar["high"] - max(bar["open"], bar["close"])) / POINT
        wick_dn = (min(bar["open"], bar["close"]) - bar["low"]) / POINT

        if features["wick_pips"] < 10 or features["volume_ratio"] < 1.3:
            return None

        # Large upper wick = stop hunt above → expect reversal down
        if wick_up > wick_dn and wick_up > 15 and features["rsi"] > 60:
            return "SELL"
        # Large lower wick = stop hunt below → expect reversal up
        if wick_dn > wick_up and wick_dn > 15 and features["rsi"] < 40:
            return "BUY"

        # Momentum burst
        if features["momentum_pips"] > 20 and features["volume_ratio"] > 1.5:
            if bar["close"] > bar["open"]:
                return "BUY"
            else:
                return "SELL"
        return None

    def compute_sl_tp(self, direction, price, atr, features):
        if direction == "BUY":
            return price - self.sl_pips * POINT, price + self.tp_pips * POINT
        return price + self.sl_pips * POINT, price - self.tp_pips * POINT


class ORBStrategy(BaseStrategy):
    """Opening Range Breakout (MatlamaORB)"""
    def __init__(self):
        super().__init__("ORB", max_trades_per_day=4, max_hold_hours=6)
        self.rr_multiple = 2.0
        self.range_minutes = 30
        self.range_high = None
        self.range_low = None
        self.range_session = None

    def compute_features(self, idx, df, ind):
        return {
            "range_high": self.range_high or 0,
            "range_low": self.range_low or 0,
            "session": self.range_session or "",
        }

    def generate_signal(self, idx, df, ind, features):
        t = df.index[idx]
        hour = t.hour if hasattr(t, 'hour') else 12

        # Build opening range for London (8:00) or NY (13:30)
        if hour == 8 and self.range_session != f"LONDON_{t.date()}":
            # Use first bar as the opening range
            self.range_high = df["high"].iloc[idx]
            self.range_low = df["low"].iloc[idx]
            self.range_session = f"LONDON_{t.date()}"
            return None

        if hour == 14 and self.range_session != f"NY_{t.date()}":
            self.range_high = df["high"].iloc[idx]
            self.range_low = df["low"].iloc[idx]
            self.range_session = f"NY_{t.date()}"
            return None

        if self.range_high is None or self.range_low is None:
            return None

        close = df["close"].iloc[idx]
        rng = self.range_high - self.range_low

        if rng < 2 * POINT:
            return None

        # Breakout detection
        if close > self.range_high + 2 * POINT:
            return "BUY"
        if close < self.range_low - 2 * POINT:
            return "SELL"
        return None

    def compute_sl_tp(self, direction, price, atr, features):
        rng = features["range_high"] - features["range_low"]
        if rng < POINT:
            rng = atr
        if direction == "BUY":
            sl = features["range_low"] - 5 * POINT
            tp = price + rng * self.rr_multiple
        else:
            sl = features["range_high"] + 5 * POINT
            tp = price - rng * self.rr_multiple
        return sl, tp


class VWAPStrategy(BaseStrategy):
    """VWAP mean-reversion (MatlamaTickScalper, adapted for H1)"""
    def __init__(self):
        super().__init__("TICK_SCALPER", max_trades_per_day=10, max_hold_hours=2)

    def compute_features(self, idx, df, ind):
        vwap_val = ind["vwap"].iloc[idx]
        vwap_std = ind["vwap_std"].iloc[idx]
        close = df["close"].iloc[idx]

        deviation = (close - vwap_val) / vwap_std if vwap_std > 0 else 0

        vwap_slope = 0
        if idx >= 3:
            prev_vwap = ind["vwap"].iloc[idx - 3]
            vwap_slope = (vwap_val - prev_vwap) / POINT if not np.isnan(prev_vwap) else 0

        return {
            "vwap_deviation": deviation,
            "rsi": ind["rsi"].iloc[idx],
            "adx": ind["adx"].iloc[idx],
            "spread_pips": SPREAD_PIPS,
            "vwap_slope": vwap_slope,
        }

    def generate_signal(self, idx, df, ind, features):
        dev = features["vwap_deviation"]
        rsi = features["rsi"]
        adx = features["adx"]

        if np.isnan(dev) or np.isnan(rsi) or np.isnan(adx):
            return None

        # Skip trending markets
        if adx > 30:
            return None

        # Mean reversion: enter when price deviates > 1.5 std from VWAP
        if dev < -1.5 and rsi < 35:
            return "BUY"
        if dev > 1.5 and rsi > 65:
            return "SELL"
        return None

    def compute_sl_tp(self, direction, price, atr, features):
        vwap_dist = abs(features["vwap_deviation"]) * POINT * 10
        tp_dist = max(min(vwap_dist, 15 * POINT), 2 * POINT)
        sl_dist = max(min(vwap_dist * 1.5, 15 * POINT), 3 * POINT)
        if direction == "BUY":
            return price - sl_dist, price + tp_dist
        return price + sl_dist, price - tp_dist


# ---------------------------------------------------------------------------
# Orchestrator replica (Python-native, no HTTP)
# ---------------------------------------------------------------------------
class OrchestratorSim:
    """Replicates orchestrator_v2.py logic without HTTP overhead."""

    BASE_THRESHOLDS = {"QUANT": 0.22}
    DEFAULT_THRESHOLD = 0.30

    def __init__(self):
        self.memory = deque(maxlen=300)

    def detect_regime(self, atr, adx, volatility, news_risk=0):
        if news_risk == 1:
            return "NEWS"
        if atr > 25 and adx > 25:
            return "TREND"
        if volatility < 0.4:
            return "RANGE"
        if atr > 40 and volatility > 0.8:
            return "CRISIS"
        return "MIXED"

    def win_rate(self, strategy=None, regime=None):
        data = list(self.memory)
        if strategy:
            data = [t for t in data if t["strategy"] == strategy]
        if regime:
            data = [t for t in data if t["regime"] == regime]
        if not data:
            return 0.5
        return sum(t["result"] for t in data) / len(data)

    def drawdown_factor(self, strategy=None):
        data = list(self.memory)
        if strategy:
            data = [t for t in data if t["strategy"] == strategy]
        if not data:
            return 1.0
        losses = sum(1 for t in data if t["result"] == 0)
        return max(0.5, 1.0 - losses / len(data))

    def streak(self, strategy=None):
        data = list(self.memory)
        if strategy:
            data = [t for t in data if t["strategy"] == strategy]
        if not data:
            return 0
        last = data[-1]["result"]
        count = 0
        for t in reversed(data):
            if t["result"] == last:
                count += 1
            else:
                break
        return count if last == 1 else -count

    def adaptive_threshold(self, regime, strategy):
        base = self.BASE_THRESHOLDS.get(strategy, self.DEFAULT_THRESHOLD)
        wr = self.win_rate(strategy=strategy, regime=regime)
        dd = self.drawdown_factor(strategy=strategy)
        strk = self.streak(strategy=strategy)

        wr_adj = (0.5 - wr) * 0.4
        dd_adj = (1.0 - dd) * 0.3
        strk_adj = 0.05 if strk <= -3 else (-0.03 if strk >= 3 else 0.0)

        return float(np.clip(base + wr_adj + dd_adj + strk_adj, 0.15, 0.75))

    def risk_check(self, spread, max_spread, regime, allow_news, allow_crisis,
                   equity, balance, max_dd_pct):
        if spread > max_spread:
            return False
        if regime == "NEWS" and not allow_news:
            return False
        if regime == "CRISIS" and not allow_crisis:
            return False
        if balance > 0 and (1 - equity / balance) > max_dd_pct:
            return False
        return True

    def decide(self, strategy_tag, signal, features, atr, adx, volatility,
               spread, equity, balance):
        regime = self.detect_regime(atr, adx, volatility)
        threshold = self.adaptive_threshold(regime, strategy_tag)

        if not self.risk_check(spread, 3.5, regime, False, False,
                               equity, balance, 0.05):
            return "HOLD", regime, 0.0, threshold

        # Without a trained model, use the strategy's own signal with a
        # confidence proxy based on feature quality
        if signal is None:
            return "HOLD", regime, 0.0, threshold

        # Simulate model confidence from strategy features
        confidence = self._feature_confidence(strategy_tag, features)

        if confidence >= threshold:
            return signal, regime, confidence, threshold
        return "HOLD", regime, confidence, threshold

    def _feature_confidence(self, strategy, features):
        """Heuristic confidence score in lieu of a trained ML model."""
        if strategy == "QUANT":
            score = features.get("signal_score", 0) / 5.0
            if features.get("volume_ratio", 0) > 2.0:
                score += 0.1
            return min(score, 1.0)
        elif strategy == "SCALPER":
            ema_diff = abs(features.get("ema_diff_pips", 0))
            rsi = features.get("rsi", 50)
            score = min(ema_diff / 50, 0.5)
            if rsi < 30 or rsi > 70:
                score += 0.3
            return min(score, 1.0)
        elif strategy == "HFT":
            wick = features.get("wick_pips", 0)
            vol_r = features.get("volume_ratio", 0)
            score = min(wick / 30, 0.5) + min(vol_r / 3, 0.3)
            return min(score, 1.0)
        elif strategy == "TICK_SCALPER":
            dev = abs(features.get("vwap_deviation", 0))
            return min(dev / 3.0, 1.0)
        elif strategy == "ORB":
            return 0.5  # rule-based, always moderate confidence
        return 0.3

    def report_trade(self, strategy, regime, win, profit):
        self.memory.append({
            "strategy": strategy,
            "regime": regime,
            "result": 1 if win else 0,
            "score": profit,
        })


# ---------------------------------------------------------------------------
# Trade execution engine
# ---------------------------------------------------------------------------
class TradeEngine:
    def __init__(self, initial_balance: float = 10000.0,
                 lot_mode: str = "fixed", risk_pct: float = 0.01):
        self.initial_balance = initial_balance
        self.balance = initial_balance
        self.equity = initial_balance
        self.lot_mode = lot_mode
        self.risk_pct = risk_pct
        self.open_positions: list[Trade] = []
        self.closed_trades: list[Trade] = []
        self.ticket_counter = 0
        self.equity_curve = []
        self.max_concurrent = 0
        self.peak_equity = initial_balance

    def calculate_lots(self, atr: float) -> float:
        if self.lot_mode == "fixed":
            return 0.01
        # Dynamic: risk_pct of equity / (ATR * pip_value)
        risk_amount = self.equity * self.risk_pct
        sl_pips = max(atr / POINT, 10)  # ATR-based SL in pips
        pip_value = PIP_VALUE_PER_LOT
        lots = risk_amount / (sl_pips * pip_value)
        return round(max(0.01, min(lots, 1.0)), 2)

    def open_trade(self, strategy: str, direction: str, price: float,
                   sl: float, tp: float, lots: float, time: datetime,
                   regime: str, features: dict) -> Optional[Trade]:
        # Apply spread + slippage
        adj = (SPREAD_PIPS + SLIPPAGE_PIPS) * POINT
        if direction == "BUY":
            entry = price + adj
        else:
            entry = price - adj

        self.ticket_counter += 1
        trade = Trade(
            ticket=self.ticket_counter,
            strategy=strategy,
            direction=direction,
            open_time=time,
            open_price=entry,
            sl=sl,
            tp=tp,
            lots=lots,
            regime=regime,
            features=features,
        )
        self.open_positions.append(trade)
        self.max_concurrent = max(self.max_concurrent, len(self.open_positions))
        return trade

    def check_exits(self, bar: Bar):
        still_open = []
        for t in self.open_positions:
            closed = False
            close_price = None
            reason = ""

            if t.direction == "BUY":
                if bar.low <= t.sl:
                    close_price = t.sl
                    reason = "SL"
                    closed = True
                elif bar.high >= t.tp:
                    close_price = t.tp
                    reason = "TP"
                    closed = True
            else:  # SELL
                if bar.high >= t.sl:
                    close_price = t.sl
                    reason = "SL"
                    closed = True
                elif bar.low <= t.tp:
                    close_price = t.tp
                    reason = "TP"
                    closed = True

            # Time exit
            if not closed:
                hours_open = (bar.time - t.open_time).total_seconds() / 3600
                if hours_open >= 4:  # generic max hold
                    close_price = bar.close
                    reason = "TIME"
                    closed = True

            if closed:
                self._close_trade(t, close_price, bar.time, reason)
            else:
                still_open.append(t)

        self.open_positions = still_open

    def _close_trade(self, t: Trade, close_price: float, close_time: datetime,
                     reason: str):
        t.close_price = close_price
        t.close_time = close_time
        t.close_reason = reason

        if t.direction == "BUY":
            pips = (close_price - t.open_price) / POINT
        else:
            pips = (t.open_price - close_price) / POINT

        t.profit = pips * PIP_VALUE_PER_LOT * t.lots
        self.balance += t.profit
        self.closed_trades.append(t)

    def update_equity(self, current_price: float, time: datetime):
        unrealized = 0
        for t in self.open_positions:
            if t.direction == "BUY":
                pips = (current_price - t.open_price) / POINT
            else:
                pips = (t.open_price - current_price) / POINT
            unrealized += pips * PIP_VALUE_PER_LOT * t.lots

        self.equity = self.balance + unrealized
        self.peak_equity = max(self.peak_equity, self.equity)

        self.equity_curve.append({
            "time": time,
            "equity": round(self.equity, 2),
            "balance": round(self.balance, 2),
            "open_positions": len(self.open_positions),
            "drawdown_pct": round(
                (1 - self.equity / self.peak_equity) * 100, 2
            ) if self.peak_equity > 0 else 0,
        })

    def has_position(self, strategy: str) -> bool:
        return any(t.strategy == strategy for t in self.open_positions)


# ---------------------------------------------------------------------------
# Performance metrics
# ---------------------------------------------------------------------------
def compute_metrics(engine: TradeEngine, months: float) -> dict:
    trades = engine.closed_trades
    if not trades:
        return {"error": "No trades to analyze"}

    profits = [t.profit for t in trades]
    wins = [p for p in profits if p > 0]
    losses = [p for p in profits if p <= 0]

    total_pnl = sum(profits)
    win_rate = len(wins) / len(profits) * 100 if profits else 0

    # Equity curve analysis
    eq = pd.DataFrame(engine.equity_curve)
    if len(eq) < 2:
        return {"error": "Insufficient equity data"}

    eq["returns"] = eq["equity"].pct_change().fillna(0)
    daily_returns = eq.set_index("time")["returns"].resample("D").sum().dropna()

    # Sharpe ratio (annualized)
    if daily_returns.std() > 0:
        sharpe = (daily_returns.mean() / daily_returns.std()) * math.sqrt(252)
    else:
        sharpe = 0

    # Sortino ratio
    downside = daily_returns[daily_returns < 0]
    if len(downside) > 0 and downside.std() > 0:
        sortino = (daily_returns.mean() / downside.std()) * math.sqrt(252)
    else:
        sortino = 0

    # Max drawdown
    max_dd = eq["drawdown_pct"].max()

    # Calmar ratio
    annual_return = (total_pnl / engine.initial_balance) * (12 / max(months, 1)) * 100
    calmar = annual_return / max_dd if max_dd > 0 else 0

    # Profit factor
    gross_profit = sum(wins) if wins else 0
    gross_loss = abs(sum(losses)) if losses else 1
    profit_factor = gross_profit / gross_loss if gross_loss > 0 else 0

    # Average trade
    avg_win = np.mean(wins) if wins else 0
    avg_loss = abs(np.mean(losses)) if losses else 0

    # Per-strategy breakdown
    strategy_stats = {}
    for tag in set(t.strategy for t in trades):
        st = [t for t in trades if t.strategy == tag]
        st_profits = [t.profit for t in st]
        st_wins = [p for p in st_profits if p > 0]
        strategy_stats[tag] = {
            "trades": len(st),
            "win_rate": len(st_wins) / len(st) * 100 if st else 0,
            "total_pnl": sum(st_profits),
            "avg_trade": np.mean(st_profits) if st_profits else 0,
            "best_trade": max(st_profits) if st_profits else 0,
            "worst_trade": min(st_profits) if st_profits else 0,
        }

    return {
        "total_trades": len(trades),
        "total_pnl": round(total_pnl, 2),
        "win_rate": round(win_rate, 1),
        "profit_factor": round(profit_factor, 2),
        "sharpe_ratio": round(sharpe, 2),
        "sortino_ratio": round(sortino, 2),
        "max_drawdown_pct": round(max_dd, 2),
        "calmar_ratio": round(calmar, 2),
        "avg_win": round(avg_win, 2),
        "avg_loss": round(avg_loss, 2),
        "win_loss_ratio": round(avg_win / avg_loss, 2) if avg_loss > 0 else 0,
        "max_concurrent_positions": engine.max_concurrent,
        "annual_return_pct": round(annual_return, 2),
        "initial_balance": engine.initial_balance,
        "final_balance": round(engine.balance, 2),
        "strategy_breakdown": strategy_stats,
    }


# ---------------------------------------------------------------------------
# Main backtest loop
# ---------------------------------------------------------------------------
def run_backtest(months: int = 6, strategies: list = None,
                 lot_mode: str = "fixed", initial_balance: float = 10000.0,
                 risk_pct: float = 0.01, max_concurrent: int = 0):

    log.info("=" * 60)
    log.info("MATLAMA QUANT ECOSYSTEM — PORTFOLIO BACKTEST")
    log.info("=" * 60)

    # Load data
    df = load_real_data(months)
    if df is None:
        df = generate_synthetic_gold(months)

    # Compute indicators
    log.info("Computing indicators...")
    ind = {
        "ema8": Indicators.ema(df["close"], 8),
        "ema21": Indicators.ema(df["close"], 21),
        "ema26": Indicators.ema(df["close"], 26),
        "rsi": Indicators.rsi(df["close"], 14),
        "atr": Indicators.atr(df["high"], df["low"], df["close"], 14),
        "adx": Indicators.adx(df["high"], df["low"], df["close"], 14),
        "volatility": Indicators.volatility(df["close"], 20),
        "momentum": Indicators.momentum(df["close"], 5),
        "swing_hi": Indicators.swing_highs(df["high"], 20),
        "swing_lo": Indicators.swing_lows(df["low"], 20),
    }
    vwap_vals, vwap_std = Indicators.vwap(df["high"], df["low"], df["close"],
                                           df["volume"], 20)
    ind["vwap"] = vwap_vals
    ind["vwap_std"] = vwap_std
    macd_line, macd_signal, macd_hist = Indicators.macd(df["close"])
    ind["macd_hist"] = macd_hist

    # Initialize strategies
    all_strategies = {
        "SCALPER": ScalperStrategy(),
        "QUANT": QuantStrategy(),
        "HFT": HFTStrategy(),
        "ORB": ORBStrategy(),
        "TICK_SCALPER": VWAPStrategy(),
    }

    if strategies:
        active = {k: v for k, v in all_strategies.items() if k in strategies}
    else:
        active = all_strategies

    log.info(f"Active strategies: {list(active.keys())}")
    log.info(f"Lot mode: {lot_mode} | Initial balance: ${initial_balance:,.0f}")
    if max_concurrent > 0:
        log.info(f"Max concurrent positions: {max_concurrent}")

    # Initialize engine
    engine = TradeEngine(initial_balance, lot_mode, risk_pct)
    orchestrator = OrchestratorSim()

    # Warmup period (skip first 50 bars for indicator stability)
    warmup = 50
    log.info(f"Processing {len(df) - warmup} bars (skipping {warmup} warmup)...")

    daily_start_balance = initial_balance
    current_day = -1
    daily_trade_counts = {tag: 0 for tag in active}

    for i in range(warmup, len(df)):
        bar_time = df.index[i]
        bar = Bar(
            time=bar_time,
            open=df["open"].iloc[i],
            high=df["high"].iloc[i],
            low=df["low"].iloc[i],
            close=df["close"].iloc[i],
            volume=df["volume"].iloc[i],
        )

        day = bar_time.day if hasattr(bar_time, 'day') else 0

        # Daily reset
        if day != current_day:
            current_day = day
            daily_start_balance = engine.balance
            daily_trade_counts = {tag: 0 for tag in active}

        # Daily loss check
        if (daily_start_balance - engine.equity) >= 50:
            engine.check_exits(bar)
            engine.update_equity(bar.close, bar_time)
            continue

        # Check exits on existing positions
        engine.check_exits(bar)

        # Get current indicator values
        atr = ind["atr"].iloc[i]
        adx = ind["adx"].iloc[i]
        vol = ind["volatility"].iloc[i]

        if np.isnan(atr) or np.isnan(adx):
            engine.update_equity(bar.close, bar_time)
            continue

        # Evaluate each strategy
        for tag, strat in active.items():
            # Skip if already in position for this strategy
            if engine.has_position(tag):
                continue

            # Skip if daily trade limit reached
            if daily_trade_counts[tag] >= strat.max_trades_per_day:
                continue

            # Portfolio-level position limit
            if max_concurrent > 0 and len(engine.open_positions) >= max_concurrent:
                continue

            # Compute features
            features = strat.compute_features(i, df, ind)

            # Generate signal
            signal = strat.generate_signal(i, df, ind, features)

            # Run through orchestrator
            decision, regime, confidence, threshold = orchestrator.decide(
                tag, signal, features, atr, adx, vol,
                SPREAD_PIPS * POINT, engine.equity, engine.balance
            )

            if decision == "HOLD":
                continue

            # Calculate position size and SL/TP
            lots = engine.calculate_lots(atr)
            sl, tp = strat.compute_sl_tp(decision, bar.close, atr, features)

            # Execute
            trade = engine.open_trade(
                tag, decision, bar.close, sl, tp, lots, bar_time, regime, features
            )
            if trade:
                daily_trade_counts[tag] += 1

        # Update equity
        engine.update_equity(bar.close, bar_time)

    # Close any remaining positions at last bar's close
    last_bar = Bar(
        time=df.index[-1],
        open=df["close"].iloc[-1],
        high=df["close"].iloc[-1] + 1,
        low=df["close"].iloc[-1] - 1,
        close=df["close"].iloc[-1],
        volume=0,
    )
    for t in list(engine.open_positions):
        engine._close_trade(t, last_bar.close, last_bar.time, "END")
    engine.update_equity(last_bar.close, last_bar.time)

    # Report results
    for t in engine.closed_trades:
        orchestrator.report_trade(
            t.strategy, t.regime, t.profit > 0, t.profit
        )

    metrics = compute_metrics(engine, months)
    return engine, metrics


# ---------------------------------------------------------------------------
# Output generation
# ---------------------------------------------------------------------------
def save_results(engine: TradeEngine, metrics: dict):
    # Equity curve
    eq_df = pd.DataFrame(engine.equity_curve)
    eq_path = os.path.join(OUTPUT_DIR, "equity_curve.csv")
    eq_df.to_csv(eq_path, index=False)

    # Trade log
    trade_data = []
    for t in engine.closed_trades:
        trade_data.append({
            "ticket": t.ticket,
            "strategy": t.strategy,
            "direction": t.direction,
            "open_time": t.open_time,
            "close_time": t.close_time,
            "open_price": t.open_price,
            "close_price": t.close_price,
            "lots": t.lots,
            "sl": t.sl,
            "tp": t.tp,
            "profit": t.profit,
            "close_reason": t.close_reason,
            "regime": t.regime,
        })
    trade_df = pd.DataFrame(trade_data)
    trade_path = os.path.join(OUTPUT_DIR, "trade_log.csv")
    trade_df.to_csv(trade_path, index=False)

    # Strategy breakdown
    if "strategy_breakdown" in metrics:
        breakdown = pd.DataFrame(metrics["strategy_breakdown"]).T
        breakdown.index.name = "strategy"
        bd_path = os.path.join(OUTPUT_DIR, "strategy_breakdown.csv")
        breakdown.to_csv(bd_path)

    # Performance report
    report_lines = [
        "=" * 60,
        "MATLAMA QUANT ECOSYSTEM — BACKTEST RESULTS",
        "=" * 60,
        "",
        "PORTFOLIO SUMMARY",
        "-" * 40,
        f"  Initial Balance:     ${metrics.get('initial_balance', 0):>12,.2f}",
        f"  Final Balance:       ${metrics.get('final_balance', 0):>12,.2f}",
        f"  Total P&L:           ${metrics.get('total_pnl', 0):>12,.2f}",
        f"  Annual Return:       {metrics.get('annual_return_pct', 0):>11.1f}%",
        "",
        "RISK METRICS",
        "-" * 40,
        f"  Sharpe Ratio:        {metrics.get('sharpe_ratio', 0):>12.2f}",
        f"  Sortino Ratio:       {metrics.get('sortino_ratio', 0):>12.2f}",
        f"  Max Drawdown:        {metrics.get('max_drawdown_pct', 0):>11.1f}%",
        f"  Calmar Ratio:        {metrics.get('calmar_ratio', 0):>12.2f}",
        "",
        "TRADE STATISTICS",
        "-" * 40,
        f"  Total Trades:        {metrics.get('total_trades', 0):>12d}",
        f"  Win Rate:            {metrics.get('win_rate', 0):>11.1f}%",
        f"  Profit Factor:       {metrics.get('profit_factor', 0):>12.2f}",
        f"  Avg Win:             ${metrics.get('avg_win', 0):>12.2f}",
        f"  Avg Loss:            ${metrics.get('avg_loss', 0):>12.2f}",
        f"  Win/Loss Ratio:      {metrics.get('win_loss_ratio', 0):>12.2f}",
        f"  Max Concurrent:      {metrics.get('max_concurrent_positions', 0):>12d}",
        "",
        "STRATEGY BREAKDOWN",
        "-" * 40,
    ]

    if "strategy_breakdown" in metrics:
        for tag, stats in metrics["strategy_breakdown"].items():
            report_lines.extend([
                f"  {tag}:",
                f"    Trades: {stats['trades']:<6d} | "
                f"Win Rate: {stats['win_rate']:5.1f}% | "
                f"P&L: ${stats['total_pnl']:>8.2f} | "
                f"Avg: ${stats['avg_trade']:>7.2f}",
            ])

    report_lines.extend(["", "=" * 60])
    report = "\n".join(report_lines)

    report_path = os.path.join(OUTPUT_DIR, "performance_report.txt")
    with open(report_path, "w") as f:
        f.write(report)

    # Also save metrics as JSON
    json_path = os.path.join(OUTPUT_DIR, "metrics.json")
    metrics_clean = {
        k: v for k, v in metrics.items()
        if k != "strategy_breakdown"
    }
    metrics_clean["strategy_breakdown"] = {
        k: {kk: round(vv, 4) if isinstance(vv, float) else vv
            for kk, vv in v.items()}
        for k, v in metrics.get("strategy_breakdown", {}).items()
    }
    with open(json_path, "w") as f:
        json.dump(metrics_clean, f, indent=2, default=str)

    return report


# ---------------------------------------------------------------------------
# Comparison runner (fixed vs dynamic lots)
# ---------------------------------------------------------------------------
def run_comparison(months: int = 6, strategies: list = None):
    """Run fixed vs dynamic lot sizing side by side."""
    log.info("\n" + "=" * 60)
    log.info("COMPARISON: Fixed Lots vs Dynamic Position Sizing")
    log.info("=" * 60)

    # Fixed lots
    log.info("\n--- Fixed Lots (0.01) ---")
    engine_fixed, metrics_fixed = run_backtest(
        months=months, strategies=strategies, lot_mode="fixed"
    )

    # Dynamic lots (1% risk)
    log.info("\n--- Dynamic Lots (1% equity risk) ---")
    engine_dynamic, metrics_dynamic = run_backtest(
        months=months, strategies=strategies, lot_mode="dynamic", risk_pct=0.01
    )

    # Dynamic lots with portfolio limit
    log.info("\n--- Dynamic Lots + 3-Position Limit ---")
    engine_limited, metrics_limited = run_backtest(
        months=months, strategies=strategies, lot_mode="dynamic",
        risk_pct=0.01, max_concurrent=3
    )

    comparison = {
        "Fixed 0.01 Lots": metrics_fixed,
        "Dynamic 1% Risk": metrics_dynamic,
        "Dynamic + 3-Pos Limit": metrics_limited,
    }

    # Print comparison table
    print("\n" + "=" * 80)
    print("COMPARISON RESULTS")
    print("=" * 80)
    header = f"{'Metric':<25} {'Fixed':<18} {'Dynamic':<18} {'Dyn+Limit':<18}"
    print(header)
    print("-" * 80)
    for key in ["total_pnl", "win_rate", "sharpe_ratio", "sortino_ratio",
                "max_drawdown_pct", "profit_factor", "total_trades",
                "annual_return_pct", "calmar_ratio"]:
        vals = []
        for name, m in comparison.items():
            v = m.get(key, 0)
            if isinstance(v, float):
                vals.append(f"{v:>14.2f}")
            else:
                vals.append(f"{v:>14}")
        print(f"  {key:<23} {vals[0]:<18} {vals[1]:<18} {vals[2]:<18}")

    print("=" * 80)

    # Save comparison
    comp_path = os.path.join(OUTPUT_DIR, "comparison.json")
    with open(comp_path, "w") as f:
        json.dump(comparison, f, indent=2, default=str)

    return comparison


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="Matlama Backtest Engine")
    parser.add_argument("--months", type=int, default=6, help="Backtest period")
    parser.add_argument("--strategies", type=str, default=None,
                        help="Comma-separated strategy tags (default: all)")
    parser.add_argument("--lot-mode", choices=["fixed", "dynamic"],
                        default="fixed", help="Lot sizing mode")
    parser.add_argument("--risk-pct", type=float, default=0.01,
                        help="Risk per trade (dynamic mode)")
    parser.add_argument("--balance", type=float, default=10000.0,
                        help="Initial account balance")
    parser.add_argument("--max-positions", type=int, default=0,
                        help="Max concurrent positions (0=unlimited)")
    parser.add_argument("--compare", action="store_true",
                        help="Run fixed vs dynamic comparison")
    args = parser.parse_args()

    strats = args.strategies.split(",") if args.strategies else None

    if args.compare:
        run_comparison(args.months, strats)
    else:
        engine, metrics = run_backtest(
            months=args.months,
            strategies=strats,
            lot_mode=args.lot_mode,
            initial_balance=args.balance,
            risk_pct=args.risk_pct,
            max_concurrent=args.max_positions,
        )
        report = save_results(engine, metrics)
        print(report)
        print(f"\nResults saved to: {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
