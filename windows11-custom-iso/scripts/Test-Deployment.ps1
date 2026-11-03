<#
.SYNOPSIS
  Post-installation acceptance check. Run INSIDE the freshly installed test VM/PC
  from an elevated Windows PowerShell after the first logon and one reboot.
.DESCRIPTION
  Checks: edition/build, post-install completion, bundled apps installed and
  launchable, desktop (explorer) running, Defender, Firewall, SmartScreen, UAC,
  Windows Update service and search, Microsoft Store + App Installer, WinRE,
  Secure Boot, TPM, .NET, applied settings, setup logs. Writes a Markdown report to
  %ProgramData%\CustomImage\TestReport.md. Read-only except for briefly starting apps.
#>
[CmdletBinding()]
param([switch]$SkipWindowsUpdateSearch, [switch]$SkipLaunch)
$ErrorActionPreference = 'Continue'
$results = New-Object System.Collections.ArrayList
function Add-Result([string]$Area, [string]$Check, [string]$Status, [string]$Detail) {
    [void]$results.Add([pscustomobject]@{ Area = $Area; Check = $Check; Status = $Status; Detail = $Detail })
}
function Try-Check([string]$Area, [string]$Check, [scriptblock]$Body) {
    try { & $Body } catch { Add-Result $Area $Check 'ERROR' $_.Exception.Message }
}

$ciDir = Join-Path $env:ProgramData 'CustomImage'
$cfgPath = Join-Path $ciDir 'postinstall.json'
$cfg = $null
if (Test-Path $cfgPath) { $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json }

Try-Check 'OS' 'Edition/build' {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $ok = ($cv.EditionID -eq 'Professional')
    Add-Result 'OS' 'Edition/build' ($(if ($ok) { 'PASS' } else { 'FAIL' })) ("{0} {1} build {2}.{3} ({4})" -f $cv.ProductName, $cv.EditionID, $cv.CurrentBuild, $cv.UBR, $cv.DisplayVersion)
}
Try-Check 'OS' 'UI language' {
    $l = (Get-WinSystemLocale).Name; $ui = (Get-Culture).Name
    Add-Result 'OS' 'UI language' ($(if ((Get-UICulture).Name -eq 'ru-RU') { 'PASS' } else { 'WARN' })) "UI $((Get-UICulture).Name), system locale $l, culture $ui"
}
Try-Check 'Setup' 'Post-install completed' {
    $st = Get-Content (Join-Path $ciDir 'state.json') -Raw | ConvertFrom-Json
    Add-Result 'Setup' 'Post-install completed' ($(if ($st.completed) { 'PASS' } else { 'FAIL' })) ("attempts={0}, rebootRequired={1}" -f $st.attempts, $st.rebootRequired)
    $task = Get-ScheduledTask -TaskName 'CustomImage-PostInstall' -ErrorAction SilentlyContinue
    Add-Result 'Setup' 'Retry task removed' ($(if (-not $task) { 'PASS' } else { 'FAIL' })) ($(if ($task) { "state $($task.State)" } else { 'absent' }))
    $log = Join-Path $ciDir 'Logs\PostInstall.log'
    $errs = @(Select-String -Path $log -Pattern '\[ERROR\]' -ErrorAction SilentlyContinue)
    Add-Result 'Setup' 'PostInstall.log errors' ($(if ($errs.Count -eq 0) { 'PASS' } else { 'WARN' })) ("{0} error line(s); last: {1}" -f $errs.Count, ($errs | Select-Object -Last 1).Line)
}
Try-Check 'Setup' 'Windows Setup logs' {
    foreach ($f in @("$env:windir\Panther\setuperr.log", "$env:windir\Panther\UnattendGC\setuperr.log")) {
        if (Test-Path $f) {
            $n = @(Get-Content $f | Where-Object { $_ -match '\bError\b' }).Count
            Add-Result 'Setup' (Split-Path $f -Leaf) ($(if ($n -eq 0) { 'PASS' } else { 'REVIEW' })) "$n line(s) containing 'Error' in $f (setuperr.log often has benign entries - review)"
        }
    }
}
if ($cfg) {
    foreach ($a in $cfg.apps) {
        Try-Check 'Apps' $a.name {
            $p = [Environment]::ExpandEnvironmentVariables($a.detectPath)
            if (-not (Test-Path $p)) { Add-Result 'Apps' "$($a.name) installed" 'FAIL' "$p missing"; return }
            $v = (Get-Item $p).VersionInfo.ProductVersion
            Add-Result 'Apps' "$($a.name) installed" 'PASS' "$p (file version $v, bundled $($a.version))"
            if ($SkipLaunch) { return }
            if ($a.id -eq '7zip') {
                $o = & (Join-Path (Split-Path $p) '7z.exe') i 2>&1
                Add-Result 'Apps' "$($a.name) runs" ($(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' })) "7z.exe i exit $LASTEXITCODE"
            } else {
                $proc = Start-Process -FilePath $p -PassThru
                Start-Sleep -Seconds 8
                $alive = -not $proc.HasExited
                $okExit = ($proc.HasExited -and $proc.ExitCode -eq 0)
                Add-Result 'Apps' "$($a.name) runs" ($(if ($alive -or $okExit) { 'PASS' } else { 'FAIL' })) ($(if ($alive) { 'process running after 8 s' } else { "exited with $($proc.ExitCode)" }))
                Get-Process -Id $proc.Id -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            }
        }
    }
} else { Add-Result 'Apps' 'postinstall.json' 'FAIL' "$cfgPath not found" }

Try-Check 'Desktop' 'Explorer running' {
    $e = @(Get-Process explorer -ErrorAction SilentlyContinue)
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    Add-Result 'Desktop' 'Explorer running' ($(if ($e.Count -gt 0) { 'PASS' } else { 'FAIL' })) "last boot $boot"
}
Try-Check 'Security' 'Defender' {
    $m = Get-MpComputerStatus
    $ok = $m.AMServiceEnabled -and $m.AntivirusEnabled -and $m.RealTimeProtectionEnabled
    Add-Result 'Security' 'Defender' ($(if ($ok) { 'PASS' } else { 'FAIL' })) ("AMService={0} AV={1} RTP={2} signatures {3}" -f $m.AMServiceEnabled, $m.AntivirusEnabled, $m.RealTimeProtectionEnabled, $m.AntivirusSignatureVersion)
}
Try-Check 'Security' 'Firewall' {
    $p = Get-NetFirewallProfile
    $off = @($p | Where-Object { -not $_.Enabled })
    Add-Result 'Security' 'Firewall' ($(if ($off.Count -eq 0) { 'PASS' } else { 'FAIL' })) (($p | ForEach-Object { "$($_.Name)=$($_.Enabled)" }) -join ' ')
}
Try-Check 'Security' 'UAC' {
    $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System').EnableLUA
    Add-Result 'Security' 'UAC (EnableLUA)' ($(if ($v -eq 1) { 'PASS' } else { 'FAIL' })) "EnableLUA=$v"
}
Try-Check 'Security' 'SmartScreen' {
    $pol = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name EnableSmartScreen -ErrorAction SilentlyContinue
    $exp = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -Name SmartScreenEnabled -ErrorAction SilentlyContinue
    $disabled = ($pol -and $pol.EnableSmartScreen -eq 0) -or ($exp -and $exp.SmartScreenEnabled -eq 'Off')
    Add-Result 'Security' 'SmartScreen not disabled' ($(if (-not $disabled) { 'PASS' } else { 'FAIL' })) ("policy={0} explorer={1}" -f $(if ($pol) { $pol.EnableSmartScreen } else { 'unset' }), $(if ($exp) { $exp.SmartScreenEnabled } else { 'default' }))
}
Try-Check 'Security' 'Secure Boot / TPM' {
    $sb = Confirm-SecureBootUEFI
    Add-Result 'Security' 'Secure Boot' ($(if ($sb) { 'PASS' } else { 'FAIL' })) "Confirm-SecureBootUEFI=$sb"
    $t = Get-Tpm
    Add-Result 'Security' 'TPM' ($(if ($t.TpmPresent -and $t.TpmReady) { 'PASS' } else { 'FAIL' })) "present=$($t.TpmPresent) ready=$($t.TpmReady)"
}
Try-Check 'Update' 'Windows Update' {
    foreach ($s in @('wuauserv', 'UsoSvc', 'BITS')) {
        $svc = Get-Service $s; $start = (Get-CimInstance Win32_Service -Filter "Name='$s'").StartMode
        Add-Result 'Update' "Service $s" ($(if ($start -ne 'Disabled') { 'PASS' } else { 'FAIL' })) "status $($svc.Status), start $start"
    }
    if (-not $SkipWindowsUpdateSearch) {
        $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $r = $searcher.Search('IsInstalled=0 and IsHidden=0')
        Add-Result 'Update' 'Update search (needs network)' 'PASS' "ResultCode=$($r.ResultCode), $($r.Updates.Count) update(s) available"
    }
}
Try-Check 'Store' 'Store/App Installer' {
    foreach ($n in @('Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller')) {
        $p = Get-AppxPackage -Name $n
        Add-Result 'Store' $n ($(if ($p) { 'PASS' } else { 'FAIL' })) ($(if ($p) { $p.Version } else { 'missing' }))
    }
    $wg = Get-Command winget.exe -ErrorAction SilentlyContinue
    Add-Result 'Store' 'winget' ($(if ($wg) { 'PASS' } else { 'WARN' })) ($(if ($wg) { (& winget.exe --version) } else { 'not yet registered for this user (App Installer registers on first logon/Store update)' }))
}
Try-Check 'Recovery' 'WinRE' {
    $o = (& reagentc.exe /info) -join ' '
    $en = $o -match 'Enabled'
    Add-Result 'Recovery' 'WinRE enabled' ($(if ($en) { 'PASS' } else { 'FAIL' })) (($o -replace '\s+', ' ').Substring(0, [Math]::Min(160, $o.Length)))
}
Try-Check 'Runtime' '.NET Framework 4.x' {
    $rel = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full').Release
    Add-Result 'Runtime' '.NET Framework 4.x' ($(if ($rel -ge 533320) { 'PASS' } else { 'FAIL' })) "Release=$rel"
}
if ($cfg) {
    foreach ($t in $cfg.tweaks) {
        Try-Check 'Settings' $t.id {
            $root = $(if ($t.hive -eq 'HKLM') { 'HKLM:\' } else { 'HKCU:\' })
            $v = (Get-ItemProperty -Path ($root + $t.key) -Name $t.name -ErrorAction SilentlyContinue).($t.name)
            Add-Result 'Settings' $t.id ($(if ("$v" -eq "$($t.value)") { 'PASS' } else { 'WARN' })) "$root$($t.key)\$($t.name) = $v (expected $($t.value))"
        }
    }
}

$report = Join-Path $ciDir 'TestReport.md'
$lines = @("# CustomImage deployment test", '', "Computer: $env:COMPUTERNAME  Date: $(Get-Date -Format s)", '', '| Area | Check | Status | Detail |', '|---|---|---|---|')
$lines += $results | ForEach-Object { "| $($_.Area) | $($_.Check) | $($_.Status) | $(($_.Detail -replace '\|', '/')) |" }
$lines | Set-Content -LiteralPath $report -Encoding UTF8
$results | Format-Table -AutoSize -Wrap
$bad = @($results | Where-Object { $_.Status -in @('FAIL', 'ERROR') })
Write-Host ("Report: {0}. FAIL/ERROR: {1}" -f $report, $bad.Count)
exit $bad.Count
