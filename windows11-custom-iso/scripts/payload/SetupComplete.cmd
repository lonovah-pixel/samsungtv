@echo off
rem CustomImage: runs once after Windows Setup, as SYSTEM, before the first logon.
rem Installs the bundled applications and applies the image settings.
rem Log: %ProgramData%\CustomImage\Logs\PostInstall.log
if not exist "%ProgramData%\CustomImage\Logs" mkdir "%ProgramData%\CustomImage\Logs"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%SystemRoot%\Setup\Scripts\CustomImage\Invoke-PostInstall.ps1" -Mode Run -Trigger SetupComplete >> "%ProgramData%\CustomImage\Logs\SetupComplete.log" 2>&1
exit /b 0
