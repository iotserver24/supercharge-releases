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

function Write-Banner {
    Write-Host ""
    Write-Host "  Supercharge AI installer" -ForegroundColor Cyan
    Write-Host "  ────────────────────────" -ForegroundColor DarkGray
}

function Write-Step([string]$N, [string]$Label, [string]$Detail = '') {
    Write-Host -NoNewline "  " -ForegroundColor Cyan
    Write-Host -NoNewline "$N/4  " -ForegroundColor Cyan
    Write-Host -NoNewline $Label
    if ($Detail) {
        Write-Host "  $Detail" -ForegroundColor DarkGray
    } else {
        Write-Host ""
    }
}

function Write-Ok([string]$Msg) {
    Write-Host -NoNewline "       "
    Write-Host -NoNewline "✓ " -ForegroundColor Green
    Write-Host $Msg
}

function Write-Warn([string]$Msg) {
    Write-Host -NoNewline "       "
    Write-Host -NoNewline "! " -ForegroundColor Yellow
    Write-Host $Msg
}

function Write-Fail([string]$Msg) {
    Write-Host -NoNewline "       "
    Write-Host -NoNewline "✗ " -ForegroundColor Red
    Write-Host $Msg
}

Write-Banner

if ($PSVersionTable.Platform -and $PSVersionTable.Platform -ne 'Win32NT') {
    Write-Fail "This installer is for Windows. On macOS/Linux use install.sh instead."
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
    Write-Fail "Invalid version format: $Version (expected X.Y.Z)"
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

        Write-Warn "HTTPS certificate revocation check failed; retrying without it..."
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
    $result = 'already'
    if (-not $already) {
        $joined = if ($parts.Count -gt 0) { ($parts + $Dir) -join ';' } else { $Dir }
        [Environment]::SetEnvironmentVariable('Path', $joined, 'User')
        $result = 'added'
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
        if ($result -ne 'added') { $result = 'session' }
    }
    return $result
}

$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { 'x86_64' }
    'ARM64' { 'aarch64' }
    default {
        Write-Fail "Unsupported architecture: $($env:PROCESSOR_ARCHITECTURE)"
        exit 1
    }
}

$platform = "windows-$arch"
$asset = "supercharge-$platform.exe"

Write-Step '1' 'Version'
if (-not $Version) {
    $latest = Download-String "https://api.github.com/repos/$Repo/releases/latest"
    if ($latest -and $latest -match '"tag_name"\s*:\s*"v?([^"]+)"') {
        $Version = $Matches[1]
    } else {
        Write-Warn "GitHub API unavailable; falling back to release asset."
        $fallback = Download-String "https://github.com/$Repo/releases/latest/download/version"
        if ($fallback) { $Version = $fallback.Trim() }
    }
}

if (-not $Version) {
    Write-Fail "Failed to resolve latest version from $Repo"
    exit 1
}
Write-Ok "$Version  ($platform)"

$tag = "v$($Version -replace '^v','')"
$baseUrl = "https://github.com/$Repo/releases/download/$tag"
$exe = Join-Path $BinDir 'supercharge.exe'
$tmp = Join-Path $env:TEMP "supercharge-$Version-$platform.exe.tmp"

try {
    New-Item -ItemType Directory -Force -Path $BinDir, $ConfigHome | Out-Null
} catch {
    Write-Fail "Cannot create install directories (permission denied?)."
    Write-Host "         $BinDir" -ForegroundColor DarkGray
    Write-Host "         $ConfigHome" -ForegroundColor DarkGray
    Write-Host "         $($_.Exception.Message)" -ForegroundColor DarkGray
    exit 1
}

Write-Step '2' 'Download' $asset
try {
    Download-File "$baseUrl/$asset" $tmp
} catch {
    Remove-Item -Force -ErrorAction SilentlyContinue $tmp
    Write-Fail "Download failed"
    Write-Host "         $baseUrl/$asset" -ForegroundColor DarkGray
    Write-Host "         $($_.Exception.Message)" -ForegroundColor DarkGray
    Write-Host "         If CRYPT_E_REVOCATION_OFFLINE / schannel: try another network, or download in a browser." -ForegroundColor DarkGray
    Write-Host "         If Access denied: antivirus or folder ACLs; avoid installing as a different admin user." -ForegroundColor DarkGray
    exit 1
}
Write-Ok 'saved'

Write-Step '3' 'Install' $BinDir
try {
    Move-Item -Force $tmp $exe
    Copy-Item -Force $exe (Join-Path $BinDir 'sc.exe')
} catch {
    Remove-Item -Force -ErrorAction SilentlyContinue $tmp
    Write-Fail "Cannot write to $BinDir (permission denied?)."
    Write-Host "         $($_.Exception.Message)" -ForegroundColor DarkGray
    Write-Host "         If this folder is owned by Administrators, take ownership or pick another SUPERCHARGE_BIN_DIR." -ForegroundColor DarkGray
    exit 1
}
Write-Ok $exe
Write-Ok (Join-Path $BinDir 'sc.exe')

Write-Step '4' 'PATH'
$pathState = Add-UserPath $BinDir
switch ($pathState) {
    'added' { Write-Ok "added $BinDir to user PATH" }
    'session' { Write-Ok "on PATH in this session (user PATH already had it)" }
    default { Write-Ok 'already on PATH' }
}

Write-Host ""
Write-Host "  Installed Supercharge AI $Version" -ForegroundColor Green
Write-Host "  Config: $ConfigHome" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Start:"
Write-Host "    supercharge"
Write-Host "    sc"
Write-Host ""
Write-Host "  This terminal can run it now. New terminals pick up PATH automatically." -ForegroundColor DarkGray
Write-Host ""
