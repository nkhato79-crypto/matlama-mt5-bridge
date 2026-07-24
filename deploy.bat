@echo off
REM ================================================================
REM  Matlama Deploy Script — Run on VPS as Administrator
REM  Pulls latest code, copies EA files to MT5, restarts services.
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
echo   Matlama Deployment Script
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

REM --- Step 2: Copy MQ5 files to MT5 ---
echo [2/5] Copying EA files to MetaTrader...
if not exist "%MT5_EXPERTS%" mkdir "%MT5_EXPERTS%"

for %%f in (
    MatlamaQuant.mq5
    MatlamaScalper.mq5
    MatlamaTickScalper.mq5
    MatlamaBridgeHFT.mq5
    matlamabridgeV3.mq5
    MatlamaORB.mq5
    MatlamaFundamentals.mq5
    MatlamaMonitor.mq5
    OrchestratorClient.mqh
) do (
    if exist "%REPO_DIR%\%%f" (
        copy /y "%REPO_DIR%\%%f" "%MT5_EXPERTS%\%%f" >nul
        echo      Copied %%f
    )
)

REM DynamicLot.mqh goes to Include folder so all EAs can find it
copy /y "%REPO_DIR%\DynamicLot.mqh" "%MT5_EXPERTS%\DynamicLot.mqh" >nul
echo      Copied DynamicLot.mqh
echo      Done.
echo.

REM --- Step 3: Compile EAs ---
echo [3/5] Compiling EAs in MetaEditor...

if not exist %METAEDITOR% (
    echo      WARNING: MetaEditor not found at %METAEDITOR%
    echo      You will need to compile manually in MetaEditor (F7 on each EA).
    echo      Skipping compilation...
    goto skip_compile
)

for %%f in (
    MatlamaQuant.mq5
    MatlamaScalper.mq5
    MatlamaTickScalper.mq5
    MatlamaBridgeHFT.mq5
    matlamabridgeV3.mq5
    MatlamaORB.mq5
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
for %%f in (%REPO_DIR%\logs\compile_*.log) do (
    findstr /i "error" "%%f" >nul 2>&1
    if not errorlevel 1 (
        echo      WARNING: Compile errors in %%~nxf
        set COMPILE_ERRORS=1
    )
)
if %COMPILE_ERRORS%==1 (
    echo      Review compile logs before proceeding.
    echo.
)

:skip_compile
echo.

REM --- Step 4: Restart Python services ---
echo [4/5] Restarting Python services...

REM Kill existing processes gracefully
tasklist /fi "windowtitle eq Orchestrator*" 2>nul | findstr python >nul
for /f "tokens=2" %%p in ('tasklist /fi "imagename eq python.exe" /fo list 2^>nul ^| findstr PID') do (
    REM We restart via swarm — it supervises the others now
)

REM Stop old swarm if running
taskkill /f /fi "windowtitle eq MatlamaSwarm" >nul 2>&1

REM Give processes time to exit
timeout /t 3 /nobreak >nul

REM Start swarm (it will auto-start orchestrator, threshold, bridge via supervisor)
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
echo  IMPORTANT: Restart MetaTrader 5 to load
echo  the newly compiled EAs. Or remove and
echo  re-attach each EA to its chart.
echo.
pause
