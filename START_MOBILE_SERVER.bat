@echo off
title SonyBox ISP - Mobile Phone Server
cls
echo ==========================================================
echo        SonyBox ISP - Mobile Phone Server Launcher
echo ==========================================================
echo.
echo Server shuru ho raha hai...
echo Apne Mobile Phone par yeh link open karein:
echo.
powershell -NoExit -ExecutionPolicy Bypass -File "%~dp0server.ps1"
pause
