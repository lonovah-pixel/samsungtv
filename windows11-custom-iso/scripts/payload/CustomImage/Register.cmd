@echo off
rem CustomImage: called from autounattend.xml (specialize pass, SYSTEM).
rem Only registers the startup retry task; the work itself runs later.
if not exist "%ProgramData%\CustomImage\Logs" mkdir "%ProgramData%\CustomImage\Logs"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%SystemRoot%\Setup\Scripts\CustomImage\Invoke-PostInstall.ps1" -Mode Register -Trigger Specialize >> "%ProgramData%\CustomImage\Logs\Specialize.log" 2>&1
exit /b 0
