<#
.SYNOPSIS
  Logic test of payload/CustomImage/Invoke-PostInstall.ps1 with STUBBED Windows cmdlets.
.DESCRIPTION
  Runs on Linux/pwsh. Scheduled-task cmdlets and Start-Process are replaced by stubs,
  installers are shell scripts. Verifies: failure -> retry state, success -> completion,
  installer cleanup, idempotent re-run, maxAttempts limit.
  It does NOT exercise real msiexec/NSIS installers, registry or Appx on Windows.
#>
$ErrorActionPreference = 'Stop'
$Project = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$T = Join-Path $Project 'work-synthetic/postinstall-logic'
if (Test-Path $T) { Remove-Item $T -Recurse -Force }
$payload = Join-Path $T 'Scripts/CustomImage'
New-Item -ItemType Directory -Path (Join-Path $payload 'Apps') -Force | Out-Null
Copy-Item (Join-Path $Project 'scripts/payload/CustomImage/Invoke-PostInstall.ps1') $payload
$pd = Join-Path $T 'ProgramData'; $pf = Join-Path $T 'ProgramFiles'
New-Item -ItemType Directory -Path $pd, $pf -Force | Out-Null
$ctl = Join-Path $T 'exitcode.txt'
Set-Content $ctl '1'
# Installer stub: exits with the code from exitcode.txt; on 0 creates the detect file.
$inst = Join-Path $payload 'Apps/demo-1.0.exe'
Set-Content $inst "#!/bin/sh`nc=`$(cat '$ctl')`nif [ `"`$c`" = 0 ]; then mkdir -p '$pf/Demo' && touch '$pf/Demo/demo.exe'; fi`nexit `$c`n"
& chmod +x $inst
$cfg = [ordered]@{ maxAttempts = 3; deleteInstallersAfterSuccess = $true
    apps = @([ordered]@{ id = 'demo'; name = 'Demo'; version = '1.0'; file = 'demo-1.0.exe'; type = 'exe'; silentArgs = '/S'; detectPath = '%CI_PF%/Demo/demo.exe' })
    appx = [ordered]@{ enabled = $false; packages = @() }; tweaks = @() }
$cfg | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $payload 'postinstall.json')

$stubs = @'
$env:ProgramData = '__PD__'; $env:CI_PF = '__PF__'; $env:SystemRoot = '__PD__'
$global:TaskRegistered = $false
function global:New-ScheduledTaskAction { [pscustomobject]@{} }
function global:New-ScheduledTaskTrigger { [pscustomobject]@{ Delay = $null } }
function global:New-ScheduledTaskPrincipal { [pscustomobject]@{} }
function global:New-ScheduledTaskSettingsSet { [pscustomobject]@{} }
function global:Register-ScheduledTask { Set-Content '__PD__/task.flag' 'registered' }
function global:Get-ScheduledTask { param($TaskName) if (Test-Path '__PD__/task.flag') { [pscustomobject]@{ TaskName = $TaskName } } }
function global:Unregister-ScheduledTask { Remove-Item '__PD__/task.flag' -Force }
function global:Disable-ScheduledTask { Set-Content '__PD__/task.flag' 'disabled' }
function global:Start-Process { param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru, $WindowStyle)
    & /bin/sh $FilePath $ArgumentList; [pscustomobject]@{ ExitCode = $LASTEXITCODE } }
& '__SCRIPT__' -Mode Run -Trigger Test
exit $LASTEXITCODE
'@
$stubs = $stubs.Replace('__PD__', $pd).Replace('__PF__', $pf).Replace('__SCRIPT__', (Join-Path $payload 'Invoke-PostInstall.ps1'))
$runner = Join-Path $T 'run.ps1'; Set-Content $runner $stubs
$fails = 0
function Assert([bool]$c, [string]$t) { if ($c) { Write-Host "PASS  $t" -ForegroundColor Green } else { Write-Host "FAIL  $t" -ForegroundColor Red; $script:fails++ } }
function Invoke-Run { & pwsh -NoProfile -File $runner *> $null; return $LASTEXITCODE }
$state = Join-Path $pd 'CustomImage/state.json'

$c = Invoke-Run
Assert ($c -eq 1) "run 1 (installer fails): exit 1 (got $c)"
$s = Get-Content $state -Raw | ConvertFrom-Json
Assert ($s.attempts -eq 1 -and -not $s.completed) 'run 1: attempts=1, not completed'
Assert ((Get-Content (Join-Path $pd 'task.flag')) -eq 'registered') 'run 1: retry task registered'
Assert (Test-Path $inst) 'run 1: installers kept for retry'

Set-Content $ctl '0'
$c = Invoke-Run
Assert ($c -eq 0) "run 2 (installer ok): exit 0 (got $c)"
$s = Get-Content $state -Raw | ConvertFrom-Json
Assert ($s.completed -and $s.steps.'app-demo'.ok) 'run 2: completed, app step ok'
Assert (-not (Test-Path (Join-Path $pd 'task.flag'))) 'run 2: retry task removed'
Assert (-not (Test-Path (Join-Path $payload 'Apps'))) 'run 2: bundled installers deleted'

$c = Invoke-Run
Assert ($c -eq 0) 'run 3 (already completed): exit 0'
Assert ((Get-Content (Join-Path $pd 'CustomImage/Logs/PostInstall.log') -Raw) -match 'Already completed') 'run 3: reports already completed'

# maxAttempts: reset state, keep installer failing
Remove-Item (Join-Path $pd 'CustomImage') -Recurse -Force
New-Item -ItemType Directory -Path (Join-Path $payload 'Apps') -Force | Out-Null
Set-Content $inst "#!/bin/sh`nexit 1603`n"
Remove-Item -Recurse -Force (Join-Path $pf 'Demo')
1..4 | ForEach-Object { $null = Invoke-Run }
$s = Get-Content $state -Raw | ConvertFrom-Json
Assert ($s.attempts -eq 4) "attempt counter reaches 4 (got $($s.attempts))"
Assert ((Get-Content (Join-Path $pd 'task.flag')) -eq 'disabled') 'task disabled after maxAttempts exceeded'
Assert ((Get-Content (Join-Path $pd 'CustomImage/Logs/PostInstall.log') -Raw) -match 'FAILED: installer exit code \d+') 'non-zero installer exit code logged as failure'
Write-Host ("Post-install logic test finished: {0} failure(s)" -f $fails)
exit $fails
