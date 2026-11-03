#Requires -Version 5.1
<#
.SYNOPSIS
  Откат настроек реестра WinIso в установленной системе.

.DESCRIPTION
  Значения, установленные сборкой (tweaks.applied.json), удаляются — при отсутствии значения
  Windows использует поведение по умолчанию.
    -Scope CurrentUser  : HKCU текущего пользователя (твики DefaultUser) — без прав администратора.
    -Scope Machine      : HKLM\SOFTWARE (политики) — нужны права администратора.
    -Scope DefaultProfile: профиль по умолчанию C:\Users\Default (для будущих пользователей) — нужны права администратора.
  Удалённое значение (type=DELETE, например OneDriveSetup) не восстанавливается: см. поле undo.
  -WhatIf показывает действия без изменений.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('CurrentUser', 'Machine', 'DefaultProfile')][string[]]$Scope = @('CurrentUser', 'Machine'),
    [string]$TweaksFile = (Join-Path $PSScriptRoot 'tweaks.applied.json')
)
$ErrorActionPreference = 'Stop'
$tweaks = @((Get-Content -LiteralPath $TweaksFile -Raw -Encoding UTF8 | ConvertFrom-Json).tweaks)
$loaded = $false
try {
    if ($Scope -contains 'DefaultProfile') {
        & reg.exe load 'HKU\WINISO_DEFAULT' "$env:SystemDrive\Users\Default\NTUSER.DAT" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Не удалось загрузить профиль по умолчанию (нужны права администратора).' }
        $loaded = $true
    }
    foreach ($t in $tweaks) {
        $roots = @()
        if ($t.hive -eq 'DefaultUser') {
            if ($Scope -contains 'CurrentUser') { $roots += 'HKCU:\' }
            if ($Scope -contains 'DefaultProfile') { $roots += 'Registry::HKEY_USERS\WINISO_DEFAULT\' }
        } elseif ($t.hive -eq 'Software' -and $Scope -contains 'Machine') { $roots += 'HKLM:\SOFTWARE\' }
        foreach ($r in $roots) {
            $key = $r + $t.path
            if ($t.type -eq 'DELETE') { Write-Host "[$($t.id)] значение было удалено; вернуть: $($t.undo)"; continue }
            $cur = Get-ItemProperty -LiteralPath $key -Name $t.name -ErrorAction SilentlyContinue
            if ($null -eq $cur) { Write-Host "[$($t.id)] $key\$($t.name): уже отсутствует"; continue }
            if ($PSCmdlet.ShouldProcess("$key\$($t.name)", 'Remove-ItemProperty')) {
                Remove-ItemProperty -LiteralPath $key -Name $t.name
                Write-Host "[$($t.id)] $key\$($t.name): удалено (поведение Windows по умолчанию)"
            }
        }
    }
} finally {
    if ($loaded) { [GC]::Collect(); [GC]::WaitForPendingFinalizers(); & reg.exe unload 'HKU\WINISO_DEFAULT' | Out-Null }
}
Write-Host 'Для применения части настроек выйдите из системы и войдите снова. Удалённые приложения возвращаются из Microsoft Store (см. config\appx-remove.json → undo).'
