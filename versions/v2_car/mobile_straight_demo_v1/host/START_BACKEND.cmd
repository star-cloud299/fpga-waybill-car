@echo off
setlocal
cd /d "%~dp0"
set "WB_PYTHON=%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
if exist "%WB_PYTHON%" (
    set "TCL_LIBRARY=%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\tcl\tcl8.6"
    set "TK_LIBRARY=%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\tcl\tk8.6"
    "%WB_PYTHON%" "%~dp0app.py" --autostart
) else (
    py -3.12 "%~dp0app.py" --autostart
)
if errorlevel 1 pause
