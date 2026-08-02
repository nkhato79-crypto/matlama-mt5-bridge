# Linking Claude to MetaTrader 5

MetaTrader 5 ships an MCP server. Claude can drive it — read quotes, pull history,
inspect the account — but only through the Claude API's MCP connector, and only once
the endpoint is reachable from outside the VPS.

## Why a tunnel is required

The MCP connector runs **server-side**. When you pass `mcp_servers` to the Messages
API, Anthropic's infrastructure makes the HTTP calls to the MCP server — the request
does not originate from your machine. MT5 binds its MCP listener to `127.0.0.1`, which
Anthropic cannot reach. A tunnel gives that listener a public hostname.

This also means a chat session on claude.ai cannot reach MT5 on its own. The link is
made by code you run, using your own API key.

## One-time setup

**1. Enable the MCP server in MT5**

Tools → Options → MCP → tick *Enable MCP server*. Note the port (default `22346`) and
copy the API key.

**2. Start the tunnel** (on the VPS, MT5 running)

```powershell
powershell -ExecutionPolicy Bypass -File setup_mt5_tunnel.ps1
```

It checks the MCP port, downloads `cloudflared` if needed, starts a quick tunnel, and
prints the public URL. Leave the window open — closing it kills the tunnel.

**3. Point the bridge at it**

```powershell
$env:ANTHROPIC_API_KEY = "sk-ant-..."           # console.anthropic.com
$env:MT5_MCP_URL       = "https://<random>.trycloudflare.com/mcp"
$env:MT5_MCP_KEY       = "<API key from the MT5 MCP tab>"
```

**4. Verify**

```powershell
python mt5_claude_bridge.py check
```

This lists the tools MT5 exposes and reads back the account number, broker, balance
and equity. If that works, the link is live.

## Using it

```powershell
# free-form, with live terminal access
python mt5_claude_bridge.py ask "Current XAUUSD bid, ask and spread?"
python mt5_claude_bridge.py ask "List open positions with their unrealised P&L."

# pull real history for backtesting
python mt5_claude_bridge.py export --symbol XAUUSD --timeframe H1 `
    --start 2026-01-01 --end 2026-07-31 --out xauusd_h1.csv
```

`export` writes a `time,open,high,low,close,tick_volume` CSV. Every run also dumps the
raw response blocks — including each MCP tool call and its result — to a JSON file, so
when a response is truncated or malformed the underlying data is still recoverable.

## Getting history without any of this

For backtesting alone the tunnel is optional. In MT5: press `F2` (History Center),
pick the symbol and timeframe, click *Export*, and upload the resulting CSV. Same data,
no networking involved.

## Notes and limits

- **Quick-tunnel hostnames are ephemeral.** Restarting `cloudflared` issues a new one;
  `MT5_MCP_URL` has to be updated each time. A named Cloudflare tunnel gives a stable
  hostname if this becomes routine.
- **The tunnel is public while it runs.** The MT5 API key is the only thing guarding
  it. Treat that key as a credential — environment variables only, never committed —
  and stop the tunnel when you are done with it.
- **Bar counts are bounded by the response size.** A single `export` call returns what
  fits in one response; for long ranges, run it in chunks or use the F2 export.
- **The connector is behind a beta flag**, `mcp-client-2025-11-20`, and is not
  available on Bedrock or Vertex.
- Anything the MT5 toolset can do — including placing orders, if MT5 exposes that —
  becomes reachable while the tunnel is up. Account 591603250 is a demo account; think
  carefully before pointing this at a live one.
