#!/usr/bin/env python3
"""
mt5_claude_bridge.py — connect the Claude API to MetaTrader 5's built-in MCP server.

MT5 (build 5100+) exposes an MCP endpoint under Tools -> Options -> MCP, bound to
localhost (default http://127.0.0.1:22346/mcp) and protected by an API key.

The Claude API's MCP connector runs SERVER-SIDE: Anthropic's infrastructure makes the
HTTP calls to the MCP server, not this script. So the URL you give it must be publicly
reachable. On the VPS that means fronting the localhost endpoint with a tunnel:

    C:\\cloudflared.exe tunnel --url http://localhost:22346

which prints an https://<random>.trycloudflare.com address. The MCP path is appended:

    MT5_MCP_URL=https://<random>.trycloudflare.com/mcp

Usage
-----
    export ANTHROPIC_API_KEY=sk-ant-...
    export MT5_MCP_URL=https://<random>.trycloudflare.com/mcp
    export MT5_MCP_KEY=<the API key from the MT5 MCP options tab>

    python mt5_claude_bridge.py check
    python mt5_claude_bridge.py ask "What is the current XAUUSD bid/ask and spread?"
    python mt5_claude_bridge.py export --symbol XAUUSD --timeframe H1 \\
        --start 2026-01-01 --end 2026-07-31 --out xauusd_h1.csv

Nothing here is hardcoded: credentials come from the environment only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from datetime import datetime, timezone

try:
    import anthropic
except ImportError:  # pragma: no cover
    sys.exit("anthropic SDK not installed.  pip install anthropic")


MCP_BETA = "mcp-client-2025-11-20"
SERVER_NAME = "mt5"
DEFAULT_MODEL = "claude-opus-5"

# Non-streaming responses should stay well under the SDK's HTTP timeout.
MAX_TOKENS = 16000


# --------------------------------------------------------------------------- config


class Config:
    def __init__(self) -> None:
        self.api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
        self.mcp_url = os.environ.get("MT5_MCP_URL", "").strip()
        self.mcp_key = os.environ.get("MT5_MCP_KEY", "").strip()
        self.model = os.environ.get("MT5_CLAUDE_MODEL", DEFAULT_MODEL).strip()

    def validate(self) -> None:
        missing = [
            name
            for name, value in (
                ("ANTHROPIC_API_KEY", self.api_key),
                ("MT5_MCP_URL", self.mcp_url),
                ("MT5_MCP_KEY", self.mcp_key),
            )
            if not value
        ]
        if missing:
            sys.exit(
                "Missing environment variable(s): "
                + ", ".join(missing)
                + "\nSee the module docstring for how to obtain each one."
            )

        if self.mcp_url.startswith("http://127.0.0.1") or self.mcp_url.startswith(
            "http://localhost"
        ):
            sys.exit(
                "MT5_MCP_URL points at localhost.\n"
                "The MCP connector is server-side — Anthropic must be able to reach the\n"
                "URL over the public internet. Start the tunnel first:\n"
                "    cloudflared tunnel --url http://localhost:22346\n"
                "then use the https://<random>.trycloudflare.com/mcp address it prints."
            )

        if not self.mcp_url.startswith("https://"):
            sys.exit("MT5_MCP_URL must be an https:// URL.")


def server_spec(cfg: Config) -> dict:
    return {
        "type": "url",
        "name": SERVER_NAME,
        "url": cfg.mcp_url,
        "authorization_token": cfg.mcp_key,
    }


# --------------------------------------------------------------------------- calling


def call_claude(cfg: Config, prompt: str, system: str | None = None) -> "anthropic.types.Message":
    """One MCP-enabled turn. The connector loop (tool calls -> results) runs server-side."""
    client = anthropic.Anthropic(api_key=cfg.api_key)

    kwargs = {
        "model": cfg.model,
        "max_tokens": MAX_TOKENS,
        "betas": [MCP_BETA],
        "mcp_servers": [server_spec(cfg)],
        # Every declared server must be referenced by exactly one toolset entry,
        # otherwise the request fails validation.
        "tools": [{"type": "mcp_toolset", "mcp_server_name": SERVER_NAME}],
        "messages": [{"role": "user", "content": prompt}],
    }
    if system:
        kwargs["system"] = system

    try:
        return client.beta.messages.create(**kwargs)
    except anthropic.APIStatusError as exc:
        detail = getattr(exc, "message", None) or str(exc)
        sys.exit(f"Claude API error ({exc.status_code}): {detail}")
    except anthropic.APIConnectionError as exc:
        sys.exit(f"Could not reach the Claude API: {exc}")


def text_of(message) -> str:
    return "\n".join(b.text for b in message.content if getattr(b, "type", "") == "text")


def dump_blocks(message, path: str) -> None:
    """Persist every block, including MCP tool calls and their raw results."""
    blocks = []
    for b in message.content:
        try:
            blocks.append(b.model_dump(mode="json"))
        except AttributeError:
            blocks.append({"type": getattr(b, "type", "unknown"), "repr": repr(b)})
    payload = {
        "id": message.id,
        "model": message.model,
        "stop_reason": message.stop_reason,
        "usage": message.usage.model_dump(mode="json"),
        "content": blocks,
    }
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)


def report_usage(message) -> None:
    u = message.usage
    print(
        f"\n[usage] in={u.input_tokens} out={u.output_tokens} "
        f"stop={message.stop_reason}",
        file=sys.stderr,
    )


# --------------------------------------------------------------------------- commands


def cmd_check(cfg: Config, args) -> int:
    print(f"MCP server : {cfg.mcp_url}")
    print(f"Model      : {cfg.model}")
    print("Asking Claude to enumerate the MT5 toolset...\n")

    msg = call_claude(
        cfg,
        "You are connected to a MetaTrader 5 instance over MCP. "
        "List every tool the mt5 server exposes, one per line, as `name — what it does`. "
        "Then call whichever tool reports account or terminal information and show me "
        "the account number, broker, currency, balance and equity. "
        "If a call fails, quote the exact error rather than guessing.",
    )
    print(text_of(msg))
    dump_blocks(msg, args.raw or "mt5_check_raw.json")
    print(f"\nRaw blocks written to {args.raw or 'mt5_check_raw.json'}", file=sys.stderr)
    report_usage(msg)
    return 0


def cmd_ask(cfg: Config, args) -> int:
    msg = call_claude(cfg, args.prompt)
    print(text_of(msg))
    if args.raw:
        dump_blocks(msg, args.raw)
        print(f"\nRaw blocks written to {args.raw}", file=sys.stderr)
    report_usage(msg)
    return 0


CSV_FENCE = re.compile(r"```(?:csv)?\s*\n(.*?)```", re.DOTALL)


def cmd_export(cfg: Config, args) -> int:
    prompt = (
        f"Using the mt5 MCP tools, fetch historical bars for {args.symbol} on the "
        f"{args.timeframe} timeframe from {args.start} to {args.end} (UTC, inclusive).\n\n"
        "Return the result as a single fenced csv block and nothing else outside it. "
        "Header row exactly:\n"
        "  time,open,high,low,close,tick_volume\n"
        "One row per bar, ISO-8601 UTC timestamps (YYYY-MM-DD HH:MM:SS), ascending by time, "
        "prices at the symbol's full quoted precision. Do not summarise, truncate, "
        "round, or interpolate — if the range is too large to return in one response, "
        "emit as many complete bars as fit and state the last timestamp reached "
        "on a line after the fenced block."
    )

    msg = call_claude(cfg, prompt)
    body = text_of(msg)

    raw_path = args.raw or f"mt5_export_raw_{int(time.time())}.json"
    dump_blocks(msg, raw_path)

    match = CSV_FENCE.search(body)
    if not match:
        print(body)
        print(
            f"\nNo CSV block found in the response. Raw tool results kept at {raw_path} "
            "— the bar data is probably in there under the mcp tool result blocks.",
            file=sys.stderr,
        )
        report_usage(msg)
        return 1

    csv_text = match.group(1).strip() + "\n"
    with open(args.out, "w", encoding="utf-8", newline="") as fh:
        fh.write(csv_text)

    rows = csv_text.count("\n") - 1
    print(f"Wrote {rows} bars to {args.out}")
    print(f"Raw blocks at {raw_path}", file=sys.stderr)

    trailer = body[match.end():].strip()
    if trailer:
        print(f"\nModel note: {trailer}")

    report_usage(msg)
    return 0


# --------------------------------------------------------------------------- cli


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="mt5_claude_bridge",
        description="Talk to MetaTrader 5 through the Claude API's MCP connector.",
    )
    sub = p.add_subparsers(dest="command", required=True)

    def with_raw(sp):
        sp.add_argument("--raw", help="write the full response blocks to this JSON file")
        return sp

    with_raw(sub.add_parser("check", help="verify the link and list the MT5 toolset"))

    ask = with_raw(sub.add_parser("ask", help="ask Claude a free-form question with MT5 access"))
    ask.add_argument("prompt")

    exp = with_raw(sub.add_parser("export", help="pull historical bars into a CSV file"))
    exp.add_argument("--symbol", default="XAUUSD")
    exp.add_argument("--timeframe", default="H1")
    exp.add_argument("--start", default="2026-01-01")
    exp.add_argument("--end", default=datetime.now(timezone.utc).strftime("%Y-%m-%d"))
    exp.add_argument("--out", default="bars.csv")

    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    cfg = Config()
    cfg.validate()

    handlers = {"check": cmd_check, "ask": cmd_ask, "export": cmd_export}
    return handlers[args.command](cfg, args)


if __name__ == "__main__":
    raise SystemExit(main())
