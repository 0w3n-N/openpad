@echo off
rem OpenPad command for Windows: runs bin\openpad with the Python launcher (py), or python.
setlocal
set "SCRIPT=%~dp0openpad"
where py >nul 2>nul
if %errorlevel%==0 (
  py -3 -B "%SCRIPT%" %*
) else (
  python -B "%SCRIPT%" %*
)
exit /b %errorlevel%
