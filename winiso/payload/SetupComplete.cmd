@echo off
rem WinIso: runs as SYSTEM at the end of Windows Setup, before the first logon.
rem Installs only machine-wide offline installers (stage=setupcomplete). Never reboots.
rem Note: Windows skips SetupComplete.cmd when an OEM product key is used (except Enterprise);
rem Deploy-Apps.ps1 -Stage FirstLogon then performs the same steps (idempotent).
if not exist "%ProgramData%\WinIsoDeploy\logs" mkdir "%ProgramData%\WinIsoDeploy\logs"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%ProgramData%\WinIsoDeploy\Deploy-Apps.ps1" -Stage SetupComplete >> "%ProgramData%\WinIsoDeploy\logs\SetupComplete.cmd.log" 2>&1
exit /b 0
