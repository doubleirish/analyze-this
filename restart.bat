@echo off
rem Starts (or restarts) analyze_this on Windows.
set "FLUTTER=%~dp0..\flutter-sdk\bin\flutter.bat"
taskkill /F /IM analyze_this.exe >nul 2>&1
cd /d "%~dp0"
rem Output is shown live and also saved to flutter_run.log (overwritten each run).
powershell -NoProfile -Command "& '%FLUTTER%' run -d windows 2>&1 | Tee-Object -FilePath '%~dp0flutter_run.log'"
