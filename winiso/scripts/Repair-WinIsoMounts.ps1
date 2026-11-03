#Requires -Version 5.1
<#
.SYNOPSIS
  Освобождает ресурсы после аварийного прерывания сборки: кусты реестра, смонтированные WIM, ISO.
  По умолчанию изменения в смонтированных образах ОТБРАСЫВАЮТСЯ (-Discard). -PlanOnly — только показать.
#>
[CmdletBinding()]
param([switch]$PlanOnly)
$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'WinIso.Common.psm1') -Force

foreach ($h in 'HKLM\WINISO_DEFUSER', 'HKLM\WINISO_SOFTWARE') {
    & reg.exe query $h 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-WinIsoLog "Загружен куст $h" 'WARN'
        if (-not $PlanOnly) { [GC]::Collect(); & reg.exe unload $h }
    }
}
foreach ($m in @(Get-WindowsImage -Mounted)) {
    Write-WinIsoLog "Смонтирован образ: $($m.ImagePath) → $($m.Path) ($($m.MountStatus))" 'WARN'
    if (-not $PlanOnly) { Dismount-WindowsImage -Path $m.Path -Discard | Out-Null }
}
foreach ($d in @(Get-DiskImage -DevicePath * -ErrorAction SilentlyContinue | Where-Object { $_.Attached -and $_.ImagePath -like '*\source\source.iso' })) {
    Write-WinIsoLog "Подключён ISO: $($d.ImagePath)" 'WARN'
    if (-not $PlanOnly) { Dismount-DiskImage -ImagePath $d.ImagePath | Out-Null }
}
if (-not $PlanOnly) { & dism.exe /Cleanup-Wim | Out-Null; Write-WinIsoLog 'Выполнено dism /Cleanup-Wim' 'OK' }
