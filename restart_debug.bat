@echo off
rem Starts (or restarts) analyze_this on Windows in debug mode, for investigating UI errors
rem (e.g. the accessibility_bridge "Failed to update ui::AXTree" messages).
rem In the running session: press "w" to dump the widget tree, "S" for the semantics tree
rem (traversal order), "U" for inverse hit test, "r" to hot reload, "R" to hot restart.
set "FLUTTER=%~dp0..\flutter-sdk\bin\flutter.bat"
taskkill /F /IM analyze_this.exe >nul 2>&1
cd /d "%~dp0"
rem Output is shown live and also saved to flutter_debug.log (overwritten each run).
powershell -NoProfile -Command "& '%FLUTTER%' run -d windows --debug --track-widget-creation --verbose 2>&1 | Tee-Object -FilePath '%~dp0flutter_debug.log'"
