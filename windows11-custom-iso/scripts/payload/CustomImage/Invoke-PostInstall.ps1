<#
.SYNOPSIS
  Post-deployment step of the custom Windows 11 image. Runs as SYSTEM on the
  installed PC (Windows PowerShell 5.1), never inside the WIM.

.DESCRIPTION
  Location on the target: %WINDIR%\Setup\Scripts\CustomImage\
  Triggers:
    1. %WINDIR%\Setup\Scripts\SetupComplete.cmd  (after Setup, before first logon)
    2. Scheduled task "CustomImage-PostInstall" (at startup) - retry path; it is
       registered by this script and by the specialize-pass command in
       autounattend.xml (covers the case where SetupComplete.cmd is skipped,
       e.g. when Setup used an OEM product key).
  Steps (each has its own completion marker, so a re-run only repeats what failed):
    tweaks  - registry settings from postinstall.json (HKLM + Default user hive)
    appx    - remove explicitly listed provisioned Appx packages (dependency-checked)
    apps    - silent install of the bundled offline installers
  On full success: unregisters the task, optionally deletes the installers, exits 0.
  On failure: keeps the task for the next boot, up to maxAttempts, then disables it.
  Logs: %ProgramData%\CustomImage\Logs\   State: %ProgramData%\CustomImage\state.json
  Stores no passwords and never enables auto-logon.
#>
[CmdletBinding()]
param(
    [ValidateSet('Run', 'Register')][string]$Mode = 'Run',
    [string]$Trigger = 'manual'
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$ConfigPath = Join-Path $Root 'postinstall.json'
$StateDir = Join-Path $env:ProgramData 'CustomImage'
$LogDir = Join-Path $StateDir 'Logs'
$StatePath = Join-Path $StateDir 'state.json'
$TaskName = 'CustomImage-PostInstall'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir 'PostInstall.log'

function Write-PiLog([string]$Message, [string]$Level = 'INFO') {
    $line = '{0} [{1}] [{2}] {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Trigger, $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Register-PostInstallTask {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script = Join-Path $Root 'Invoke-PostInstall.ps1'
    $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Mode Run -Trigger Task"
    try {
        $action = New-ScheduledTaskAction -Execute $ps -Argument $arg
        $taskTrigger = New-ScheduledTaskTrigger -AtStartup
        $taskTrigger.Delay = 'PT1M'
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $taskTrigger -Principal $principal -Settings $settings -Force | Out-Null
    }
    catch {
        Write-PiLog "Register-ScheduledTask failed ($($_.Exception.Message)); falling back to schtasks.exe" 'WARN'
        $tr = "$ps $arg"
        & schtasks.exe /Create /TN $TaskName /TR $tr /SC ONSTART /DELAY 0001:00 /RU SYSTEM /RL HIGHEST /F | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "schtasks.exe /Create failed with exit code $LASTEXITCODE" }
    }
    Write-PiLog "Scheduled task '$TaskName' registered (retry at startup)."
}

function Unregister-PostInstallTask {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; Write-PiLog "Scheduled task '$TaskName' removed." }
}

function Read-State {
    if (Test-Path -LiteralPath $StatePath) {
        try { return (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json) } catch { Write-PiLog "state.json unreadable, starting fresh: $($_.Exception.Message)" 'WARN' }
    }
    return [pscustomobject]@{ attempts = 0; completed = $false; rebootRequired = $false; steps = [pscustomobject]@{}; history = @() }
}

function Save-State($State) {
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Set-StepResult($State, [string]$Step, [bool]$Ok, [string]$Detail) {
    $val = [pscustomobject]@{ ok = $Ok; detail = $Detail; time = (Get-Date).ToString('s') }
    if ($State.steps.PSObject.Properties.Name -contains $Step) { $State.steps.$Step = $val }
    else { $State.steps | Add-Member -NotePropertyName $Step -NotePropertyValue $val }
}

function Test-StepDone($State, [string]$Step) {
    return (($State.steps.PSObject.Properties.Name -contains $Step) -and [bool]$State.steps.$Step.ok)
}

# ---------------------------------------------------------------- tweaks ---
function Set-RegValue([string]$Path, [string]$Name, [string]$Type, $Value) {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType $Type -Value $Value -Force | Out-Null
}

function Invoke-Tweaks($Config) {
    $tweaks = @($Config.tweaks)
    if ($tweaks.Count -eq 0) { return $true }
    $ok = $true
    $defaultHive = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    $mountKey = 'HKU\CustomImageDefault'
    $needDefault = @($tweaks | Where-Object { $_.hive -eq 'DefaultUser' }).Count -gt 0
    $loaded = $false
    try {
        if ($needDefault) {
            & reg.exe load $mountKey $defaultHive | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "reg load of $defaultHive failed ($LASTEXITCODE)" }
            $loaded = $true
            if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) { New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS | Out-Null }
        }
        foreach ($t in $tweaks) {
            try {
                switch ($t.hive) {
                    'HKLM'        { $p = 'HKLM:\' + $t.key }
                    'DefaultUser' { $p = 'HKU:\CustomImageDefault\' + $t.key }
                    default       { throw "unknown hive '$($t.hive)'" }
                }
                Set-RegValue -Path $p -Name $t.name -Type $t.type -Value $t.value
                Write-PiLog ("tweak {0}: {1}\{2} = {3}" -f $t.id, $p, $t.name, $t.value)
            }
            catch { $ok = $false; Write-PiLog ("tweak {0} FAILED: {1}" -f $t.id, $_.Exception.Message) 'ERROR' }
        }
    }
    finally {
        if ($loaded) {
            [gc]::Collect(); [gc]::WaitForPendingFinalizers()
            Start-Sleep -Seconds 1
            & reg.exe unload $mountKey | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-PiLog "reg unload $mountKey failed ($LASTEXITCODE)" 'ERROR'; $ok = $false }
        }
    }
    return $ok
}

# ------------------------------------------------------------------ appx ---
function Get-ManifestDependencies([string]$ManifestPath) {
    $deps = @()
    if ($ManifestPath -and (Test-Path -LiteralPath $ManifestPath)) {
        try {
            [xml]$x = Get-Content -LiteralPath $ManifestPath -Raw
            $deps = @($x.SelectNodes("//*[local-name()='PackageDependency']") | ForEach-Object { $_.GetAttribute('Name') })
        } catch { }
    }
    return $deps
}

function Invoke-AppxRemoval($Config) {
    if (-not $Config.appx -or -not $Config.appx.enabled) { Write-PiLog 'Appx removal disabled.'; return $true }
    $ok = $true
    $prov = @(Get-AppxProvisionedPackage -Online)
    $protected = @()
    if ($Config.appx.PSObject.Properties.Name -contains 'neverRemove') { $protected = @($Config.appx.neverRemove) }
    foreach ($name in @($Config.appx.packages)) {
        if ($protected -contains $name) { Write-PiLog "appx $name : listed in neverRemove, skipped" 'WARN'; continue }
        $pkg = @($prov | Where-Object { $_.DisplayName -eq $name }) | Select-Object -First 1
        if (-not $pkg) { Write-PiLog "appx $name : not provisioned in this build, skipped"; continue }
        # Dependency check: never remove a package that another provisioned package declares as dependency.
        $dependents = @()
        foreach ($other in $prov) {
            if ($other.DisplayName -eq $name) { continue }
            $manifest = $null
            if ($other.InstallLocation) { $manifest = $other.InstallLocation -replace '^%SYSTEMDRIVE%', $env:SystemDrive }
            if ((Get-ManifestDependencies $manifest) -contains $name) { $dependents += $other.DisplayName }
        }
        if ($dependents.Count -gt 0) { Write-PiLog ("appx {0}: kept, required by {1}" -f $name, ($dependents -join ', ')) 'WARN'; continue }
        try {
            $cmd = Get-Command Remove-AppxProvisionedPackage
            if ($cmd.Parameters.ContainsKey('AllUsers')) {
                Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -AllUsers | Out-Null
            } else {
                Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName | Out-Null
            }
            Write-PiLog "appx $name : removed ($($pkg.PackageName))"
        }
        catch { $ok = $false; Write-PiLog "appx $name : removal FAILED: $($_.Exception.Message)" 'ERROR' }
    }
    return $ok
}

# ------------------------------------------------------------------ apps ---
function Test-AppInstalled($App) {
    $p = [Environment]::ExpandEnvironmentVariables([string]$App.detectPath)
    return (Test-Path -LiteralPath $p)
}

function Install-App($App, $State) {
    $installer = Join-Path (Join-Path $Root 'Apps') $App.file
    if (-not (Test-Path -LiteralPath $installer)) { throw "installer missing: $installer" }
    $appLog = Join-Path $LogDir ("{0}-{1}.log" -f $App.id, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    if ($App.type -eq 'msi') {
        $exe = Join-Path $env:SystemRoot 'System32\msiexec.exe'
        $arguments = "/i `"$installer`" $($App.silentArgs) /l*v `"$appLog`""
    } else {
        $exe = $installer
        $arguments = [string]$App.silentArgs
    }
    for ($try = 1; $try -le 3; $try++) {
        Write-PiLog ("{0}: running {1} {2} (try {3})" -f $App.name, $exe, $arguments, $try)
        $p = Start-Process -FilePath $exe -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
        $code = $p.ExitCode
        Write-PiLog ("{0}: exit code {1}" -f $App.name, $code)
        if ($code -eq 1618) { Write-PiLog 'another installation is in progress (1618), waiting 60 s' 'WARN'; Start-Sleep -Seconds 60; continue }
        break
    }
    switch ($code) {
        0 { }
        3010 { $State.rebootRequired = $true; Write-PiLog "$($App.name): success, reboot required (3010)" }
        1641 { $State.rebootRequired = $true; Write-PiLog "$($App.name): success, installer initiated reboot (1641)" }
        default { throw "installer exit code $code" }
    }
    if (-not (Test-AppInstalled $App)) { throw "installer returned $code but $($App.detectPath) does not exist" }
}

# ------------------------------------------------------------------ main ---
Write-PiLog "Start (mode $Mode, user $([Environment]::UserDomainName)\$([Environment]::UserName))"
if ($Mode -eq 'Register') {
    try { Register-PostInstallTask; exit 0 } catch { Write-PiLog "Register failed: $($_.Exception.Message)" 'ERROR'; exit 1 }
}

$mutex = New-Object System.Threading.Mutex($false, 'Global\CustomImagePostInstall')
$haveLock = $false
try { $haveLock = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $haveLock = $true }
if (-not $haveLock) { Write-PiLog 'Another instance is running; exiting.'; exit 0 }

function Invoke-Main {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $StateDir 'postinstall.json') -Force
    $state = Read-State
    if ($state.completed) { Write-PiLog 'Already completed earlier.'; Unregister-PostInstallTask; return 0 }

    $state.attempts = [int]$state.attempts + 1
    $max = [int]$config.maxAttempts
    Save-State $state
    if ($state.attempts -gt $max) {
        Write-PiLog "Giving up after $max attempts. See $LogFile. Run the script manually as admin to retry." 'ERROR'
        try { Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null } catch { }
        return 1
    }
    Write-PiLog "Attempt $($state.attempts) of $max"
    try { Register-PostInstallTask } catch { Write-PiLog "Could not register retry task: $($_.Exception.Message)" 'WARN' }

    if (-not (Test-StepDone $state 'tweaks')) {
        $r = $false
        try { $r = Invoke-Tweaks $config } catch { Write-PiLog "tweaks: $($_.Exception.Message)" 'ERROR' }
        Set-StepResult $state 'tweaks' $r ''
        Save-State $state
    }
    if (-not (Test-StepDone $state 'appx')) {
        $r = $false
        try { $r = Invoke-AppxRemoval $config } catch { Write-PiLog "appx: $($_.Exception.Message)" 'ERROR' }
        Set-StepResult $state 'appx' $r ''
        Save-State $state
    }
    foreach ($app in @($config.apps)) {
        $step = 'app-' + $app.id
        if (Test-StepDone $state $step) { continue }
        try {
            if (Test-AppInstalled $app) { Write-PiLog "$($app.name): already present ($($app.detectPath))" }
            else { Install-App $app $state }
            Set-StepResult $state $step $true $app.version
            Write-PiLog "$($app.name) $($app.version): OK"
        }
        catch {
            Set-StepResult $state $step $false $_.Exception.Message
            Write-PiLog "$($app.name): FAILED: $($_.Exception.Message)" 'ERROR'
        }
        Save-State $state
    }

    $failed = @($state.steps.PSObject.Properties | Where-Object { -not $_.Value.ok } | ForEach-Object { $_.Name })
    if ($failed.Count -eq 0) {
        $state.completed = $true
        Save-State $state
        Unregister-PostInstallTask
        if ($config.deleteInstallersAfterSuccess) {
            Remove-Item -LiteralPath (Join-Path $Root 'Apps') -Recurse -Force -ErrorAction SilentlyContinue
            Write-PiLog 'Bundled installers deleted.'
        }
        if ($state.rebootRequired) { Write-PiLog 'An installer requested a reboot; it will take effect on the next restart (no forced reboot).' 'WARN' }
        Write-PiLog 'All post-install steps completed.' 'OK'
        return 0
    }
    Write-PiLog ("Failed steps: {0}. Will retry at next startup." -f ($failed -join ', ')) 'ERROR'
    return 1
}

$exitCode = 1
try {
    $exitCode = [int](Invoke-Main | Select-Object -Last 1)
}
catch {
    Write-PiLog "Unhandled error: $($_.Exception.Message)" 'ERROR'
}
finally {
    if ($haveLock) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
exit $exitCode
