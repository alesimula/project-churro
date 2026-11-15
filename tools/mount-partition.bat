@echo off
rem Project Churro: open one partition of a Churro USB stick in Explorer (boot files, logs, system,
rem vendor, ... picked from a short list). Same steps as flash-keep-data.bat, whose PowerShell part
rem this runs: pick the USB disk, pass it to WSL, check it holds Googlebook OS (buildinfo.sh), then
rem mount the partition in WSL (Android's partitions read-only) and open it in Explorer. Press Enter
rem in this window when done: it is unmounted and the stick goes back to Windows.
setlocal
set "FKD_DIR=%~dp0"
set "FKD_ACTION=mount"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ([IO.File]::ReadAllText('%~dp0flash-keep-data.bat'))"
exit /b %errorlevel%
