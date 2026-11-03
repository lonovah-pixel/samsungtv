<#
.SYNOPSIS
  Mechanics test of the Linux backend of build.ps1 on a SYNTHETIC source.
.DESCRIPTION
  Creates a fake "Windows ISO" (random boot images, a tiny WIM with three fake
  editions carrying Windows-like XML metadata, dummy installers), runs build.ps1
  against it and checks the result. This validates the build logic only:
  index detection, export, payload injection, SWM split, boot image reuse,
  ISO creation and verification, hash-mismatch stop.
  It does NOT produce or test a Windows installation medium.
  Requires: pwsh 7, wimlib-imagex, xorriso, 7z (Linux).
#>
param([string]$TestRoot = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'work-synthetic'))

$ErrorActionPreference = 'Stop'
$Project = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $Project 'scripts/BuildCommon.ps1')
$fails = 0
function Assert([bool]$Cond, [string]$Text) {
    if ($Cond) { Write-Host "PASS  $Text" -ForegroundColor Green } else { Write-Host "FAIL  $Text" -ForegroundColor Red; $script:fails++ }
}
function Write-RandomFile([string]$Path, [int]$Size) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $b = New-Object byte[] $Size; (New-Object System.Random).NextBytes($b); [System.IO.File]::WriteAllBytes($Path, $b)
}

if (Test-Path $TestRoot) { Remove-Item $TestRoot -Recurse -Force }
$tree = Join-Path $TestRoot 'srctree'
# --- fake media tree (lowercase names like Microsoft media) ---
foreach ($f in @('setup.exe', 'bootmgr', 'bootmgr.efi', 'boot/bcd', 'efi/boot/bootx64.efi', 'efi/microsoft/boot/bcd', 'sources/boot.wim', 'sources/sxs/readme.txt')) {
    Write-RandomFile (Join-Path $tree $f) 4096
}
Write-RandomFile (Join-Path $tree 'boot/etfsboot.com') 4096
Write-RandomFile (Join-Path $tree 'efi/microsoft/boot/efisys.bin') 1474560
Write-RandomFile (Join-Path $tree 'efi/microsoft/boot/efisys_EX.bin') 1474560
Write-RandomFile (Join-Path $tree 'efi/microsoft/boot/efisys_noprompt.bin') 1474560
# --- fake WIM with 3 editions ---
$fake = Join-Path $TestRoot 'fakeos'
Write-RandomFile (Join-Path $fake 'Windows/System32/config/SOFTWARE') 65536
Write-RandomFile (Join-Path $fake 'Windows/explorer.exe') 3000000
New-Item -ItemType Directory -Path (Join-Path $fake 'Windows/Setup') -Force | Out-Null
$wim = Join-Path $tree 'sources/install.wim'
$editions = @(@('Windows 11 Home', 'Core'), @('Windows 11 Pro', 'Professional'), @('Windows 11 Pro N', 'ProfessionalN'))
$i = 0
foreach ($e in $editions) {
    $i++
    $verb = $(if ($i -eq 1) { 'capture' } else { 'append' })
    & wimlib-imagex $verb $fake $wim $e[0] --compress=LZX | Out-Null
    & wimlib-imagex info $wim $i --image-property "WINDOWS/EDITIONID=$($e[1])" --image-property 'WINDOWS/ARCH=9' `
        --image-property 'WINDOWS/LANGUAGES/LANGUAGE=ru-RU' --image-property 'WINDOWS/VERSION/MAJOR=10' --image-property 'WINDOWS/VERSION/MINOR=0' `
        --image-property 'WINDOWS/VERSION/BUILD=26200' --image-property 'WINDOWS/VERSION/SPBUILD=9999' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'wimlib-imagex info --image-property failed' }
}
# --- fake source ISO: UEFI entry uses efisys_EX.bin on purpose ---
$srcIso = Join-Path $TestRoot 'synthetic-source.iso'
& xorriso -as mkisofs -iso-level 3 -J -joliet-long -volid SYNTH -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 -hide boot.catalog `
    -eltorito-alt-boot -e efi/microsoft/boot/efisys_EX.bin -no-emul-boot -o $srcIso $tree 2>$null
if ($LASTEXITCODE -ne 0) { throw 'xorriso failed creating the synthetic source ISO' }
$srcHash = Get-Sha256 $srcIso
# --- dummy installers: real but unsigned PE files (signature stripped from a pwsh DLL) ---
function New-UnsignedPe([string]$Path) {
    $srcDll = Get-ChildItem (Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)) -Filter 'System.Runtime.dll' | Select-Object -First 1
    $d = [System.IO.File]::ReadAllBytes($srcDll.FullName)
    $pe = [BitConverter]::ToInt32($d, 0x3c)
    $magic = [BitConverter]::ToUInt16($d, $pe + 24)
    $dd = $pe + 24 + $(if ($magic -eq 0x10b) { 96 } else { 112 })
    $off = [BitConverter]::ToInt32($d, $dd + 32)
    for ($k = 0; $k -lt 8; $k++) { $d[$dd + 32 + $k] = 0 }
    if ($off -gt 0) { $d = $d[0..($off - 1)] }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::WriteAllBytes($Path, [byte[]]$d)
}
$apps = @()
foreach ($a in @(@('7zip', 'exe'), @('vlc', 'exe'))) {
    $p = Join-Path $TestRoot "dl/$($a[0]).$($a[1])"
    New-UnsignedPe $p
    $apps += [ordered]@{ id = $a[0]; name = "Dummy $($a[0])"; enabled = $true; version = '1.0'; resolver = 'none'; installerType = $a[1]
        silentArgs = '/S'; detectPath = "%ProgramFiles%\\$($a[0])\\x.exe"; expectedSha256 = (Get-Sha256 $p); localFile = $p
        signature = [ordered]@{ required = $false; subjectPattern = '' } }
}

$cfg = Get-Content (Join-Path $Project 'config.json') -Raw | ConvertFrom-Json
$cfg.project.workDir = 'work-synthetic/work'; $cfg.project.downloadsDir = 'work-synthetic/downloads'
$cfg.project.logsDir = 'work-synthetic/logs'; $cfg.project.outputDir = 'work-synthetic/output'
$cfg.project.minFreeGBLinux = 1
$cfg.source.localIsoPath = $srcIso; $cfg.source.expectedSha256 = $srcHash; $cfg.source.expectedSha256Reference = 'synthetic test'
$cfg.source.verifyBootFileSignatures = $false
$cfg.image.splitThresholdMBLinux = 0; $cfg.image.splitSizeMBLinux = 1
$cfg.apps = $apps
$cfgPath = Join-Path $TestRoot 'config.synthetic.json'
Write-JsonFile -Object $cfg -Path $cfgPath

# ---------- negative test: wrong reference hash must stop the build ----------
$bad = Get-Content $cfgPath -Raw | ConvertFrom-Json
$bad.source.expectedSha256 = ('0' * 64)
$badPath = Join-Path $TestRoot 'config.badhash.json'
Write-JsonFile -Object $bad -Path $badPath
& pwsh -NoProfile -File (Join-Path $Project 'build.ps1') -ConfigPath $badPath *> (Join-Path $TestRoot 'badhash.out')
Assert ($LASTEXITCODE -ne 0) 'build stops on source SHA-256 mismatch'
Assert ((Get-Content (Join-Path $TestRoot 'badhash.out') -Raw) -match 'SHA-256 MISMATCH') 'mismatch is reported'
Assert (-not (Test-Path (Join-Path $TestRoot 'output/Windows11-Pro-RU-Custom.iso'))) 'no ISO produced on mismatch'

# ---------- positive run ----------
& pwsh -NoProfile -File (Join-Path $Project 'build.ps1') -ConfigPath $cfgPath -KeepWorkDir *> (Join-Path $TestRoot 'build.out')
$code = $LASTEXITCODE
Get-Content (Join-Path $TestRoot 'build.out') | Select-String -Pattern '\[(STEP|OK|WARN|ERROR)\]' | ForEach-Object { Write-Host "   | $($_.Line)" }
Assert ($code -eq 0) 'build.ps1 exit code 0'
$out = Join-Path $TestRoot 'output/Windows11-Pro-RU-Custom.iso'
Assert (Test-Path $out) 'output ISO exists'
if (Test-Path $out) {
    $m = Get-Content (Join-Path $TestRoot 'output/build-manifest.json') -Raw | ConvertFrom-Json
    Assert ($m.selectedImage.Index -eq 2) "edition index detected from metadata (got $($m.selectedImage.Index), expected 2)"
    Assert ($m.bootImages.uefi -match 'efisys_EX\.bin$') "original UEFI boot image identified ($($m.bootImages.uefi))"
    Assert ((Get-Content "$out.sha256" -Raw).StartsWith((Get-Sha256 $out))) '.sha256 file matches ISO'
    $ex = Join-Path $TestRoot 'check'
    & 7z x $out "-o$ex" -y -bd 'sources/install*.swm' 'autounattend.xml' 'sources/ei.cfg' | Out-Null
    $swm = @(Get-ChildItem (Join-Path $ex 'sources') -Filter 'install*.swm')
    Assert ($swm.Count -ge 2) "install.wim split into SWM parts ($($swm.Count))"
    & wimlib-imagex verify (Join-Path $ex 'sources/install.swm') "--ref=$(Join-Path $ex 'sources/install*.swm')" | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'SWM set from the ISO passes wimlib verify'
    $x = Join-Path $TestRoot 'img'
    & wimlib-imagex apply (Join-Path $ex 'sources/install.swm') 1 $x "--ref=$(Join-Path $ex 'sources/install*.swm')" | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'image applies'
    & wimlib-imagex info (Join-Path $ex 'sources/install.swm') --ref="$(Join-Path $ex 'sources/install*.swm')" | Out-Null
    $info = (& wimlib-imagex info (Join-Path $ex 'sources/install.swm') 2>&1) -join "`n"
    Assert ($info -match 'Image Count:\s+1') 'image count is 1'
    Assert ($info -match 'Edition ID:\s+Professional') 'edition is Professional'
    $sc = Join-Path $x 'Windows/Setup/Scripts/SetupComplete.cmd'
    Assert (Test-Path $sc) 'SetupComplete.cmd injected'
    if (Test-Path $sc) { Assert ([System.IO.File]::ReadAllText($sc).Contains("`r`n")) 'SetupComplete.cmd has CRLF' }
    $pj = Join-Path $x 'Windows/Setup/Scripts/CustomImage/postinstall.json'
    Assert (Test-Path $pj) 'postinstall.json injected'
    if (Test-Path $pj) {
        $p = Get-Content $pj -Raw | ConvertFrom-Json
        Assert (@($p.apps).Count -eq 2) 'postinstall.json lists 2 apps'
        foreach ($a in $p.apps) { Assert (Test-Path (Join-Path $x "Windows/Setup/Scripts/CustomImage/Apps/$($a.file)")) "installer $($a.file) present in image" }
        Assert (@($p.tweaks).Count -eq @($cfg.tweaks | Where-Object { $_.enabled }).Count) 'only enabled tweaks exported'
    }
    Assert (Test-Path (Join-Path $x 'Windows/Setup/Scripts/CustomImage/Invoke-PostInstall.ps1')) 'Invoke-PostInstall.ps1 injected'
    Assert (Test-Path (Join-Path $ex 'autounattend.xml')) 'autounattend.xml at ISO root'
    Assert ((Get-Content (Join-Path $ex 'sources/ei.cfg') -Raw) -match '\[EditionID\]\s+Professional') 'ei.cfg present'
}
Write-Host ("Synthetic test finished: {0} failure(s)" -f $fails)
exit $fails
