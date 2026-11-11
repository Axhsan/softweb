# SonyBox ISP One-Command Launcher
$ErrorActionPreference = "SilentlyContinue"
$workDir = "i:\Ai\softweb"
Set-Location $workDir

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "         SonyBox ISP - Web Portal & Recovery App          " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan

# Check if server is already running on port 8080
$portOpen = $false
try {
    $tcp = New-Object System.Net.Sockets.TcpClient("127.0.0.1", 8080)
    $tcp.Close()
    $portOpen = $true
} catch {}

if (-not $portOpen) {
    Write-Host "Server shuru kiya ja raha hai..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$workDir\server.ps1`"" -WindowStyle Normal
    Start-Sleep -Seconds 2
} else {
    Write-Host "Server pehle se port 8080 par active hai!" -ForegroundColor Green
}

# Launch browser
Start-Process "http://localhost:8080"

Write-Host ""
Write-Host " [OK] SonyBox Portal Browser Me Open Ho Gaya Hai!" -ForegroundColor Green
Write-Host "  -> PC URL        : http://localhost:8080" -ForegroundColor Cyan
Write-Host "  -> Phone URL     : http://192.168.0.15:8080" -ForegroundColor Yellow
Write-Host "  -> Workspace Dir : $workDir" -ForegroundColor Gray
Write-Host "==========================================================" -ForegroundColor Cyan
