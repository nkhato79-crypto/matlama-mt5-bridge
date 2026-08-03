@echo off
REM ================================================================
REM  Matlama Deploy Script — ORB + QUANT + IBB + HA Mode
REM  Pulls latest code, copies ORB + QUANT + IBB + HA + support files to MT5,
REM  restarts Swarm.
REM ================================================================

setlocal enabledelayedexpansion

set REPO_DIR=C:\Matlama
set BRANCH=claude/git-repository-access-vri6h7

set MT5_TERMINAL=C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\5A08E185CE336B177334803F286A1E5F
set MT5_EXPERTS=%MT5_TERMINAL%\MQL5\Experts\Matlama
set MT5_INCLUDE=%MT5_TERMINAL%\MQL5\Include
set METAEDITOR="%MT5_TERMINAL%\metaeditor64.exe"

echo.
echo ========================================
echo   Matlama Deploy — ORB + QUANT + IBB + HA Mode
echo   %date% %time%
echo ========================================
echo.

REM --- Step 1: Pull latest code ---
echo [1/5] Pulling latest from %BRANCH%...
cd /d %REPO_DIR%
git fetch origin %BRANCH%
git checkout %BRANCH%
git pull origin %BRANCH%
if errorlevel 1 (
    echo ERROR: Git pull failed. Check network and try again.
    pause
    exit /b 1
)
echo      Done.
echo.

REM --- Step 2: Copy ORB + QUANT + IBB + HA + support files to MT5 ---
echo [2/5] Copying EA files to MetaTrader...
if not exist "%MT5_EXPERTS%" mkdir "%MT5_EXPERTS%"

for %%f in (
    MatlamaORB.mq5
    MatlamaQuant.mq5
    MatlamaIBB.mq5
    MatlamaHAMomentum.mq5
    MatlamaFundamentals.mq5
    MatlamaMonitor.mq5
    OrchestratorClient.mqh
    DynamicLot.mqh
    PropFirmGuard.mqh
) do (
    if exist "%REPO_DIR%\%%f" (
        copy /y "%REPO_DIR%\%%f" "%MT5_EXPERTS%\%%f" >nul
        echo      Copied %%f
    )
)
echo      Done.
echo.

REM --- Step 3: Compile EAs ---
echo [3/5] Compiling EAs...

if not exist %METAEDITOR% (
    echo      WARNING: MetaEditor not found at %METAEDITOR%
    echo      Compile manually in MetaEditor -- press F7 on each EA.
    echo      Skipping compilation...
    goto skip_compile
)

if not exist "%REPO_DIR%\logs" mkdir "%REPO_DIR%\logs"

for %%f in (
    MatlamaORB.mq5
    MatlamaQuant.mq5
    MatlamaIBB.mq5
    MatlamaHAMomentum.mq5
    MatlamaFundamentals.mq5
    MatlamaMonitor.mq5
) do (
    echo      Compiling %%f...
    %METAEDITOR% /compile:"%MT5_EXPERTS%\%%f" /log:"%REPO_DIR%\logs\compile_%%~nf.log" /include:"%MT5_EXPERTS%"
)

echo      Compile logs saved to %REPO_DIR%\logs\
echo      Done.

REM Check for compile errors
set COMPILE_ERRORS=0
for %%f in ("%REPO_DIR%\logs\compile_*.log") do (
    findstr /i "error" "%%f" >nul 2>&1
    if not errorlevel 1 (
        echo      WARNING: Compile errors in %%~nxf
        set /a COMPILE_ERRORS=COMPILE_ERRORS+1
    )
)
if not %COMPILE_ERRORS%==0 (
    echo      Review compile logs before proceeding.
    echo.
)

:skip_compile
echo.

REM --- Step 4: Restart Python services ---
echo [4/5] Restarting Python services...

REM Stop old swarm if running
taskkill /f /fi "windowtitle eq MatlamaSwarm" >nul 2>&1

REM Give processes time to exit
timeout /t 3 /nobreak >nul

REM Start swarm
echo      Starting Matlama Swarm Commander...
start "MatlamaSwarm" /min python "%REPO_DIR%\matlama_swarm.py"
echo      Done.
echo.

REM --- Step 5: Verify ---
echo [5/5] Verifying services...
timeout /t 8 /nobreak >nul

set ALL_OK=1

REM Check orchestrator
curl -s http://127.0.0.1:7000/heartbeat >nul 2>&1
if errorlevel 1 (
    echo      WARNING: Orchestrator not responding yet
    set ALL_OK=0
) else (
    echo      Orchestrator: OK
)

REM Check threshold server
curl -s http://127.0.0.1:6000/ >nul 2>&1
if errorlevel 1 (
    echo      WARNING: Threshold server not responding yet
    set ALL_OK=0
) else (
    echo      Threshold Server: OK
)

REM Check bridge
curl -s http://127.0.0.1:5000/health >nul 2>&1
if errorlevel 1 (
    echo      WARNING: MT5 Bridge not responding yet
    set ALL_OK=0
) else (
    echo      MT5 Bridge: OK
)

echo.
echo ========================================
if %ALL_OK%==1 (
    echo   DEPLOYMENT COMPLETE — All services UP
) else (
    echo   DEPLOYMENT COMPLETE — Some services still starting
    echo   The Swarm Supervisor will auto-restart them.
    echo   Run /status in Telegram to check.
)
echo ========================================
echo.
echo  ORB + QUANT + IBB + HA MODE: Attach MatlamaORB,
echo  MatlamaQuant, MatlamaIBB and MatlamaHAMomentum
echo  to your charts. MatlamaIBB and MatlamaHAMomentum
echo  both go on the GOLD chart.
echo  Remove all other EAs from MT5 if still attached:
echo    - MatlamaScalper
echo    - MatlamaTickScalper
echo    - MatlamaBridgeHFT
echo    - matlamabridgeV3
echo.
echo  Then restart MT5 or re-attach the EAs.
echo.
pause
