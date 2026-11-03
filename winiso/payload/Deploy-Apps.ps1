#Requires -Version 5.1
<#
.SYNOPSIS
  Установка программ на установленной системе. Идемпотентен: перед установкой проверяет наличие
  программы, ведёт state.json и журнал, не создаёт дубликатов при повторном запуске.

.PARAMETER Stage
  SetupComplete — запускается SetupComplete.cmd от SYSTEM до первого входа: только офлайн-установщики stage=setupcomplete.
  FirstLogon    — FirstLogonCommands / повторная попытка: всё оставшееся, включая winget (нужен интернет).
  Retry         — то же, что FirstLogon (вызывается запланированной задачей повторной попытки).
  Status        — только показать состояние.

.NOTES
  Коды возврата: 0 и коды из success_codes — успех; reboot_codes — успех, нужна перезагрузка
  (скрипт сам НЕ перезагружает); winget 0x8A150061/0x8A15010D (уже установлено) — успех;
  0x8A150109/0x8A15010A — нужна перезагрузка.
  Журналы: C:\ProgramData\WinIsoDeploy\logs. Состояние: C:\ProgramData\WinIsoDeploy\state.json.
#>
[CmdletBinding()]
param(
    [ValidateSet('SetupComplete', 'FirstLogon', 'Retry', 'Status')][string]$Stage = 'FirstLogon',
    [string]$Root = $PSScriptRoot,
    [int]$WingetWaitSeconds = 300,
    [int]$MaxAttempts = 3
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$LogDir = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Log = Join-Path $LogDir ("Deploy-{0}-{1}.log" -f $Stage, (Get-Date -Format 'yyyyMMdd-HHmmss'))
$StatePath = Join-Path $Root 'state.json'
$TaskName = 'WinIsoDeploy-Retry'
$WINGET_ALREADY = @(-1978335135, -1978334963)   # 0x8A150061, 0x8A15010D
$WINGET_REBOOT = @(-1978334967, -1978334966, -1978334965) # 0x8A150109, 0x8A15010A, 0x8A15010B
$WINGET_NOT_FOUND = -1978335212                  # 0x8A150014

function Log([string]$m, [string]$lvl = 'INFO') {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $lvl, $m
    Add-Content -LiteralPath $Log -Value $line -Encoding UTF8
    Write-Host $line
}
function P($o, [string]$n, $d = $null) { if ($null -eq $o) { return $d }; $p = $o.PSObject.Properties[$n]; if ($null -eq $p -or $null -eq $p.Value) { $d } else { $p.Value } }

function Get-State {
    $s = @{}
    if (Test-Path -LiteralPath $StatePath) {
        (Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $s[$_.Name] = $_.Value }
    }
    return $s
}
function Save-State($s) {
    $tmp = "$StatePath.tmp"
    $s | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $StatePath -Force
}
function Set-AppState($s, $app, [string]$status, $code = $null, [string]$note = '') {
    $attempts = 0
    if ($s.ContainsKey($app.id) -and $s[$app.id].PSObject.Properties['attempts']) { $attempts = [int]$s[$app.id].attempts }
    elseif ($s.ContainsKey($app.id) -and $s[$app.id] -is [System.Collections.IDictionary] -and $s[$app.id].Contains('attempts')) { $attempts = [int]$s[$app.id]['attempts'] }
    if ($status -in 'failed', 'installed', 'installed-reboot') { $attempts++ }
    if ($status -eq 'failed' -and $attempts -ge $MaxAttempts) { $status = 'failed-final'; $note = "$note; попыток: $attempts — автоматические повторы прекращены" }
    $s[$app.id] = [pscustomobject][ordered]@{ name = $app.name; status = $status; code = $code; note = $note; stage = $Stage; attempts = $attempts; time = (Get-Date).ToString('s') }
    Save-State $s
    Log ("{0}: {1} {2} {3}" -f $app.name, $status, $(if ($null -ne $code) { "(код $code)" } else { '' }), $note) $(if ($status -in 'failed', 'failed-final', 'blocked') { 'ERROR' } elseif ($status -eq 'pending') { 'WARN' } else { 'INFO' })
}

# ------------------------------------------------------------ обнаружение
function Get-UninstallEntries {
    $paths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    foreach ($p in $paths) { Get-ItemProperty -Path $p -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties['DisplayName'] } }
}
function Get-WingetPath {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # Под SYSTEM или до регистрации App Installer winget нет в PATH.
    $pkg = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($pkg) { return $pkg.FullName }
    return $null
}
function Test-AppInstalled($app) {
    $d = $app.detect
    switch ($d.type) {
        'uninstall_displayname' { return [bool](Get-UninstallEntries | Where-Object { $_.DisplayName -match $d.pattern } | Select-Object -First 1) }
        'file' { return (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($d.path))) }
        'msi_productcode' {
            return [bool](Get-UninstallEntries | Where-Object { $_.PSChildName -eq $d.product_code } | Select-Object -First 1)
        }
        'winget' {
            $wg = Get-WingetPath
            if (-not $wg) { return $false }
            & $wg list --id $app.winget.id --exact --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
            return ($LASTEXITCODE -eq 0)
        }
    }
    return $false
}

# ------------------------------------------------------------ установка
function Invoke-Offline($app) {
    $o = $app.offline
    $file = Join-Path $Root "installers\$($o.file)"
    if (-not (Test-Path -LiteralPath $file)) { return @{ Code = $null; Status = 'failed'; Note = "нет файла $file" } }
    $argStr = [string](P $o 'args' '')
    if ($o.type -eq 'msi') {
        $msiLog = Join-Path $LogDir "msi-$($app.id).log"
        $p = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList "/i `"$file`" $argStr /l*v `"$msiLog`"" -Wait -PassThru -WindowStyle Hidden
    } else {
        $p = if ($argStr) { Start-Process -FilePath $file -ArgumentList $argStr -Wait -PassThru -WindowStyle Hidden } else { Start-Process -FilePath $file -Wait -PassThru -WindowStyle Hidden }
    }
    return (Resolve-Code $app $p.ExitCode)
}
function Resolve-Code($app, [int]$code, [switch]$Winget) {
    $ok = @(P $app 'success_codes' @(0)); $rb = @(P $app 'reboot_codes' @(3010, 1641))
    if ($ok -contains $code) { return @{ Code = $code; Status = 'installed'; Note = '' } }
    if ($rb -contains $code) { return @{ Code = $code; Status = 'installed-reboot'; Note = 'требуется перезагрузка' } }
    if ($Winget -and $WINGET_ALREADY -contains $code) { return @{ Code = $code; Status = 'present'; Note = 'уже установлено (winget)' } }
    if ($Winget -and $WINGET_REBOOT -contains $code) { return @{ Code = $code; Status = 'installed-reboot'; Note = 'требуется перезагрузка (winget)' } }
    return @{ Code = $code; Status = 'failed'; Note = ('код 0x{0:X8}' -f $code) }
}
function Test-Internet {
    try {
        $r = Invoke-WebRequest -Uri 'https://cdn.winget.microsoft.com/cache/source.msix' -Method Head -UseBasicParsing -TimeoutSec 15
        return ($r.StatusCode -lt 400)
    } catch { return $false }
}
function Initialize-Winget {
    $wg = Get-WingetPath
    if (-not $wg) {
        # Документированный способ: регистрация App Installer для текущего пользователя.
        Log 'winget не найден — регистрация App Installer (Add-AppxPackage -RegisterByFamilyName)'
        try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop } catch { Log "Регистрация не удалась: $($_.Exception.Message)" 'WARN' }
        $deadline = (Get-Date).AddSeconds($WingetWaitSeconds)
        while (-not ($wg = Get-WingetPath) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 10 }
    }
    if (-not $wg) { return $null }
    $ver = (& $wg --version 2>$null) -join ''
    Log "winget: $wg $ver"
    return $wg
}
function Invoke-Winget($app, [string]$wg) {
    $w = $app.winget
    $a = @('install', '--id', $w.id, '--exact', '--source', (P $w 'source' 'winget'), '--silent',
           '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    $scope = P $w 'scope'; if ($scope) { $a += @('--scope', $scope) }
    $ver = P $w 'version'; if ($ver) { $a += @('--version', $ver) }
    Log ("winget {0}" -f ($a -join ' '))
    $out = & $wg @a 2>&1
    $code = $LASTEXITCODE
    $out | Where-Object { "$_".Trim() -and "$_" -notmatch '^[\s\-\\|/█▒]+$' } | ForEach-Object { Add-Content -LiteralPath $Log -Value "    $_" -Encoding UTF8 }
    return (Resolve-Code $app $code -Winget)
}

function Register-RetryTask {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File `"$Root\Deploy-Apps.ps1`" -Stage Retry"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Log "Создана задача '$TaskName': повтор при следующем входе $user" 'WARN'
}
function Unregister-RetryTask {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; Log "Задача '$TaskName' удалена (всё установлено)"
    }
}

# ------------------------------------------------------------ основной ход
$manifest = Get-Content -LiteralPath (Join-Path $Root 'apps.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$apps = @(P $manifest 'apps' @())
$state = Get-State
Log "Стадия: $Stage; пользователь: $([Security.Principal.WindowsIdentity]::GetCurrent().Name); программ: $($apps.Count)"

if ($Stage -eq 'Status') { $state.GetEnumerator() | ForEach-Object { Log ("{0}: {1}" -f $_.Key, ($_.Value | ConvertTo-Json -Compress)) }; exit 0 }

$isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Log 'Нужны права администратора — установка пропущена. Войдите администратором или запустите скрипт с повышением.' 'ERROR'; exit 1 }

$wg = $null; $online = $null; $pending = 0; $rebootNeeded = $false
foreach ($app in $apps) {
    $id = $app.id
    $prev = if ($state.ContainsKey($id)) { $state[$id].status } else { $null }
    if ($prev -in 'installed', 'installed-reboot', 'present', 'failed-final') { Log "$($app.name): уже обработано ($prev) — пропуск"; continue }
    if ($Stage -eq 'SetupComplete' -and -not ($app.method -eq 'offline' -and $app.stage -eq 'setupcomplete')) { continue }

    $blocked = @(P $app 'depends_on' @()) | Where-Object { -not ($state.ContainsKey($_) -and $state[$_].status -in 'installed', 'installed-reboot', 'present') }
    if ($blocked) { Set-AppState $state $app 'blocked' $null ("ждёт зависимости: " + ($blocked -join ', ')); $pending++; continue }

    try {
        if (Test-AppInstalled $app) { Set-AppState $state $app 'present' $null 'обнаружена до установки'; continue }
        $res = $null
        if ($app.method -eq 'offline') {
            $res = Invoke-Offline $app
            if ($res.Status -eq 'failed' -and (P $app 'fallback_winget_id') -and $Stage -ne 'SetupComplete') {
                Log "$($app.name): офлайн-установка не удалась ($($res.Note)), пробую winget $($app.fallback_winget_id)" 'WARN'
                $app | Add-Member -NotePropertyName winget -NotePropertyValue ([pscustomobject]@{ id = $app.fallback_winget_id; source = 'winget'; scope = 'machine' }) -Force
            }
        }
        if ($app.method -eq 'winget' -or ($res -and $res.Status -eq 'failed' -and (P $app 'winget'))) {
            if ($null -eq $online) { $online = Test-Internet; Log "Интернет: $(if ($online) {'доступен'} else {'НЕДОСТУПЕН'})" }
            if (-not $online) { Set-AppState $state $app 'pending' $null 'нет интернета — повтор при следующем входе'; $pending++; continue }
            if (-not $wg) { $wg = Initialize-Winget }
            if (-not $wg) { Set-AppState $state $app 'pending' $null 'winget недоступен — повтор при следующем входе'; $pending++; continue }
            $res = Invoke-Winget $app $wg
        }
        Set-AppState $state $app $res.Status $res.Code $res.Note
        if ($res.Status -eq 'installed-reboot') { $rebootNeeded = $true }
        if ($state[$app.id].status -eq 'failed') { $pending++ }
        elseif ($res.Status -eq 'installed' -and -not (Test-AppInstalled $app)) { Log "$($app.name): установщик вернул успех, но программа не обнаружена правилом detect — проверьте правило." 'WARN' }
    } catch {
        Set-AppState $state $app 'failed' $null $_.Exception.Message
        if ($state[$app.id].status -eq 'failed') { $pending++ }
    }
}

if ($Stage -ne 'SetupComplete') {
    if ($pending) { Register-RetryTask } else { Unregister-RetryTask }
}
if ($rebootNeeded) {
    Log 'Некоторым программам нужна перезагрузка. Перезагрузите компьютер, когда удобно (автоматически не перезагружаю).' 'WARN'
    New-Item -ItemType File -Force -Path (Join-Path $Root 'REBOOT_REQUIRED') | Out-Null
}
Log ("Готово. Не завершено: {0}. Журнал: {1}" -f $pending, $Log)
exit 0
