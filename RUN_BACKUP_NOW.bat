@echo off
title SonyBox ISP - Run Instant Backup
cd /d "%~dp0"
echo ==========================================================
echo         SonyBox ISP - Instant Backup Runner
echo ==========================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup_job.ps1"
echo.
echo Backup mukammal ho gaya hai!
pause
