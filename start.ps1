# CloudPhone Startup Script
Write-Host "==================================" -ForegroundColor Cyan
Write-Host "Welcome to CloudPhone Quick Start" -ForegroundColor Cyan
Write-Host "Version: v0.0.1" -ForegroundColor Cyan
Write-Host "==================================" -ForegroundColor Cyan
Write-Host ""

# Set environment variables - using safer path handling
$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AdbPath = Join-Path -Path $RootDir -ChildPath "adb"

# Set environment variables
$env:Path = "$AdbPath;" + $env:Path

# Get all service PIDs for later cleanup
$global:serviceProcesses = @()

# Terminate any existing services
function Stop-ExistingServices {
    Write-Host "Checking and stopping existing services..." -ForegroundColor Yellow

    # Stop Nginx if running
    Write-Host "Stopping Nginx service..." -ForegroundColor Yellow
    try {
        Get-Process -Name "nginx" -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host "Terminating Nginx process (PID: $($_.Id))" -ForegroundColor Yellow
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
        # Attempt graceful shutdown via executable as well, in case of orphaned master process
        # This is a best-effort and might not always work if Nginx wasn't started in a standard way
        $nginxDirForStop = Join-Path -Path $RootDir -ChildPath "nginx"
        $nginxExeForStop = Join-Path -Path $nginxDirForStop -ChildPath "nginx.exe"
        if (Test-Path $nginxExeForStop) {
            & $nginxExeForStop -p "$nginxDirForStop" -s stop 2>$null # Suppress errors, as it might fail if no master is running
            Start-Sleep -Seconds 1 # Give it a moment
        }
    } catch {
        Write-Host "Error stopping Nginx service: $_" -ForegroundColor Red
    }

    # Terminate processes that might be running on specific ports
    # Port 8000 is removed as scrcpy service and its Nginx proxy are removed
    # Nginx now primarily serves on 443 (HTTPS), 8848 redirects to 443
    $portsToCheck = @(8800, 443, 8848) # Backend 8800, Nginx HTTPS 443, Nginx HTTP redirector 8848

    foreach ($port in $portsToCheck) {
        $processInfo = netstat -ano | findstr ":$port " | findstr "LISTENING"
        if ($processInfo) {
            $processPid = ($processInfo -split '\s+')[-1]
            if ($processPid -match '^\d+$') {
                try {
                    $process = Get-Process -Id $processPid -ErrorAction SilentlyContinue
                    if ($process) {
                        Write-Host "Terminating process on port $port (PID: $processPid)" -ForegroundColor Yellow
                        Stop-Process -Id $processPid -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 1
                    }
                } catch {
                    Write-Host "Unable to terminate process on port $port (PID: $processPid): $_" -ForegroundColor Red
                }
            }
        }
    }
}

# Terminate all started services
function Stop-AllServices {
    Write-Host "Terminating all services..." -ForegroundColor Yellow

    # Call Stop-ExistingServices to handle port and Nginx cleanup
    Stop-ExistingServices

    # Clean up processes in the $global:serviceProcesses list (mainly backend services)
    # Stop-ExistingServices might have already stopped them by port, but this ensures any other tracked processes are handled.
    foreach ($process in $global:serviceProcesses) {
        if ($process -and $process.Id) {
            try {
                $procToCheck = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
                if ($procToCheck -and (-not $procToCheck.HasExited)) {
                    Write-Host "Terminating process started by script (PID: $($process.Id))" -ForegroundColor Yellow
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                }
            } catch {
                # Process might have already been stopped or doesn't exist, ignore error
            }
        }
    }
    $global:serviceProcesses = @() # Clear the list

    # Shut down ADB server
    Write-Host "Shutting down ADB server..." -ForegroundColor Yellow
    try {
        $adbExe = Join-Path -Path $AdbPath -ChildPath "adb.exe"
        & $adbExe kill-server
        Write-Host "ADB server shutdown signal sent." -ForegroundColor Green
    } catch {
        Write-Host "Unable to terminate ADB service: $_" -ForegroundColor Red
    }

    Write-Host "All service cleanup attempts completed." -ForegroundColor Green
}

# Register script exit event handler
$OnExit = {
    Stop-AllServices
}
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action $OnExit | Out-Null

# First terminate any existing services
Stop-ExistingServices

Write-Host "Starting services..." -ForegroundColor Yellow

# Check if ADB service is working properly
Write-Host "Checking ADB service..." -ForegroundColor Yellow
try {
    $adbExe = Join-Path -Path $AdbPath -ChildPath "adb.exe"
    & $adbExe start-server
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ADB service startup failed, please check USB connection and driver installation" -ForegroundColor Red
        Read-Host "Press any key to exit"
        exit 1
    }
    Write-Host "ADB service running normally" -ForegroundColor Green
}
catch {
    Write-Host "ADB service startup error: $_" -ForegroundColor Red
    Read-Host "Press any key to exit"
    exit 1
}

# Create logs directory
$logsDir = Join-Path -Path $RootDir -ChildPath "logs"
if (-not (Test-Path $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir | Out-Null
}

# Function to check if a service has started
function Test-ServiceStarted {
    param (
        [string]$ServiceName,
        [int]$Port,
        [int]$MaxRetries = 30,
        [int]$RetryInterval = 1000 # milliseconds
    )

    Write-Host "Checking $ServiceName service startup status (Port: $Port)..." -ForegroundColor Yellow

    for ($i = 0; $i -lt $MaxRetries; $i++) {
        try {
            $connection = Test-NetConnection -ComputerName "127.0.0.1" -Port $Port -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            if ($connection -and $connection.TcpTestSucceeded) {
                Write-Host "$ServiceName service started successfully" -ForegroundColor Green
                return $true
            }
        } catch {
            # Silently ignore errors, we'll retry
        }

        Write-Host "Waiting for $ServiceName service to start... (Attempt $($i+1)/$MaxRetries)" -ForegroundColor Yellow
        Start-Sleep -Milliseconds $RetryInterval
    }

    Write-Host "$ServiceName service startup timed out (Port: $Port)" -ForegroundColor Red
    return $false
}

# Start backend service
Write-Host "Starting backend service..." -ForegroundColor Yellow
$backendLogFile = Join-Path -Path $logsDir -ChildPath "CloudPhone.log"
$backendProcess = Start-Process -FilePath "cmd.exe" -ArgumentList "/c cd /d `"$RootDir`" && CloudPhone.exe > `"$backendLogFile`" 2>&1" -WindowStyle Hidden -PassThru
$global:serviceProcesses += $backendProcess

# Wait for backend to start
if (-not (Test-ServiceStarted -ServiceName "Backend" -Port 8800)) {
    Write-Host "Backend service startup failed, please check log file $backendLogFile" -ForegroundColor Red
    Stop-AllServices
    Read-Host "Press any key to exit"
    exit 1
}

# Start Nginx frontend proxy service
Write-Host "Starting Nginx frontend proxy service..." -ForegroundColor Yellow
$nginxDir = Join-Path -Path $RootDir -ChildPath "nginx"
$nginxExe = Join-Path -Path $nginxDir -ChildPath "nginx.exe"
$nginxConf = Join-Path -Path $nginxDir -ChildPath "nginx.conf"
$nginxStartupOutLogFile = Join-Path -Path $logsDir -ChildPath "nginx_startup_out.log"
$nginxStartupErrLogFile = Join-Path -Path $logsDir -ChildPath "nginx_startup_err.log"

if (-not (Test-Path $nginxExe)) {
    Write-Host "Nginx executable not found at $nginxExe. Please ensure Nginx for Windows is placed in $nginxDir." -ForegroundColor Red
    Stop-AllServices
    Read-Host "Press any key to exit"
    exit 1
}
if (-not (Test-Path $nginxConf)) {
    Write-Host "Nginx configuration not found at $nginxConf." -ForegroundColor Red
    Stop-AllServices
    Read-Host "Press any key to exit"
    exit 1
}

try {
    Write-Host "Nginx working directory: $nginxDir" -ForegroundColor Yellow
    Start-Process -FilePath $nginxExe -ArgumentList "-p `"$nginxDir`" -c `"$nginxConf`"" -WorkingDirectory $nginxDir -WindowStyle Hidden -RedirectStandardOutput "$nginxStartupOutLogFile" -RedirectStandardError "$nginxStartupErrLogFile"
    Write-Host "Nginx frontend proxy service startup command sent..." -ForegroundColor Yellow
} catch {
    Write-Host "Nginx frontend proxy service startup failed: $_" -ForegroundColor Red
    Write-Host "Check $nginxStartupOutLogFile and $nginxStartupErrLogFile for more information."
    Stop-AllServices
    Read-Host "Press any key to exit"
    exit 1
}

if (-not (Test-ServiceStarted -ServiceName "Nginx Frontend Proxy" -Port 443)) {
    Write-Host "Nginx frontend proxy service startup failed or not listening on port 443." -ForegroundColor Red
    Write-Host "Please check Nginx logs (usually in $nginxDir/logs, as well as $nginxStartupOutLogFile and $nginxStartupErrLogFile)." -ForegroundColor Red
    Stop-AllServices
    Read-Host "Press any key to exit"
    exit 1
}

# Launch browser pointing to Nginx HTTPS
Start-Process "https://127.0.0.1"

Write-Host ""
Write-Host "CloudPhone has started successfully!" -ForegroundColor Green
Write-Host "Nginx frontend proxy service address: https://127.0.0.1 (HTTP on port 8848 redirects to HTTPS)" -ForegroundColor Green
Write-Host "Backend service API address: http://127.0.0.1:8800 (proxied through Nginx /api/)" -ForegroundColor Green
Write-Host ""
Write-Host "Backend log: $backendLogFile"
Write-Host "Nginx startup stdout log: $nginxStartupOutLogFile"
Write-Host "Nginx startup stderr log: $nginxStartupErrLogFile"
Write-Host "Nginx main logs usually located at: $nginxDir\logs"
Write-Host "Closing this window will attempt to stop all services." -ForegroundColor Yellow

try {
    Read-Host "Press any key to close and stop all services"
} finally {
    Stop-AllServices
    Write-Host "All services have been stopped" -ForegroundColor Green
    Start-Sleep -Seconds 1
}