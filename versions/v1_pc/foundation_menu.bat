@echo off
cd /d "%~dp0"
:menu
cls
echo 1 - Foundation GUI (modes 1-4, fixed example)
echo 2 - Extended GUI (mode 5 + photo auto ROI)
echo 3 - Environment and archived evidence check
echo 4 - Audit formal 150-frame evidence
echo 5 - Audit uploaded photo evidence
echo 6 - RTL regression (Icarus required)
echo 7 - Window architecture simulation comparison
echo 8 - Build board bitstream (Vivado required; no programming)
echo 9 - Build OOC resource comparison (Vivado required)
echo 0 - Exit
choice /c 1234567890 /n /m "Select: "
if errorlevel 10 exit /b 0
if errorlevel 9 goto compare
if errorlevel 8 goto build
if errorlevel 7 goto bench
if errorlevel 6 goto rtl
if errorlevel 5 goto photo
if errorlevel 4 goto formal
if errorlevel 3 goto check
if errorlevel 2 goto extended
call run_python.bat tools/foundation.py gui-basic
goto done
:extended
call run_python.bat run.py gui
goto done
:check
call run_python.bat tools/foundation.py check
goto done
:formal
call run_python.bat tools/foundation.py audit-runs --source evidence/formal_150
goto done
:photo
call run_python.bat tools/foundation.py audit-runs --source evidence/photo_runs.zip
goto done
:rtl
call run_python.bat run.py rtl-test
goto done
:bench
call run_python.bat tools/foundation.py benchmark
goto done
:build
call vivado -mode batch -source tools/build_current.tcl
goto done
:compare
call vivado -mode batch -source benchmark/compare.tcl
:done
if errorlevel 1 echo ACTION_FAILED - Read the error above.
pause
goto menu
