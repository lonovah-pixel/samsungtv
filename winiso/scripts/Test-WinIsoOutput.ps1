#Requires -Version 5.1
<#
.SYNOPSIS
  Статическая проверка готового ISO: SHA-256, загрузочные файлы, autounattend.xml, install.wim
  и встроенные сценарии. Это НЕ проверка установки — для неё нужна виртуальная машина.

.DESCRIPTION
  Windows: монтирование ISO только для чтения, Get-WindowsImage, dism /List-Image.
  Linux/macOS: 7z для извлечения файлов и wimlib-imagex для чтения WIM (если установлены).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$IsoPath,
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\build.json'),
    [string]$ReportPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot 'WinIso.Common.psm1') -Force

$cfg = Import-WinIsoConfig -ConfigPath $ConfigPath
$b = $cfg.Build
$IsWin = ($env:OS -eq 'Windows_NT')
$results = New-Object System.Collections.Generic.List[object]
function Add-Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ check = $Name; ok = $Ok; detail = $Detail })
    Write-WinIsoLog ("{0} {1} {2}" -f $(if ($Ok) { '[OK]  ' } else { '[FAIL]' }), $Name, $Detail) $(if ($Ok) { 'OK' } else { 'ERROR' })
}

$IsoPath = (Resolve-Path -LiteralPath $IsoPath).Path
$hash = (Get-FileHash -LiteralPath $IsoPath -Algorithm SHA256).Hash.ToLowerInvariant()
Add-Check 'Вычислен SHA-256' $true $hash
$sumFile = "$IsoPath.sha256"
if (Test-Path -LiteralPath $sumFile) {
    $expected = ((Get-Content -LiteralPath $sumFile -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    Add-Check 'SHA-256 совпадает с .sha256' ($expected -eq $hash) $sumFile
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("winiso-verify-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$mounted = $false
try {
    $arch = Get-WinIsoProp $b.target 'architecture' 'amd64'
    $efiBoot = if ($arch -eq 'arm64') { 'efi\boot\bootaa64.efi' } else { 'efi\boot\bootx64.efi' }
    $required = @('bootmgr', 'bootmgr.efi', 'boot\etfsboot.com', 'efi\microsoft\boot\efisys.bin', $efiBoot, 'sources\boot.wim', 'sources\install.wim', 'sources\setup.exe')
    if ($b.unattend.enabled) { $required += 'autounattend.xml' }

    if ($IsWin) {
        $img = Mount-DiskImage -ImagePath $IsoPath -Access ReadOnly -StorageType ISO -PassThru; $mounted = $true
        $root = "$(($img | Get-Volume).DriveLetter):\"
        $exists = { param($rel) Test-Path -LiteralPath (Join-Path $root $rel) }
        $readText = { param($rel) Get-Content -LiteralPath (Join-Path $root $rel) -Raw -Encoding UTF8 }
        $wim = Join-Path $root 'sources\install.wim'
    } else {
        if (-not (Get-Command 7z -ErrorAction SilentlyContinue)) { throw 'Нужен 7z (p7zip) для проверки ISO вне Windows.' }
        $list = & 7z l -slt -ba $IsoPath | Where-Object { $_ -like 'Path = *' } | ForEach-Object { $_.Substring(7).Replace('/', '\').ToLowerInvariant() }
        $exists = { param($rel) $list -contains $rel.ToLowerInvariant() }
        & 7z x -y "-o$tmp" $IsoPath 'autounattend.xml' 'sources/install.wim' 2>&1 | Out-Null
        $readText = { param($rel) Get-Content -LiteralPath (Join-Path $tmp $rel) -Raw -Encoding UTF8 }
        $wim = Join-Path $tmp 'sources/install.wim'
    }

    foreach ($r in $required) { Add-Check "Файл $r" ([bool](& $exists $r)) }
    Add-Check 'Нет install.esd (заменён install.wim)' (-not (& $exists 'sources\install.esd'))

    if ($b.unattend.enabled -and (& $exists 'autounattend.xml')) {
        $text = & $readText 'autounattend.xml'
        $okXml = $true; try { [xml]$doc = $text } catch { $okXml = $false }
        Add-Check 'autounattend.xml: корректный XML' $okXml
        if ($okXml) {
            foreach ($bad in 'DiskConfiguration', 'InstallTo', 'InstallToAvailablePartition', 'WillWipeDisk', 'ProductKey', 'Password', 'AutoLogon', 'UserAccounts', 'BypassTPMCheck', 'BypassSecureBootCheck', 'LabConfig') {
                Add-Check "autounattend.xml: нет '$bad'" ($text -notmatch [regex]::Escape($bad))
            }
            $passes = @($doc.unattend.settings | ForEach-Object { $_.pass })
            Add-Check 'autounattend.xml: только проход oobeSystem' (@($passes | Where-Object { $_ -ne 'oobeSystem' }).Count -eq 0) ($passes -join ',')
            Add-Check 'autounattend.xml: FirstLogonCommands вызывает Deploy-Apps' ($text -match 'Deploy-Apps\.ps1')
        }
    }

    if (& $exists 'sources\install.wim') {
        if ($IsWin) {
            $imgs = @(Get-WindowsImage -ImagePath $wim)
            $names = $imgs.ImageName
            $files = (& dism.exe /English /List-Image "/ImageFile:$wim" /Index:1) -join "`n"
        } elseif (Get-Command wimlib-imagex -ErrorAction SilentlyContinue) {
            $info = (& wimlib-imagex info $wim) -join "`n"
            $names = @([regex]::Matches($info, '(?m)^Name:\s+(.+)$') | ForEach-Object { $_.Groups[1].Value.Trim() })
            $files = ((& wimlib-imagex dir $wim 1) -join "`n").Replace('/', '\')
        } else { $names = $null; $files = $null; Add-Check 'Чтение install.wim' $false 'нет wimlib-imagex' }
        if ($null -ne $names) {
            Add-Check 'install.wim: одна редакция' (@($names).Count -eq 1 -or -not $b.image.keep_single_edition) (@($names) -join '; ')
            if ($b.target.edition_name) { Add-Check 'install.wim: выбранная редакция' (@($names) -contains $b.target.edition_name) $b.target.edition_name }
        }
        if ($files) {
            foreach ($f in '\Windows\Setup\Scripts\SetupComplete.cmd', '\ProgramData\WinIsoDeploy\Deploy-Apps.ps1', '\ProgramData\WinIsoDeploy\apps.json', '\ProgramData\WinIsoDeploy\Undo-Tweaks.ps1') {
                Add-Check "install.wim содержит $f" ($files -match [regex]::Escape($f))
            }
            foreach ($a in @((Get-WinIsoAppPlan $cfg) | Where-Object { $_.method -eq 'offline' })) {
                Add-Check "install.wim содержит установщик $($a.offline.file)" ($files -match [regex]::Escape("\ProgramData\WinIsoDeploy\installers\$($a.offline.file)"))
            }
        }
    }
} finally {
    if ($mounted) { Dismount-DiskImage -ImagePath $IsoPath | Out-Null }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_.ok }).Count
Write-WinIsoLog ("Итог статической проверки: {0} проверок, ошибок: {1}. Загрузка и установка этой проверкой НЕ подтверждаются." -f $results.Count, $failed) $(if ($failed) { 'ERROR' } else { 'OK' })
if ($ReportPath) { [ordered]@{ iso = $IsoPath; sha256 = $hash; checks = $results } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ReportPath -Encoding UTF8 }
if ($failed) { exit 1 }
