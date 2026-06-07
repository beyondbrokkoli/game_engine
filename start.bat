@echo off
REM Ensures we are running from the project root to protect Lua's package.path
cd /d "%~dp0"
bin\boot.exe
