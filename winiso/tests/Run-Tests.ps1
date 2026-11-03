#Requires -Version 5.1
<#
  Проверки PowerShell-части без Windows-специфичных операций (работают в pwsh на Linux/macOS/Windows):
  синтаксис всех скриптов, валидация конфигурации, защитные ограничения, файл ответов, режим плана.
  Запуск: pwsh -NoProfile -File tests/Run-Tests.ps1
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $Root 'scripts/WinIso.Common.psm1') -Force
$script:fail = 0; $script:count = 0
function Assert([string]$Name, [scriptblock]$Test) {
    $script:count++
    try { $r = & $Test; if ($r -ne $true) { throw "результат: $r" }; Write-Host "[OK]   $Name" -ForegroundColor Green }
    catch { $script:fail++; Write-Host "[FAIL] $Name — $($_.Exception.Message)" -ForegroundColor Red }
}
function Throws([scriptblock]$Block, [string]$Like) {
    try { & $Block } catch { if ($_.Exception.Message -like $Like) { return $true } else { throw "другое исключение: $($_.Exception.Message)" } }
    throw 'исключения не было'
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('winiso-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
function New-TestConfig([scriptblock]$Mutate) {
    $d = Join-Path $tmp ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $d | Out-Null
    Copy-Item (Join-Path $Root 'config/*.json') $d
    Copy-Item (Join-Path $d 'apps.example.json') (Join-Path $d 'apps.json') -Force
    $b = Get-Content (Join-Path $d 'build.json') -Raw | ConvertFrom-Json
    $b.source.iso_path = 'C:\iso\Win11.iso'; $b.target.windows = 'Windows 11 25H2'; $b.target.edition_name = 'Windows 11 Pro'
    $b.target.language = 'ru-RU'; $b.paths.work_dir = 'D:\WinBuild'; $b.paths.output_iso = 'D:\WinBuild\out\custom.iso'
    $b | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $d 'build.json') -Encoding UTF8
    if ($Mutate) { & $Mutate $d }
    return (Join-Path $d 'build.json')
}
function Edit-Json([string]$Path, [scriptblock]$Edit) {
    $j = Get-Content $Path -Raw | ConvertFrom-Json; & $Edit $j; $j | ConvertTo-Json -Depth 10 | Set-Content $Path -Encoding UTF8
}

try {
    # 1. Синтаксис и кодировка
    foreach ($f in Get-ChildItem -Path $Root -Recurse -Include *.ps1, *.psm1) {
        Assert "Синтаксис $($f.Name)" {
            $errs = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
            if ($errs) { throw ($errs | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ' }
            $true
        }
        Assert "UTF-8 BOM в $($f.Name) (для Windows PowerShell 5.1)" {
            $b = [IO.File]::ReadAllBytes($f.FullName); ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
        }
    }
    Assert 'SetupComplete.cmd: только ASCII, CRLF' {
        $b = [IO.File]::ReadAllBytes((Join-Path $Root 'payload/SetupComplete.cmd'))
        (-not ($b | Where-Object { $_ -gt 127 })) -and ([Text.Encoding]::ASCII.GetString($b) -match "`r`n")
    }

    # 2. Текущая конфигурация: неполная, это ожидаемо до ответов пользователя
    $cfg = Import-WinIsoConfig (Join-Path $Root 'config/build.json')
    $p = Get-WinIsoConfigProblems $cfg
    Assert 'Текущий build.json: обнаружены незаполненные параметры' { @($p | Where-Object { $_ -like '*source.iso_path*' }).Count -eq 1 -and @($p | Where-Object { $_ -like '*edition_name*' }).Count -eq 1 }

    # 3. Полная тестовая конфигурация проходит
    $ok = Import-WinIsoConfig (New-TestConfig)
    Assert 'Полная конфигурация без проблем' { (Get-WinIsoConfigProblems $ok).Count -eq 0 }
    Assert 'Порядок программ по order' { ((Get-WinIsoAppPlan $ok).id -join ',') -eq 'vcredist-x64,firefox,vlc,notepadplusplus' }
    Assert 'Зависимость поднимает программу раньше' {
        $c = Import-WinIsoConfig (New-TestConfig { param($d) Edit-Json "$d/apps.json" { param($j) $j.apps[0].depends_on = @('firefox') } })
        ((Get-WinIsoAppPlan $c).id[0..1] -join ',') -eq 'firefox,vcredist-x64'
    }
    Assert 'Твики: включено 8, все поля заполнены' { (Get-WinIsoTweakList $ok).Count -eq 8 }
    Assert 'Удаление приложений: 14 по умолчанию' { (Get-WinIsoAppxRemovalList $ok).Count -eq 14 }

    # 4. Защитные ограничения
    Assert 'Защищённый пакет (Store) нельзя удалить' {
        $c = Import-WinIsoConfig (New-TestConfig { param($d) Edit-Json "$d/build.json" { param($j) $j.optimization.user_extra_appx_remove = @('Microsoft.WindowsStore') } })
        Throws { Get-WinIsoAppxRemovalList $c } '*защищённый*'
    }
    Assert 'Защищённый пакет по шаблону (VCLibs)' {
        $c = Import-WinIsoConfig (New-TestConfig { param($d) Edit-Json "$d/build.json" { param($j) $j.optimization.user_extra_appx_remove = @('Microsoft.VCLibs.140.00') } })
        Throws { Get-WinIsoAppxRemovalList $c } '*защищённый*'
    }
    foreach ($bad in @(
            @{ hive = 'Software'; path = 'Policies\Microsoft\Windows Defender'; name = 'DisableAntiSpyware' },
            @{ hive = 'Software'; path = 'Microsoft\Windows\CurrentVersion\Policies\System'; name = 'EnableLUA' },
            @{ hive = 'Software'; path = 'Policies\Microsoft\Windows\WindowsUpdate\AU'; name = 'NoAutoUpdate' })) {
        Assert "Запрещённый твик $($bad.name) отклоняется" {
            $c = Import-WinIsoConfig (New-TestConfig { param($d) Edit-Json "$d/tweaks.json" { param($j)
                        $j.tweaks += [pscustomobject]@{ id = 'bad'; enabled = $true; hive = $bad.hive; path = $bad.path; name = $bad.name; type = 'REG_DWORD'; value = 1; purpose = 'x'; side_effect = 'x'; undo = 'x' } } })
            Throws { Get-WinIsoTweakList $c } '*запрещённый*'
        }
    }
    Assert 'Твик без описания побочного эффекта отклоняется' {
        $c = Import-WinIsoConfig (New-TestConfig { param($d) Edit-Json "$d/tweaks.json" { param($j) $j.tweaks[0].side_effect = '' } })
        Throws { Get-WinIsoTweakList $c } '*side_effect*'
    }
    Assert 'winget на этапе setupcomplete отклоняется' {
        $c = Import-WinIsoConfig (New-TestConfig { param($d) Edit-Json "$d/apps.json" { param($j) $j.apps[2].stage = 'setupcomplete' } })
        Throws { Get-WinIsoAppPlan $c } '*firstlogon*'
    }
    Assert 'Циклическая зависимость обнаруживается' {
        $c = Import-WinIsoConfig (New-TestConfig { param($d) Edit-Json "$d/apps.json" { param($j) $j.apps[2].depends_on = @('notepadplusplus'); $j.apps[3].depends_on = @('vlc') } })
        Throws { Get-WinIsoAppPlan $c } '*Циклическая*'
    }
    Assert 'Имя файла установщика с путём отклоняется' {
        $c = Import-WinIsoConfig (New-TestConfig { param($d) Edit-Json "$d/apps.json" { param($j) $j.apps[0].offline.file = '..\evil.exe' } })
        Throws { Get-WinIsoAppPlan $c } '*только имя файла*'
    }

    # 5. Файл ответов
    $xmlText = (Get-Content (Join-Path $Root 'unattend/autounattend.template.xml') -Raw).Replace('{{ARCH}}', 'amd64').Replace('{{FIRST_LOGON_SCRIPT}}', 'C:\ProgramData\WinIsoDeploy\Deploy-Apps.ps1')
    Assert 'autounattend: корректный XML, только oobeSystem' { [xml]$x = $xmlText; (@($x.unattend.settings).pass -join ',') -eq 'oobeSystem' }
    Assert 'autounattend: нет разметки дисков, ключей, учёток, обходов' {
        -not ($xmlText -match 'DiskConfiguration|InstallTo|WillWipeDisk|ProductKey|Password|AutoLogon|UserAccounts|BypassTPM|BypassSecureBoot|BypassRAM|LabConfig')
    }

    # 6. Режим плана (не требует Windows)
    $pw = (Get-Process -Id $PID).Path
    Assert 'Build-WinIso -PlanOnly: неполная конфигурация → код 2' {
        & $pw -NoProfile -File (Join-Path $Root 'scripts/Build-WinIso.ps1') -PlanOnly *> $null; $LASTEXITCODE -eq 2
    }
    Assert 'Build-WinIso -PlanOnly: полная конфигурация → код 0' {
        & $pw -NoProfile -File (Join-Path $Root 'scripts/Build-WinIso.ps1') -PlanOnly -ConfigPath (New-TestConfig) *> $null; $LASTEXITCODE -eq 0
    }
    if ($env:OS -ne 'Windows_NT') {
        Assert 'Build-WinIso без -PlanOnly вне Windows отказывается' {
            $out = & $pw -NoProfile -File (Join-Path $Root 'scripts/Build-WinIso.ps1') -ConfigPath (New-TestConfig) 2>&1 | Out-String
            ($LASTEXITCODE -ne 0) -and ($out -match 'только на Windows')
        }
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ("Итого: {0} проверок, ошибок: {1}" -f $script:count, $script:fail)
if ($script:fail) { exit 1 }
