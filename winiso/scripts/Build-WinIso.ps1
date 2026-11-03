#Requires -Version 5.1
<#
.SYNOPSIS
  Сборка настроенного установочного ISO Windows штатными средствами (DISM + oscdimg из Windows ADK).

.DESCRIPTION
  Порядок работы:
    1. Проверка конфигурации, прав администратора, инструментов и свободного места.
    2. Копирование оригинального ISO в рабочую папку (оригинал не изменяется) и сверка SHA-256.
    3. Распаковка копии, экспорт выбранной редакции в отдельный install.wim.
    4. Офлайн-обслуживание: удаление предустановленных приложений, консервативные настройки
       реестра, драйверы (по желанию), сценарии установки программ.
    5. Создание autounattend.xml (только FirstLogonCommands, без разметки дисков и секретов).
    6. Сборка ISO через oscdimg (BIOS + UEFI), SHA-256, проверка, отчёт.

  -PlanOnly показывает план и найденные проблемы, ничего не меняя (работает и не на Windows).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\Build-WinIso.ps1 -PlanOnly
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\Build-WinIso.ps1
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\build.json'),
    [switch]$PlanOnly,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot 'WinIso.Common.psm1') -Force

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$IsWin = ($env:OS -eq 'Windows_NT')
$cfg = Import-WinIsoConfig -ConfigPath $ConfigPath
$b = $cfg.Build
$problems = Get-WinIsoConfigProblems $cfg

# ---------------------------------------------------------------- план
function Show-Plan {
    Write-WinIsoLog '=== ПЛАН СБОРКИ (изменения не выполняются) ===' 'STEP'
    $t = $b.target
    Write-WinIsoLog ("Windows: {0}; редакции (EditionId): {1}; язык: {2}; архитектура: {3}" -f $t.windows, (@($t.editions) -join ', '), $t.language, $t.architecture) 'PLAN'
    Write-WinIsoLog ("Оригинал ISO: {0} (только чтение, работа с копией)" -f $b.source.iso_path) 'PLAN'
    Write-WinIsoLog ("Рабочая папка: {0}; результат: {1}" -f $b.paths.work_dir, $b.paths.output_iso) 'PLAN'
    Write-WinIsoLog 'Шаги: копия ISO → распаковка → экспорт выбранных редакций → для каждой: монтирование install.wim → удаление приложений → твики → драйверы → сценарии программ → сохранение → autounattend.xml → oscdimg → SHA-256 → проверка' 'PLAN'

    Write-WinIsoLog '--- Удаление предустановленных приложений (DISM Remove-AppxProvisionedPackage)' 'STEP'
    try {
        $names = Get-WinIsoAppxRemovalList $cfg
        foreach ($r in @($cfg.Appx.remove)) {
            $mark = if ($names -contains $r.name) { '[x]' } else { '[ ]' }
            Write-WinIsoLog ("{0} {1} — {2} Побочный эффект: {3} Отмена: {4}" -f $mark, $r.name, $r.purpose, $r.side_effect, $r.undo) 'PLAN'
        }
        foreach ($n in $names) { if (-not (@($cfg.Appx.remove).name -contains $n)) { Write-WinIsoLog "[x] $n — из user_extra_appx_remove. Отмена: установить из Microsoft Store." 'PLAN' } }
    } catch { Write-WinIsoLog $_.Exception.Message 'ERROR' }

    Write-WinIsoLog '--- Настройки реестра (офлайн, профиль по умолчанию и HKLM\SOFTWARE)' 'STEP'
    try {
        foreach ($tw in (Get-WinIsoTweakList $cfg)) {
            Write-WinIsoLog ("[x] {0}: {1}\{2}\{3} = {4} ({5}). {6} Побочный эффект: {7} Отмена: {8}" -f $tw.id, $tw.hive, $tw.path, $tw.name, $tw.value, $tw.type, $tw.purpose, $tw.side_effect, $tw.undo) 'PLAN'
        }
    } catch { Write-WinIsoLog $_.Exception.Message 'ERROR' }
    Write-WinIsoLog 'Не изменяются: Defender, брандмауэр, UAC, Windows Update, восстановление, файл подкачки, службы, аппаратные требования, выбор диска в установщике.' 'PLAN'

    Write-WinIsoLog '--- Программы' 'STEP'
    try {
        $plan = Get-WinIsoAppPlan $cfg
        if ($plan.Count -eq 0) { Write-WinIsoLog 'Список программ пуст.' 'WARN' }
        foreach ($a in $plan) {
            $net = if ($a.method -eq 'winget') { 'нужен интернет' } else { 'без интернета (установщик в образе)' }
            $src = if ($a.method -eq 'winget') { "winget id=$($a.winget.id)" } else { "$($a.offline.file) ← $(Get-WinIsoProp $a.offline 'url' 'локальный файл')" }
            Write-WinIsoLog ("{0,-3} {1} — {2}, этап {3}, {4}; {5}" -f (Get-WinIsoProp $a 'order' ''), $a.name, $a.method, $a.stage, $net, $src) 'PLAN'
        }
    } catch { Write-WinIsoLog $_.Exception.Message 'ERROR' }

    if ($problems.Count) {
        Write-WinIsoLog "--- Требуется исправить/уточнить ($($problems.Count)):" 'STEP'
        $problems | ForEach-Object { Write-WinIsoLog " - $_" 'WARN' }
    } else { Write-WinIsoLog 'Конфигурация полная.' 'OK' }
}

if ($PlanOnly) {
    Show-Plan
    if ($IsWin -and $b.source.iso_path -and (Test-Path -LiteralPath $b.source.iso_path)) {
        Write-WinIsoLog '--- Редакции в ISO (только чтение)' 'STEP'
        $img = $null
        try {
            $img = Mount-DiskImage -ImagePath $b.source.iso_path -Access ReadOnly -StorageType ISO -PassThru
            $letter = ($img | Get-Volume).DriveLetter
            $wim = @("${letter}:\sources\install.wim", "${letter}:\sources\install.esd") | Where-Object { Test-Path $_ } | Select-Object -First 1
            Get-WindowsImage -ImagePath $wim | ForEach-Object { $x = Get-WindowsImage -ImagePath $wim -Index $_.ImageIndex; Write-WinIsoLog ("  Index {0}: {1} [EditionId={2}] {3}" -f $x.ImageIndex, $x.ImageName, $x.EditionId, $(if (@($t.editions) -contains $x.EditionId) { '← выбрана' } else { '' })) 'PLAN' }
        } finally { if ($img) { Dismount-DiskImage -ImagePath $b.source.iso_path | Out-Null } }
    }
    exit ([int]($problems.Count -gt 0) * 2)
}

# ---------------------------------------------------------------- реальная сборка
if ($problems.Count) {
    Show-Plan
    throw "Конфигурация неполная ($($problems.Count) проблем). Сборка не начата."
}
if (-not $IsWin) { throw 'Сборка возможна только на Windows 10/11 с правами администратора (DISM, oscdimg). Используйте -PlanOnly для проверки плана.' }
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Запустите PowerShell от имени администратора.' }

$Work = [IO.Path]::GetFullPath($b.paths.work_dir)
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Initialize-WinIsoLog (Join-Path $Work "logs\build-$Stamp.log")
$Media = Join-Path $Work 'media'
$Mount = Join-Path $Work 'mount'
$MountBoot = Join-Path $Work 'mount-boot'
$SrcCopy = Join-Path $Work 'source\source.iso'
$OutIso = [IO.Path]::GetFullPath($b.paths.output_iso)
$Cache = if ([IO.Path]::IsPathRooted($b.paths.installers_cache)) { $b.paths.installers_cache } else { Join-Path $Work $b.paths.installers_cache }
$Dism = $b.tools.dism
$Oscdimg = $b.tools.oscdimg
$Report = [ordered]@{ started = (Get-Date).ToString('s'); config = $b; removed_appx = @(); skipped_appx = @(); tweaks = @(); apps = @(); drivers = @(); iso = $null; sha256 = $null; checks = @() }

$state = @{ IsoMounted = $false; WimMounted = $false; BootMounted = $false; Hives = @() }

function Invoke-HiveUnload {
    foreach ($h in @($state.Hives)) {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        & reg.exe unload $h 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-WinIsoLog "Куст $h выгружен" } else { Write-WinIsoLog "Не удалось выгрузить куст $h — выполните reg unload $h вручную" 'WARN' }
    }
    $state.Hives = @()
}

function Invoke-Cleanup {
    param([bool]$Discard)
    Invoke-HiveUnload
    foreach ($m in @(@{ Key = 'BootMounted'; Path = $MountBoot }, @{ Key = 'WimMounted'; Path = $Mount })) {
        if ($state[$m.Key]) {
            try {
                if ($Discard) { Dismount-WindowsImage -Path $m.Path -Discard | Out-Null } else { Dismount-WindowsImage -Path $m.Path -Save | Out-Null }
                Write-WinIsoLog "Образ отключён: $($m.Path) ($(if ($Discard) {'без сохранения'} else {'с сохранением'}))"
            } catch {
                Write-WinIsoLog "Ошибка отключения $($m.Path): $($_.Exception.Message). Запустите scripts\Repair-WinIsoMounts.ps1" 'ERROR'
            }
            $state[$m.Key] = $false
        }
    }
    if ($state.IsoMounted) {
        Dismount-DiskImage -ImagePath $SrcCopy -ErrorAction SilentlyContinue | Out-Null
        $state.IsoMounted = $false
        Write-WinIsoLog 'Копия ISO отключена'
    }
}

function Set-OfflineTweaks {
    $tweaks = Get-WinIsoTweakList $cfg
    if ($tweaks.Count -eq 0) { return }
    $hiveFiles = @{
        DefaultUser = @{ Key = 'HKLM\WINISO_DEFUSER'; File = Join-Path $Mount 'Users\Default\NTUSER.DAT' }
        Software    = @{ Key = 'HKLM\WINISO_SOFTWARE'; File = Join-Path $Mount 'Windows\System32\config\SOFTWARE' }
    }
    foreach ($h in ($tweaks | Select-Object -ExpandProperty hive -Unique)) {
        $hf = $hiveFiles[$h]
        Invoke-WinIsoNative reg.exe @('load', $hf.Key, $hf.File) | Out-Null
        $state.Hives += $hf.Key
    }
    foreach ($tw in $tweaks) {
        $key = '{0}\{1}' -f $hiveFiles[$tw.hive].Key, $tw.path
        if ($tw.type -eq 'DELETE') {
            & reg.exe query $key /v $tw.name 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Invoke-WinIsoNative reg.exe @('delete', $key, '/v', $tw.name, '/f') | Out-Null; $res = 'deleted' } else { $res = 'absent' }
        } else {
            Invoke-WinIsoNative reg.exe @('add', $key, '/v', $tw.name, '/t', $tw.type, '/d', [string]$tw.value, '/f') | Out-Null
            $res = 'set'
        }
        Write-WinIsoLog "Твик $($tw.id): $res" 'OK'
        if (-not (@($Report.tweaks | ForEach-Object { $_.id }) -contains $tw.id)) {
            $Report.tweaks += [ordered]@{ id = $tw.id; result = $res; purpose = $tw.purpose; side_effect = $tw.side_effect; undo = $tw.undo }
        }
    }
    Invoke-HiveUnload
}

function Copy-Payload {
    param([switch]$RecordReport)
    $dst = Join-Path $Mount 'ProgramData\WinIsoDeploy'
    New-Item -ItemType Directory -Force -Path (Join-Path $dst 'installers'), (Join-Path $dst 'logs') | Out-Null
    foreach ($f in 'Deploy-Apps.ps1', 'Undo-Tweaks.ps1') { Copy-Item -LiteralPath (Join-Path $ProjectRoot "payload\$f") -Destination $dst -Force }
    $plan = Get-WinIsoAppPlan $cfg
    $reqSha = [bool](Get-WinIsoProp $b.security 'require_sha256_for_offline' $true)
    $reqSig = [bool](Get-WinIsoProp $b.security 'require_authenticode' $true)
    foreach ($a in $plan) {
        $entry = [ordered]@{ id = $a.id; name = $a.name; method = $a.method; stage = $a.stage; version = ''; sha256 = ''; signer = ''; included = $false; note = '' }
        if ($a.method -eq 'offline') {
            $src = Join-Path $Cache $a.offline.file
            if (-not (Test-Path -LiteralPath $src)) { throw "Нет установщика $src. Запустите scripts\Get-Installers.ps1." }
            $chk = Test-WinIsoInstallerFile -Path $src -ExpectedSha256 (Get-WinIsoProp $a.offline 'sha256') -ExpectedSigner (Get-WinIsoProp $a.offline 'expected_signer') `
                -RequireSha256 $reqSha -RequireAuthenticode ([bool](Get-WinIsoProp $a.offline 'require_authenticode' $reqSig))
            $entry.version = $chk.Version; $entry.sha256 = $chk.Sha256; $entry.signer = $chk.Signer
            if (-not $chk.Ok) { throw "Установщик $($a.offline.file) не прошёл проверку: $($chk.Notes -join '; ')" }
            Copy-Item -LiteralPath $src -Destination (Join-Path $dst 'installers') -Force
            $entry.included = $true
        } else { $entry.note = 'загрузка winget при первом входе' }
        if ($RecordReport) { $Report.apps += $entry }
        Write-WinIsoLog "Программа $($a.name): $(if ($entry.included) {'установщик встроен'} else {$entry.note})" 'OK'
    }
    # Итоговые файлы конфигурации для установленной системы (только включённые элементы).
    [ordered]@{ generated = (Get-Date).ToString('s'); apps = $plan } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $dst 'apps.json') -Encoding UTF8
    [ordered]@{ tweaks = (Get-WinIsoTweakList $cfg) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dst 'tweaks.applied.json') -Encoding UTF8

    $scripts = Join-Path $Mount 'Windows\Setup\Scripts'
    $sc = Join-Path $scripts 'SetupComplete.cmd'
    if (Test-Path -LiteralPath $sc) { throw "В образе уже есть $sc (OEM-сценарий). Объединение не выполняется автоматически — проверьте вручную." }
    New-Item -ItemType Directory -Force -Path $scripts | Out-Null
    Copy-Item -LiteralPath (Join-Path $ProjectRoot 'payload\SetupComplete.cmd') -Destination $sc -Force
}

$success = $false
try {
    Write-WinIsoLog '=== 1. Предварительные проверки ===' 'STEP'
    foreach ($tool in @($Dism, $Oscdimg)) { if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Не найден инструмент: $tool (установите Windows ADK → Deployment Tools)" } }
    if (-not (Get-Module -ListAvailable -Name Dism)) { throw 'Модуль PowerShell DISM недоступен.' }
    $src = $b.source.iso_path
    if (-not (Test-Path -LiteralPath $src)) { throw "Оригинальный ISO не найден: $src" }
    New-Item -ItemType Directory -Force -Path $Work, (Split-Path $OutIso), (Split-Path $SrcCopy), $Cache | Out-Null
    $fs = (Get-Volume -DriveLetter ([IO.Path]::GetPathRoot($Work).Substring(0, 1))).FileSystem
    if ($fs -ne 'NTFS') { throw "Рабочая папка должна быть на NTFS (сейчас $fs)." }
    $free = Get-WinIsoFreeSpaceGB $Work
    $need = [math]::Ceiling((Get-Item -LiteralPath $src).Length / 1GB * 3 + 8)
    Write-WinIsoLog "Свободно на диске рабочей папки: $free ГБ, требуется около $need ГБ"
    if ($free -lt $need) { throw "Недостаточно места: $free ГБ < $need ГБ." }
    $stale = @(Get-WindowsImage -Mounted | Where-Object { $_.Path -like "$Work*" })
    if ($stale.Count) { throw "Найдены незакрытые монтирования в $Work. Запустите scripts\Repair-WinIsoMounts.ps1." }
    $osBuild = [Environment]::OSVersion.Version.Build
    Write-WinIsoLog "Сборочная ОС: build $osBuild; DISM: $((Get-Command $Dism).Source)"

    Write-WinIsoLog '=== 2. Копия оригинального ISO ===' 'STEP'
    $origHash = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-WinIsoLog "SHA-256 оригинала: $origHash"
    $pinned = Get-WinIsoProp $b.source 'iso_sha256'
    if ($pinned -and $pinned.ToLowerInvariant() -ne $origHash) { throw "SHA-256 оригинала не совпадает с source.iso_sha256." }
    if (-not (Test-Path -LiteralPath $SrcCopy) -or (Get-FileHash -LiteralPath $SrcCopy -Algorithm SHA256).Hash.ToLowerInvariant() -ne $origHash) {
        Copy-Item -LiteralPath $src -Destination $SrcCopy -Force
    }
    if ((Get-FileHash -LiteralPath $SrcCopy -Algorithm SHA256).Hash.ToLowerInvariant() -ne $origHash) { throw 'Копия ISO не совпадает с оригиналом.' }
    $Report.source_sha256 = $origHash

    Write-WinIsoLog '=== 3. Распаковка копии ===' 'STEP'
    if (Test-Path -LiteralPath $Media) { Remove-Item -LiteralPath $Media -Recurse -Force }
    $img = Mount-DiskImage -ImagePath $SrcCopy -Access ReadOnly -StorageType ISO -PassThru
    $state.IsoMounted = $true
    $letter = ($img | Get-Volume).DriveLetter
    Invoke-WinIsoNative robocopy.exe @("${letter}:\", $Media, '/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NP') -AllowedExitCodes @(0, 1, 2, 3) | Out-Null
    Dismount-DiskImage -ImagePath $SrcCopy | Out-Null; $state.IsoMounted = $false
    Get-ChildItem -LiteralPath $Media -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReadOnly } |
        ForEach-Object { $_.Attributes = $_.Attributes -bxor [IO.FileAttributes]::ReadOnly }
    if (Test-Path -LiteralPath (Join-Path $Media 'autounattend.xml')) { throw 'В исходном ISO уже есть autounattend.xml — проверьте источник образа.' }

    Write-WinIsoLog '=== 4. Выбор редакций и экспорт ===' 'STEP'
    $srcWim = @('install.wim', 'install.esd') | ForEach-Object { Join-Path $Media "sources\$_" } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $srcWim) { throw 'В ISO не найден sources\install.wim/esd.' }
    $images = @(Get-WindowsImage -ImagePath $srcWim | ForEach-Object { Get-WindowsImage -ImagePath $srcWim -Index $_.ImageIndex })
    $images | ForEach-Object { Write-WinIsoLog ("  Index {0}: {1} [EditionId={2}] ({3:N1} ГБ)" -f $_.ImageIndex, $_.ImageName, $_.EditionId, ($_.ImageSize / 1GB)) }
    $wanted = @($b.target.editions)
    $sel = @($images | Where-Object { $wanted -contains $_.EditionId } | Sort-Object ImageIndex)
    foreach ($e in $wanted) {
        $m = @($sel | Where-Object { $_.EditionId -eq $e })
        if ($m.Count -ne 1) { throw "Редакция EditionId='$e' найдена $($m.Count) раз(а). Доступные: $(($images | ForEach-Object { "$($_.EditionId) ($($_.ImageName))" }) -join '; ')" }
    }
    $archMap = @{ amd64 = 9; arm64 = 12 }
    foreach ($info in $sel) {
        if ([int]$info.Architecture -ne $archMap[$b.target.architecture]) { throw "Архитектура $($info.ImageName) ($($info.Architecture)) не совпадает с target.architecture." }
        if (@($info.Languages) -notcontains $b.target.language) { throw "Язык $($info.ImageName) ($($info.Languages -join ',')) не совпадает с target.language." }
        if ($info.Version -and ([version]$info.Version).Build -gt $osBuild -and $Dism -eq 'dism.exe') {
            Write-WinIsoLog "Образ ($($info.Version)) новее сборочной ОС: рекомендуется DISM из ADK соответствующей версии (tools.dism)." 'WARN'
        }
    }
    $Report.images = @($sel | ForEach-Object { [ordered]@{ name = $_.ImageName; edition_id = $_.EditionId; version = "$($_.Version)"; languages = @($_.Languages); index_in_source = $_.ImageIndex } })
    $newWim = Join-Path $Work 'install.wim'
    if (Test-Path -LiteralPath $newWim) { Remove-Item -LiteralPath $newWim -Force }
    foreach ($info in $sel) {
        Write-WinIsoLog "Экспорт: $($info.ImageName) (index $($info.ImageIndex))"
        Export-WindowsImage -SourceImagePath $srcWim -SourceIndex $info.ImageIndex -DestinationImagePath $newWim -CompressionType $b.image.compression -CheckIntegrity | Out-Null
    }
    Remove-Item -LiteralPath $srcWim -Force

    Write-WinIsoLog '=== 5. Обслуживание образа ===' 'STEP'
    $drv = Get-WinIsoProp $b.paths 'drivers_dir'
    if ($drv -and -not (Test-Path -LiteralPath $drv)) { throw "Папка драйверов не найдена: $drv" }
    for ($i = 1; $i -le $sel.Count; $i++) {
        Write-WinIsoLog "--- install.wim index ${i}: $($sel[$i - 1].ImageName)" 'STEP'
        if (Test-Path -LiteralPath $Mount) { Remove-Item -LiteralPath $Mount -Recurse -Force }
        New-Item -ItemType Directory -Path $Mount | Out-Null
        Mount-WindowsImage -ImagePath $newWim -Index $i -Path $Mount | Out-Null
        $state.WimMounted = $true

        $present = @(Get-AppxProvisionedPackage -Path $Mount)
        Write-WinIsoLog "Предустановленных пакетов: $($present.Count)"
        foreach ($n in (Get-WinIsoAppxRemovalList $cfg)) {
            $pkg = @($present | Where-Object { $_.DisplayName -eq $n })
            if (-not $pkg.Count) { Write-WinIsoLog "Пакета $n нет в образе — пропуск"; $Report.skipped_appx += "[$i] $n"; continue }
            foreach ($p in $pkg) {
                Remove-AppxProvisionedPackage -Path $Mount -PackageName $p.PackageName | Out-Null
                Write-WinIsoLog "Удалён пакет: $($p.PackageName)" 'OK'
                $Report.removed_appx += "[$i] $($p.PackageName)"
            }
        }
        Set-OfflineTweaks
        if ($drv) { Add-WindowsDriver -Path $Mount -Driver $drv -Recurse | ForEach-Object { $Report.drivers += "[$i] $($_.Driver)" } }
        Copy-Payload -RecordReport:($i -eq 1)
        Write-WinIsoLog 'Сохранение индекса…'
        Dismount-WindowsImage -Path $Mount -Save -CheckIntegrity | Out-Null
        $state.WimMounted = $false
    }
    if ($drv) {
        $bootWim = Join-Path $Media 'sources\boot.wim'
        New-Item -ItemType Directory -Force -Path $MountBoot | Out-Null
        Mount-WindowsImage -ImagePath $bootWim -Index 2 -Path $MountBoot | Out-Null; $state.BootMounted = $true
        Add-WindowsDriver -Path $MountBoot -Driver $drv -Recurse | Out-Null
        Dismount-WindowsImage -Path $MountBoot -Save | Out-Null; $state.BootMounted = $false
        Write-WinIsoLog "Драйверы добавлены в install.wim и boot.wim (индекс 2)" 'OK'
    }
    Move-Item -LiteralPath $newWim -Destination (Join-Path $Media 'sources\install.wim') -Force
    if ($sel.Count -gt 1 -and (Get-WinIsoProp $b.image 'edition_choice_ei_cfg' $true)) {
        # ei.cfg без EditionID и без ключа: Setup показывает выбор редакции, даже если в прошивке есть OEM-ключ Home.
        $ei = Join-Path $Media 'sources\ei.cfg'
        if (Test-Path -LiteralPath $ei) { throw 'В ISO уже есть sources\ei.cfg — проверьте источник образа.' }
        [IO.File]::WriteAllText($ei, "[Channel]`r`nRetail`r`n", [Text.Encoding]::ASCII)
        Write-WinIsoLog 'Добавлен sources\ei.cfg ([Channel] Retail, без ключа) — выбор редакции при установке' 'OK'
    }

    Write-WinIsoLog '=== 6. Файл ответов ===' 'STEP'
    if ($b.unattend.enabled) {
        $xml = Get-Content -LiteralPath (Join-Path $ProjectRoot 'unattend\autounattend.template.xml') -Raw -Encoding UTF8
        $xml = $xml.Replace('{{ARCH}}', $b.target.architecture).Replace('{{FIRST_LOGON_SCRIPT}}', $b.unattend.first_logon_script)
        [xml]$null = $xml   # проверка синтаксиса
        [IO.File]::WriteAllText((Join-Path $Media 'autounattend.xml'), $xml, (New-Object Text.UTF8Encoding($false)))
    }

    Write-WinIsoLog '=== 7. Сборка ISO ===' 'STEP'
    $etfs = Join-Path $Media 'boot\etfsboot.com'
    $efiName = if ($b.image.boot_efi_image -eq 'auto') { 'efisys.bin' } else { $b.image.boot_efi_image }
    $efi = Join-Path $Media "efi\microsoft\boot\$efiName"
    foreach ($f in $etfs, $efi) { if (-not (Test-Path -LiteralPath $f)) { throw "Нет загрузочного файла: $f" } }
    if (Test-Path -LiteralPath $OutIso) { Move-Item -LiteralPath $OutIso -Destination "$OutIso.prev-$Stamp" }
    $boot = '2#p0,e,b{0}#pEF,e,b{1}' -f $etfs, $efi
    Invoke-WinIsoNative $Oscdimg @('-m', '-o', '-u2', '-udfver102', "-l$($b.target.volume_label)", "-bootdata:$boot", $Media, $OutIso) | Out-Null
    $iso = (Get-FileHash -LiteralPath $OutIso -Algorithm SHA256).Hash.ToLowerInvariant()
    "$iso *$(Split-Path -Leaf $OutIso)" | Set-Content -LiteralPath "$OutIso.sha256" -Encoding ASCII
    $Report.iso = $OutIso; $Report.sha256 = $iso
    Write-WinIsoLog "ISO готов: $OutIso" 'OK'
    Write-WinIsoLog "SHA-256: $iso" 'OK'
    $success = $true
}
catch {
    Write-WinIsoLog "ОШИБКА: $($_.Exception.Message)" 'ERROR'
    Write-WinIsoLog ($_.ScriptStackTrace) 'ERROR'
    throw
}
finally {
    Invoke-Cleanup -Discard:(-not $success)
    $Report.finished = (Get-Date).ToString('s'); $Report.success = $success
    if ($Work -and (Test-Path -LiteralPath $Work)) {
        $Report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Work "logs\build-report-$Stamp.json") -Encoding UTF8
    }
}

if (-not $SkipVerify) {
    & (Join-Path $PSScriptRoot 'Test-WinIsoOutput.ps1') -IsoPath $OutIso -ConfigPath $ConfigPath -ReportPath (Join-Path $Work "logs\verify-$Stamp.json")
}
