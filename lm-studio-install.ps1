#Requires -Version 5.1
<#
.SYNOPSIS
    LM Studio installation / update script for Windows.

.DESCRIPTION
    Downloads the official LM Studio desktop installer from lmstudio.ai and
    installs or upgrades it. Supports version pinning, non-interactive mode,
    update checks, and uninstall.

    NOTE: The official one-liner at lmstudio.ai/install.ps1 installs *llmster*
    (headless daemon), not the full desktop app. This script installs the GUI.

.PARAMETER Version
    Target version to install (e.g. 0.4.20-1). Default: latest.

.PARAMETER Yes
    Non-interactive mode; accept prompts automatically.

.PARAMETER Quiet
    Suppress informational output.

.PARAMETER Subcommand
    Optional: info | check | uninstall

.EXAMPLE
    .\lm-studio-install.ps1
    .\lm-studio-install.ps1 -Version 0.4.20-1 -Yes
    .\lm-studio-install.ps1 check
    .\lm-studio-install.ps1 uninstall -Yes
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('', 'info', 'check', 'uninstall', 'help')]
    [string]$Subcommand = '',

    [Alias('v', 'ver')]
    [string]$Version = '',

    [Alias('y')]
    [switch]$Yes,

    [Alias('q')]
    [switch]$Quiet,

    [Alias('h')]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ===============================
# CONFIGURATION
# ===============================
$script:StateDir = Join-Path $env:LOCALAPPDATA 'lm-studio-installer'
$script:VersionFile = Join-Path $script:StateDir 'installed_version.txt'
$script:DownloadDir = Join-Path $script:StateDir 'downloads'
$script:MinInstallerBytes = 50MB
$script:LatestUrlBase = 'https://lmstudio.ai/download/latest/win32'
$script:InstallerUrlBase = 'https://installers.lmstudio.ai/win32'

# Common install locations used by Electron / NSIS builds
$script:KnownInstallRoots = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\LM Studio'),
    (Join-Path $env:LOCALAPPDATA 'LM Studio'),
    (Join-Path $env:ProgramFiles 'LM Studio'),
    (Join-Path ${env:ProgramFiles(x86)} 'LM Studio')
) | Where-Object { $_ }

# ===============================
# LOGGING
# ===============================
function Write-Info {
    param([string]$Message)
    if (-not $Quiet) { Write-Host "i  $Message" -ForegroundColor Cyan }
}
function Write-Ok {
    param([string]$Message)
    if (-not $Quiet) { Write-Host "OK $Message" -ForegroundColor Green }
}
function Write-WarnMsg {
    param([string]$Message)
    Write-Host "!  $Message" -ForegroundColor Yellow
}
function Write-ErrMsg {
    param([string]$Message)
    Write-Host "X  $Message" -ForegroundColor Red
}

function Show-Usage {
    @'
Usage: lm-studio-install.ps1 [OPTIONS] [SUBCOMMAND]

Subcommands:
  (none)       Install or upgrade LM Studio (desktop app)
  uninstall    Remove LM Studio
  info         Show installed version and paths
  check        Check if a newer version is available

Options:
  -Version, -v, -ver <ver>   Target version (e.g. 0.4.20-1)
  -Yes, -y                   Non-interactive: accept prompts
  -Quiet, -q                 Suppress informational output
  -Help, -h                  Show this help

Environment:
  LMS_INSTALL_DIR            Preferred install path hint (passed to installer when supported)

Examples:
  .\lm-studio-install.ps1
  .\lm-studio-install.ps1 -Version 0.4.20-1 -Yes
  .\lm-studio-install.ps1 check
  .\lm-studio-install.ps1 uninstall -Yes
'@ | Write-Host
}

# ===============================
# ARCHITECTURE & VERSION
# ===============================
function Get-WindowsArchToken {
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') {
        return 'arm64'
    }
    if ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') {
        return 'x64'
    }
    throw "Unsupported architecture: $($env:PROCESSOR_ARCHITECTURE)"
}

function Test-VersionFormat {
    param([string]$Ver)
    return [bool]($Ver -match '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$')
}

function Get-LatestVersion {
    param([string]$Arch = (Get-WindowsArchToken))

    $url = "$script:LatestUrlBase/$Arch"
    try {
        # Follow redirects; final URL contains the versioned filename.
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method = 'HEAD'
        $req.AllowAutoRedirect = $true
        $req.Timeout = 15000
        $resp = $req.GetResponse()
        try {
            $final = $resp.ResponseUri.AbsoluteUri
        }
        finally {
            $resp.Close()
        }

        if ($final -match 'LM-Studio-([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9]+)?)-') {
            return $Matches[1]
        }
    }
    catch {
        Write-WarnMsg "Could not resolve latest version via redirect: $($_.Exception.Message)"
    }

    # Fallback: scrape download page for LM-Studio-X.Y.Z tokens only
    try {
        $page = Invoke-WebRequest -Uri 'https://lmstudio.ai/download' -UseBasicParsing -TimeoutSec 15
        $m = [regex]::Match($page.Content, 'LM-Studio-([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9]+)?)')
        if ($m.Success) { return $m.Groups[1].Value }
        $m2 = [regex]::Match($page.Content, '0\.[0-9]+\.[0-9]+(?:-[0-9]+)?')
        if ($m2.Success) { return $m2.Value }
    }
    catch {
        Write-WarnMsg "Could not reach lmstudio.ai - check your network connection."
    }
    return $null
}

function Get-InstallerUrl {
    param(
        [Parameter(Mandatory)][string]$Ver,
        [string]$Arch = (Get-WindowsArchToken)
    )
    $name = "LM-Studio-$Ver-$Arch.exe"
    return "$script:InstallerUrlBase/$Arch/$Ver/$name"
}

function Get-ExeFileVersion {
    param([string]$ExePath)
    if (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath)) { return $null }
    try {
        $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($ExePath)
        foreach ($candidate in @($vi.ProductVersion, $vi.FileVersion)) {
            if (-not $candidate) { continue }
            # Normalize e.g. 0.4.20.1 or 0.4.20-1
            $norm = $candidate.Trim()
            if ($norm -match '^([0-9]+\.[0-9]+\.[0-9]+)(?:[.-]([0-9]+))?') {
                if ($Matches[2]) { return "$($Matches[1])-$($Matches[2])" }
                return $Matches[1]
            }
        }
    }
    catch { }
    return $null
}

function Get-RecordedVersion {
    if (Test-Path -LiteralPath $script:VersionFile) {
        $v = (Get-Content -LiteralPath $script:VersionFile -Raw).Trim()
        if ($v) { return $v }
    }
    # Fall back to FileVersion of installed executable
    $path = Get-LmStudioInstallPath
    if ($path) {
        $exe = Join-Path $path 'LM Studio.exe'
        return Get-ExeFileVersion -ExePath $exe
    }
    return $null
}

function Set-RecordedVersion {
    param([string]$Ver)
    if (-not (Test-Path -LiteralPath $script:StateDir)) {
        New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
    }
    Set-Content -LiteralPath $script:VersionFile -Value $Ver -Encoding UTF8
}

# ===============================
# DISCOVERY (install / uninstall)
# ===============================
function Get-LmStudioInstallPath {
    foreach ($root in $script:KnownInstallRoots) {
        $exe = Join-Path $root 'LM Studio.exe'
        if (Test-Path -LiteralPath $exe) { return $root }
    }

    # Registry uninstall keys
    $uninstallRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstallRoots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $p = Get-ItemProperty $_.PSPath -ErrorAction Stop
                $dn = [string]$p.DisplayName
                if ($dn -like '*LM Studio*') {
                    if ($p.InstallLocation -and (Test-Path -LiteralPath $p.InstallLocation)) {
                        return $p.InstallLocation
                    }
                }
            }
            catch { }
        }
    }
    return $null
}

function Get-LmStudioUninstallCommand {
    $uninstallRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstallRoots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($key in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            try {
                $p = Get-ItemProperty $key.PSPath -ErrorAction Stop
                $dn = [string]$p.DisplayName
                if ($dn -like '*LM Studio*') {
                    if ($p.QuietUninstallString) { return [string]$p.QuietUninstallString }
                    if ($p.UninstallString) { return [string]$p.UninstallString }
                }
            }
            catch { }
        }
    }
    return $null
}

# ===============================
# DOWNLOAD & VALIDATE
# ===============================
function Test-PeExecutable {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $fi = Get-Item -LiteralPath $Path
    $sizeBytes = $fi.Length
    if ($sizeBytes -lt $script:MinInstallerBytes) {
        Write-ErrMsg ("File is suspiciously small ({0} bytes). Download may be incomplete." -f $sizeBytes)
        return $false
    }
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $b0 = $fs.ReadByte()
        $b1 = $fs.ReadByte()
        # MZ header
        if ($b0 -ne 0x4D -or $b1 -ne 0x5A) {
            Write-ErrMsg "Not a valid Windows PE executable (missing MZ header)."
            return $false
        }
    }
    finally {
        $fs.Close()
    }
    # Reject HTML error pages that somehow passed size (unlikely with MIN size)
    $head = Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction SilentlyContinue
    if ($head -match '<!DOCTYPE|<html') {
        Write-ErrMsg "Got an HTML error page - wrong version or server error?"
        return $false
    }
    Write-Ok ("Download validated (PE/MZ OK, size {0} bytes)" -f $sizeBytes)
    return $true
}

function Invoke-FileDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination
    )
    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force
    }

    Write-Info "Downloading..."
    if (-not $Quiet) { Write-Host "  URL: $Url" }

    # Progress-friendly download via WebClient / BITS not required; use IWR stream
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = 'GET'
    $req.AllowAutoRedirect = $true
    $req.Timeout = 60000
    $req.ReadWriteTimeout = 600000
    $resp = $req.GetResponse()
    try {
        $total = $resp.ContentLength
        $stream = $resp.GetResponseStream()
        $file = [System.IO.File]::Create($Destination)
        try {
            $buffer = New-Object byte[] 65536
            $readTotal = [long]0
            $last = [DateTime]::UtcNow
            while ($true) {
                $n = $stream.Read($buffer, 0, $buffer.Length)
                if ($n -le 0) { break }
                $file.Write($buffer, 0, $n)
                $readTotal += $n
                if (-not $Quiet) {
                    $now = [DateTime]::UtcNow
                    if (($now - $last).TotalMilliseconds -gt 250) {
                        if ($total -gt 0) {
                            $pct = [int](($readTotal / $total) * 100)
                            $mbR = [math]::Round($readTotal / 1MB, 1)
                            $mbT = [math]::Round($total / 1MB, 1)
                            Write-Progress -Activity 'Downloading LM Studio' -Status "$mbR MB / $mbT MB" -PercentComplete $pct
                        }
                        else {
                            $mbR = [math]::Round($readTotal / 1MB, 1)
                            Write-Progress -Activity 'Downloading LM Studio' -Status "$mbR MB downloaded" -PercentComplete -1
                        }
                        $last = $now
                    }
                }
            }
        }
        finally {
            $file.Close()
            $stream.Close()
        }
    }
    finally {
        $resp.Close()
        if (-not $Quiet) { Write-Progress -Activity 'Downloading LM Studio' -Completed }
    }
    Write-Ok "Downloaded to $Destination"
}

function Invoke-TextDownload {
    param([Parameter(Mandatory)][string]$Url)
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30
    if ($response.Content -is [byte[]]) {
        return [System.Text.Encoding]::ASCII.GetString($response.Content)
    }
    return [string]$response.Content
}

function Test-Sha512 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ArtifactUrl
    )

    $expected = (Invoke-TextDownload -Url "$ArtifactUrl.sha512").Trim()
    if ($expected -notmatch '^[A-Fa-f0-9]{128}$') {
        throw 'Malformed SHA-512 sidecar.'
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA512).Hash
    if ($actual -ine $expected) {
        throw 'SHA-512 mismatch.'
    }
    Write-Ok 'SHA-512 verified'
}

function Test-LmStudioSignature {
    param([Parameter(Mandatory)][string]$Path)

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid') {
        throw "Invalid Authenticode signature: $($signature.Status)"
    }
    $subject = [string]$signature.SignerCertificate.Subject
    if ($subject -notmatch '(?:^|,\s*)O=Element Labs Inc\.(?:,|$)') {
        throw "Unexpected installer publisher: $subject"
    }
    Write-Ok 'Authenticode signature verified (Element Labs Inc.)'
}

# ===============================
# INSTALL / UNINSTALL
# ===============================
function Show-SecurityNotice {
    Write-Host ""
    Write-WarnMsg "======================================================"
    Write-WarnMsg " SECURITY NOTICE"
    Write-WarnMsg "======================================================"
    Write-Host "  This script downloads LM Studio from official servers."
    Write-Host "  The installer is verified with LM Studio's official"
    Write-Host "  SHA-512 sidecar and an Element Labs Authenticode signature."
    Write-Host ""

    if ($Yes) {
        Write-Info "Skipping confirmation (-Yes)"
        return
    }
    $response = Read-Host "Continue? (yes/no)"
    if ($response -notmatch '^[Yy][Ee][Ss]$') {
        Write-Info "Cancelled."
        exit 0
    }
}

function Install-LmStudio {
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [Parameter(Mandatory)][string]$Ver
    )

    Write-Info "Running installer for v$Ver..."

    # Electron-builder NSIS typically accepts /S for silent.
    # Strategy: if -Yes, run with /S first; fall back to interactive on failure.
    $exitCode = 0
    if ($Yes) {
        $proc = Start-Process -FilePath $InstallerPath -ArgumentList '/S' -Wait -PassThru
        $exitCode = $proc.ExitCode
        if ($exitCode -ne 0) {
            Write-WarnMsg "Silent install exited with code $exitCode; retrying interactive..."
            $proc = Start-Process -FilePath $InstallerPath -Wait -PassThru
            $exitCode = $proc.ExitCode
        }
    }
    else {
        $proc = Start-Process -FilePath $InstallerPath -Wait -PassThru
        $exitCode = $proc.ExitCode
    }

    if ($exitCode -ne 0) {
        throw "Installer exited with code $exitCode"
    }

    Set-RecordedVersion -Ver $Ver
    Write-Ok "Installer finished for v$Ver"

    $installPath = Get-LmStudioInstallPath
    if ($installPath) {
        Write-Ok "Detected install path: $installPath"
    }
    else {
        Write-Info "Install path not yet detectable (shortcuts may still work)."
    }
}

function Invoke-Uninstall {
    $uninstall = Get-LmStudioUninstallCommand
    $installPath = Get-LmStudioInstallPath
    $recorded = Get-RecordedVersion

    if (-not $uninstall -and -not $installPath -and -not $recorded) {
        Write-WarnMsg "LM Studio does not appear to be installed."
        return
    }

    Write-Host ""
    $verLabel = if ($recorded) { $recorded } else { '(unknown)' }
    Write-WarnMsg "This will remove LM Studio $verLabel and associated installer state."

    if (-not $Yes) {
        $response = Read-Host "Are you sure? (yes/no)"
        if ($response -notmatch '^[Yy][Ee][Ss]$') {
            Write-Info "Cancelled."
            return
        }
    }

    if ($uninstall) {
        Write-Info "Running uninstaller..."
        # UninstallString may be quoted path + args
        if ($uninstall -match '^\s*"([^"]+)"\s*(.*)$') {
            $exe = $Matches[1]
            $uargs = $Matches[2].Trim()
            if ($Yes -and $uargs -notmatch '/S') { $uargs = ($uargs + ' /S').Trim() }
            if ($uargs) {
                $p = Start-Process -FilePath $exe -ArgumentList $uargs -Wait -PassThru
            }
            else {
                $p = Start-Process -FilePath $exe -ArgumentList $(if ($Yes) { '/S' } else { '' }) -Wait -PassThru
            }
            if ($p.ExitCode -ne 0) {
                Write-WarnMsg "Uninstaller exit code: $($p.ExitCode)"
            }
        }
        else {
            # bare path or path with unquoted args
            if ($Yes) {
                Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $uninstall /S" -Wait | Out-Null
            }
            else {
                Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $uninstall" -Wait | Out-Null
            }
        }
    }
    elseif ($installPath) {
        Write-WarnMsg "No registry uninstaller found; removing directory $installPath"
        Remove-Item -LiteralPath $installPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $script:StateDir) {
        Remove-Item -LiteralPath $script:StateDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Ok "LM Studio uninstalled (or removal attempted)."
}

function Show-Info {
    $recorded = Get-RecordedVersion
    $path = Get-LmStudioInstallPath
    Write-Host ""
    if ($recorded -or $path) {
        Write-Host "  Installed version: $(if ($recorded) { $recorded } else { '(unknown)' })" -ForegroundColor Green
        Write-Host "  Install path:      $(if ($path) { $path } else { '(not found)' })" -ForegroundColor Green
        Write-Host "  State directory:   $script:StateDir" -ForegroundColor Green
        $exe = if ($path) { Join-Path $path 'LM Studio.exe' } else { $null }
        if ($exe -and (Test-Path -LiteralPath $exe)) {
            Write-Host "  Executable:        $exe" -ForegroundColor Green
        }
    }
    else {
        Write-Host "  LM Studio does not appear to be installed." -ForegroundColor Yellow
    }
    Write-Host ""
}

function Show-Check {
    $arch = Get-WindowsArchToken
    $latest = Get-LatestVersion -Arch $arch
    $installed = Get-RecordedVersion
    $pathOnly = $false
    if (-not $installed) {
        $path = Get-LmStudioInstallPath
        if ($path) {
            $installed = '(present, version unknown)'
            $pathOnly = $true
        }
    }

    Write-Host ""
    if ($installed) {
        Write-Host "  Installed: $installed" -ForegroundColor Green
    }
    else {
        Write-Host "  Installed: (none)" -ForegroundColor Yellow
    }
    if ($latest) {
        Write-Host "  Latest:    $latest" -ForegroundColor Green
        if (-not $pathOnly -and $installed -and $installed -eq $latest) {
            Write-Host ""
            Write-Host "  You are up to date." -ForegroundColor Green
        }
        elseif ($installed -and $installed -ne $latest) {
            Write-Host ""
            Write-Host "  An update may be available. Run without 'check' to upgrade." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "  Latest:    (could not fetch - check https://lmstudio.ai/download)" -ForegroundColor Yellow
    }
    Write-Host ""
}

function Show-GpuInfo {
    try {
        $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name -First 3
        if ($gpu) {
            foreach ($g in $gpu) { Write-Info "GPU: $g" }
        }
        else {
            Write-Info "No GPU information available."
        }
    }
    catch {
        Write-Info "GPU detection skipped."
    }
}

# ===============================
# MAIN
# ===============================
function Invoke-Main {
    if ($Help -or $Subcommand -eq 'help') {
        Show-Usage
        return
    }

    if (-not $Quiet) {
        Write-Host ""
        Write-Host "======================================================="
        Write-Host "         LM Studio Installer / Updater (Windows)       "
        Write-Host "======================================================="
        Write-Host ""
    }

    switch ($Subcommand) {
        'info' {
            Show-Info
            return
        }
        'uninstall' {
            Invoke-Uninstall
            return
        }
        'check' {
            Show-Check
            return
        }
    }

    $arch = Get-WindowsArchToken
    Write-Ok "Architecture: $arch"

    $target = $Version
    if (-not $target) {
        $latest = Get-LatestVersion -Arch $arch
        if ($latest) {
            Write-Info "Latest detected version: $latest"
            if ($Yes) {
                $target = $latest
            }
            else {
                $inputVer = Read-Host "Press Enter to install $latest, or type another version"
                if ([string]::IsNullOrWhiteSpace($inputVer)) {
                    $target = $latest
                }
                else {
                    $target = $inputVer.Trim()
                }
            }
        }
        else {
            Write-WarnMsg "Could not auto-detect latest version."
            Write-Info "Check https://lmstudio.ai/download for the current release."
            $target = Read-Host "Enter the exact version to install (e.g. 0.4.20-1)"
            if ([string]::IsNullOrWhiteSpace($target)) {
                throw "No version entered."
            }
        }
    }

    if (-not (Test-VersionFormat -Ver $target)) {
        throw "Invalid version format: $target (example: 0.4.20-1)"
    }
    Write-Ok "Target version: $target"

    $recorded = Get-RecordedVersion
    if ($recorded -eq $target) {
        Write-WarnMsg "Version $target is already recorded as installed."
        if (-not $Yes) {
            $re = Read-Host "Reinstall anyway? (y/n)"
            if ($re -notmatch '^[Yy]$') {
                Write-Info "Cancelled."
                return
            }
        }
    }
    elseif ($recorded) {
        Write-Info "Upgrading $recorded -> $target"
    }

    Show-SecurityNotice

    $url = Get-InstallerUrl -Ver $target -Arch $arch
    $installerName = "LM-Studio-$target-$arch.exe"
    $dest = Join-Path $script:DownloadDir $installerName

    try {
        Invoke-FileDownload -Url $url -Destination $dest
        if (-not (Test-PeExecutable -Path $dest)) {
            throw "Download validation failed."
        }
        Test-Sha512 -Path $dest -ArtifactUrl $url
        Test-LmStudioSignature -Path $dest
        Install-LmStudio -InstallerPath $dest -Ver $target
        Show-GpuInfo
        Write-Host ""
        Write-Ok "LM Studio v$target installed successfully!"
        Write-Host "  Launch from the Start Menu: LM Studio"
        Write-Host "  Uninstall:  .\lm-studio-install.ps1 uninstall"
        Write-Host ""
    }
    finally {
        # Keep the installer on disk for reuse unless quiet success cleanup preferred.
        # Remove large installer to save space after success.
        if (Test-Path -LiteralPath $dest) {
            Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($env:LMS_INSTALLER_SOURCE_ONLY -ne '1') {
    try {
        Invoke-Main
    }
    catch {
        Write-ErrMsg $_.Exception.Message
        exit 1
    }
}
