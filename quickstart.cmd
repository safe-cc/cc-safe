@echo off
setlocal DisableDelayedExpansion
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0quickstart.ps1" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    echo [cc-safe] 退出码: %RC%
    setlocal EnableDelayedExpansion
    if /i not "!CMDCMDLINE:/c=!"=="!CMDCMDLINE!" pause
    endlocal
)
exit /b %RC%
