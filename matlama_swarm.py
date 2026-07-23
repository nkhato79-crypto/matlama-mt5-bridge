"""
Matlama Swarm Commander v1.0
Multi-bot operations system for Matlama Trading + EventPulse

Bots:
  Sentinel  - Health monitoring (every 5 min)
  Analyst   - Trade performance tracking (hourly + daily summary)
  Trainer   - ML pipeline monitor (every 30 min)
  Commander - Telegram command interface (real-time)

Deploy on VPS:  python matlama_swarm.py
Config:         Set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID env vars
Schedule:       Register as Windows Task (on startup, SYSTEM account)
"""

import csv
import json
import logging
import os
import signal
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests as http_requests

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TELEGRAM_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "")
EVENTPULSE_URL = os.getenv(
    "EVENTPULSE_URL", "https://matlamapulse-app.onrender.com"
)

ORCHESTRATOR_URL = "http://127.0.0.1:7000"
THRESHOLD_URL = "http://127.0.0.1:6000"
BRIDGE_URL = "http://127.0.0.1:5000"

BASE_DIR = os.getenv("MATLAMA_DIR", r"C:\Matlama")
MODEL_DIR = os.path.join(BASE_DIR, "model")
LOG_DIR = os.path.join(BASE_DIR, "logs")

MT5_FILES = (
    r"C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal"
    r"\5A08E185CE336B177334803F286A1E5F\MQL5\Files"
)

TRADE_CSVS = {
    "MBV3": os.path.join(MT5_FILES, "bridgev3_trades.csv"),
    "QUANT": os.path.join(MT5_FILES, "quant_trades.csv"),
    "HFT": os.path.join(MT5_FILES, "hft_trades.csv"),
    "SCALPER": os.path.join(MT5_FILES, "scalper_trades.csv"),
    "TICK_SCALPER": os.path.join(MT5_FILES, "tick_scalper_trades.csv"),
}

MODEL_FILES = {
    "MBV3": os.path.join(MODEL_DIR, "rf_model.pkl"),
    "QUANT": os.path.join(MODEL_DIR, "quant_model.pkl"),
    "HFT": os.path.join(MODEL_DIR, "hft_model.pkl"),
    "SCALPER": os.path.join(MODEL_DIR, "scalper_model.pkl"),
    "TICK_SCALPER": os.path.join(MODEL_DIR, "tick_scalper_model.pkl"),
}

STATE_FILES = {
    "MBV3": os.path.join(MODEL_DIR, "ml_train_state.json"),
    "QUANT": os.path.join(MODEL_DIR, "quant_train_state.json"),
    "HFT": os.path.join(MODEL_DIR, "hft_train_state.json"),
    "SCALPER": os.path.join(MODEL_DIR, "scalper_train_state.json"),
    "TICK_SCALPER": os.path.join(MODEL_DIR, "tick_scalper_train_state.json"),
}

SENTINEL_INTERVAL = 300       # 5 minutes
TRAINER_INTERVAL = 1800       # 30 minutes
ANALYST_INTERVAL = 3600       # 1 hour
MODEL_STALE_HOURS = 48
ALERT_COOLDOWN = 900          # 15 min between duplicate alerts
DAILY_SUMMARY_HOUR_UTC = 22   # 00:00 SAST
SUPERVISOR_INTERVAL = 60      # check supervised processes every 60s
SUPERVISOR_MAX_RESTARTS = 5   # max restarts before giving up

os.makedirs(LOG_DIR, exist_ok=True)


# ---------------------------------------------------------------------------
# Telegram API Client
# ---------------------------------------------------------------------------
class Telegram:
    def __init__(self, token):
        self.base = f"https://api.telegram.org/bot{token}"
        self.offset = 0

    def send(self, chat_id, text, parse_mode="Markdown"):
        try:
            r = http_requests.post(
                f"{self.base}/sendMessage",
                json={
                    "chat_id": chat_id,
                    "text": text,
                    "parse_mode": parse_mode,
                },
                timeout=10,
            )
            return r.json().get("ok", False)
        except Exception:
            return False

    def get_updates(self, timeout=30):
        try:
            r = http_requests.get(
                f"{self.base}/getUpdates",
                params={"offset": self.offset, "timeout": timeout},
                timeout=timeout + 5,
            )
            data = r.json()
            if data.get("ok") and data.get("result"):
                for u in data["result"]:
                    self.offset = u["update_id"] + 1
                return data["result"]
        except Exception:
            pass
        return []


# ---------------------------------------------------------------------------
# Sentinel Bot - Health Monitoring
# ---------------------------------------------------------------------------
class SentinelBot:
    STATUS_ICONS = {"UP": "✅", "DOWN": "🔴", "DEGRADED": "⚠️", "ERROR": "🟠"}

    def __init__(self, tg, chat_id, log):
        self.tg = tg
        self.chat_id = chat_id
        self.log = log
        self.last_status = {}
        self.alert_times = {}

    def check_service(self, name, url, timeout=5):
        try:
            r = http_requests.get(url, timeout=timeout)
            is_json = "application/json" in r.headers.get("content-type", "")
            return {
                "name": name,
                "status": "UP" if r.status_code == 200 else "DEGRADED",
                "code": r.status_code,
                "data": r.json() if is_json else {},
            }
        except http_requests.ConnectionError:
            return {"name": name, "status": "DOWN", "code": 0, "data": {}}
        except Exception as exc:
            return {"name": name, "status": "ERROR", "code": 0, "data": {"error": str(exc)}}

    def check_all(self):
        results = {
            "orchestrator": self.check_service("Orchestrator", f"{ORCHESTRATOR_URL}/health"),
            "threshold": self.check_service("Threshold Server", f"{THRESHOLD_URL}/"),
            "bridge": self.check_service("MT5 Bridge", f"{BRIDGE_URL}/health"),
        }
        if EVENTPULSE_URL:
            results["eventpulse"] = self.check_service(
                "EventPulse", f"{EVENTPULSE_URL}/api/health", timeout=10
            )

        for key, result in results.items():
            prev = self.last_status.get(key, {}).get("status")
            curr = result["status"]
            if prev and prev != curr:
                if curr == "DOWN":
                    self._alert(f"🚨 *{result['name']}* is DOWN!")
                elif curr == "UP" and prev in ("DOWN", "DEGRADED"):
                    self._alert(f"✅ *{result['name']}* recovered - UP")
                elif curr == "DEGRADED":
                    self._alert(f"⚠️ *{result['name']}* is DEGRADED")

        self.last_status = results
        self.log.info(
            "Health: %s", {k: v["status"] for k, v in results.items()}
        )
        return results

    def _alert(self, message):
        now = time.time()
        if message in self.alert_times and now - self.alert_times[message] < ALERT_COOLDOWN:
            return
        self.alert_times[message] = now
        if self.tg and self.chat_id:
            self.tg.send(self.chat_id, message)
        self.log.warning("ALERT: %s", message)

    def format_status(self):
        if not self.last_status:
            self.check_all()
        lines = ["*🛡️ System Status*", ""]
        for result in self.last_status.values():
            icon = self.STATUS_ICONS.get(result["status"], "⚪")
            lines.append(f"{icon} {result['name']}: *{result['status']}*")
            data = result.get("data", {})
            if "models_loaded" in data:
                ml = data["models_loaded"]
                lines.append(f"   Models: {sum(v for v in ml.values() if v)}/{len(ml)}")
            if "trade_memory_size" in data:
                lines.append(f"   Trade memory: {data['trade_memory_size']}")
            if "balance" in data:
                lines.append(f"   Balance: ${data['balance']:.2f}")
            if "supabase" in data:
                sb = "✅" if data["supabase"] == "connected" else "🔴"
                lines.append(f"   Supabase: {sb}")
        lines.append(f"\n_Checked {datetime.utcnow().strftime('%H:%M UTC')}_")
        return "\n".join(lines)


# ---------------------------------------------------------------------------
# Analyst Bot - Trade Performance
# ---------------------------------------------------------------------------
class AnalystBot:
    def __init__(self, log):
        self.log = log

    @staticmethod
    def _read_csv(path):
        if not os.path.exists(path):
            return []
        try:
            rows = []
            with open(path, newline="", encoding="utf-8-sig") as f:
                for row in csv.DictReader(f):
                    rows.append(row)
            return rows
        except Exception:
            return []

    def todays_trades(self):
        today = datetime.utcnow().strftime("%Y.%m.%d")
        summary = {}
        for strategy, path in TRADE_CSVS.items():
            trades = self._read_csv(path)
            day_trades = [
                t for t in trades if t.get("close_time", "").startswith(today)
            ]
            if day_trades:
                wins = sum(1 for t in day_trades if float(t.get("profit", 0)) > 0)
                pnl = sum(float(t.get("profit", 0)) for t in day_trades)
                summary[strategy] = {
                    "count": len(day_trades),
                    "wins": wins,
                    "losses": len(day_trades) - wins,
                    "profit": pnl,
                }
        return summary

    def strategy_performance(self, strategy, days=7):
        trades = self._read_csv(TRADE_CSVS.get(strategy, ""))
        if not trades:
            return None
        cutoff = (datetime.utcnow() - timedelta(days=days)).strftime("%Y.%m.%d")
        recent = [t for t in trades if t.get("close_time", "") >= cutoff]
        if not recent:
            return None
        wins = sum(1 for t in recent if float(t.get("profit", 0)) > 0)
        pnl = sum(float(t.get("profit", 0)) for t in recent)
        return {
            "strategy": strategy,
            "trades": len(recent),
            "wins": wins,
            "losses": len(recent) - wins,
            "win_rate": wins / len(recent) * 100,
            "total_profit": pnl,
            "avg_profit": pnl / len(recent),
        }

    def all_performance(self, days=7):
        return {
            s: p
            for s in TRADE_CSVS
            if (p := self.strategy_performance(s, days)) is not None
        }

    def total_trades_count(self):
        total = 0
        for path in TRADE_CSVS.values():
            total += len(self._read_csv(path))
        return total

    def format_todays_trades(self):
        summary = self.todays_trades()
        if not summary:
            return "📊 *Today's Trades*\n\nNo trades today yet."
        lines = ["📊 *Today's Trades*", ""]
        t_pnl, t_cnt = 0.0, 0
        for strat, d in summary.items():
            wr = d["wins"] / d["count"] * 100
            icon = "🟢" if d["profit"] > 0 else "🔴"
            lines.append(
                f"*{strat}*: {d['count']} trades | "
                f"W:{d['wins']} L:{d['losses']} ({wr:.0f}%) | "
                f"{icon} ${d['profit']:.2f}"
            )
            t_pnl += d["profit"]
            t_cnt += d["count"]
        icon = "🟢" if t_pnl > 0 else "🔴"
        lines += ["", f"*Total*: {t_cnt} trades | {icon} *${t_pnl:.2f}*"]
        return "\n".join(lines)

    def format_performance(self, days=7):
        results = self.all_performance(days)
        if not results:
            return f"📈 *{days}-Day Performance*\n\nNo trade data available."
        lines = [f"📈 *{days}-Day Performance*", ""]
        t_pnl, t_cnt, t_wins = 0.0, 0, 0
        for strat, d in results.items():
            icon = "🟢" if d["total_profit"] > 0 else "🔴"
            lines.append(f"*{strat}*")
            lines.append(f"  {d['trades']} trades | {d['win_rate']:.1f}% win rate")
            lines.append(f"  {icon} ${d['total_profit']:.2f} (avg ${d['avg_profit']:.2f})")
            lines.append("")
            t_pnl += d["total_profit"]
            t_cnt += d["trades"]
            t_wins += d["wins"]
        wr = t_wins / t_cnt * 100 if t_cnt else 0
        icon = "🟢" if t_pnl > 0 else "🔴"
        lines.append(f"*Overall*: {t_cnt} trades | {wr:.1f}% win rate")
        lines.append(f"Total P&L: {icon} *${t_pnl:.2f}*")
        return "\n".join(lines)


# ---------------------------------------------------------------------------
# Trainer Bot - ML Pipeline Monitor
# ---------------------------------------------------------------------------
class TrainerBot:
    def __init__(self, log):
        self.log = log

    def check_model(self, strategy):
        path = MODEL_FILES.get(strategy, "")
        if not path or not os.path.exists(path):
            return {"strategy": strategy, "exists": False}
        stat = os.stat(path)
        modified = datetime.fromtimestamp(stat.st_mtime)
        age_h = (datetime.now() - modified).total_seconds() / 3600
        trade_count = 0
        sf = STATE_FILES.get(strategy, "")
        if sf and os.path.exists(sf):
            try:
                with open(sf) as fh:
                    trade_count = json.load(fh).get("trade_count", 0)
            except Exception:
                pass
        return {
            "strategy": strategy,
            "exists": True,
            "age_hours": age_h,
            "modified": modified.strftime("%Y-%m-%d %H:%M"),
            "stale": age_h > MODEL_STALE_HOURS,
            "trade_count": trade_count,
            "size_kb": stat.st_size / 1024,
        }

    def check_all(self):
        return {s: self.check_model(s) for s in MODEL_FILES}

    def format_status(self):
        models = self.check_all()
        lines = ["*🧠 Model Status*", ""]
        for strat, info in models.items():
            if not info["exists"]:
                lines.append(f"❌ *{strat}*: No model")
            else:
                icon = "🟡" if info["stale"] else "🟢"
                lines.append(f"{icon} *{strat}*")
                lines.append(f"  Age: {info['age_hours']:.1f}h | Updated: {info['modified']}")
                lines.append(f"  Trades trained on: {info['trade_count']} | Size: {info['size_kb']:.0f} KB")
                if info["stale"]:
                    lines.append(f"  ⚠️ Stale (>{MODEL_STALE_HOURS}h)")
                lines.append("")
        return "\n".join(lines)


# ---------------------------------------------------------------------------
# Commander Bot - Telegram Command Interface
# ---------------------------------------------------------------------------
class CommanderBot:
    HELP_TEXT = (
        "*🎮 Matlama Swarm Commands*\n\n"
        "`/status`  — System health\n"
        "`/trades`  — Today's trades\n"
        "`/performance`  — 7-day performance\n"
        "`/performance30`  — 30-day performance\n"
        "`/models`  — ML model status\n"
        "`/supervisor`  — Process supervisor status\n"
        "`/pulse`  — EventPulse status\n"
        "`/full`  — Full system report\n"
        "`/chatid`  — Show your Chat ID\n"
        "`/help`  — This message"
    )

    def __init__(self, tg, chat_id, sentinel, analyst, trainer, log, supervisor=None):
        self.tg = tg
        self.chat_id = chat_id
        self.sentinel = sentinel
        self.analyst = analyst
        self.trainer = trainer
        self.supervisor = supervisor
        self.log = log

    def handle(self, update):
        msg = update.get("message", {})
        text = msg.get("text", "").strip()
        cid = str(msg.get("chat", {}).get("id", ""))
        if self.chat_id and cid != self.chat_id:
            return
        if not text.startswith("/"):
            return
        cmd = text.split()[0].lower().split("@")[0]
        handlers = {
            "/start": self._start,
            "/status": self._status,
            "/trades": self._trades,
            "/performance": self._performance,
            "/performance30": self._performance30,
            "/models": self._models,
            "/supervisor": self._supervisor,
            "/pulse": self._pulse,
            "/full": self._full,
            "/chatid": self._chatid,
            "/help": self._help,
        }
        fn = handlers.get(cmd, self._unknown)
        try:
            self.tg.send(cid, fn(cid))
        except Exception as exc:
            self.log.error("Command %s failed: %s", cmd, exc)
            self.tg.send(cid, f"❌ Command failed: {exc}")

    def _start(self, cid):
        return (
            "🤖 *Matlama Swarm Commander*\n\n"
            "I monitor your trading system and EventPulse app 24/7.\n\n"
            f"Your Chat ID: `{cid}`\n\n"
            "Type /help for commands."
        )

    def _status(self, _):
        return self.sentinel.format_status()

    def _trades(self, _):
        return self.analyst.format_todays_trades()

    def _performance(self, _):
        return self.analyst.format_performance(7)

    def _performance30(self, _):
        return self.analyst.format_performance(30)

    def _models(self, _):
        return self.trainer.format_status()

    def _supervisor(self, _):
        if self.supervisor:
            return self.supervisor.format_status()
        return "⚠️ Process supervisor not initialized."

    def _pulse(self, _):
        if not EVENTPULSE_URL:
            return "⚠️ EventPulse URL not configured."
        r = self.sentinel.check_service("EventPulse", f"{EVENTPULSE_URL}/api/health", timeout=10)
        icon = {
            "UP": "🟢", "DOWN": "🔴", "DEGRADED": "🟡"
        }.get(r["status"], "⚪")
        lines = [f"🎯 *EventPulse Status*", "", f"{icon} {r['status']}"]
        d = r.get("data", {})
        if "supabase" in d:
            sb = "🟢 Connected" if d["supabase"] == "connected" else "🔴 Down"
            lines.append(f"Supabase: {sb}")
        for k in ("events_count", "vendors_count", "tasks_count"):
            if k in d:
                label = k.replace("_count", "").title()
                lines.append(f"{label}: {d[k]}")
        if "response_ms" in d:
            lines.append(f"Response: {d['response_ms']}ms")
        return "\n".join(lines)

    def _full(self, cid):
        parts = [
            self.sentinel.format_status(),
            "",
            self.analyst.format_todays_trades(),
            "",
            self.trainer.format_status(),
        ]
        if self.supervisor:
            parts += ["", self.supervisor.format_status()]
        return "\n".join(parts)

    def _chatid(self, cid):
        return f"Your Chat ID: `{cid}`"

    def _help(self, _):
        return self.HELP_TEXT

    def _unknown(self, _):
        return "Unknown command. Type /help for available commands."


# ---------------------------------------------------------------------------
# Process Supervisor - Auto-restart critical services
# ---------------------------------------------------------------------------
class ProcessSupervisor:
    """Monitors and restarts Python services that should always be running."""

    MANAGED_PROCESSES = {
        "orchestrator": {
            "script": os.path.join(BASE_DIR, "orchestrator_v2.py"),
            "health_url": f"{ORCHESTRATOR_URL}/heartbeat",
            "display": "Orchestrator v2",
        },
        "threshold": {
            "script": os.path.join(BASE_DIR, "threshold_server_v2.py"),
            "health_url": f"{THRESHOLD_URL}/",
            "display": "Threshold Server",
        },
        "bridge": {
            "script": os.path.join(BASE_DIR, "flask_mt5_bridge.py"),
            "health_url": f"{BRIDGE_URL}/health",
            "display": "MT5 Bridge",
        },
    }

    def __init__(self, tg, chat_id, log):
        self.tg = tg
        self.chat_id = chat_id
        self.log = log
        self.processes = {}
        self.restart_counts = {k: 0 for k in self.MANAGED_PROCESSES}
        self.enabled = True

    def _is_healthy(self, name):
        cfg = self.MANAGED_PROCESSES[name]
        try:
            r = http_requests.get(cfg["health_url"], timeout=5)
            return r.status_code == 200
        except Exception:
            return False

    def _start_process(self, name):
        import subprocess
        cfg = self.MANAGED_PROCESSES[name]
        script = cfg["script"]
        if not os.path.exists(script):
            self.log.warning("Supervisor: %s script not found at %s", name, script)
            return False

        try:
            python_exe = sys.executable
            proc = subprocess.Popen(
                [python_exe, script],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            self.processes[name] = proc
            self.restart_counts[name] += 1
            self.log.info("Supervisor: Started %s (PID %d, restart #%d)",
                          name, proc.pid, self.restart_counts[name])
            return True
        except Exception as exc:
            self.log.error("Supervisor: Failed to start %s: %s", name, exc)
            return False

    def check_and_restart(self):
        if not self.enabled:
            return

        for name, cfg in self.MANAGED_PROCESSES.items():
            if self.restart_counts[name] >= SUPERVISOR_MAX_RESTARTS:
                continue

            if self._is_healthy(name):
                continue

            proc = self.processes.get(name)
            if proc and proc.poll() is None:
                continue

            self.log.warning("Supervisor: %s is DOWN, attempting restart...", cfg["display"])
            if self._start_process(name):
                msg = (f"🔄 *{cfg['display']}* was down — restarted "
                       f"(attempt {self.restart_counts[name]}/{SUPERVISOR_MAX_RESTARTS})")
            else:
                msg = f"❌ *{cfg['display']}* is down and could not be restarted"

            if self.tg and self.chat_id:
                self.tg.send(self.chat_id, msg)

            if self.restart_counts[name] >= SUPERVISOR_MAX_RESTARTS:
                exhausted_msg = (f"🛑 *{cfg['display']}* has exhausted restart attempts "
                                 f"({SUPERVISOR_MAX_RESTARTS}). Manual intervention needed.")
                if self.tg and self.chat_id:
                    self.tg.send(self.chat_id, exhausted_msg)
                self.log.error("Supervisor: %s exhausted restart limit", name)

    def stop_all(self):
        for name, proc in self.processes.items():
            if proc and proc.poll() is None:
                self.log.info("Supervisor: Stopping %s (PID %d)", name, proc.pid)
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except Exception:
                    proc.kill()

    def format_status(self):
        lines = ["*🔧 Process Supervisor*", ""]
        for name, cfg in self.MANAGED_PROCESSES.items():
            healthy = self._is_healthy(name)
            icon = "🟢" if healthy else "🔴"
            restarts = self.restart_counts[name]
            proc = self.processes.get(name)
            pid_str = f"PID {proc.pid}" if proc and proc.poll() is None else "external"
            lines.append(f"{icon} *{cfg['display']}*: {'UP' if healthy else 'DOWN'} ({pid_str})")
            if restarts > 0:
                lines.append(f"   Restarts: {restarts}/{SUPERVISOR_MAX_RESTARTS}")
        if not self.enabled:
            lines.append("\n⚠️ Supervisor disabled")
        return "\n".join(lines)


# ---------------------------------------------------------------------------
# Swarm Orchestrator
# ---------------------------------------------------------------------------
class MatlamaSwarm:
    def __init__(self):
        self.log = logging.getLogger("swarm")
        self.tg = Telegram(TELEGRAM_TOKEN) if TELEGRAM_TOKEN else None
        self.sentinel = SentinelBot(self.tg, TELEGRAM_CHAT_ID, self.log)
        self.analyst = AnalystBot(self.log)
        self.trainer = TrainerBot(self.log)
        self.supervisor = ProcessSupervisor(self.tg, TELEGRAM_CHAT_ID, self.log)
        self.commander = (
            CommanderBot(self.tg, TELEGRAM_CHAT_ID, self.sentinel, self.analyst,
                         self.trainer, self.log, self.supervisor)
            if self.tg
            else None
        )
        self.running = True

    def run(self):
        self.log.info("=== Matlama Swarm Commander v1.0 starting ===")
        self.sentinel.check_all()

        if self.tg and TELEGRAM_CHAT_ID:
            self.tg.send(
                TELEGRAM_CHAT_ID,
                "🤖 *Matlama Swarm Commander* is online!\nType /help for commands.",
            )

        if self.commander:
            threading.Thread(target=self._telegram_loop, daemon=True).start()

        last_sentinel = time.time()
        last_trainer = 0.0
        last_analyst = 0.0
        last_supervisor = 0.0
        last_daily = ""

        while self.running:
            now = time.time()

            if now - last_supervisor >= SUPERVISOR_INTERVAL:
                try:
                    self.supervisor.check_and_restart()
                except Exception as exc:
                    self.log.error("Supervisor: %s", exc)
                last_supervisor = now

            if now - last_sentinel >= SENTINEL_INTERVAL:
                try:
                    self.sentinel.check_all()
                except Exception as exc:
                    self.log.error("Sentinel: %s", exc)
                last_sentinel = now

            if now - last_trainer >= TRAINER_INTERVAL:
                try:
                    for strat, info in self.trainer.check_all().items():
                        if info.get("stale"):
                            self.sentinel._alert(
                                f"⚠️ *{strat}* model stale ({info['age_hours']:.0f}h)"
                            )
                except Exception as exc:
                    self.log.error("Trainer: %s", exc)
                last_trainer = now

            utcnow = datetime.utcnow()
            if (
                now - last_analyst >= ANALYST_INTERVAL
                and utcnow.weekday() < 5
                and 6 <= utcnow.hour <= 22
            ):
                self.log.info("Analyst refresh")
                last_analyst = now

            today = utcnow.strftime("%Y-%m-%d")
            if (
                utcnow.hour == DAILY_SUMMARY_HOUR_UTC
                and today != last_daily
                and utcnow.weekday() < 5
            ):
                if self.tg and TELEGRAM_CHAT_ID:
                    try:
                        self.tg.send(
                            TELEGRAM_CHAT_ID,
                            f"🌙 *End-of-Day Report ({today})*\n\n"
                            + self.analyst.format_todays_trades(),
                        )
                        self.tg.send(TELEGRAM_CHAT_ID, self.analyst.format_performance(7))
                        self.tg.send(TELEGRAM_CHAT_ID, self.trainer.format_status())
                    except Exception as exc:
                        self.log.error("Daily summary: %s", exc)
                last_daily = today

            time.sleep(10)

    def _telegram_loop(self):
        self.log.info("Commander bot polling started")
        while self.running:
            try:
                for update in self.tg.get_updates(timeout=30):
                    self.commander.handle(update)
            except Exception as exc:
                self.log.error("Telegram poll: %s", exc)
                time.sleep(5)

    def stop(self, *_):
        self.log.info("Swarm shutting down")
        self.running = False
        self.supervisor.stop_all()
        if self.tg and TELEGRAM_CHAT_ID:
            self.tg.send(TELEGRAM_CHAT_ID, "🔴 Matlama Swarm Commander shutting down.")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        handlers=[
            logging.FileHandler(os.path.join(LOG_DIR, "swarm.log")),
            logging.StreamHandler(),
        ],
    )

    swarm = MatlamaSwarm()
    signal.signal(signal.SIGINT, swarm.stop)
    signal.signal(signal.SIGTERM, swarm.stop)

    try:
        swarm.run()
    except KeyboardInterrupt:
        swarm.stop()
