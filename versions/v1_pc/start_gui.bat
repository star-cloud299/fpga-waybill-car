@echo off
cd /d "%~dp0"
call run_python.bat run.py gui
if errorlevel 1 pause
