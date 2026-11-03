# AppInstallers.ps1 - resolve, download and verify application installers.
# Dot-sourced by build.ps1 (requires BuildCommon.ps1).
#
# Every resolver queries only the vendor's own distribution endpoint and returns:
#   Version, Url, FileName, PublishedSha256 (or $null), HashSource (text).

Set-StrictMode -Version 2.0

function Get-OptionalProperty($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object -and ($Object.PSObject.Properties.Name -contains $Name) -and $null -ne $Object.$Name) { return $Object.$Name }
    return $Default
}

function Resolve-7Zip($App) {
    # Official site: https://www.7-zip.org/download.html (files under /a/).
    $ver = [string](Get-OptionalProperty $App 'version' 'latest')
    if ($ver -eq 'latest') {
        $html = Get-WebText 'https://www.7-zip.org/download.html'
        $m = [regex]::Match($html, 'a/7z(\d{4})-x64\.msi')
        if (-not $m.Success) { throw '7-Zip: could not find the x64 MSI link on https://www.7-zip.org/download.html' }
        $code = $m.Groups[1].Value
        $ver = $code.Substring(0, 2) + '.' + $code.Substring(2)
    } else {
        $code = ($ver -replace '\.', '')
    }
    $file = "7z$code-x64.msi"
    return [pscustomobject]@{
        Version = $ver; Url = "https://www.7-zip.org/a/$file"; FileName = $file
        PublishedSha256 = $null; HashSource = 'none: 7-zip.org does not publish checksums; pin expectedSha256 in config.json after first verified download'
    }
}

function Resolve-Firefox($App) {
    # Official: product-details.mozilla.org for the version, Mozilla CDN for files,
    # SHA256SUMS published next to every release.
    $ver = [string](Get-OptionalProperty $App 'version' 'latest')
    $locale = [string](Get-OptionalProperty $App 'locale' 'ru')
    if ($ver -eq 'latest') {
        $j = Get-WebJson 'https://product-details.mozilla.org/1.0/firefox_versions.json'
        $ver = [string]$j.LATEST_FIREFOX_VERSION
        if (-not $ver) { throw 'Firefox: LATEST_FIREFOX_VERSION missing in product-details' }
    }
    $base = "https://download-installer.cdn.mozilla.net/pub/firefox/releases/$ver"
    $rel = "win64/$locale/Firefox Setup $ver.msi"
    $url = "$base/win64/$locale/" + [uri]::EscapeDataString("Firefox Setup $ver.msi")
    $sums = Get-WebText "$base/SHA256SUMS"
    $published = $null
    foreach ($line in ($sums -split "`n")) {
        $parts = $line.Trim() -split '\s+', 2
        if ($parts.Count -eq 2 -and $parts[1].Trim() -eq $rel) { $published = $parts[0].ToUpperInvariant() }
    }
    if (-not $published) { throw "Firefox: no SHA256SUMS entry for '$rel'" }
    return [pscustomobject]@{
        Version = $ver; Url = $url; FileName = "Firefox Setup $ver.msi"
        PublishedSha256 = $published; HashSource = "$base/SHA256SUMS"
    }
}

function Resolve-Vlc($App) {
    # Official: download.videolan.org, every file has a .sha256 companion.
    $ver = [string](Get-OptionalProperty $App 'version' 'latest')
    if ($ver -eq 'latest') {
        $html = Get-WebText 'https://download.videolan.org/pub/videolan/vlc/last/win64/'
        $m = [regex]::Match($html, 'vlc-(\d+\.\d+\.\d+(?:\.\d+)?)-win64\.exe"')
        if (-not $m.Success) { throw 'VLC: no win64 installer in https://download.videolan.org/pub/videolan/vlc/last/win64/' }
        $ver = $m.Groups[1].Value
    }
    $file = "vlc-$ver-win64.exe"
    $url = "https://download.videolan.org/pub/videolan/vlc/$ver/win64/$file"
    $shaText = Get-WebText "$url.sha256"
    $published = (($shaText.Trim() -split '\s+')[0]).ToUpperInvariant()
    if ($published -notmatch '^[0-9A-F]{64}$') { throw "VLC: unexpected .sha256 content at $url.sha256" }
    return [pscustomobject]@{
        Version = $ver; Url = $url; FileName = $file
        PublishedSha256 = $published; HashSource = "$url.sha256"
    }
}

function Resolve-NotepadPlusPlus($App) {
    # Official releases are published on the project's GitHub repository
    # (linked from https://notepad-plus-plus.org/downloads/).
    $ver = [string](Get-OptionalProperty $App 'version' 'latest')
    $api = 'https://api.github.com/repos/notepad-plus-plus/notepad-plus-plus/releases'
    if ($ver -eq 'latest') { $rel = Get-WebJson "$api/latest" } else { $rel = Get-WebJson "$api/tags/v$ver" }
    $asset = @($rel.assets | Where-Object { $_.name -match '^npp\.[\d.]+\.Installer\.x64\.exe$' }) | Select-Object -First 1
    if (-not $asset) { throw "Notepad++: x64 installer asset not found in release $($rel.tag_name)" }
    $published = $null
    $digest = Get-OptionalProperty $asset 'digest'
    if ($digest -and $digest -match '^sha256:([0-9a-fA-F]{64})$') { $published = $Matches[1].ToUpperInvariant() }
    return [pscustomobject]@{
        Version = ([string]$rel.tag_name -replace '^v', ''); Url = $asset.browser_download_url; FileName = $asset.name
        PublishedSha256 = $published; HashSource = $(if ($published) { 'GitHub release asset digest (api.github.com)' } else { 'none' })
    }
}

function Resolve-AppSource($App) {
    $local = [string](Get-OptionalProperty $App 'localFile' '')
    if ($local) {
        return [pscustomobject]@{
            Version = [string](Get-OptionalProperty $App 'version' 'local'); Url = 'local:' + $local
            FileName = (Split-Path -Leaf $local); PublishedSha256 = $null; HashSource = 'local file (expectedSha256 from config is mandatory)'
        }
    }
    switch ([string]$App.resolver) {
        '7zip'      { return Resolve-7Zip $App }
        'firefox'   { return Resolve-Firefox $App }
        'vlc'       { return Resolve-Vlc $App }
        'notepadpp' { return Resolve-NotepadPlusPlus $App }
        default     { throw "Unknown resolver '$($App.resolver)' for app '$($App.id)'" }
    }
}

function Get-AppInstaller {
    <#
      Resolves, downloads (or reuses) and verifies one installer.
      Throws on: hash mismatch vs vendor-published or pinned hash, invalid
      signature, signer mismatch, or missing mandatory signature.
    #>
    param($App, [string]$DownloadRoot, [string]$ProjectRoot)
    Write-Log "Application: $($App.name)" 'STEP'
    $src = Resolve-AppSource $App
    Write-Log ("  version {0}; url {1}" -f $src.Version, $src.Url)
    $dir = Join-Path $DownloadRoot $App.id
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $target = Join-Path $dir $src.FileName

    if ($src.Url -like 'local:*') {
        $lp = Resolve-ProjectPath $ProjectRoot $src.Url.Substring(6)
        if (-not (Test-Path -LiteralPath $lp)) { throw "Local installer not found: $lp" }
        if ($lp -ne $target) { Copy-Item -LiteralPath $lp -Destination $target -Force }
    } else {
        $reuse = $false
        if (Test-Path -LiteralPath $target) {
            $h = Get-Sha256 $target
            $pinned = [string](Get-OptionalProperty $App 'expectedSha256' '')
            if (($src.PublishedSha256 -and $h -eq $src.PublishedSha256) -or ($pinned -and $h -eq $pinned.ToUpperInvariant())) { $reuse = $true }
        }
        if ($reuse) { Write-Log "  reusing verified download $target" }
        else {
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
            Invoke-Download -Uri $src.Url -OutFile $target
        }
    }

    $sha = Get-Sha256 $target
    Write-Log "  SHA-256 $sha"
    $pinnedHash = ([string](Get-OptionalProperty $App 'expectedSha256' '')).ToUpperInvariant()
    $hashChecks = @()
    if ($src.PublishedSha256) {
        if ($sha -ne $src.PublishedSha256) { throw "$($App.name): SHA-256 mismatch with vendor-published value ($($src.PublishedSha256)) from $($src.HashSource)" }
        $hashChecks += "matches vendor-published hash ($($src.HashSource))"
    }
    if ($pinnedHash) {
        if ($sha -ne $pinnedHash) { throw "$($App.name): SHA-256 mismatch with expectedSha256 pinned in config.json ($pinnedHash)" }
        $hashChecks += 'matches expectedSha256 pinned in config.json'
    }
    if ($src.Url -like 'local:*' -and -not $pinnedHash) { throw "$($App.name): localFile requires expectedSha256 in config.json" }
    if ($hashChecks.Count -eq 0) { $hashChecks += 'NO reference hash available (recorded only)' }

    $sigCfg = Get-OptionalProperty $App 'signature'
    $required = [bool](Get-OptionalProperty $sigCfg 'required' $false)
    $pattern = [string](Get-OptionalProperty $sigCfg 'subjectPattern' '')
    $sig = Test-FileSignature -Path $target -SubjectPattern $pattern
    Write-Log ("  Authenticode: {0}; signer: {1}" -f $sig.Status, $sig.Signer)
    if ($sig.Status -eq 'Invalid') { throw "$($App.name): Authenticode signature is INVALID. $($sig.Detail)" }
    if ($sig.Status -eq 'UntrustedRoot' -and $required) { throw "$($App.name): signature chain could not be validated against the local trust store. $($sig.Detail)" }
    if ($sig.Status -eq 'Valid' -and -not $sig.SubjectMatches) { throw "$($App.name): signer '$($sig.Signer)' does not match '$pattern'" }
    if ($required -and $sig.Status -ne 'Valid') { throw "$($App.name): a valid Authenticode signature is required but status is $($sig.Status). $($sig.Detail)" }
    if (-not $required -and $sig.Status -ne 'Valid') { Write-Log "  $($App.name): no valid signature (vendor does not sign; integrity relies on hash checks)" 'WARN' }

    Write-Log ("  verified: {0}" -f ($hashChecks -join '; ')) 'OK'
    return [pscustomobject]@{
        id = $App.id; name = $App.name; version = $src.Version; url = $src.Url
        fileName = $src.FileName; path = $target; sha256 = $sha
        hashVerification = ($hashChecks -join '; '); hashSource = $src.HashSource
        signatureStatus = $sig.Status; signer = $sig.Signer
        installerType = $App.installerType; silentArgs = $App.silentArgs; detectPath = $App.detectPath
    }
}
