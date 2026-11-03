#Requires -Version 5.1
<#
.SYNOPSIS
  Запись на флешку Ventoy: новый баннер меню и/или готовый ISO. Ничего не форматирует,
  не меняет разделы и не переустанавливает Ventoy.

.DESCRIPTION
  1. Показывает носитель: букву, метку, файловую систему, размер, диск, модель, серийный номер, наличие раздела VTOYEFI.
  2. Показывает план (для баннера — вывод ventoy_banner.py plan).
  3. Пишет только после ввода токена подтверждения именно этого носителя (метка-UUID).
  Баннер: резервные копии в X:\ventoy\winiso_backup\ и winiso\ventoy-backups\; откат — -Rollback.
  ISO: копируется в X:\iso\ (или -IsoFolder) с .sha256 и проверкой SHA-256 после записи.
  -PlanOnly — только показать.

.EXAMPLE
  .\scripts\Install-ToVentoy.ps1 -Drive D -Banner .\ventoy\draft-banner.png -PlanOnly
.EXAMPLE
  .\scripts\Install-ToVentoy.ps1 -Drive D -Banner .\ventoy\draft-banner.png -Iso C:\WinBuild\out\Win11_HomePro_ru-RU_custom.iso
.EXAMPLE
  .\scripts\Install-ToVentoy.ps1 -Drive D -Rollback
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z]:?$')][string]$Drive,
    [string]$Banner,
    [string]$Iso,
    [string]$IsoFolder = 'iso',
    [string]$TextColor = 'auto',
    [switch]$Rollback,
    [switch]$PlanOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot 'WinIso.Common.psm1') -Force
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$letter = $Drive.Substring(0, 1).ToUpperInvariant()
$root = "${letter}:\"
if (-not ($Banner -or $Iso -or $Rollback)) { throw 'Укажите -Banner, -Iso и/или -Rollback.' }

# ---------------------------------------------------------------- носитель
$vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
if (-not $vol) { throw "Диск ${letter}: не найден. Подключите флешку Ventoy." }
$part = Get-Partition -DriveLetter $letter
$disk = Get-Disk -Number $part.DiskNumber
$labels = @(Get-Partition -DiskNumber $disk.Number | Get-Volume -ErrorAction SilentlyContinue | ForEach-Object { $_.FileSystemLabel })
$isVentoy = $labels -contains 'VTOYEFI'
$uuid = if ("$($vol.UniqueId)" -match '\{([0-9a-fA-F-]+)\}') { $Matches[1] } else { "$($vol.UniqueId)" }
$label = if ($vol.FileSystemLabel) { $vol.FileSystemLabel } else { 'NOLABEL' }
$token = "$label-$uuid"
Write-Host 'Носитель:' -ForegroundColor Cyan
Write-Host ("  точка подключения : {0}" -f $root)
Write-Host ("  метка / ФС        : {0} / {1}, раздел {2:N1} ГБ, свободно {3:N1} ГБ" -f $vol.FileSystemLabel, $vol.FileSystem, ($vol.Size / 1GB), ($vol.SizeRemaining / 1GB))
Write-Host ("  диск              : №{0} {1}, {2:N1} ГБ, шина {3}, серийный {4}" -f $disk.Number, $disk.FriendlyName, ($disk.Size / 1GB), $disk.BusType, $disk.SerialNumber)
Write-Host ("  раздел VTOYEFI    : {0}" -f $(if ($isVentoy) { 'найден — это флешка Ventoy' } else { 'НЕ найден' }))
if (-not $isVentoy) { throw "На диске ${letter}: нет раздела VTOYEFI — это не флешка Ventoy. Запись отменена." }
if ($disk.Number -eq (Get-Partition -DriveLetter ($env:SystemDrive.Substring(0, 1))).DiskNumber) { throw 'Выбран системный диск. Запись отменена.' }

# ---------------------------------------------------------------- python для баннера
function Get-Python {
    foreach ($c in @(@('py', '-3'), @('python'), @('python3'))) {
        if (Get-Command $c[0] -ErrorAction SilentlyContinue) {
            $v = & $c[0] @($c | Select-Object -Skip 1) --version 2>&1
            if ($LASTEXITCODE -eq 0 -and "$v" -match 'Python 3\.([89]|1\d)') { return , $c }
        }
    }
    throw 'Нужен Python 3.8+ для баннера: winget install -e --id Python.Python.3.12 (затем откройте новое окно PowerShell). Либо скопируйте папку ventoy\staged вручную по INSTRUCTIONS.md.'
}
$tool = Join-Path $ProjectRoot 'ventoy\ventoy_banner.py'
function Invoke-Banner([string[]]$ToolArgs) {
    $py = Get-Python
    & $py[0] @($py | Select-Object -Skip 1) -X utf8 $tool @ToolArgs
    if ($LASTEXITCODE -ne 0) { throw "ventoy_banner.py завершился с кодом $LASTEXITCODE" }
}

# ---------------------------------------------------------------- план
Write-Host "`nПлан:" -ForegroundColor Cyan
if ($Rollback) { Write-Host '  откат последнего применения баннера:'; Invoke-Banner @('rollback', $root, '--list') }
if ($Banner) {
    $Banner = (Resolve-Path -LiteralPath $Banner).Path
    Invoke-Banner @('plan', $root, '--banner', $Banner, '--text-color', $TextColor)
}
if ($Iso) {
    $Iso = (Resolve-Path -LiteralPath $Iso).Path
    $dstDir = Join-Path $root $IsoFolder
    $dst = Join-Path $dstDir (Split-Path -Leaf $Iso)
    $size = (Get-Item -LiteralPath $Iso).Length
    Write-Host ("  скопировать ISO: {0} → {1} ({2:N1} ГБ) + .sha256" -f $Iso, $dst, ($size / 1GB))
    if (Test-Path -LiteralPath $dst) { Write-Host "  ! $dst уже существует — будет переименован в .prev-<время>, не удалён" -ForegroundColor Yellow }
    if ($vol.SizeRemaining -lt $size + 256MB) { throw ("На флешке недостаточно места: свободно {0:N1} ГБ, нужно {1:N1} ГБ." -f ($vol.SizeRemaining / 1GB), ($size / 1GB)) }
    if ($vol.FileSystem -eq 'FAT32' -and $size -gt 4GB - 1) { throw 'Раздел FAT32 не вмещает файлы > 4 ГБ.' }
}
if ($PlanOnly) { Write-Host "`nРежим плана: ничего не записано. Токен для подтверждения: $token"; return }

# ---------------------------------------------------------------- подтверждение
Write-Host "`nДля записи на ЭТОТ носитель введите токен: $token" -ForegroundColor Yellow
$answer = Read-Host 'Токен'
if ($answer -ne $token) { throw 'Токен не совпал — запись отменена.' }

if ($Rollback) { Invoke-Banner @('rollback', $root) }
if ($Banner) { Invoke-Banner @('apply', $root, '--banner', $Banner, '--text-color', $TextColor, '--confirm', $token, '--local-backup', (Join-Path $ProjectRoot 'ventoy-backups')) }
if ($Iso) {
    $hash = (Get-FileHash -LiteralPath $Iso -Algorithm SHA256).Hash.ToLowerInvariant()
    New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
    if (Test-Path -LiteralPath $dst) { Move-Item -LiteralPath $dst -Destination ("$dst.prev-" + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
    Write-Host 'Копирование ISO…'
    Copy-Item -LiteralPath $Iso -Destination "$dst.part"
    $copied = (Get-FileHash -LiteralPath "$dst.part" -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($copied -ne $hash) { Remove-Item -LiteralPath "$dst.part" -Force; throw 'SHA-256 копии не совпал с оригиналом — файл удалён, повторите.' }
    Move-Item -LiteralPath "$dst.part" -Destination $dst
    "$hash *$(Split-Path -Leaf $dst)" | Set-Content -LiteralPath "$dst.sha256" -Encoding ASCII
    Write-Host "ISO скопирован и проверен: $dst (SHA-256 $hash)" -ForegroundColor Green
}
Write-Host 'Готово. Безопасно извлеките флешку перед загрузкой.' -ForegroundColor Green
