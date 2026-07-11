@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

set "ROOT=%~dp0"
cd /d "%ROOT%"

echo ========================================
echo  AutoLiangDu - GitHub Sync
echo ========================================
echo.

REM ---- Check git availability ----
where git >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Git not found. Please install Git first.
    exit /b 1
)

REM ---- Stage files ----
echo [1/4] Staging files...
git add -A
echo   -- Done.

REM ---- Show status ----
echo [2/4] Current status:
git status --short
echo.

REM ---- Commit ----
echo [3/4] Creating commit...
for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /value ^| find "="') do set "dt=%%I"
set "TIMESTAMP=%dt:~0,4%-%dt:~4,2%-%dt:~6,2%_%dt:~8,2%:%dt:~10,2%:%dt:~12,2%"
git commit -m "Auto sync at %TIMESTAMP%"
if %ERRORLEVEL% neq 0 (
    echo [SKIP] Nothing to commit or commit failed.
    goto :push
)

REM ---- Push ----
:push
echo [4/4] Pushing to origin...
git push origin main
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Push failed. Check your network or GitHub credentials.
    exit /b 1
)

echo.
echo ========================================
echo  Sync complete!
echo ========================================
endlocal
