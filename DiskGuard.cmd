@echo off
chcp 65001 >nul
setlocal
set "PS1=%~dp0DiskGuard.ps1"

if not exist "%PS1%" (
    echo DiskGuard.ps1 not found next to this launcher.
    pause
    exit /b 1
)

where pwsh >nul 2>nul
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
)
