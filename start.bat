@echo off
echo CloudPhone Quick Start
echo ==========================

:: Check if PowerShell exists
where powershell >nul 2>nul
if %errorlevel% neq 0 (
    echo Error: PowerShell not found. Please ensure PowerShell is installed on your Windows system.
    pause
    exit /b 1
)

:: Check if start.ps1 file exists
if not exist "%~dp0start.ps1" (
    echo Error: start.ps1 file not found. Please ensure the file exists.
    pause
    exit /b 1
)

:: Execute PowerShell script directly
echo Starting CloudPhone...
echo.

powershell -ExecutionPolicy Bypass -File "%~dp0start.ps1"

:: Display execution result
echo.
echo CloudPhone has been closed.
pause