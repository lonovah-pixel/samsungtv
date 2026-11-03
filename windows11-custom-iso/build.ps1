<#
.SYNOPSIS
  Builds a customised Windows 11 installation ISO (default: Windows 11 Pro x64 ru-RU)
  with bundled offline application installers that are installed after deployment.

.DESCRIPTION
  Reference pipeline (Windows host, elevated Windows PowerShell 5.1):
    DISM PowerShell module + Oscdimg from Windows ADK Deployment Tools.
  Fallback pipeline (Linux/WSL, PowerShell 7): wimlib-imagex + xorriso + 7z.
    The fallback is NOT equivalent: no DISM, ISO built without Oscdimg, install.wim
    is split into .swm parts. It is reported as a deviation in the build manifest.

  Steps: environment check -> source ISO (download + SHA-256 against a published
  reference) -> application installers (vendor URLs, SHA-256, Authenticode) ->
  extract ISO -> detect edition index from metadata -> export the single edition ->
  add the post-install payload into the image -> ISO with the original boot images ->
  verification -> SHA-256 + manifest.

  Nothing outside the project folder is modified, except temporary virtual mounts
  (ISO mount and DISM mount on Windows) which are always released, also on failure.

.PARAMETER ConfigPath    Path to config.json (default: next to this script).
.PARAMETER Backend       Auto | Windows | Linux.
.PARAMETER CheckOnly     Only run the environment check.
.PARAMETER AllowUnverifiedSource
  Continue when config has no reference SHA-256 for the source ISO. The manifest
  then records the source as NOT verified. Never overrides a hash MISMATCH.
.PARAMETER KeepWorkDir   Keep work\ after a successful build.
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [ValidateSet('Auto', 'Windows', 'Linux')][string]$Backend = 'Auto',
    [switch]$CheckOnly,
    [switch]$AllowUnverifiedSource,
    [switch]$KeepWorkDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$ProjectRoot = $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $ProjectRoot 'config.json' }
. (Join-Path $ProjectRoot 'scripts/BuildCommon.ps1')
. (Join-Path $ProjectRoot 'scripts/AppInstallers.ps1')

$cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$WorkDir = Resolve-ProjectPath $ProjectRoot $cfg.project.workDir
$DownloadsDir = Resolve-ProjectPath $ProjectRoot $cfg.project.downloadsDir
$LogsDir = Resolve-ProjectPath $ProjectRoot $cfg.project.logsDir
$OutputDir = Resolve-ProjectPath $ProjectRoot $cfg.project.outputDir
foreach ($d in @($DownloadsDir, $LogsDir, $OutputDir)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Initialize-BuildLog (Join-Path $LogsDir "build-$Stamp.log")

# Safety: the work directory must live inside the project folder (it gets deleted).
$rootFull = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
if (-not ([System.IO.Path]::GetFullPath($WorkDir).StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar))) {
    throw "project.workDir must be inside the project folder: $WorkDir"
}

$script:MountedIsoPath = $null     # Windows: ISO attached with Mount-DiskImage
$script:DismMountDir = $null       # Windows: DISM mount directory
$Warnings = New-Object System.Collections.ArrayList
$Manifest = [ordered]@{
    buildId = $Stamp; startedAt = (Get-Date).ToString('s'); host = [System.Environment]::MachineName
    backend = $null; config = (Split-Path -Leaf $ConfigPath)
}

function Add-BuildWarning([string]$Text) { [void]$Warnings.Add($Text); Write-Log $Text 'WARN' }

function Find-PathCI {
    # Case-insensitive relative path lookup (Linux extraction keeps original case).
    param([string]$Root, [string]$Relative)
    $cur = $Root
    foreach ($seg in ($Relative -split '[\\/]')) {
        if ($seg -eq '') { continue }
        $hit = Get-ChildItem -LiteralPath $cur -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq $seg } | Select-Object -First 1
        if (-not $hit) { return $null }
        $cur = $hit.FullName
    }
    return $cur
}

function Get-RelativePath([string]$Root, [string]$Full) {
    $r = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    return $Full.Substring($r.Length + 1)
}

function ConvertTo-ArchName($a) {
    $s = "$a"
    switch -Regex ($s) { '^(9|x64|amd64)$' { return 'x64' } '^(12|arm64)$' { return 'arm64' } '^(0|x86)$' { return 'x86' } default { return $s } }
}

# ------------------------------------------------------------- source ISO ---
function Get-SourceIso {
    Write-Log 'Source ISO' 'STEP'
    $src = $cfg.source
    $info = [ordered]@{ pageUrl = $src.pageUrl; downloadUrl = $null; localIsoPath = $null; path = $null; sha256 = $null
        expectedSha256 = $null; expectedSha256Reference = $src.expectedSha256Reference; authenticityVerified = $false }
    if ($src.localIsoPath) {
        $p = Resolve-ProjectPath $ProjectRoot $src.localIsoPath
        if (-not (Test-Path -LiteralPath $p)) { throw "source.localIsoPath not found: $p" }
        $info.localIsoPath = $p; $info.path = $p
    }
    elseif ($src.downloadUrl) {
        $u = [uri]$src.downloadUrl
        if ($u.Scheme -ne 'https') { throw 'source.downloadUrl must be https' }
        $name = [uri]::UnescapeDataString($u.Segments[-1])
        if ($name -notmatch '\.iso$') { $name = 'source.iso' }
        $p = Join-Path (Join-Path $DownloadsDir 'iso') $name
        $info.downloadUrl = $src.downloadUrl; $info.path = $p
        $reuse = ((Test-Path -LiteralPath $p) -and $src.expectedSha256 -and ((Get-Sha256 $p) -eq $src.expectedSha256.ToUpperInvariant()))
        if ($reuse) { Write-Log "Reusing verified download $p" } else { Invoke-Download -Uri $src.downloadUrl -OutFile $p }
    }
    else {
        throw ('No source ISO configured. Set source.downloadUrl (ru-ru x64 consumer ISO link from the Genuine Installation Media page ' +
            $src.pageUrl + ') or source.localIsoPath (ISO from https://www.microsoft.com/ru-ru/software-download/windows11), and source.expectedSha256 (hash published by Microsoft for that file).')
    }
    $fileName = Split-Path -Leaf $info.path
    if (-not $cfg.windows.allowInsider -and $fileName -match '(?i)insider|preview|canary|flight') {
        throw "Source file name '$fileName' looks like an Insider/preview build; allowInsider is false."
    }
    Write-Log "Computing SHA-256 of $($info.path) ..."
    $info.sha256 = Get-Sha256 $info.path
    Write-Log "Source SHA-256: $($info.sha256)"
    if ($src.expectedSha256) {
        $info.expectedSha256 = $src.expectedSha256.ToUpperInvariant()
        if ($info.sha256 -ne $info.expectedSha256) {
            throw "SOURCE ISO SHA-256 MISMATCH. expected $($info.expectedSha256) ($($src.expectedSha256Reference)), got $($info.sha256). Build stopped; the file is not used."
        }
        $info.authenticityVerified = $true
        Write-Log "Source SHA-256 matches the reference ($($src.expectedSha256Reference))." 'OK'
    }
    elseif ($AllowUnverifiedSource) {
        Add-BuildWarning 'Source ISO authenticity NOT verified: no reference SHA-256 in config (-AllowUnverifiedSource). The SHA-256 above is only a self-computed fingerprint.'
    }
    else {
        throw 'source.expectedSha256 is empty: authenticity of the source ISO cannot be verified. Put the SHA-256 published by Microsoft for this exact file into config.json (or rerun with -AllowUnverifiedSource to proceed knowingly).'
    }
    $info.fileName = $fileName
    $info.size = (Get-Item -LiteralPath $info.path).Length
    return $info
}

# ---------------------------------------------------------- applications ---
function Get-Applications {
    Write-Log 'Application installers' 'STEP'
    $list = @()
    foreach ($app in @($cfg.apps | Where-Object { $_.enabled })) {
        $list += Get-AppInstaller -App $app -DownloadRoot (Join-Path $DownloadsDir 'apps') -ProjectRoot $ProjectRoot
    }
    Write-JsonFile -Object $list -Path (Join-Path $DownloadsDir 'apps/manifest.json')
    return $list
}

# ----------------------------------------------------------- extraction ---
function Expand-SourceIso([string]$IsoPath, [string]$Target, [string]$BackendName) {
    Write-Log "Extracting ISO to $Target" 'STEP'
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
    if ($BackendName -eq 'Windows') {
        $img = Mount-DiskImage -ImagePath $IsoPath -Access ReadOnly -StorageType ISO -PassThru
        $script:MountedIsoPath = $IsoPath
        $letter = $null
        for ($i = 0; $i -lt 30 -and -not $letter; $i++) { $letter = ($img | Get-Volume).DriveLetter; if (-not $letter) { Start-Sleep 1 } }
        if (-not $letter) { throw 'Mounted ISO did not get a drive letter' }
        $srcRoot = "$($letter):\"
        $robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
        $a = "$(Format-NativeArg ($srcRoot + '.')) $(Format-NativeArg $Target) /E /XF install.wim install.esd install*.swm /R:1 /W:1 /NFL /NDL /NP /NJH"
        Invoke-Native -FilePath $robocopy -Arguments $a -SuccessCodes @(0, 1, 2, 3) | Out-Null
        Get-ChildItem -LiteralPath $Target -Recurse -File -Force | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
        foreach ($n in @('install.wim', 'install.esd')) {
            $p = Join-Path $srcRoot "sources\$n"
            if (Test-Path -LiteralPath $p) { return $p }
        }
        if (Test-Path (Join-Path $srcRoot 'sources\install.swm')) { throw 'Split install.swm source media is not supported by the Windows backend; use a standard ISO.' }
        throw 'No sources\install.wim or install.esd in the source ISO'
    }
    else {
        $7z = @(Get-Command 7z -CommandType Application)[0].Source
        $list = Invoke-Native -FilePath $7z -Arguments "l -slt $(Format-NativeArg $IsoPath)" -Quiet
        $paths = @($list.StdOut | Where-Object { $_ -like 'Path = *' } | ForEach-Object { $_.Substring(7) -replace '\\', '/' })
        $wimRel = $paths | Where-Object { $_ -imatch '^sources/install\.(wim|esd)$' } | Select-Object -First 1
        if (-not $wimRel) { throw 'No sources/install.wim or install.esd in the source ISO' }
        Invoke-Native -FilePath $7z -Arguments ("x $(Format-NativeArg $IsoPath) -o$(Format-NativeArg $Target) -y -bd " +
            "-x!sources/install.wim -x!sources/install.esd -x!sources/install*.swm") -Quiet | Out-Null
        $srcDir = Join-Path $WorkDir 'src'
        New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
        Invoke-Native -FilePath $7z -Arguments "e $(Format-NativeArg $IsoPath) -o$(Format-NativeArg $srcDir) -y -bd $(Format-NativeArg $wimRel)" -Quiet | Out-Null
        return (Join-Path $srcDir (Split-Path -Leaf $wimRel))
    }
}

function Test-SourceBootFiles([string]$IsoTree, [string]$BackendName) {
    Write-Log 'Checking source boot files and signatures' 'STEP'
    $required = @('setup.exe', 'bootmgr', 'bootmgr.efi', 'boot/etfsboot.com', 'efi/boot/bootx64.efi', 'efi/microsoft/boot/efisys.bin', 'sources/boot.wim')
    foreach ($r in $required) { if (-not (Find-PathCI $IsoTree $r)) { throw "Source ISO is missing $r" } }
    if (Find-PathCI $IsoTree 'autounattend.xml') { throw 'Source ISO already contains autounattend.xml; refusing to overwrite it.' }
    if (-not $cfg.source.verifyBootFileSignatures) { Add-BuildWarning 'Boot file signature check disabled in config.'; return @() }
    $res = @()
    foreach ($r in @('setup.exe', 'efi/boot/bootx64.efi', 'bootmgr.efi')) {
        $p = Find-PathCI $IsoTree $r
        $sig = Test-FileSignature -Path $p -SubjectPattern 'Microsoft'
        Write-Log ("  {0}: {1}; {2}" -f $r, $sig.Status, $sig.Signer)
        $res += [pscustomobject]@{ file = $r; status = $sig.Status; signer = $sig.Signer }
        if ($sig.Status -eq 'Valid' -and $sig.SubjectMatches) { continue }
        if ($BackendName -eq 'Linux' -and $sig.Status -eq 'UntrustedRoot') {
            Add-BuildWarning "$r : signature digest OK but Microsoft root is not in the Linux trust store (chain not validated here)."
            continue
        }
        if ($r -ne 'setup.exe' -and $sig.Status -ne 'NotSigned' -and $sig.Status -ne 'Invalid' -and $sig.Signer -match 'Microsoft') {
            # UEFI binaries may chain to UEFI CA roots that are not in the host code-signing store.
            Add-BuildWarning "$r : Microsoft-signed, but chain status on this host is $($sig.Status); authenticity relies on the ISO SHA-256."
            continue
        }
        throw "$r : Microsoft signature check failed (status $($sig.Status), signer '$($sig.Signer)')"
    }
    return $res
}

# -------------------------------------------------------- image metadata ---
function Get-ImageList([string]$WimPath, [string]$BackendName) {
    $out = @()
    if ($BackendName -eq 'Windows') {
        foreach ($i in @(Get-WindowsImage -ImagePath $WimPath)) {
            $d = Get-WindowsImage -ImagePath $WimPath -Index $i.ImageIndex
            $out += [pscustomobject]@{
                Index = [int]$d.ImageIndex; Name = $d.ImageName; EditionId = $d.EditionId
                Arch = (ConvertTo-ArchName $d.Architecture); Languages = @($d.Languages); Version = "$($d.Version)"
                Build = [int](("$($d.Version)" -split '\.')[2])
            }
        }
    }
    else {
        $xmlFile = Join-Path $WorkDir 'wiminfo.xml'
        Invoke-Native -FilePath 'wimlib-imagex' -Arguments "info $(Format-NativeArg $WimPath) --extract-xml $(Format-NativeArg $xmlFile)" -Quiet | Out-Null
        [xml]$x = [System.IO.File]::ReadAllText($xmlFile, [System.Text.Encoding]::Unicode)
        foreach ($img in @($x.SelectNodes('/WIM/IMAGE'))) {
            $t = { param($xp) $n = $img.SelectSingleNode($xp); if ($n) { $n.InnerText } else { '' } }
            $langs = @($img.SelectNodes('WINDOWS/LANGUAGES/LANGUAGE') | ForEach-Object { $_.InnerText })
            $ed = & $t 'WINDOWS/EDITIONID'
            $arch = ConvertTo-ArchName (& $t 'WINDOWS/ARCH')
            $build = 0; $ver = ''
            $b = & $t 'WINDOWS/VERSION/BUILD'
            if ($b) { $build = [int]$b; $ver = '{0}.{1}.{2}.{3}' -f (& $t 'WINDOWS/VERSION/MAJOR'), (& $t 'WINDOWS/VERSION/MINOR'), $b, (& $t 'WINDOWS/VERSION/SPBUILD') }
            $out += [pscustomobject]@{ Index = [int]$img.GetAttribute('INDEX'); Name = (& $t 'NAME'); EditionId = $ed; Arch = $arch; Languages = $langs; Version = $ver; Build = $build }
        }
    }
    return $out
}

function Select-Edition([object[]]$Images) {
    Write-Log 'Images in source:' 'STEP'
    foreach ($i in $Images) { Write-Log ("  [{0}] {1} | EditionId={2} | {3} | {4} | {5}" -f $i.Index, $i.Name, $i.EditionId, $i.Arch, ($i.Languages -join ','), $i.Version) }
    $want = $cfg.windows
    $hits = @($Images | Where-Object { $_.EditionId -eq $want.editionId -and $_.Arch -eq $want.architecture -and (@($_.Languages) -contains $want.language) })
    if ($hits.Count -ne 1) {
        throw ("Expected exactly one image with EditionId={0}, arch={1}, language={2}; found {3}." -f $want.editionId, $want.architecture, $want.language, $hits.Count)
    }
    $sel = $hits[0]
    if ($sel.Build -lt [int]$want.minBuild) { throw "Selected image build $($sel.Build) is older than minBuild $($want.minBuild)." }
    Write-Log ("Selected index {0}: {1} ({2})" -f $sel.Index, $sel.Name, $sel.Version) 'OK'
    return $sel
}

# ---------------------------------------------------------------- payload ---
function New-Payload([object[]]$Apps, [string]$Target) {
    Write-Log 'Staging post-install payload' 'STEP'
    $scripts = Join-Path $Target 'Windows/Setup/Scripts'
    $ci = Join-Path $scripts 'CustomImage'
    $appsDir = Join-Path $ci 'Apps'
    New-Item -ItemType Directory -Path $appsDir -Force | Out-Null
    $payloadSrc = Join-Path $ProjectRoot 'scripts/payload'
    foreach ($pair in @(@('SetupComplete.cmd', $scripts), @('CustomImage/Register.cmd', $ci))) {
        $text = [System.IO.File]::ReadAllText((Join-Path $payloadSrc $pair[0]))
        $text = ($text -replace "`r`n", "`n") -replace "`n", "`r`n"   # CMD files need CRLF
        [System.IO.File]::WriteAllText((Join-Path $pair[1] (Split-Path -Leaf $pair[0])), $text, (New-Object System.Text.ASCIIEncoding))
    }
    Copy-Item -LiteralPath (Join-Path $payloadSrc 'CustomImage/Invoke-PostInstall.ps1') -Destination $ci -Force

    $appEntries = @()
    foreach ($a in $Apps) {
        $ext = [System.IO.Path]::GetExtension($a.fileName)
        $safe = ('{0}-{1}{2}' -f $a.id, ($a.version -replace '[^0-9A-Za-z.\-]', '_'), $ext)
        Copy-Item -LiteralPath $a.path -Destination (Join-Path $appsDir $safe) -Force
        $appEntries += [ordered]@{ id = $a.id; name = $a.name; version = $a.version; file = $safe; sha256 = $a.sha256
            type = $a.installerType; silentArgs = $a.silentArgs; detectPath = $a.detectPath }
    }
    $tweaks = @($cfg.tweaks | Where-Object { $_.enabled } | ForEach-Object {
            [ordered]@{ id = $_.id; hive = $_.hive; key = $_.key; name = $_.name; type = $_.type; value = $_.value } })
    $neverRemove = @($cfg.appxRemoval.neverRemove)
    $clash = @($cfg.appxRemoval.packages | Where-Object { $neverRemove -contains $_ })
    if ($clash.Count -gt 0) { throw "appxRemoval.packages contains protected packages: $($clash -join ', ')" }
    $pi = [ordered]@{
        generatedBy = "build.ps1 $Stamp"
        maxAttempts = [int]$cfg.postInstall.maxAttempts
        deleteInstallersAfterSuccess = [bool]$cfg.postInstall.deleteInstallersAfterSuccess
        apps = $appEntries
        appx = [ordered]@{ enabled = [bool]$cfg.appxRemoval.enabled; packages = @($cfg.appxRemoval.packages); neverRemove = $neverRemove }
        tweaks = $tweaks
    }
    Write-JsonFile -Object $pi -Path (Join-Path $ci 'postinstall.json')
    return $scripts
}

# ------------------------------------------------------------ image work ---
function Export-Edition([string]$SourceWim, [int]$Index, [string]$DestWim, [string]$BackendName) {
    Write-Log "Exporting index $Index to $DestWim" 'STEP'
    if (Test-Path -LiteralPath $DestWim) { Remove-Item -LiteralPath $DestWim -Force }
    if ($BackendName -eq 'Windows') {
        Export-WindowsImage -SourceImagePath $SourceWim -SourceIndex $Index -DestinationImagePath $DestWim -CompressionType max -CheckIntegrity | Out-Null
    } else {
        Invoke-Native -FilePath 'wimlib-imagex' -Arguments "export $(Format-NativeArg $SourceWim) $Index $(Format-NativeArg $DestWim) --compress=LZX --check" | Out-Null
    }
}

function Update-ImageWindows([string]$Wim, [string]$PayloadScripts, [string]$IsoTree) {
    $mount = Join-Path $WorkDir 'mount'
    New-Item -ItemType Directory -Path $mount -Force | Out-Null
    Write-Log "Mounting $Wim at $mount" 'STEP'
    Mount-WindowsImage -ImagePath $Wim -Index 1 -Path $mount -CheckIntegrity | Out-Null
    $script:DismMountDir = $mount
    $target = Join-Path $mount 'Windows\Setup\Scripts'
    if (Test-Path -LiteralPath (Join-Path $target 'SetupComplete.cmd')) { throw 'Image already contains Windows\Setup\Scripts\SetupComplete.cmd; refusing to overwrite.' }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Copy-Item -Path (Join-Path $PayloadScripts '*') -Destination $target -Recurse -Force
    Write-Log 'Payload copied to Windows\Setup\Scripts' 'OK'

    $prov = @(Get-AppxProvisionedPackage -Path $mount)
    $prov | Sort-Object DisplayName | ForEach-Object { "$($_.DisplayName)`t$($_.PackageName)" } |
        Set-Content -LiteralPath (Join-Path $LogsDir "provisioned-appx-$Stamp.txt") -Encoding UTF8
    foreach ($n in @($cfg.appxRemoval.packages)) {
        $present = [bool]($prov | Where-Object { $_.DisplayName -eq $n })
        Write-Log ("  provisioned {0}: {1}" -f $n, $(if ($present) { 'present (will be removed after deployment)' } else { 'not in this build' }))
    }
    if ($cfg.image.enableNetFx3) {
        $sxs = Join-Path $IsoTree 'sources\sxs'
        Write-Log 'Enabling NetFx3 from sources\sxs' 'STEP'
        Enable-WindowsOptionalFeature -Path $mount -FeatureName NetFx3 -All -LimitAccess -Source $sxs | Out-Null
    }
    if ($cfg.image.componentCleanupResetBase) {
        Add-BuildWarning 'IRREVERSIBLE: StartComponentCleanup /ResetBase - installed updates in the image can no longer be uninstalled.'
        Repair-WindowsImage -Path $mount -StartComponentCleanup -ResetBase | Out-Null
    }
    Write-Log 'Committing and unmounting image' 'STEP'
    Dismount-WindowsImage -Path $mount -Save -CheckIntegrity | Out-Null
    $script:DismMountDir = $null
}

function Update-ImageLinux([string]$Wim, [string]$PayloadScripts) {
    if ($cfg.image.enableNetFx3 -or $cfg.image.componentCleanupResetBase) {
        throw 'image.enableNetFx3 / image.componentCleanupResetBase need DISM (Windows backend).'
    }
    if ($PayloadScripts.Contains("'")) { throw 'Work path must not contain single quotes.' }
    $probe = Invoke-Native -FilePath 'wimlib-imagex' -Arguments "dir $(Format-NativeArg $Wim) 1 --path=/Windows/Setup/Scripts" -AllowAnyExitCode -Quiet
    if ($probe.ExitCode -eq 0 -and ($probe.StdOut -match '(?i)SetupComplete\.cmd$')) { throw 'Image already contains Windows\Setup\Scripts\SetupComplete.cmd; refusing to overwrite.' }
    Write-Log 'Adding payload with wimlib-imagex update' 'STEP'
    $cmd = "--command=`"add '$PayloadScripts' '/Windows/Setup/Scripts'`""
    Invoke-Native -FilePath 'wimlib-imagex' -Arguments "update $(Format-NativeArg $Wim) 1 --check $cmd" | Out-Null
    Add-BuildWarning 'Linux backend: provisioned Appx list of the image was not inspected at build time (no DISM); removal happens after deployment with presence and dependency checks.'
}

function Test-StagedImage([string]$Wim, [string]$BackendName, $Selected) {
    Write-Log "Verifying staged image $Wim" 'STEP'
    if ($BackendName -eq 'Linux') { Invoke-Native -FilePath 'wimlib-imagex' -Arguments "verify $(Format-NativeArg $Wim)" | Out-Null }
    $imgs = @(Get-ImageList $Wim $BackendName)
    if ($imgs.Count -ne 1) { throw "Staged image must contain exactly 1 index, found $($imgs.Count)" }
    $i = $imgs[0]
    if ($i.EditionId -ne $cfg.windows.editionId -or $i.Arch -ne $cfg.windows.architecture -or -not (@($i.Languages) -contains $cfg.windows.language)) {
        throw "Staged image metadata unexpected: $($i.EditionId) $($i.Arch) $($i.Languages -join ',')"
    }
    Write-Log ("Staged image OK: {0} {1} {2} {3}" -f $i.Name, $i.EditionId, $i.Arch, $i.Version) 'OK'
    return $i
}

function Set-InstallImageInTree([string]$Wim, [string]$IsoTree, [string]$BackendName) {
    $sources = Find-PathCI $IsoTree 'sources'
    $limit = [long]4GB - 1
    if ($cfg.image.PSObject.Properties.Name -contains 'splitThresholdMBLinux') { $limit = [long]$cfg.image.splitThresholdMBLinux * 1MB }
    $size = (Get-Item -LiteralPath $Wim).Length
    if ($BackendName -eq 'Windows' -or $size -le $limit) {
        Move-Item -LiteralPath $Wim -Destination (Join-Path $sources 'install.wim') -Force
        return @('install.wim')
    }
    Write-Log ("install.wim is {0:N0} bytes (> split threshold {1:N0}; ISO9660 limit is 4 GiB per file): splitting into SWM parts" -f $size, $limit) 'STEP'
    $swm = Join-Path $sources 'install.swm'
    Invoke-Native -FilePath 'wimlib-imagex' -Arguments "split $(Format-NativeArg $Wim) $(Format-NativeArg $swm) $([int]$cfg.image.splitSizeMBLinux) --check" | Out-Null
    Remove-Item -LiteralPath $Wim -Force
    $parts = @(Get-ChildItem -LiteralPath $sources -Filter 'install*.swm' | Sort-Object Name | ForEach-Object { $_.Name })
    $ref = Join-Path $sources 'install*.swm'
    Invoke-Native -FilePath 'wimlib-imagex' -Arguments "verify $(Format-NativeArg $swm) --ref=$(Format-NativeArg $ref)" | Out-Null
    Add-BuildWarning "Linux backend: install.wim split into $($parts.Count) SWM parts (Windows Setup supports install.swm)."
    return $parts
}

# -------------------------------------------------------------- ISO build ---
function Get-BootImages([string]$SourceIso, [string]$IsoTree) {
    Write-Log 'Identifying original El Torito boot images' 'STEP'
    $efiDir = Find-PathCI $IsoTree 'efi/microsoft/boot'
    $efiCandidates = @(Get-ChildItem -LiteralPath $efiDir -Filter 'efisys*.bin' | ForEach-Object { $_.FullName })
    $efi = Find-MatchingBootFile -IsoPath $SourceIso -Platform 0xEF -Candidates $efiCandidates
    if (-not $efi) { throw 'Could not identify which efisys*.bin the source ISO uses for UEFI boot; refusing to guess.' }
    $bios = $null; $biosCount = 8
    $biosEntry = @(Get-IsoBootEntries -IsoPath $SourceIso | Where-Object { $_.Platform -eq 0 }) | Select-Object -First 1
    if ($biosEntry) {
        $etfs = Find-PathCI $IsoTree 'boot/etfsboot.com'
        $bios = Find-MatchingBootFile -IsoPath $SourceIso -Platform 0 -Candidates @($etfs)
        if (-not $bios) { Add-BuildWarning 'BIOS boot image of the source ISO does not match boot\etfsboot.com byte-for-byte; using boot\etfsboot.com.'; $bios = $etfs }
        if ($biosEntry.SectorCount -gt 0) { $biosCount = [int]$biosEntry.SectorCount }
    }
    Write-Log ("UEFI: {0} (SHA-256 {1})" -f (Get-RelativePath $IsoTree $efi), (Get-Sha256 $efi)) 'OK'
    if ($bios) { Write-Log ("BIOS: {0} (SHA-256 {1})" -f (Get-RelativePath $IsoTree $bios), (Get-Sha256 $bios)) 'OK' }
    return [pscustomobject]@{ Efi = $efi; Bios = $bios; BiosLoadSectors = $biosCount }
}

function New-IsoImage([string]$IsoTree, [string]$OutIso, $Boot, [string]$BackendName, [string]$Oscdimg) {
    Write-Log "Building ISO $OutIso" 'STEP'
    if (Test-Path -LiteralPath $OutIso) { Remove-Item -LiteralPath $OutIso -Force }
    $label = [string]$cfg.iso.volumeLabel
    if ($label -notmatch '^[A-Z0-9_]{1,32}$') { throw 'iso.volumeLabel must be 1-32 chars of A-Z, 0-9, _' }
    if ($BackendName -eq 'Windows') {
        if ($Boot.Bios) { $bd = "-bootdata:2#p0,e,b`"$($Boot.Bios)`"#pEF,e,b`"$($Boot.Efi)`"" }
        else { $bd = "-bootdata:1#pEF,e,b`"$($Boot.Efi)`"" }
        $a = "-m -o -u2 -udfver102 -l$label $bd $(Format-NativeArg $IsoTree.TrimEnd('\')) $(Format-NativeArg $OutIso)"
        Invoke-Native -FilePath $Oscdimg -Arguments $a -Quiet | Out-Null
    }
    else {
        $efiRel = (Get-RelativePath $IsoTree $Boot.Efi) -replace '\\', '/'
        $a = "-as mkisofs -iso-level 3 -full-iso9660-filenames -J -joliet-long -volid $label "
        if ($Boot.Bios) {
            $biosRel = (Get-RelativePath $IsoTree $Boot.Bios) -replace '\\', '/'
            $a += "-b $(Format-NativeArg $biosRel) -no-emul-boot -boot-load-size $($Boot.BiosLoadSectors) -hide boot.catalog -eltorito-alt-boot "
        }
        $a += "-e $(Format-NativeArg $efiRel) -no-emul-boot --md5 -o $(Format-NativeArg $OutIso) $(Format-NativeArg $IsoTree)"
        Invoke-Native -FilePath 'xorriso' -Arguments $a -Quiet | Out-Null
    }
    Write-Log ("ISO written: {0:N0} bytes" -f (Get-Item -LiteralPath $OutIso).Length) 'OK'
}

function Test-OutputIso([string]$OutIso, [string]$IsoTree, $Boot, [string[]]$WimFiles, [string]$BackendName) {
    Write-Log 'Verifying output ISO' 'STEP'
    $checks = [ordered]@{}
    $entries = @(Get-IsoBootEntries -IsoPath $OutIso)
    $checks.bootEntries = @($entries | ForEach-Object { 'platform 0x{0:X2} lba {1} sectors {2}' -f $_.Platform, $_.Lba, $_.SectorCount })
    if (-not (Find-MatchingBootFile -IsoPath $OutIso -Platform 0xEF -Candidates @($Boot.Efi))) { throw 'UEFI boot image in output ISO differs from the original efisys image' }
    $checks.uefiBootImageIdentical = $true
    if ($Boot.Bios) {
        $same = [bool](Find-MatchingBootFile -IsoPath $OutIso -Platform 0 -Candidates @($Boot.Bios))
        if (-not $same) { Add-BuildWarning 'BIOS boot image in output ISO differs from etfsboot.com byte-for-byte.' }
        $checks.biosBootImageIdentical = $same
    }
    $required = @('setup.exe', 'bootmgr', 'bootmgr.efi', 'boot/etfsboot.com', 'boot/bcd', 'efi/boot/bootx64.efi', 'efi/microsoft/boot/bcd', 'sources/boot.wim') + @($WimFiles | ForEach-Object { "sources/$_" })
    if ($cfg.image.addAnswerFileFallback) { $required += 'autounattend.xml' }
    if ($BackendName -eq 'Windows') {
        $img = Mount-DiskImage -ImagePath $OutIso -Access ReadOnly -StorageType ISO -PassThru
        $script:MountedIsoPath = $OutIso
        try {
            $letter = $null
            for ($i = 0; $i -lt 30 -and -not $letter; $i++) { $letter = ($img | Get-Volume).DriveLetter; if (-not $letter) { Start-Sleep 1 } }
            if (-not $letter) { throw 'Output ISO did not get a drive letter' }
            $r = "$($letter):\"
            foreach ($f in $required) { if (-not (Test-Path -LiteralPath (Join-Path $r $f))) { throw "Output ISO is missing $f" } }
            $isoWim = Join-Path $r 'sources\install.wim'
            $staged = Join-Path $IsoTree 'sources\install.wim'
            if ((Get-Sha256 $isoWim) -ne (Get-Sha256 $staged)) { throw 'install.wim inside the ISO differs from the staged image' }
            $checks.installWimIdentical = $true
            $imgs = @(Get-ImageList $isoWim 'Windows')
            if ($imgs.Count -ne 1 -or $imgs[0].EditionId -ne $cfg.windows.editionId) { throw 'install.wim in ISO: unexpected edition/index count' }
            $checks.installWimEdition = "$($imgs[0].Name) / $($imgs[0].EditionId) / $($imgs[0].Version)"
        }
        finally {
            Dismount-DiskImage -ImagePath $OutIso | Out-Null
            $script:MountedIsoPath = $null
        }
    }
    else {
        $7z = @(Get-Command 7z -CommandType Application)[0].Source
        $list = Invoke-Native -FilePath $7z -Arguments "l -slt $(Format-NativeArg $OutIso)" -Quiet
        $paths = @($list.StdOut | Where-Object { $_ -like 'Path = *' } | ForEach-Object { ($_.Substring(7) -replace '\\', '/').ToLowerInvariant() })
        foreach ($f in $required) { if ($paths -notcontains $f.ToLowerInvariant()) { throw "Output ISO is missing $f" } }
        Invoke-Native -FilePath 'xorriso' -Arguments "-abort_on FAILURE -indev $(Format-NativeArg $OutIso) -check_md5_r FAILURE / --" | Out-Null
        $checks.xorrisoMd5AllFiles = 'ok'
    }
    $checks.requiredFiles = 'all present'
    Write-Log 'Output ISO verification passed' 'OK'
    return $checks
}

# ================================================================== main ===
$exitCode = 1
try {
    Write-Log 'Environment check' 'STEP'
    $envr = & (Join-Path $ProjectRoot 'scripts/Test-BuildEnvironment.ps1') -ProjectRoot $ProjectRoot -OscdimgPath ([string]$cfg.iso.oscdimgPath) `
        -MinFreeGBWindows ([double]$cfg.project.minFreeGBWindows) -MinFreeGBLinux ([double]$cfg.project.minFreeGBLinux) -Quiet
    foreach ($c in $envr.Checks) { Write-Log ("  {0,-40} {1,-6} {2}" -f $c.Check, $c.State, $c.Value) }
    foreach ($w in $envr.Warnings) { Write-Log "  $w" 'WARN' }
    foreach ($i in $envr.Issues) { Write-Log "  $i" 'ERROR' }
    Write-JsonFile -Object $envr -Path (Join-Path $LogsDir "environment-$Stamp.json")
    $hostBackend = $(if (Test-IsWindowsHost) { 'Windows' } else { 'Linux' })
    if ($Backend -ne 'Auto' -and $Backend -ne $hostBackend) { throw "Backend $Backend cannot run on this host ($hostBackend)." }
    if (-not $envr.Ready) { throw ('Build environment not ready: ' + ($envr.Issues -join ' ')) }
    $UseBackend = $envr.Backend
    $Manifest.backend = $UseBackend
    if ($UseBackend -eq 'Linux') {
        Add-BuildWarning 'Linux fallback backend: DISM and Oscdimg are not used; result is not equivalent to the reference Windows pipeline.'
    }
    if ($CheckOnly) { Write-Log 'CheckOnly: environment is ready.' 'OK'; $exitCode = 0; return }
    $oscdimg = $null
    if ($UseBackend -eq 'Windows') {
        $oscdimg = $envr.OscdimgPath
        if (Get-Command Get-WindowsImage -ErrorAction SilentlyContinue) {
            foreach ($m in @(Get-WindowsImage -Mounted | Where-Object { $_.Path -like "$WorkDir*" })) {
                Write-Log "Discarding stale mount from a previous run: $($m.Path)" 'WARN'
                Dismount-WindowsImage -Path $m.Path -Discard | Out-Null
            }
        }
    }

    $source = Get-SourceIso
    $Manifest.source = $source
    $apps = @(Get-Applications)
    $Manifest.apps = @($apps | ForEach-Object { [ordered]@{ name = $_.name; version = $_.version; url = $_.url; sha256 = $_.sha256
                hashVerification = $_.hashVerification; signature = $_.signatureStatus; signer = $_.signer; installerType = $_.installerType; silentArgs = $_.silentArgs } })

    if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    $isoTree = Join-Path $WorkDir 'iso'
    $srcWim = Expand-SourceIso -IsoPath $source.path -Target $isoTree -BackendName $UseBackend
    $Manifest.sourceBootFileSignatures = @(Test-SourceBootFiles -IsoTree $isoTree -BackendName $UseBackend)

    $images = @(Get-ImageList $srcWim $UseBackend)
    $sel = Select-Edition $images
    $Manifest.sourceImages = $images
    $Manifest.selectedImage = $sel

    $stagedWim = Join-Path $WorkDir 'install.wim'
    Export-Edition -SourceWim $srcWim -Index $sel.Index -DestWim $stagedWim -BackendName $UseBackend
    if ($UseBackend -eq 'Windows') {
        Dismount-DiskImage -ImagePath $source.path | Out-Null; $script:MountedIsoPath = $null
    } else {
        Remove-Item -LiteralPath (Split-Path -Parent $srcWim) -Recurse -Force
    }
    # Read the El Torito catalog only after the source ISO is no longer attached (Windows).
    $boot = Get-BootImages -SourceIso $source.path -IsoTree $isoTree

    $payloadScripts = New-Payload -Apps $apps -Target (Join-Path $WorkDir 'payload')
    if ($UseBackend -eq 'Windows') { Update-ImageWindows -Wim $stagedWim -PayloadScripts $payloadScripts -IsoTree $isoTree }
    else { Update-ImageLinux -Wim $stagedWim -PayloadScripts $payloadScripts }
    $Manifest.finalImage = Test-StagedImage -Wim $stagedWim -BackendName $UseBackend -Selected $sel
    $wimFiles = Set-InstallImageInTree -Wim $stagedWim -IsoTree $isoTree -BackendName $UseBackend

    if ($cfg.image.addAnswerFileFallback) {
        Copy-Item -LiteralPath (Join-Path $ProjectRoot 'scripts/payload/autounattend.xml') -Destination (Join-Path $isoTree 'autounattend.xml')
        Write-Log 'autounattend.xml (specialize-only fallback) added to ISO root'
    }
    $eiCfgPath = Join-Path (Find-PathCI $isoTree 'sources') 'ei.cfg'
    if (-not (Test-Path -LiteralPath $eiCfgPath)) {
        # Official Setup configuration file: edition = Pro, retail channel. Contains no product key.
        [System.IO.File]::WriteAllText($eiCfgPath, "[EditionID]`r`n$($cfg.windows.editionId)`r`n[Channel]`r`nRetail`r`n", (New-Object System.Text.ASCIIEncoding))
        Write-Log 'sources\ei.cfg added (EditionID/Channel only, no key)'
    }

    $outIso = Join-Path $OutputDir $cfg.iso.outputFileName
    New-IsoImage -IsoTree $isoTree -OutIso $outIso -Boot $boot -BackendName $UseBackend -Oscdimg $oscdimg
    $Manifest.verification = Test-OutputIso -OutIso $outIso -IsoTree $isoTree -Boot $boot -WimFiles $wimFiles -BackendName $UseBackend
    $Manifest.bootImages = [ordered]@{ uefi = (Get-RelativePath $isoTree $boot.Efi); uefiSha256 = (Get-Sha256 $boot.Efi)
        bios = $(if ($boot.Bios) { Get-RelativePath $isoTree $boot.Bios } else { $null }) }

    Write-Log 'Computing SHA-256 of the output ISO' 'STEP'
    $outHash = Get-Sha256 $outIso
    $outSize = (Get-Item -LiteralPath $outIso).Length
    [System.IO.File]::WriteAllText("$outIso.sha256", "$outHash *$($cfg.iso.outputFileName)`n", (New-Object System.Text.ASCIIEncoding))
    $Manifest.output = [ordered]@{ path = $outIso; sizeBytes = $outSize; sha256 = $outHash }
    $Manifest.appxRemoval = $cfg.appxRemoval
    $Manifest.tweaksApplied = @($cfg.tweaks | Where-Object { $_.enabled } | ForEach-Object { $_.id })
    $Manifest.imageOptions = $cfg.image
    $Manifest.vmTest = 'NOT RUN by build.ps1 - see scripts/New-TestVM.ps1 and scripts/Test-Deployment.ps1'
    Write-Log ("RESULT: {0}  {1:N0} bytes  SHA-256 {2}" -f $outIso, $outSize, $outHash) 'OK'
    $exitCode = 0
}
catch {
    Write-Log ("BUILD FAILED: {0}" -f $_.Exception.Message) 'ERROR'
    if ($_.InvocationInfo) { Write-Log ("  at {0}" -f $_.InvocationInfo.PositionMessage.Split("`n")[0]) 'ERROR' }
    $Manifest.error = $_.Exception.Message
}
finally {
    if ($script:DismMountDir) {
        Write-Log "Discarding DISM mount $($script:DismMountDir)" 'WARN'
        try { Dismount-WindowsImage -Path $script:DismMountDir -Discard | Out-Null } catch { Write-Log "Dismount failed: $($_.Exception.Message). Run: Dismount-WindowsImage -Path '$($script:DismMountDir)' -Discard; Clear-WindowsCorruptMountPoint" 'ERROR' }
    }
    if ($script:MountedIsoPath) {
        try { Dismount-DiskImage -ImagePath $script:MountedIsoPath | Out-Null } catch { Write-Log "ISO dismount failed: $($_.Exception.Message)" 'ERROR' }
    }
    if (-not $CheckOnly) {
        $Manifest.finishedAt = (Get-Date).ToString('s')
        $Manifest.success = ($exitCode -eq 0)
        $Manifest.warnings = $Warnings.ToArray()
        $mf = $(if ($exitCode -eq 0) { Join-Path $OutputDir 'build-manifest.json' } else { Join-Path $LogsDir "build-manifest-failed-$Stamp.json" })
        try { Write-JsonFile -Object $Manifest -Path $mf; Write-Log "Manifest: $mf" } catch { Write-Log "Manifest write failed: $($_.Exception.Message)" 'ERROR' }
        if ($exitCode -eq 0 -and -not $KeepWorkDir -and (Test-Path -LiteralPath $WorkDir)) {
            Remove-Item -LiteralPath $WorkDir -Recurse -Force
            Write-Log "Removed work directory $WorkDir"
        }
    }
}
exit $exitCode
