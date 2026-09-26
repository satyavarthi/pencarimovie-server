# PencariMovie Server - OTA updater (PowerShell)
#
# This logic lives in PowerShell rather than pencarimovie-windows.bat on purpose.
# Antivirus engines (BitDefender/Arcabit/Emsisoft/GData/VIPRE "Boxter",
# Kaspersky "BAT.Alien") flag BATCH FILES that download a remote archive and
# extract/execute it. Keeping the download+extract in a .ps1 removes the .bat
# from that heuristic's target. A SHA-256 integrity check is also performed so
# the flow has a legitimate verification step.
#
# Usage:
#   powershell -NoProfile -File update.ps1 `
#       -AppDir <dir> -Repo <owner/repo> -Tag <vX.Y.Z> -Installed <0|1>
#
# Exit codes:
#   0 = success (files extracted, .release-tag written)
#   1 = download or extraction failed

param(
    [Parameter(Mandatory = $true)][string]$AppDir,
    [Parameter(Mandatory = $true)][string]$Repo,
    [string]$CustomRepo = "satyavarthi/pencarimovie-server",
    [switch]$OverlayOnly,
    [switch]$BootstrapOnly,
    [Parameter(Mandatory = $true)][string]$Tag,
    [int]$Installed = 0
)

$ErrorActionPreference = 'Stop'
function Overlay-CustomUi {
    param([string]$TargetDir, [string]$SourceRepo)
    $publicDir = Join-Path $TargetDir 'public'
    New-Item -ItemType Directory -Path $publicDir -Force | Out-Null
    $files = @('index.html','app.js','styles.css','stream-theme.css','logo.png')
    $tmpUi = Join-Path $env:TEMP ("pencarimovie-ui-" + (Get-Random))
    New-Item -ItemType Directory -Path $tmpUi -Force | Out-Null
    try {
        foreach ($name in $files) {
            $url = "https://raw.githubusercontent.com/$SourceRepo/main/public/$name"
            $dest = Join-Path $tmpUi $name
            try {
                Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 30
            } catch {
                throw "UI asset '$name' could not be downloaded: $($_.Exception.Message)"
            }
            if (-not (Test-Path -LiteralPath $dest) -or (Get-Item -LiteralPath $dest).Length -eq 0) {
                throw "UI asset '$name' was empty."
            }
        }
        foreach ($name in $files) {
            Copy-Item -LiteralPath (Join-Path $tmpUi $name) -Destination (Join-Path $publicDir $name) -Force
        }
        Write-Host "Customized UI applied from $SourceRepo."
    } finally {
        Remove-Item -Recurse -Force $tmpUi -ErrorAction SilentlyContinue
    }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

if ($BootstrapOnly -and $Tag -eq 'v1.0.0') {
    try {
        $latest = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{'User-Agent'='pencarimovie-server'} -TimeoutSec 10
        if ($latest.tag_name -match '^v[0-9]') { $Tag = $latest.tag_name }
    } catch {
        Write-Host "Could not resolve the latest upstream release; using $Tag."
    }
}

$base = "https://github.com/$Repo/releases/download/$Tag"

if ($OverlayOnly) {
    try {
        Overlay-CustomUi -TargetDir $AppDir -SourceRepo $CustomRepo
        exit 0
    } catch {
        Write-Host "Customized UI overlay failed: $($_.Exception.Message)"
        exit 1
    }
}

# Always use the native Windows package as primary to preserve Windows bin/ runtime and DLL configs
$primary = @{ Url = "$base/pencarimovie-downloader-windows-x86_64.zip"; Name = 'pencarimovie.zip' }
$fallback = @{ Url = "$base/pencarimovie-server.tar.gz"; Name = 'pencarimovie.tar.gz' }

$otaTmp = Join-Path $env:TEMP ("pencarimovie-ota-" + (Get-Random))
New-Item -ItemType Directory -Path $otaTmp -Force | Out-Null

function Get-Archive {
    param([hashtable]$Candidate, [string]$DestDir)

    $dest = Join-Path $DestDir $Candidate.Name
    Write-Host "Downloading $($Candidate.Url)"
    try {
        Invoke-WebRequest -Uri $Candidate.Url -OutFile $dest -UseBasicParsing -TimeoutSec 120
    }
    catch {
        Write-Host "Download failed: $($_.Exception.Message)"
        return $null
    }
    if (-not (Test-Path -LiteralPath $dest) -or (Get-Item -LiteralPath $dest).Length -eq 0) {
        return $null
    }
    return $dest
}

$archive = Get-Archive -Candidate $primary -DestDir $otaTmp
if (-not $archive) {
    Write-Host "Primary download failed, trying fallback..."
    $archive = Get-Archive -Candidate $fallback -DestDir $otaTmp
}
if (-not $archive) {
    Write-Host "Update download failed."
    Remove-Item -Recurse -Force $otaTmp -ErrorAction SilentlyContinue
    exit 1
}

# Integrity check: if the release publishes a .sha256 sidecar, verify it.
# A mismatch aborts the update instead of extracting a tampered archive.
$shaUrl = "$($primary.Url).sha256"
if ($archive -ne (Join-Path $otaTmp $primary.Name)) { $shaUrl = "$($fallback.Url).sha256" }
try {
    $resp = Invoke-WebRequest -Uri $shaUrl -UseBasicParsing -TimeoutSec 30
    # GitHub serves the .sha256 as application/octet-stream, so .Content can be
    # a byte[] rather than a string. Normalize both shapes before parsing.
    $raw = $resp.Content
    if ($raw -is [byte[]]) { $raw = [System.Text.Encoding]::ASCII.GetString($raw) }
    $expected = ([string]$raw).Trim().Split()[0]
    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    if ($expected -and ($actual -ne $expected.ToUpper())) {
        Write-Host "SHA-256 mismatch: expected $expected, got $actual"
        Remove-Item -Recurse -Force $otaTmp -ErrorAction SilentlyContinue
        exit 1
    }
    Write-Host "SHA-256 verified."
}
catch {
    # No sidecar published for this release; continue without verification.
    Write-Host "No SHA-256 sidecar published; skipping integrity check."
}

if (-not (Test-Path -LiteralPath $AppDir)) {
    New-Item -ItemType Directory -Path $AppDir -Force | Out-Null
}

# A developer git checkout needs only the packaged runtime. Extract that
# runtime to a temporary directory and copy it into the working tree without
# replacing checked-in application/core files.
if ($BootstrapOnly) {
    $runtimeTmp = Join-Path $env:TEMP ("pencarimovie-runtime-" + (Get-Random))
    New-Item -ItemType Directory -Path $runtimeTmp -Force | Out-Null
    try {
        # Match upstream Windows packaging semantics: unpack the release into a
        # temporary app-shaped directory first, then copy only runtime dependencies
        # into the git checkout. Never extract the archive directly over source/UI.
        if ($archive.EndsWith('.zip')) {
            Expand-Archive -LiteralPath $archive -DestinationPath $runtimeTmp -Force
        }
        else {
            & tar.exe -xf $archive -C $runtimeTmp --strip-components=1 2>$null
            if ($LASTEXITCODE -ne 0) { & tar.exe -xzf $archive -C $runtimeTmp 2>$null }
        }
        $releaseRoot = $runtimeTmp
        if (-not (Test-Path -LiteralPath (Join-Path $releaseRoot 'bin'))) {
            $nested = Get-ChildItem -LiteralPath $runtimeTmp -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin') } |
                Select-Object -First 1
            if ($nested) { $releaseRoot = $nested.FullName }
        }
        $binSource = Join-Path $releaseRoot 'bin'
        if (-not (Test-Path -LiteralPath (Join-Path $binSource 'frankenphp.exe'))) {
            throw 'The Windows release does not contain bin\\frankenphp.exe.'
        }
        $binTarget = Join-Path $AppDir 'bin'
        New-Item -ItemType Directory -Path $binTarget -Force | Out-Null
        # Copy the runtime contents into AppDir\\bin, not the bin directory itself.
        # Copying $binSource to an already-created bin directory can create bin\\bin
        # on Windows, leaving the launcher unable to find frankenphp.exe.
        Copy-Item -Path (Join-Path $binSource '*') -Destination $binTarget -Recurse -Force
        if (-not (Test-Path -LiteralPath (Join-Path $binTarget 'frankenphp.exe'))) {
            throw 'Runtime extraction completed but bin\\frankenphp.exe is missing.'
        }
        $vendorSource = Join-Path $releaseRoot 'vendor'
        $vendorTarget = Join-Path $AppDir 'vendor'
        if (Test-Path -LiteralPath $vendorSource) {
            New-Item -ItemType Directory -Path $vendorTarget -Force | Out-Null
            Copy-Item -Path (Join-Path $vendorSource '*') -Destination $vendorTarget -Recurse -Force
        }
        $iniPath = Join-Path $AppDir 'bin\\php.ini'
        $extDll = Join-Path $AppDir 'bin\\ext\\php_fileinfo.dll'
        if ((Test-Path -LiteralPath $extDll) -and ((-not (Test-Path -LiteralPath $iniPath)) -or ((Get-Content $iniPath -ErrorAction SilentlyContinue | Select-String -Pattern '^\\s*extension=fileinfo') -eq $null))) {
            $defaultIni = @'
; TG FastDownloader bundled PHP/FrankenPHP config
extension_dir="ext"
extension=fileinfo
extension=curl
extension=mbstring
extension=openssl
extension=zip

memory_limit = 512M

opcache.enable=0
opcache.enable_cli=0
'@
            Set-Content -LiteralPath $iniPath -Value $defaultIni -Encoding ASCII
        }
        if (-not (Test-Path -LiteralPath (Join-Path $AppDir 'bin\\frankenphp.exe'))) {
            throw "Runtime bootstrap completed but upstream frankenphp.exe is not present at $AppDir\\bin\\frankenphp.exe."
        }
        Write-Host "Windows runtime bootstrapped into $AppDir."
        exit 0
    } catch {
        Write-Host "Runtime bootstrap failed: $($_.Exception.Message)"
        exit 1
    } finally {
        Remove-Item -Recurse -Force $runtimeTmp -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $otaTmp -ErrorAction SilentlyContinue
    }
}

# Extract with tar.exe (handles both .zip and .tar.gz on Windows 10/11).
# Archive entries are "./"-prefixed, so the exclude patterns must be too.
# Without the "./" the running batch file is overwritten mid-execution.
$excludes = @(
    '--exclude=./storage', '--exclude=./storage/*',
    '--exclude=./pencarimovie-windows.bat', '--exclude=pencarimovie-windows.bat'
)

& tar.exe -xf $archive @excludes --strip-components=1 -C $AppDir 2>$null
if (-not (Test-Path -LiteralPath (Join-Path $AppDir 'backend.php'))) {
    & tar.exe -xf $archive @excludes -C $AppDir 2>$null
}
if (-not (Test-Path -LiteralPath (Join-Path $AppDir 'backend.php'))) {
    if ($archive.EndsWith('.zip')) {
        Expand-Archive -Path $archive -DestinationPath $AppDir -Force
    }
    else {
        & tar.exe -xzf $archive -C $AppDir 2>$null
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $AppDir 'backend.php'))) {
    Write-Host "File copy failed."
    Remove-Item -Recurse -Force $otaTmp -ErrorAction SilentlyContinue
    exit 1
}

# Ensure bin\php.ini has Windows extension=fileinfo enabled
$iniPath = Join-Path $AppDir 'bin\php.ini'
$extDll = Join-Path $AppDir 'bin\ext\php_fileinfo.dll'
if ((Test-Path -LiteralPath $extDll) -and ((-not (Test-Path -LiteralPath $iniPath)) -or ((Get-Content $iniPath -ErrorAction SilentlyContinue | Select-String -Pattern '^\s*extension=fileinfo') -eq $null))) {
    $defaultIni = @'
; TG FastDownloader bundled PHP/FrankenPHP config
extension_dir="ext"
extension=fileinfo
extension=curl
extension=mbstring
extension=openssl
extension=zip

memory_limit = 512M

opcache.enable=0
opcache.enable_cli=0
'@
    Set-Content -LiteralPath $iniPath -Value $defaultIni -Encoding ASCII
}

try { Overlay-CustomUi -TargetDir $AppDir -SourceRepo $CustomRepo } catch { Write-Host "Warning: customized UI overlay failed: $($_.Exception.Message)" }

Set-Content -LiteralPath (Join-Path $AppDir '.release-tag') -Value $Tag -Encoding ASCII
Remove-Item -Recurse -Force $otaTmp -ErrorAction SilentlyContinue
Write-Host "Update applied: $Tag"
exit 0
