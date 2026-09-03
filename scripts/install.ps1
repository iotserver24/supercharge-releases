#
# Supercharge AI public installer for Windows PowerShell
#
# Usage:
#   irm https://raw.githubusercontent.com/iotserver24/supercharge-releases/main/scripts/install.ps1 | iex
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/iotserver24/supercharge-releases/main/scripts/install.ps1))) -Version 1.0.5
#   $env:SUPERCHARGE_VERSION="1.0.5"; irm ... | iex
#

param(
    [Parameter(Position = 0)]
    [string]$Version
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

# This script is Windows-only; check before referencing USERPROFILE (unset on macOS/Linux).
if ($PSVersionTable.Platform -and $PSVersionTable.Platform -ne 'Win32NT') {
    Write-Error "This installer is for Windows. On macOS/Linux use install.sh instead."
    exit 1
}

if (-not $Version -and $env:SUPERCHARGE_VERSION) {
    $Version = $env:SUPERCHARGE_VERSION
}
$Version = $Version -replace '^v', ''

$Repo = if ($env:SUPERCHARGE_GITHUB_REPO) { $env:SUPERCHARGE_GITHUB_REPO } else { 'iotserver24/supercharge-releases' }
$BinDir = if ($env:SUPERCHARGE_BIN_DIR) { $env:SUPERCHARGE_BIN_DIR } else { Join-Path $env:USERPROFILE '.local\bin' }
$ConfigHome = if ($env:SUPERCHARGE_HOME) { $env:SUPERCHARGE_HOME } else { Join-Path $env:USERPROFILE '.supercharge' }
$DownloadDir = if ($env:SUPERCHARGE_DOWNLOAD_DIR) { $env:SUPERCHARGE_DOWNLOAD_DIR } else { Join-Path $ConfigHome 'downloads' }

if ($Version -and $Version -notmatch '^\d+\.\d+\.\d+([.-]\S+)?$') {
    Write-Error "Invalid version format: $Version (expected X.Y.Z)"
    exit 1
}

function Download-String([string]$Url) {
    try {
        return (Invoke-WebRequest -Uri $Url -UseBasicParsing).Content
    } catch {
        return $null
    }
}

function Download-File([string]$Url, [string]$OutFile) {
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Timeout = 300000
    $response = $request.GetResponse()
    $stream = $response.GetResponseStream()
    $fileStream = [System.IO.File]::Create($OutFile)
    $buffer = New-Object byte[] 65536
    try {
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $read)
        }
    } finally {
        $fileStream.Close()
        $stream.Close()
        $response.Close()
    }
}

$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { 'x86_64' }
    'ARM64' { 'aarch64' }
    default {
        Write-Error "Unsupported architecture: $($env:PROCESSOR_ARCHITECTURE)"
        exit 1
    }
}

$platform = "windows-$arch"
$asset = "supercharge-$platform.exe"

if (-not $Version) {
    Write-Host "Fetching latest release from $Repo..." -ForegroundColor DarkGray
    $latest = Download-String "https://api.github.com/repos/$Repo/releases/latest"
    if ($latest -and $latest -match '"tag_name"\s*:\s*"v?([^"]+)"') {
        $Version = $Matches[1]
    } else {
        $fallback = Download-String "https://github.com/$Repo/releases/latest/download/version"
        if ($fallback) { $Version = $fallback.Trim() }
    }
}

if (-not $Version) {
    Write-Error "Failed to resolve latest version from $Repo"
    exit 1
}

$tag = "v$($Version -replace '^v','')"
$baseUrl = "https://github.com/$Repo/releases/download/$tag"
New-Item -ItemType Directory -Force -Path $BinDir, $ConfigHome, $DownloadDir | Out-Null

$binaryPath = Join-Path $DownloadDir "supercharge-$Version-$platform.exe"
$binaryTmp = "$binaryPath.tmp"

Write-Host "Installing Supercharge $Version ($platform) from $Repo..." -ForegroundColor Cyan
try {
    Download-File "$baseUrl/$asset" $binaryTmp
} catch {
    Write-Error "Download failed for $baseUrl/$asset. This platform may not be published yet."
    exit 1
}

Move-Item -Force $binaryTmp $binaryPath
Copy-Item -Force $binaryPath (Join-Path $BinDir 'supercharge.exe')
Copy-Item -Force $binaryPath (Join-Path $BinDir 'sc.exe')

Write-Host @"

Installed Supercharge AI ${Version}:
  $(Join-Path $BinDir 'supercharge.exe')
  $(Join-Path $BinDir 'sc.exe')

Configuration home:
  $ConfigHome

Add $BinDir to your user PATH, then run:
  supercharge
  sc
"@
