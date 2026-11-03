#Requires -Version 5.1
<#
  Общие функции проекта WinIso: журнал, запуск внешних программ, загрузка и проверка
  конфигурации, план установки программ. Функции проверки конфигурации не зависят
  от Windows и тестируются на любой платформе (tests/Run-Tests.ps1).
#>
Set-StrictMode -Version 3.0

$script:LogFile = $null

function Initialize-WinIsoLog {
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:LogFile = $Path
    Write-WinIsoLog "Журнал: $Path"
}

function Write-WinIsoLog {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'STEP', 'PLAN', 'OK')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red'; STEP = 'Cyan'; PLAN = 'White'; OK = 'Green' }[$Level]
    Write-Host $line -ForegroundColor $color
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
}

function Invoke-WinIsoNative {
    <# Запускает внешнюю программу, пишет вывод в журнал, бросает исключение при недопустимом коде. #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int[]]$AllowedExitCodes = @(0)
    )
    Write-WinIsoLog ("> {0} {1}" -f $FilePath, ($ArgumentList -join ' '))
    $output = & $FilePath @ArgumentList 2>&1
    $code = $LASTEXITCODE
    foreach ($l in $output) { if ("$l".Trim()) { Write-WinIsoLog ("  " + "$l".TrimEnd()) } }
    if ($AllowedExitCodes -notcontains $code) {
        throw ("{0} завершился с кодом {1}" -f (Split-Path -Leaf $FilePath), $code)
    }
    return $code
}

function Read-WinIsoJson {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Не найден файл конфигурации: $Path" }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        throw "Ошибка синтаксиса JSON в ${Path}: $($_.Exception.Message)"
    }
}

function Get-WinIsoProp {
    <# Безопасное чтение свойства PSCustomObject (StrictMode не позволяет обращаться к отсутствующим). #>
    param($Object, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Import-WinIsoConfig {
    <# Загружает build.json и связанные файлы. Возвращает объект с полями Build, Apps, Appx, Tweaks, ConfigDir. #>
    param([Parameter(Mandatory)][string]$ConfigPath)
    $configPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    $dir = Split-Path -Parent $configPath
    $build = Read-WinIsoJson $configPath
    $opt = Get-WinIsoProp $build 'optimization'
    [pscustomobject]@{
        ConfigDir = $dir
        Build     = $build
        Apps      = Read-WinIsoJson (Join-Path $dir (Get-WinIsoProp $build 'apps_file' 'apps.json'))
        Appx      = Read-WinIsoJson (Join-Path $dir (Get-WinIsoProp $opt 'appx_remove_file' 'appx-remove.json'))
        Tweaks    = Read-WinIsoJson (Join-Path $dir (Get-WinIsoProp $opt 'tweaks_file' 'tweaks.json'))
    }
}

function Test-WinIsoWildcard {
    param([string]$Name, [string[]]$Patterns)
    foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
    return $false
}

function Get-WinIsoAppxRemovalList {
    <# Итоговый список имён пакетов к удалению. Бросает исключение, если среди них есть защищённый. #>
    param([Parameter(Mandatory)]$Config)
    $protected = @(Get-WinIsoProp $Config.Appx 'protected' @())
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($r in @(Get-WinIsoProp $Config.Appx 'remove' @())) {
        if ((Get-WinIsoProp $r 'enabled' $false) -eq $true) { $names.Add([string]$r.name) }
    }
    foreach ($n in @(Get-WinIsoProp (Get-WinIsoProp $Config.Build 'optimization') 'user_extra_appx_remove' @())) {
        if (-not $names.Contains([string]$n)) { $names.Add([string]$n) }
    }
    foreach ($n in $names) {
        if (Test-WinIsoWildcard $n $protected) {
            throw "Пакет '$n' входит в защищённый список (appx-remove.json → protected) и не может быть удалён."
        }
        if ($n -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]+$') { throw "Недопустимое имя пакета: '$n'" }
    }
    return , $names.ToArray()
}

function Get-WinIsoTweakList {
    <# Включённые твики с проверкой схемы и запрещённых путей. #>
    param([Parameter(Mandatory)]$Config)
    $forbidden = @(Get-WinIsoProp $Config.Tweaks 'forbidden_paths' @())
    $result = @()
    foreach ($t in @(Get-WinIsoProp $Config.Tweaks 'tweaks' @())) {
        if ((Get-WinIsoProp $t 'enabled' $false) -ne $true) { continue }
        foreach ($f in 'id', 'hive', 'path', 'name', 'type', 'purpose', 'side_effect', 'undo') {
            if (-not (Get-WinIsoProp $t $f)) { throw "Твик '$(Get-WinIsoProp $t 'id' '?')': не заполнено поле '$f'." }
        }
        if ($t.hive -notin 'DefaultUser', 'Software') { throw "Твик '$($t.id)': hive должен быть DefaultUser или Software." }
        if ($t.type -notin 'REG_DWORD', 'REG_SZ', 'DELETE') { throw "Твик '$($t.id)': тип '$($t.type)' не поддерживается." }
        $full = if ($t.hive -eq 'Software') { 'SOFTWARE\' + $t.path } else { $t.path }
        foreach ($fp in $forbidden) {
            if ($full.StartsWith($fp, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Твик '$($t.id)' затрагивает запрещённый путь '$fp' (Defender/Firewall/UAC/Update/подкачка/восстановление/обход требований)."
            }
        }
        $result += $t
    }
    return , $result
}

function Get-WinIsoAppPlan {
    <#
      Проверяет apps.json и возвращает включённые программы в порядке установки
      (по полю order с учётом depends_on). Бросает исключение при ошибке схемы.
    #>
    param([Parameter(Mandatory)]$Config)
    $apps = @(@(Get-WinIsoProp $Config.Apps 'apps' @()) | Where-Object { (Get-WinIsoProp $_ 'enabled' $true) -eq $true })
    $byId = @{}
    foreach ($a in $apps) {
        foreach ($f in 'id', 'name', 'method', 'stage', 'detect') {
            if (-not (Get-WinIsoProp $a $f)) { throw "Программа '$(Get-WinIsoProp $a 'id' '?')': не заполнено поле '$f'." }
        }
        if ($byId.ContainsKey($a.id)) { throw "Повторяющийся id программы: $($a.id)" }
        if ($a.id -notmatch '^[A-Za-z0-9._-]+$') { throw "Недопустимый id программы: $($a.id)" }
        $byId[$a.id] = $a
        switch ($a.method) {
            'offline' {
                $o = Get-WinIsoProp $a 'offline'
                foreach ($f in 'file', 'type') { if (-not (Get-WinIsoProp $o $f)) { throw "Программа '$($a.id)': offline.$f не задан." } }
                if ($o.type -notin 'msi', 'exe') { throw "Программа '$($a.id)': offline.type должен быть msi или exe." }
                if ($o.file -match '[\\/]|\.\.') { throw "Программа '$($a.id)': offline.file — только имя файла." }
                if ($a.stage -notin 'setupcomplete', 'firstlogon') { throw "Программа '$($a.id)': неизвестный stage '$($a.stage)'." }
            }
            'winget' {
                $w = Get-WinIsoProp $a 'winget'
                if (-not (Get-WinIsoProp $w 'id')) { throw "Программа '$($a.id)': winget.id не задан." }
                if ($a.stage -ne 'firstlogon') {
                    throw "Программа '$($a.id)': winget доступен только после первого входа пользователя — stage должен быть firstlogon."
                }
            }
            default { throw "Программа '$($a.id)': неизвестный method '$($a.method)' (offline|winget)." }
        }
        if ($a.detect.type -notin 'uninstall_displayname', 'file', 'winget', 'msi_productcode') {
            throw "Программа '$($a.id)': неизвестный detect.type '$($a.detect.type)'."
        }
        if ($a.detect.type -eq 'winget' -and $a.method -ne 'winget') {
            throw "Программа '$($a.id)': detect.type=winget допустим только для method=winget."
        }
    }
    foreach ($a in $apps) {
        foreach ($d in @(Get-WinIsoProp $a 'depends_on' @())) {
            if (-not $byId.ContainsKey($d)) { throw "Программа '$($a.id)' зависит от отсутствующей/выключенной '$d'." }
            $dep = $byId[$d]
            if ($dep.stage -eq 'firstlogon' -and $a.stage -eq 'setupcomplete') {
                throw "Программа '$($a.id)' (setupcomplete) не может зависеть от '$d' (firstlogon)."
            }
        }
    }
    # Топологическая сортировка с приоритетом по order.
    $ordered = New-Object System.Collections.Generic.List[object]
    $done = @{}
    $visiting = @{}
    $visit = $null
    $visit = {
        param($app)
        if ($done.ContainsKey($app.id)) { return }
        if ($visiting.ContainsKey($app.id)) { throw "Циклическая зависимость у программы '$($app.id)'." }
        $visiting[$app.id] = $true
        foreach ($d in @(Get-WinIsoProp $app 'depends_on' @())) { & $visit $byId[$d] }
        $visiting.Remove($app.id)
        $done[$app.id] = $true
        $ordered.Add($app)
    }
    foreach ($a in ($apps | Sort-Object { [int](Get-WinIsoProp $_ 'order' 1000) }, { $_.id })) { & $visit $a }
    return , $ordered.ToArray()
}

function Get-WinIsoConfigProblems {
    <# Список незаполненных обязательных параметров и ошибок конфигурации (пустой — всё в порядке). #>
    param([Parameter(Mandatory)]$Config)
    $p = New-Object System.Collections.Generic.List[string]
    $b = $Config.Build
    $required = [ordered]@{
        'source.iso_path'     = 'путь к оригинальному ISO'
        'target.windows'      = 'версия Windows'
        'target.language'     = 'язык'
        'paths.work_dir'      = 'рабочая папка'
        'paths.output_iso'    = 'путь к готовому ISO'
    }
    foreach ($k in $required.Keys) {
        $sec, $name = $k.Split('.')
        if (-not (Get-WinIsoProp (Get-WinIsoProp $b $sec) $name)) { $p.Add("Не указан параметр $k — $($required[$k]).") }
    }
    $eds = @(Get-WinIsoProp (Get-WinIsoProp $b 'target') 'editions' @())
    if ($eds.Count -eq 0) { $p.Add('Не указан параметр target.editions — редакции (EditionId, например Core = Домашняя, Professional = Pro).') }
    foreach ($e in $eds) { if ("$e" -notmatch '^[A-Za-z]+$') { $p.Add("target.editions: недопустимый EditionId '$e'.") } }
    if (@($eds | Select-Object -Unique).Count -ne $eds.Count) { $p.Add('target.editions: повторяющиеся значения.') }
    $arch = Get-WinIsoProp (Get-WinIsoProp $b 'target') 'architecture'
    if ($arch -notin 'amd64', 'arm64') { $p.Add("target.architecture должен быть amd64 или arm64 (сейчас '$arch').") }
    $label = Get-WinIsoProp (Get-WinIsoProp $b 'target') 'volume_label' ''
    if ($label -notmatch '^[A-Z0-9_]{1,32}$') { $p.Add("target.volume_label: только A-Z, 0-9, _ (до 32 символов).") }
    foreach ($check in @(
            { [void](Get-WinIsoAppxRemovalList $Config) },
            { [void](Get-WinIsoTweakList $Config) },
            { [void](Get-WinIsoAppPlan $Config) })) {
        try { & $check } catch { $p.Add($_.Exception.Message) }
    }
    if (@(Get-WinIsoProp $Config.Apps 'apps' @()).Count -eq 0) {
        $p.Add('Список программ (config\apps.json) пуст. Если программы не нужны — это допустимо, иначе заполните его.')
    }
    return , $p.ToArray()
}

function Test-WinIsoInstallerFile {
    <# Проверяет SHA-256 и подпись Authenticode установщика. Возвращает объект с результатами. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedSha256,
        [string]$ExpectedSigner,
        [bool]$RequireSha256 = $true,
        [bool]$RequireAuthenticode = $true
    )
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $r = [ordered]@{ Path = $Path; Sha256 = $hash; HashStatus = ''; SignatureStatus = ''; Signer = ''; Version = ''; Ok = $true; Notes = @() }
    if ($ExpectedSha256) {
        if ($hash -eq $ExpectedSha256.ToLowerInvariant()) { $r.HashStatus = 'match' }
        else { $r.HashStatus = 'MISMATCH'; $r.Ok = $false; $r.Notes += "SHA-256 не совпадает: ожидался $ExpectedSha256" }
    } else {
        $r.HashStatus = 'not-pinned'
        if ($RequireSha256) { $r.Ok = $false; $r.Notes += 'SHA-256 не закреплён в apps.json (запустите Get-Installers.ps1 -Pin после проверки подписи).' }
    }
    if (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue) {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path
        $r.SignatureStatus = [string]$sig.Status
        if ($sig.SignerCertificate) { $r.Signer = $sig.SignerCertificate.Subject }
        if ($sig.Status -ne 'Valid') {
            if ($RequireAuthenticode) { $r.Ok = $false }
            $r.Notes += "Подпись Authenticode: $($sig.Status)"
        } elseif ($ExpectedSigner -and ($r.Signer -notlike "*$ExpectedSigner*")) {
            $r.Ok = $false; $r.Notes += "Неожиданный издатель: $($r.Signer)"
        }
    } else {
        $r.SignatureStatus = 'unavailable'
        if ($RequireAuthenticode) { $r.Ok = $false; $r.Notes += 'Проверка Authenticode недоступна на этой платформе.' }
    }
    try {
        $vi = (Get-Item -LiteralPath $Path).VersionInfo
        if ($vi -and $vi.ProductVersion) { $r.Version = $vi.ProductVersion.Trim() }
    } catch { }
    return [pscustomobject]$r
}

function Get-WinIsoFreeSpaceGB {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $drive = New-Object IO.DriveInfo $root
    return [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
}

Export-ModuleMember -Function *-WinIso*
