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

if ($Version -and $Version -notmatch '^\d+\.\d+\.\d+([.-]\S+)?$') {
    Write-Error "Invalid version format: $Version (expected X.Y.Z)"
    exit 1
}

function Download-String([string]$Url) {
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        return (Invoke-WebRequest -Uri $Url -UseBasicParsing).Content
    } catch {
        return $null
    } finally {
        $ProgressPreference = $old
    }
}

function Download-FileNet([string]$Url, [string]$OutFile) {
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Timeout = 300000
    $request.AllowAutoRedirect = $true
    $request.UserAgent = 'supercharge-installer'
    $response = $request.GetResponse()
    $total = $response.ContentLength
    $stream = $response.GetResponseStream()
    $fileStream = [System.IO.File]::Create($OutFile)
    $buffer = New-Object byte[] 65536
    $downloaded = [long]0
    try {
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $read)
            $downloaded += $read
            if ($total -gt 0) {
                $pct = [Math]::Min(100, [int](($downloaded / $total) * 100))
                Write-Progress -Activity 'Downloading Supercharge' -Status ('{0:N1} / {1:N1} MB' -f ($downloaded / 1MB), ($total / 1MB)) -PercentComplete $pct
            } else {
                Write-Progress -Activity 'Downloading Supercharge' -Status ('{0:N1} MB' -f ($downloaded / 1MB))
            }
        }
    } finally {
        Write-Progress -Activity 'Downloading Supercharge' -Completed
        $fileStream.Close()
        $stream.Close()
        $response.Close()
    }
}

function Download-File([string]$Url, [string]$OutFile) {
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & curl.exe -fL --progress-bar -o $OutFile $Url
        if ($LASTEXITCODE -eq 0) { return }

        # Windows Schannel often fails with CRYPT_E_REVOCATION_OFFLINE when the
        # CRL/OCSP endpoint is blocked or unreachable. Retry without that check.
        Write-Host "HTTPS certificate revocation check failed; retrying without it..." -ForegroundColor Yellow
        & curl.exe -fL --ssl-no-revoke --progress-bar -o $OutFile $Url
        if ($LASTEXITCODE -eq 0) { return }
    }

    try {
        Download-FileNet $Url $OutFile
        return
    } catch {
        $prevCrl = [Net.ServicePointManager]::CheckCertificateRevocationList
        try {
            [Net.ServicePointManager]::CheckCertificateRevocationList = $false
            Download-FileNet $Url $OutFile
            return
        } catch {
            throw
        } finally {
            [Net.ServicePointManager]::CheckCertificateRevocationList = $prevCrl
        }
    }
}

function Add-UserPath([string]$Dir) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { $userPath = '' }
    $parts = @($userPath -split ';' | Where-Object { $_ -and $_.Trim() -ne '' })
    $already = $false
    foreach ($p in $parts) {
        if ([string]::Equals($p.TrimEnd('\'), $Dir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            $already = $true
            break
        }
    }
    if (-not $already) {
        $joined = if ($parts.Count -gt 0) { ($parts + $Dir) -join ';' } else { $Dir }
        [Environment]::SetEnvironmentVariable('Path', $joined, 'User')
        Write-Host "Added $Dir to your user PATH." -ForegroundColor DarkGray
    }
    $sessionParts = @($env:Path -split ';' | Where-Object { $_ })
    $inSession = $false
    foreach ($p in $sessionParts) {
        if ([string]::Equals($p.TrimEnd('\'), $Dir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            $inSession = $true
            break
        }
    }
    if (-not $inSession) {
        $env:Path = "$Dir;$env:Path"
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
$exe = Join-Path $BinDir 'supercharge.exe'
$tmp = Join-Path $env:TEMP "supercharge-$Version-$platform.exe.tmp"

New-Item -ItemType Directory -Force -Path $BinDir, $ConfigHome | Out-Null

Write-Host "Downloading Supercharge $Version ($platform)..." -ForegroundColor Cyan
try {
    Download-File "$baseUrl/$asset" $tmp
} catch {
    Remove-Item -Force -ErrorAction SilentlyContinue $tmp
    Write-Error @"
Download failed for $baseUrl/$asset

$($_.Exception.Message)

If you saw CRYPT_E_REVOCATION_OFFLINE / schannel, Windows could not reach the
certificate revocation server (firewall, proxy, or offline OCSP). Try another
network, or download the file in a browser from:
  $baseUrl/$asset
"@
    exit 1
}

Move-Item -Force $tmp $exe
Copy-Item -Force $exe (Join-Path $BinDir 'sc.exe')
Add-UserPath $BinDir

Write-Host @"

Installed Supercharge AI ${Version}:
  $exe
  $(Join-Path $BinDir 'sc.exe')

Configuration home:
  $ConfigHome

This terminal can run it now. New terminals will pick up PATH automatically.

  supercharge
  sc
"@
