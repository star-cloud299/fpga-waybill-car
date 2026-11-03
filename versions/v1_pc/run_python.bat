@echo off
setlocal
cd /d "%~dp0"
if exist "%~dp0.venv\Scripts\python.exe" (
  "%~dp0.venv\Scripts\python.exe" %*
  exit /b
)
py -3 -c "import sys" >nul 2>&1
if not errorlevel 1 (
  py -3 %*
  exit /b
)
python %*
exit /b
