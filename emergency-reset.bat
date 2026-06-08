@echo off
setlocal EnableExtensions
title WG Kill Switch - Emergency Reset
echo.
echo  WG Kill Switch - EMERGENCY NETWORK RESET
echo  ========================================
echo  This will remove KS-* firewall rules, reset firewall/IP stack,
echo  and re-enable all physical network adapters.
echo.

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "PS1=%~dp0scripts\emergency-reset.ps1"
if not exist "%PS1%" set "PS1=%~dp0emergency-reset.ps1"
if not exist "%PS1%" set "PS1=C:\WireGuard\emergency-reset.ps1"

if not exist "%PS1%" (
    echo [ERR] emergency-reset.ps1 not found.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
exit /b %errorlevel%