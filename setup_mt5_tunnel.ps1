<#
.SYNOPSIS
    Expose MetaTrader 5's built-in MCP server through a Cloudflare quick tunnel.

.DESCRIPTION
    MT5's MCP endpoint binds to localhost only. The Claude API's MCP connector runs
    server-side, so Anthropic must be able to reach the endpoint over the public
    internet. This script:

        1. confirms MT5 is actually listening on the MCP port
        2. downloads cloudflared if it is not already present
        3. starts a quick tunnel and waits for the public hostname
        4. prints the exact environment variables mt5_claude_bridge.py needs

    Run it on the VPS, in the same session where MT5 is running.

    Enable the endpoint first: MT5 -> Tools -> Options -> MCP -> tick "Enable MCP
    server", note the port and the API key.

.PARAMETER Port
    MCP port from the MT5 options tab. Default 22346.

.PARAMETER ExePath
    Where to keep cloudflared.exe. Default C:\cloudflared.exe.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File setup_mt5_tunnel.ps1
#>

[CmdletBinding()]
param(
    [int]    $Port    = 22346,
    [string] $ExePath = "C:\cloudflared.exe"
)

$ErrorActionPreference = "Stop"

function Test-Listening {
    param([int] $P)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect("127.0.0.1", $P)
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

Write-Host "Checking for the MT5 MCP server on port $Port ..." -ForegroundColor Cyan
if (-not (Test-Listening -P $Port)) {
    Write-Host ""
    Write-Host "Nothing is listening on 127.0.0.1:$Port." -ForegroundColor Red
    Write-Host "In MetaTrader 5: Tools -> Options -> MCP -> tick 'Enable MCP server',"
    Write-Host "confirm the port matches, click OK, then run this script again."
    exit 1
}
Write-Host "  MCP server is up." -ForegroundColor Green

if (-not (Test-Path $ExePath)) {
    Write-Host "Downloading cloudflared to $ExePath ..." -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $url = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
    Invoke-WebRequest -Uri $url -OutFile $ExePath -UseBasicParsing
    Write-Host "  Downloaded." -ForegroundColor Green
} else {
    Write-Host "cloudflared already present at $ExePath." -ForegroundColor Green
}

$logOut = Join-Path $env:TEMP "cloudflared.out.log"
$logErr = Join-Path $env:TEMP "cloudflared.err.log"
Remove-Item $logOut, $logErr -ErrorAction SilentlyContinue

Write-Host "Starting quick tunnel ..." -ForegroundColor Cyan
$proc = Start-Process -FilePath $ExePath `
    -ArgumentList "tunnel", "--url", "http://localhost:$Port" `
    -RedirectStandardOutput $logOut `
    -RedirectStandardError  $logErr `
    -NoNewWindow -PassThru

# cloudflared prints the hostname to stderr inside a banner, usually within a few seconds.
$pattern  = 'https://[a-z0-9-]+\.trycloudflare\.com'
$hostname = $null
$deadline = (Get-Date).AddSeconds(60)

while ((Get-Date) -lt $deadline -and -not $hostname) {
    Start-Sleep -Milliseconds 700
    if ($proc.HasExited) {
        Write-Host "cloudflared exited early (code $($proc.ExitCode))." -ForegroundColor Red
        Get-Content $logErr -ErrorAction SilentlyContinue | Select-Object -Last 20
        exit 1
    }
    foreach ($file in @($logErr, $logOut)) {
        if (Test-Path $file) {
            $text = Get-Content $file -Raw -ErrorAction SilentlyContinue
            if ($text -and $text -match $pattern) { $hostname = $Matches[0]; break }
        }
    }
}

if (-not $hostname) {
    Write-Host "Timed out waiting for the tunnel hostname." -ForegroundColor Red
    Write-Host "Last lines of $logErr :"
    Get-Content $logErr -ErrorAction SilentlyContinue | Select-Object -Last 20
    exit 1
}

$mcpUrl = "$hostname/mcp"

Write-Host ""
Write-Host "Tunnel is live." -ForegroundColor Green
Write-Host "  Public MCP URL : $mcpUrl"
Write-Host "  cloudflared PID: $($proc.Id)   (tunnel dies when this process stops)"
Write-Host ""
Write-Host "Set these where you run mt5_claude_bridge.py:" -ForegroundColor Cyan
Write-Host "  `$env:MT5_MCP_URL = `"$mcpUrl`""
Write-Host "  `$env:MT5_MCP_KEY = `"<API key from the MT5 MCP options tab>`""
Write-Host "  `$env:ANTHROPIC_API_KEY = `"<key from console.anthropic.com>`""
Write-Host ""
Write-Host "Then:  python mt5_claude_bridge.py check"
Write-Host ""
Write-Host "Quick-tunnel hostnames are ephemeral — restarting cloudflared issues a new one."
Write-Host "Leave this window open for as long as you need the link." -ForegroundColor Yellow

$env:MT5_MCP_URL = $mcpUrl
Wait-Process -Id $proc.Id
