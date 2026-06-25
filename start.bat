@echo off
title Weaver Engine - Local Node

:: Force the working directory to the folder where this batch file lives
:: (This makes it immune to breaking if you launch it via a desktop shortcut)
cd /D "%~dp0"

echo ===========================================
echo  WEAVER V2 - WAN HARNESS
echo ===========================================
echo.

:: Launch the bootloader
bin\boot.exe

:: If the engine crashes or exits, pause so the window doesn't instantly vanish
echo.
echo [SYSTEM] Engine process terminated.
pause
