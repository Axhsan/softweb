@echo off
title SonyBox ISP Launcher
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sonybox.ps1"
