# BuildCommon.ps1 - shared helpers for build.ps1.
# Compatible with Windows PowerShell 5.1 and PowerShell 7+ (Windows and Linux).
# Messages are kept ASCII-only on purpose: Windows PowerShell 5.1 misreads
# non-ASCII script text unless the file carries a BOM.

Set-StrictMode -Version 2.0

$script:BuildLogFile = $null

function Test-IsWindowsHost {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

function Initialize-BuildLog {
    param([Parameter(Mandatory = $true)][string]$Path)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:BuildLogFile = $Path
    Write-Log "Log file: $Path"
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'STEP', 'OK')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'STEP'  { Write-Host $line -ForegroundColor Cyan }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
    if ($script:BuildLogFile) {
        Add-Content -LiteralPath $script:BuildLogFile -Value $line -Encoding UTF8
    }
}

function Format-NativeArg {
    # Quote one argument for a Windows/Linux command line if it needs it.
    param([AllowEmptyString()][string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
    return $Value
}

function Invoke-Native {
    <#
      Runs an external program with an exact argument string, captures stdout/stderr
      into the build log and throws if the exit code is not in SuccessCodes.
      Start-Process is used instead of the call operator because Windows PowerShell 5.1
      mangles arguments that contain quotes (needed for oscdimg -bootdata) and turns
      stderr into terminating errors under ErrorActionPreference=Stop.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$Arguments = '',
        [int[]]$SuccessCodes = @(0),
        [switch]$Quiet,
        [switch]$AllowAnyExitCode,
        [string]$WorkingDirectory
    )
    $tmpDir = [System.IO.Path]::GetTempPath()
    $id = [guid]::NewGuid().ToString('N')
    $outFile = Join-Path $tmpDir "ci-$id.out"
    $errFile = Join-Path $tmpDir "ci-$id.err"
    Write-Log ("RUN: {0} {1}" -f $FilePath, $Arguments)
    $spArgs = @{
        FilePath               = $FilePath
        Wait                   = $true
        PassThru               = $true
        NoNewWindow            = $true
        RedirectStandardOutput = $outFile
        RedirectStandardError  = $errFile
    }
    if ($Arguments -ne '') { $spArgs['ArgumentList'] = $Arguments }
    if ($WorkingDirectory) { $spArgs['WorkingDirectory'] = $WorkingDirectory }
    try {
        $p = Start-Process @spArgs
        $code = $p.ExitCode
        $stdout = @()
        if (Test-Path -LiteralPath $outFile) { $stdout = @(Get-Content -LiteralPath $outFile) }
        $stderr = @()
        if (Test-Path -LiteralPath $errFile) { $stderr = @(Get-Content -LiteralPath $errFile) }
    }
    finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
    if (-not $Quiet) {
        foreach ($l in $stdout) { if ("$l".Trim() -ne '') { Write-Log ("    " + $l) } }
    }
    foreach ($l in $stderr) { if ("$l".Trim() -ne '') { Write-Log ("    [stderr] " + $l) } }
    Write-Log ("EXIT: {0}" -f $code)
    if (-not $AllowAnyExitCode -and $SuccessCodes -notcontains $code) {
        throw ("Command failed (exit code {0}): {1} {2}" -f $code, $FilePath, $Arguments)
    }
    return [pscustomobject]@{ ExitCode = $code; StdOut = $stdout; StdErr = $stderr }
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Enable-ModernTls {
    if (Test-IsWindowsHost) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch { }
    }
}

function Get-CurlPath {
    $c = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
    if (-not $c) { $c = Get-Command 'curl' -CommandType Application -ErrorAction SilentlyContinue }
    if (-not $c) { throw 'curl is required for downloads (Windows 10 1803+ ships curl.exe).' }
    return @($c)[0].Source
}

function Invoke-Download {
    # Resumable download with retries via curl (present on Windows 10 1803+ and Linux).
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile
    )
    $dir = Split-Path -Parent $OutFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $curl = Get-CurlPath
    $partial = "$OutFile.part"
    $a = @('-fL', '--retry', '5', '--retry-delay', '5', '--connect-timeout', '30',
        '-C', '-', '-o', (Format-NativeArg $partial), (Format-NativeArg $Uri)) -join ' '
    Invoke-Native -FilePath $curl -Arguments $a -Quiet | Out-Null
    Move-Item -LiteralPath $partial -Destination $OutFile -Force
    Write-Log ("Downloaded {0} ({1:N0} bytes)" -f $OutFile, (Get-Item -LiteralPath $OutFile).Length)
}

function Get-WebText {
    param([Parameter(Mandatory = $true)][string]$Uri)
    Enable-ModernTls
    Write-Log "GET $Uri"
    $r = Invoke-WebRequest -Uri $Uri -UseBasicParsing -Headers @{ 'User-Agent' = 'win11-custom-iso-build' }
    if ($r.Content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($r.Content) }
    return [string]$r.Content
}

function Get-WebJson {
    param([Parameter(Mandatory = $true)][string]$Uri)
    return (Get-WebText -Uri $Uri | ConvertFrom-Json)
}

function Test-FileSignature {
    <#
      Verifies an Authenticode signature (EXE/MSI).
      Windows: Get-AuthenticodeSignature (chain validated against the host trust store).
      Linux:   osslsigncode verify against the system CA bundle.
      Returns Status = Valid | NotSigned | Invalid | UntrustedRoot (Linux only) | Unavailable.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$SubjectPattern = ''
    )
    $status = 'Unavailable'; $signer = ''; $detail = ''
    if (Test-IsWindowsHost) {
        $s = Get-AuthenticodeSignature -LiteralPath $Path
        $detail = [string]$s.StatusMessage
        if ($s.SignerCertificate) { $signer = $s.SignerCertificate.Subject }
        switch ([string]$s.Status) {
            'Valid'     { $status = 'Valid' }
            'NotSigned' { $status = 'NotSigned' }
            default     { $status = 'Invalid' }
        }
    }
    else {
        $tool = Get-Command 'osslsigncode' -ErrorAction SilentlyContinue
        if ($tool) {
            $ca = '/etc/ssl/certs/ca-certificates.crt'
            $a = "verify -in $(Format-NativeArg $Path) -CAfile $ca -TSA-CAfile $ca"
            $r = Invoke-Native -FilePath $tool.Source -Arguments $a -SuccessCodes @(0, 1, 255) -Quiet
            $text = ($r.StdOut + $r.StdErr) -join "`n"
            $cur = [regex]::Match($text, 'Current message digest\s*:\s*([0-9A-Fa-f]+)')
            $calc = [regex]::Match($text, 'Calculated message digest\s*:\s*([0-9A-Fa-f]+)')
            $digestOk = ($cur.Success -and $calc.Success -and $cur.Groups[1].Value -eq $calc.Groups[1].Value)
            if ($text -match '(?i)no signature found|has no signature|unable to extract existing signature') { $status = 'NotSigned' }
            elseif ($r.ExitCode -eq 0 -and $text -match 'Signature verification: ok') { $status = 'Valid' }
            elseif ($digestOk -and $text -match '(?i)unable to get (local issuer|issuer) certificate|self.signed certificate in certificate chain|unable to get certificate CRL') {
                # File content matches its signature, but the chain ends in a root that is not in
                # the Linux CA bundle (e.g. Microsoft code-signing roots). Not equivalent to Valid.
                $status = 'UntrustedRoot'
            }
            else { $status = 'Invalid' }
            if ($text -match '(?i)unsupported input file type') { $detail = 'not a PE/MSI/CAB file; ' }
            $m = [regex]::Match($text, 'Signer #0:\s*Subject:\s*([^\r\n]+)')
            if (-not $m.Success) { $m = [regex]::Match($text, "Signer's certificate:\s*Subject:\s*([^\r\n]+)") }
            if ($m.Success) { $signer = $m.Groups[1].Value.Trim() }
            $detail += (($r.StdOut + $r.StdErr) | Select-Object -Last 3) -join ' | '
        }
        else { $detail = 'osslsigncode not installed' }
    }
    $subjectOk = $true
    if ($SubjectPattern -and $status -eq 'Valid') { $subjectOk = ($signer -match $SubjectPattern) }
    return [pscustomobject]@{
        Status = $status; Signer = $signer; SubjectMatches = $subjectOk; Detail = $detail
    }
}

# ---------------------------------------------------------------------------
# ISO 9660 El Torito parsing (used to keep the original boot images).
# ---------------------------------------------------------------------------

function Read-FileBytes {
    param([string]$Path, [long]$Offset, [int]$Count)
    $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        [void]$fs.Seek($Offset, 'Begin')
        $buf = New-Object byte[] $Count
        $read = 0
        while ($read -lt $Count) {
            $n = $fs.Read($buf, $read, $Count - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        if ($read -ne $Count) { throw "Short read from $Path at offset $Offset" }
        return , $buf
    }
    finally { $fs.Dispose() }
}

function Get-IsoBootEntries {
    <# Returns El Torito boot entries: Platform (0=BIOS, 0xEF=UEFI), Lba, SectorCount. #>
    param([Parameter(Mandatory = $true)][string]$IsoPath)
    $brvd = Read-FileBytes -Path $IsoPath -Offset (17 * 2048) -Count 2048
    $sysId = [System.Text.Encoding]::ASCII.GetString($brvd, 7, 23)
    if ($brvd[0] -ne 0 -or [System.Text.Encoding]::ASCII.GetString($brvd, 1, 5) -ne 'CD001' -or $sysId -ne 'EL TORITO SPECIFICATION') {
        throw "No El Torito boot record in $IsoPath"
    }
    $catLba = [BitConverter]::ToUInt32($brvd, 0x47)
    $cat = Read-FileBytes -Path $IsoPath -Offset ([long]$catLba * 2048) -Count 2048
    if ($cat[0] -ne 1 -or $cat[30] -ne 0x55 -or $cat[31] -ne 0xAA) { throw 'Invalid El Torito validation entry' }
    $entries = New-Object System.Collections.ArrayList
    $platform = [int]$cat[1]
    # Initial/default entry at offset 32
    if ($cat[32] -eq 0x88) {
        [void]$entries.Add([pscustomobject]@{
                Platform = $platform; SectorCount = [BitConverter]::ToUInt16($cat, 38); Lba = [BitConverter]::ToUInt32($cat, 40)
            })
    }
    $off = 64
    while ($off -le 2016) {
        $hid = $cat[$off]
        if ($hid -ne 0x90 -and $hid -ne 0x91) { break }
        $secPlatform = [int]$cat[$off + 1]
        $count = [BitConverter]::ToUInt16($cat, $off + 2)
        $off += 32
        for ($i = 0; $i -lt $count -and $off -le 2016; $i++) {
            if ($cat[$off] -eq 0x88) {
                [void]$entries.Add([pscustomobject]@{
                        Platform = $secPlatform; SectorCount = [BitConverter]::ToUInt16($cat, $off + 6); Lba = [BitConverter]::ToUInt32($cat, $off + 8)
                    })
            }
            $off += 32
        }
        if ($hid -eq 0x91) { break }
    }
    return $entries.ToArray()
}

function Get-BytesSha256 {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '') }
    finally { $sha.Dispose() }
}

function Find-MatchingBootFile {
    <#
      Finds which candidate file is byte-identical to the boot image of the given
      platform inside the ISO. Used to reuse exactly the boot image Microsoft used
      (efisys.bin vs efisys_EX.bin / etfsboot.com).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$IsoPath,
        [Parameter(Mandatory = $true)][int]$Platform,
        [Parameter(Mandatory = $true)][string[]]$Candidates
    )
    $entry = @(Get-IsoBootEntries -IsoPath $IsoPath | Where-Object { $_.Platform -eq $Platform }) | Select-Object -First 1
    if (-not $entry) { return $null }
    foreach ($c in $Candidates) {
        if (-not (Test-Path -LiteralPath $c)) { continue }
        $len = (Get-Item -LiteralPath $c).Length
        $isoBytes = Read-FileBytes -Path $IsoPath -Offset ([long]$entry.Lba * 2048) -Count ([int]$len)
        if ((Get-BytesSha256 $isoBytes) -eq (Get-Sha256 $c)) { return $c }
    }
    return $null
}

function Write-JsonFile {
    param([Parameter(Mandatory = $true)]$Object, [Parameter(Mandatory = $true)][string]$Path)
    $json = $Object | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Resolve-ProjectPath {
    param([string]$Root, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return [System.IO.Path]::GetFullPath((Join-Path $Root $Path))
}

function Get-FreeSpaceGB {
    param([string]$Path)
    if (Test-IsWindowsHost) {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
        $di = New-Object System.IO.DriveInfo($root)
        return [math]::Round($di.AvailableFreeSpace / 1GB, 1)
    }
    $line = (& df -Pk -- $Path 2>$null | Select-Object -Last 1)
    $kb = [double](($line -split '\s+')[3])
    return [math]::Round($kb / 1MB, 1)
}
