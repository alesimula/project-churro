@echo off
rem Project Churro: grow Android's data partition on a Churro USB stick to the end of the stick
rem (after writing an image with Etcher/Rufus). Same steps as flash-keep-data.bat, whose PowerShell
rem part this runs: pick the USB disk, pass it to WSL, check it holds Googlebook OS, confirm, then
rem tools/grow-data.sh. On a stick Android was already started on it grows its data too, or ERASEs it if asked.
setlocal
set "FKD_DIR=%~dp0"
set "FKD_ACTION=grow"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ([IO.File]::ReadAllText('%~dp0flash-keep-data.bat'))"
exit /b %errorlevel%
