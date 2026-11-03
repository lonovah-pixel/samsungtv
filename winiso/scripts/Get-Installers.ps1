#Requires -Version 5.1
<#
.SYNOPSIS
  Загружает офлайн-установщики (method=offline) из официальных URL в кэш и проверяет их.

.DESCRIPTION
  Для каждой программы: загрузка (если файла нет или -Force), проверка подписи Authenticode
  и ожидаемого издателя, сверка SHA-256 с apps.json. Ничего не встраивает в образ.
  -Pin записывает вычисленные SHA-256 в apps.json ТОЛЬКО для файлов с действительной подписью
  ожидаемого издателя (у файла без подписи хэш нужно сверить с сайтом производителя и вписать вручную).
  -PlanOnly показывает, что будет загружено.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\build.json'),
    [switch]$Force,
    [switch]$Pin,
    [switch]$PlanOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot 'WinIso.Common.psm1') -Force

$cfg = Import-WinIsoConfig -ConfigPath $ConfigPath
$b = $cfg.Build
if (-not $b.paths.work_dir) { throw 'Не указан paths.work_dir в build.json.' }
$cache = if ([IO.Path]::IsPathRooted($b.paths.installers_cache)) { $b.paths.installers_cache } else { Join-Path $b.paths.work_dir $b.paths.installers_cache }
$offline = @((Get-WinIsoAppPlan $cfg) | Where-Object { $_.method -eq 'offline' })
if (-not $offline.Count) { Write-WinIsoLog 'Офлайн-установщиков в apps.json нет.' 'OK'; return }

if ($PlanOnly) {
    foreach ($a in $offline) { Write-WinIsoLog ("{0}: {1} → {2}" -f $a.name, (Get-WinIsoProp $a.offline 'url' '(локальный файл, URL не задан)'), (Join-Path $cache $a.offline.file)) 'PLAN' }
    return
}
New-Item -ItemType Directory -Force -Path $cache | Out-Null
Initialize-WinIsoLog (Join-Path $b.paths.work_dir ("logs\installers-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$pins = @{}
$failed = 0
foreach ($a in $offline) {
    $dst = Join-Path $cache $a.offline.file
    $url = Get-WinIsoProp $a.offline 'url'
    if ($Force -or -not (Test-Path -LiteralPath $dst)) {
        if (-not $url) { Write-WinIsoLog "$($a.name): нет URL — положите файл вручную в $dst" 'WARN'; $failed++; continue }
        if ($url -notmatch '^https://') { throw "$($a.name): разрешены только HTTPS-источники ($url)." }
        Write-WinIsoLog "Загрузка $($a.name) из $url"
        $tmp = "$dst.part"
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -MaximumRedirection 10
        Move-Item -LiteralPath $tmp -Destination $dst -Force
    }
    $reqSig = [bool](Get-WinIsoProp $a.offline 'require_authenticode' (Get-WinIsoProp $b.security 'require_authenticode' $true))
    $chk = Test-WinIsoInstallerFile -Path $dst -ExpectedSha256 (Get-WinIsoProp $a.offline 'sha256') -ExpectedSigner (Get-WinIsoProp $a.offline 'expected_signer') `
        -RequireSha256 $false -RequireAuthenticode $reqSig
    Write-WinIsoLog ("{0}: версия {1}; SHA-256 {2} ({3}); подпись {4} {5}" -f $a.name, $chk.Version, $chk.Sha256, $chk.HashStatus, $chk.SignatureStatus, $chk.Signer) $(if ($chk.Ok) { 'OK' } else { 'ERROR' })
    $chk.Notes | ForEach-Object { Write-WinIsoLog "  $_" 'WARN' }
    if (-not $chk.Ok) { $failed++; continue }
    if ($Pin -and $chk.HashStatus -eq 'not-pinned') {
        if ($chk.SignatureStatus -eq 'Valid' -and (Get-WinIsoProp $a.offline 'expected_signer')) { $pins[$a.id] = $chk.Sha256 }
        else { Write-WinIsoLog "  $($a.name): без действительной подписи ожидаемого издателя хэш автоматически не закрепляется." 'WARN' }
    }
}

if ($pins.Count) {
    $appsPath = Join-Path $cfg.ConfigDir (Get-WinIsoProp $b 'apps_file' 'apps.json')
    Copy-Item -LiteralPath $appsPath -Destination "$appsPath.bak" -Force
    $json = Get-Content -LiteralPath $appsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($a in $json.apps) { if ($pins.ContainsKey($a.id)) { $a.offline.sha256 = $pins[$a.id]; Write-WinIsoLog "Закреплён SHA-256 для $($a.id)" 'OK' } }
    $json | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $appsPath -Encoding UTF8
    Write-WinIsoLog "apps.json обновлён (резервная копия: $appsPath.bak)"
}
if ($failed) { throw "$failed установщик(ов) не прошли загрузку/проверку." }
