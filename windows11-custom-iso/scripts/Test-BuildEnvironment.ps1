<#
.SYNOPSIS
  Checks whether this machine can build the custom Windows 11 ISO.
.DESCRIPTION
  Reports OS, admin rights, free space, DISM, Windows ADK Deployment Tools (Oscdimg),
  virtualization, and (on Linux/WSL) the wimlib/xorriso fallback toolchain.
  Read-only: changes nothing on the host.
.OUTPUTS
  PSCustomObject with Backend (Windows|Linux|None), Ready, Issues, Warnings, Checks.
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$OscdimgPath = '',
    [double]$MinFreeGBWindows = 50,
    [double]$MinFreeGBLinux = 25,
    [switch]$Quiet
)

. (Join-Path $PSScriptRoot 'BuildCommon.ps1')

$checks = New-Object System.Collections.ArrayList
$issues = New-Object System.Collections.ArrayList
$warnings = New-Object System.Collections.ArrayList
function Add-Check([string]$Name, [string]$Value, [string]$State) {
    [void]$checks.Add([pscustomobject]@{ Check = $Name; Value = $Value; State = $State })
}

function Find-Oscdimg([string]$Override) {
    $candidates = @()
    if ($Override) { $candidates += $Override }
    foreach ($rk in @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots', 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots')) {
        try {
            $kr = (Get-ItemProperty -Path $rk -Name KitsRoot10 -ErrorAction Stop).KitsRoot10
            if ($kr) { $candidates += (Join-Path $kr 'Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe') }
        } catch { }
    }
    $pf86 = [Environment]::GetFolderPath('ProgramFilesX86')
    if ($pf86) { $candidates += (Join-Path $pf86 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe') }
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

$backend = 'None'
$oscdimgFound = $null
$freeGB = Get-FreeSpaceGB -Path $ProjectRoot

if (Test-IsWindowsHost) {
    $os = Get-CimInstance Win32_OperatingSystem
    Add-Check 'OS' ("{0} build {1} ({2})" -f $os.Caption, $os.BuildNumber, $os.OSArchitecture) 'info'
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Add-Check 'Administrator' "$isAdmin" ($(if ($isAdmin) { 'ok' } else { 'fail' }))
    if (-not $isAdmin) { [void]$issues.Add('Run build.ps1 from an elevated PowerShell (DISM mount/commit requires administrator rights).') }

    Add-Check 'Free space' "$freeGB GB on project drive (need >= $MinFreeGBWindows)" ($(if ($freeGB -ge $MinFreeGBWindows) { 'ok' } else { 'fail' }))
    if ($freeGB -lt $MinFreeGBWindows) { [void]$issues.Add("Not enough free space: $freeGB GB < $MinFreeGBWindows GB.") }

    $dismExe = Join-Path $env:SystemRoot 'System32\Dism.exe'
    $dismVer = if (Test-Path $dismExe) { (Get-Item $dismExe).VersionInfo.ProductVersion } else { 'missing' }
    Add-Check 'DISM (inbox)' $dismVer ($(if ($dismVer -ne 'missing') { 'ok' } else { 'fail' }))
    $dismMod = Get-Command Mount-WindowsImage -ErrorAction SilentlyContinue
    Add-Check 'DISM PowerShell module' ($(if ($dismMod) { $dismMod.Source } else { 'missing' })) ($(if ($dismMod) { 'ok' } else { 'fail' }))
    if (-not $dismMod) { [void]$issues.Add('DISM PowerShell module (Mount-WindowsImage) not available. Use Windows PowerShell 5.1 (powershell.exe).') }

    $osc = Find-Oscdimg $OscdimgPath
    $oscdimgFound = $osc
    if ($osc) {
        Add-Check 'Oscdimg (Windows ADK Deployment Tools)' ("{0} v{1}" -f $osc, (Get-Item $osc).VersionInfo.ProductVersion) 'ok'
    } else {
        Add-Check 'Oscdimg (Windows ADK Deployment Tools)' 'not found' 'fail'
        [void]$issues.Add('Install Windows ADK for Windows 11 with the "Deployment Tools" feature (provides oscdimg.exe), or set iso.oscdimgPath in config.json.')
    }
    $adkDism = $null
    if ($osc) {
        $adkDism = Join-Path (Split-Path (Split-Path $osc -Parent) -Parent) 'DISM\dism.exe'
        if (Test-Path $adkDism) { Add-Check 'DISM (ADK)' (Get-Item $adkDism).VersionInfo.ProductVersion 'info' }
    }
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    Add-Check 'curl.exe' ($(if ($curl) { $curl.Source } else { 'missing' })) ($(if ($curl) { 'ok' } else { 'fail' }))
    if (-not $curl) { [void]$issues.Add('curl.exe is required (Windows 10 1803+ ships it in System32).') }

    $cs = Get-CimInstance Win32_ComputerSystem
    $hv = Get-Command New-VM -ErrorAction SilentlyContinue
    Add-Check 'Hypervisor present' "$($cs.HypervisorPresent)" 'info'
    Add-Check 'Hyper-V PowerShell (VM test)' ($(if ($hv) { 'available' } else { 'not available' })) ($(if ($hv) { 'ok' } else { 'warn' }))
    if (-not $hv) { [void]$warnings.Add('Hyper-V module not found: the VM install test (scripts/New-TestVM.ps1) cannot run here.') }

    if ($issues.Count -eq 0) { $backend = 'Windows' }
}
else {
    $osName = 'Linux'
    if (Test-Path /etc/os-release) {
        $m = Select-String -Path /etc/os-release -Pattern '^PRETTY_NAME="?([^"]+)' | Select-Object -First 1
        if ($m) { $osName = $m.Matches[0].Groups[1].Value }
    }
    Add-Check 'OS' "$osName ($([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture))" 'info'
    $uid = (& id -u)
    Add-Check 'Root' "uid=$uid (not required for the Linux backend)" 'info'
    Add-Check 'DISM / Windows ADK' 'not available on Linux' 'warn'

    $isWsl = $false
    if (Test-Path /proc/version) { $isWsl = ((Get-Content /proc/version -Raw) -match '(?i)microsoft') }
    Add-Check 'WSL' "$isWsl" 'info'
    if ($isWsl) {
        $winPs = Get-Command powershell.exe -ErrorAction SilentlyContinue
        Add-Check 'Windows interop (powershell.exe)' ($(if ($winPs) { $winPs.Source } else { 'not reachable' })) ($(if ($winPs) { 'ok' } else { 'warn' }))
        if ($winPs) { [void]$warnings.Add('WSL detected with Windows interop: preferred path is to run build.ps1 from an elevated Windows PowerShell on the host (DISM + Oscdimg).') }
    }

    Add-Check 'Free space' "$freeGB GB (need >= $MinFreeGBLinux)" ($(if ($freeGB -ge $MinFreeGBLinux) { 'ok' } else { 'fail' }))
    if ($freeGB -lt $MinFreeGBLinux) { [void]$issues.Add("Not enough free space: $freeGB GB < $MinFreeGBLinux GB.") }

    foreach ($t in @(
            @{ n = 'wimlib-imagex'; why = 'WIM/ESD export and update (package wimtools)' },
            @{ n = 'xorriso'; why = 'ISO creation (package xorriso)' },
            @{ n = '7z'; why = 'UDF ISO extraction (package p7zip-full)' },
            @{ n = 'curl'; why = 'downloads' },
            @{ n = 'osslsigncode'; why = 'Authenticode verification (package osslsigncode)' })) {
        $c = Get-Command $t.n -CommandType Application -ErrorAction SilentlyContinue
        if ($c) {
            $ver = ''
            try {
                if ($t.n -eq 'wimlib-imagex') { $ver = (& $t.n --version | Select-Object -First 1) }
                elseif ($t.n -eq 'xorriso') { $ver = (& $t.n -version 2>&1 | Select-Object -First 1) }
            } catch { }
            Add-Check $t.n ("{0} {1}" -f @($c)[0].Source, $ver).Trim() 'ok'
        } else {
            Add-Check $t.n "missing ($($t.why))" 'fail'
            [void]$issues.Add("Missing tool: $($t.n) - $($t.why).")
        }
    }
    $kvm = Test-Path /dev/kvm
    $cpuVirt = $false
    if (Test-Path /proc/cpuinfo) { $cpuVirt = [bool](Select-String -Path /proc/cpuinfo -Pattern '\b(vmx|svm)\b' -Quiet) }
    Add-Check 'KVM (/dev/kvm)' "$kvm" ($(if ($kvm) { 'ok' } else { 'warn' }))
    Add-Check 'CPU virtualization flags (vmx/svm)' "$cpuVirt" 'info'
    $qemu = Get-Command qemu-system-x86_64 -ErrorAction SilentlyContinue
    $swtpm = Get-Command swtpm -ErrorAction SilentlyContinue
    Add-Check 'qemu-system-x86_64 / swtpm' ("{0} / {1}" -f [bool]$qemu, [bool]$swtpm) 'info'
    if (-not $kvm) { [void]$warnings.Add('No hardware virtualization: a Windows install test in a VM (UEFI + Secure Boot + TPM) is not possible here.') }
    [void]$warnings.Add('Linux backend deviates from the reference pipeline: no DISM, ISO built with xorriso instead of Oscdimg, install.wim split into SWM parts (ISO9660/Joliet has a 4 GiB per-file limit).')
    if ($issues.Count -eq 0) { $backend = 'Linux' }
}

$result = [pscustomobject]@{
    Timestamp = (Get-Date).ToString('s')
    Backend   = $backend
    Ready     = ($issues.Count -eq 0)
    FreeGB    = $freeGB
    OscdimgPath = $oscdimgFound
    Checks    = $checks.ToArray()
    Issues    = $issues.ToArray()
    Warnings  = $warnings.ToArray()
}

if (-not $Quiet) {
    $result.Checks | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    foreach ($w in $result.Warnings) { Write-Host "WARN:  $w" -ForegroundColor Yellow }
    foreach ($i in $result.Issues) { Write-Host "ISSUE: $i" -ForegroundColor Red }
    Write-Host ("Backend: {0}; Ready: {1}" -f $result.Backend, $result.Ready)
}
return $result
