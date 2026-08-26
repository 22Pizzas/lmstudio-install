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
$script:StateMarker = Join-Path $script:StateDir '.lmstudio-installer-managed'
$script:DownloadDir = Join-Path $script:StateDir 'downloads'
$script:MinInstallerBytes = 50MB
$script:LatestUrlBase = 'https://lmstudio.ai/download/latest/win32'
$script:InstallerUrlBase = 'https://installers.lmstudio.ai/win32'
$script:NonInteractive = [bool]$Yes
$script:QuietOutput = [bool]$Quiet
$script:RequestedSubcommand = [string]$Subcommand
$script:RequestedVersion = [string]$Version
$script:HelpRequested = [bool]$Help

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
    if (-not $script:QuietOutput) { Write-Host "i  $Message" -ForegroundColor Cyan }
}
function Write-Ok {
    param([string]$Message)
    if (-not $script:QuietOutput) { Write-Host "OK $Message" -ForegroundColor Green }
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

function Get-VersionFromArtifactText {
    param([string]$Text)
    if ($Text -match 'LM-Studio-([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9]+)?)-') {
        return $Matches[1]
    }
    return $null
}

function Resolve-LatestRedirect {
    param([Parameter(Mandatory)][string]$Url)
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = 'HEAD'
    $request.AllowAutoRedirect = $true
    $request.Timeout = 15000
    $response = $request.GetResponse()
    try { return $response.ResponseUri.AbsoluteUri }
    finally { $response.Close() }
}

function Get-LatestVersion {
    param([string]$Arch = (Get-WindowsArchToken))

    $url = "$script:LatestUrlBase/$Arch"
    try {
        $final = Resolve-LatestRedirect -Url $url
        $redirectVersion = Get-VersionFromArtifactText -Text $final
        if ($redirectVersion) { return $redirectVersion }
    }
    catch {
        Write-WarnMsg "Could not resolve latest version via redirect: $($_.Exception.Message)"
    }

    # Fallback: scrape download page for LM-Studio-X.Y.Z tokens only
    try {
        $page = Invoke-WebRequest -Uri 'https://lmstudio.ai/download' -UseBasicParsing -TimeoutSec 15
        $pageText = if ($page.Content -is [byte[]]) {
            [System.Text.Encoding]::UTF8.GetString($page.Content)
        }
        else { [string]$page.Content }
        return Get-VersionFromArtifactText -Text $pageText
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

function ConvertTo-LmStudioVersion {
    param([string]$Value)
    if ($Value -and $Value.Trim() -match '^([0-9]+\.[0-9]+\.[0-9]+)(?:[.+-]([0-9]+))?') {
        if ($Matches[2]) { return "$($Matches[1])-$($Matches[2])" }
        return $Matches[1]
    }
    return $null
}

function ConvertTo-VersionObject {
    param([Parameter(Mandatory)][string]$Value)
    $normalized = ConvertTo-LmStudioVersion -Value $Value
    if (-not $normalized) { throw "Invalid LM Studio version: $Value" }
    $parts = $normalized -split '-', 2
    $build = if ($parts.Count -eq 2) { [int]$parts[1] } else { 0 }
    return [version]"$($parts[0]).$build"
}

function Get-VersionFromInfo {
    param($Info)
    foreach ($candidate in @($Info.FileVersion, $Info.ProductVersion)) {
        $normalized = ConvertTo-LmStudioVersion -Value ([string]$candidate)
        if ($normalized) { return $normalized }
    }
    return $null
}

function Get-ExeFileVersion {
    param([string]$ExePath)
    if (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath)) { return $null }
    try {
        $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($ExePath)
        return Get-VersionFromInfo -Info $info
    }
    catch { Write-Verbose "Could not read LM Studio file version: $($_.Exception.Message)" }
    return $null
}

function Get-RecordedVersion {
    if (Test-Path -LiteralPath $script:VersionFile) {
        $v = (Get-Content -LiteralPath $script:VersionFile -Raw).Trim()
        if ($v) { return $v }
    }
    return $null
}

function Set-RecordedVersion {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Ver)
    if (-not $PSCmdlet.ShouldProcess($script:VersionFile, "Record installed LM Studio version $Ver")) {
        return
    }
    Initialize-InstallerState
    if (Test-Path -LiteralPath $script:VersionFile) {
        $versionItem = Get-Item -LiteralPath $script:VersionFile -Force
        if (($versionItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to write installer version state because it is a reparse point: $script:VersionFile"
        }
    }
    Set-Content -LiteralPath $script:VersionFile -Value $Ver -Encoding UTF8
}

function Assert-SafeStateDirectory {
    if (-not (Test-Path -LiteralPath $script:StateDir)) { return }
    $item = Get-Item -LiteralPath $script:StateDir -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to use installer state directory because it is a reparse point: $script:StateDir"
    }
}

function Assert-SafeDownloadDirectory {
    if (-not (Test-Path -LiteralPath $script:DownloadDir)) { return }
    $item = Get-Item -LiteralPath $script:DownloadDir -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to use installer downloads because it is a reparse point: $script:DownloadDir"
    }
    if (-not (Test-Path -LiteralPath $script:DownloadDir -PathType Container)) {
        throw "Refusing to use unexpected installer downloads state: $script:DownloadDir"
    }
}

function Initialize-InstallerState {
    Assert-SafeStateDirectory
    if (-not (Test-Path -LiteralPath $script:StateDir)) {
        New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
    }
    Assert-SafeStateDirectory
    Assert-SafeDownloadDirectory
    if (Test-Path -LiteralPath $script:StateMarker) {
        $markerItem = Get-Item -LiteralPath $script:StateMarker -Force
        if (($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to use installer state marker because it is a reparse point: $script:StateMarker"
        }
    }
    Set-Content -LiteralPath $script:StateMarker -Value 'schema=1' -Encoding ASCII
}

function Remove-InstallerState {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not (Test-Path -LiteralPath $script:StateDir)) { return }
    Assert-SafeStateDirectory
    if (-not (Test-Path -LiteralPath $script:StateMarker -PathType Leaf)) {
        Write-WarnMsg "Preserving unmarked installer state directory: $script:StateDir"
        return
    }

    foreach ($knownPath in @($script:VersionFile, $script:StateMarker, $script:DownloadDir)) {
        if (Test-Path -LiteralPath $knownPath) {
            $knownItem = Get-Item -LiteralPath $knownPath -Force
            if (($knownItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to clean installer state because a known path is a reparse point: $knownPath"
            }
        }
    }
    if ((Test-Path -LiteralPath $script:VersionFile) -and
        -not (Test-Path -LiteralPath $script:VersionFile -PathType Leaf)) {
        throw "Refusing to clean unexpected installer version state: $script:VersionFile"
    }
    if ((Test-Path -LiteralPath $script:DownloadDir) -and
        -not (Test-Path -LiteralPath $script:DownloadDir -PathType Container)) {
        throw "Refusing to clean unexpected installer downloads state: $script:DownloadDir"
    }

    if (Test-Path -LiteralPath $script:DownloadDir) {
        if (-not (Get-ChildItem -LiteralPath $script:DownloadDir -Force | Select-Object -First 1)) {
            if ($PSCmdlet.ShouldProcess($script:DownloadDir, 'Remove empty installer download directory')) {
                Remove-Item -LiteralPath $script:DownloadDir -Force
            }
        }
    }

    foreach ($knownFile in @($script:VersionFile, $script:StateMarker)) {
        if (Test-Path -LiteralPath $knownFile -PathType Leaf) {
            if ($PSCmdlet.ShouldProcess($knownFile, 'Remove managed installer state file')) {
                Remove-Item -LiteralPath $knownFile -Force
            }
        }
    }

    if (-not (Get-ChildItem -LiteralPath $script:StateDir -Force | Select-Object -First 1)) {
        if ($PSCmdlet.ShouldProcess($script:StateDir, 'Remove empty installer state directory')) {
            Remove-Item -LiteralPath $script:StateDir -Force
        }
    }
}

# ===============================
# DISCOVERY (install / uninstall)
# ===============================
function Get-LmStudioRegistryRecord {
    $uninstallRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstallRoots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($key in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            try {
                $entry = Get-ItemProperty $key.PSPath -ErrorAction Stop
                $displayName = [string]$entry.DisplayName
                if ($displayName -match '^LM Studio(?:\s|$)' -and
                    [string]$entry.Publisher -eq 'LM Studio') {
                    Write-Output $entry
                }
            }
            catch { Write-Verbose "Could not inspect registry entry $($key.PSPath): $($_.Exception.Message)" }
        }
    }
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function ConvertTo-NormalizedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        return [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
    }
    catch { return $null }
}

function Get-RegistryEntryInstallPath {
    param([Parameter(Mandatory)]$Entry)
    $paths = @()
    $installLocation = Get-ObjectPropertyValue -InputObject $Entry -Name 'InstallLocation'
    if ($installLocation) { $paths += [string]$installLocation }
    foreach ($propertyName in @('QuietUninstallString', 'UninstallString')) {
        $command = Get-ObjectPropertyValue -InputObject $Entry -Name $propertyName
        if (-not $command) { continue }
        try {
            $parts = Split-UninstallCommand -Command ([string]$command)
            $paths += Split-Path -Parent $parts.Exe
        }
        catch { Write-Verbose "Could not derive install path from $propertyName" }
    }
    return @($paths | Where-Object { $_ } | Select-Object -Unique)
}

function Get-LmStudioRegistryEntry {
    param([string]$InstallPath)
    $entries = @(Get-LmStudioRegistryRecord)
    if (-not $InstallPath) {
        if ($entries.Count -gt 1) {
            throw 'Multiple LM Studio registry entries were found; refusing ambiguous discovery.'
        }
        if ($entries.Count -eq 1) { return $entries[0] }
        return $null
    }

    $normalizedInstallPath = ConvertTo-NormalizedPath -Path $InstallPath
    $matchingEntries = @($entries | Where-Object {
        $entry = $_
        @(Get-RegistryEntryInstallPath -Entry $entry | Where-Object {
            (ConvertTo-NormalizedPath -Path $_) -ieq $normalizedInstallPath
        }).Count -gt 0
    })
    if ($matchingEntries.Count -gt 1) {
        throw "Multiple registry entries match the live LM Studio path: $InstallPath"
    }
    if ($matchingEntries.Count -eq 1) { return $matchingEntries[0] }
    return $null
}

function Get-LmStudioInstallPath {
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    foreach ($root in $script:KnownInstallRoots) {
        $exe = Join-Path $root 'LM Studio.exe'
        if (Test-Path -LiteralPath $exe) { $candidates.Add($root) }
    }

    foreach ($entry in @(Get-LmStudioRegistryRecord)) {
        foreach ($registryPath in @(Get-RegistryEntryInstallPath -Entry $entry)) {
            $registryExe = Join-Path $registryPath 'LM Studio.exe'
            if (Test-Path -LiteralPath $registryExe) {
                $candidates.Add($registryPath)
            }
        }
    }

    $unique = @($candidates | ForEach-Object { ConvertTo-NormalizedPath -Path $_ } |
        Where-Object { $_ } | Sort-Object -Unique)
    if ($unique.Count -gt 1) {
        throw "Multiple live LM Studio installations were found: $($unique -join ', ')"
    }
    if ($unique.Count -eq 1) { return $unique[0] }
    return $null
}

function Get-LmStudioUninstallCommand {
    param([string]$InstallPath)
    $entry = Get-LmStudioRegistryEntry -InstallPath $InstallPath
    if (-not $entry) { return $null }
    $quietCommand = Get-ObjectPropertyValue -InputObject $entry -Name 'QuietUninstallString'
    if ($quietCommand) { return [string]$quietCommand }
    $command = Get-ObjectPropertyValue -InputObject $entry -Name 'UninstallString'
    if ($command) { return [string]$command }
    return $null
}

function Get-LmStudioState {
    $path = Get-LmStudioInstallPath
    $cached = Get-RecordedVersion
    if (-not $path) {
        return [pscustomobject]@{
            IsInstalled = $false
            Path = $null
            Version = $null
            CachedVersion = $cached
        }
    }

    $exe = Join-Path $path 'LM Studio.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        return [pscustomobject]@{
            IsInstalled = $false
            Path = $null
            Version = $null
            CachedVersion = $cached
        }
    }

    $entry = Get-LmStudioRegistryEntry -InstallPath $path
    $detectedVersion = if ($entry) {
        $displayVersion = Get-ObjectPropertyValue -InputObject $entry -Name 'DisplayVersion'
        ConvertTo-LmStudioVersion -Value ([string]$displayVersion)
    }
    else { $null }
    if (-not $detectedVersion) { $detectedVersion = Get-ExeFileVersion -ExePath $exe }
    if (-not $detectedVersion) { $detectedVersion = $cached }

    return [pscustomobject]@{
        IsInstalled = $true
        Path = $path
        Version = $detectedVersion
        CachedVersion = $cached
    }
}

function Split-UninstallCommand {
    param([Parameter(Mandatory)][string]$Command)

    if ($Command -match '^\s*"(?<Exe>[^"]+\.exe)"\s*(?<Args>.*)$' -or
        $Command -match '^\s*(?<Exe>.+?\.exe)\s*(?<Args>.*)$') {
        return [pscustomobject]@{
            Exe = $Matches.Exe
            Args = $Matches.Args.Trim()
        }
    }
    throw "Unsupported uninstall command: $Command"
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
    Initialize-InstallerState
    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force
    }

    Write-Info "Downloading..."
    if (-not $script:QuietOutput) { Write-Host "  URL: $Url" }

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
                if (-not $script:QuietOutput) {
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
        if (-not $script:QuietOutput) { Write-Progress -Activity 'Downloading LM Studio' -Completed }
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

    if ($script:NonInteractive) {
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

    # -Yes is strictly non-interactive: never retry without /S.
    if ($script:NonInteractive) {
        $proc = Start-Process -FilePath $InstallerPath -ArgumentList '/S' -Wait -PassThru
    }
    else {
        $proc = Start-Process -FilePath $InstallerPath -Wait -PassThru
    }

    if ($proc.ExitCode -ne 0) {
        throw "Installer exited with code $($proc.ExitCode)"
    }

    $installPath = $null
    $installedExe = $null
    $detectedVersion = $null
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $installPath = Get-LmStudioInstallPath
        $installedExe = if ($installPath) { Join-Path $installPath 'LM Studio.exe' } else { $null }
        if ($installedExe -and (Test-Path -LiteralPath $installedExe)) {
            $detectedVersion = Get-ExeFileVersion -ExePath $installedExe
            if ($detectedVersion -and
                (ConvertTo-VersionObject -Value $detectedVersion).CompareTo(
                    (ConvertTo-VersionObject -Value $Ver)
                ) -eq 0) {
                break
            }
        }
        if ($attempt -lt 10) { Start-Sleep -Milliseconds 250 }
    }

    if (-not $installedExe -or -not (Test-Path -LiteralPath $installedExe)) {
        throw 'Installer exited successfully but LM Studio.exe was not found.'
    }
    if (-not $detectedVersion) {
        throw "Installer exited successfully, but the installed LM Studio version could not be verified (expected version $Ver)."
    }
    if ((ConvertTo-VersionObject -Value $detectedVersion).CompareTo(
            (ConvertTo-VersionObject -Value $Ver)
        ) -ne 0) {
        throw "Installer exited successfully, but expected version $Ver and found $detectedVersion."
    }

    Set-RecordedVersion -Ver $Ver
    Write-Ok "Installer finished for v$Ver"
    Write-Ok "Detected install path: $installPath"
}

function Invoke-Uninstall {
    $installPath = Get-LmStudioInstallPath
    $recorded = Get-RecordedVersion

    if (-not $installPath) {
        Write-WarnMsg "LM Studio does not appear to be installed."
        return
    }

    $uninstall = Get-LmStudioUninstallCommand -InstallPath $installPath

    if (-not $uninstall) {
        throw 'LM Studio is present, but no valid registry uninstaller was found. Use Windows Apps settings or the vendor uninstaller; no files were removed.'
    }

    Write-Host ""
    $verLabel = if ($recorded) { $recorded } else { '(unknown)' }
    Write-WarnMsg "This will remove LM Studio $verLabel and associated installer state."

    if (-not $script:NonInteractive) {
        $response = Read-Host "Are you sure? (yes/no)"
        if ($response -notmatch '^[Yy][Ee][Ss]$') {
            Write-Info "Cancelled."
            return
        }
    }

    Write-Info "Running uninstaller..."
    $parts = Split-UninstallCommand -Command $uninstall
    $uninstallArgs = $parts.Args
    if ($script:NonInteractive -and $uninstallArgs -notmatch '(?i)(?:^|\s)/S(?:\s|$)') {
        $uninstallArgs = ($uninstallArgs + ' /S').Trim()
    }
    if ($uninstallArgs) {
        $process = Start-Process -FilePath $parts.Exe -ArgumentList $uninstallArgs -Wait -PassThru
    }
    else {
        $process = Start-Process -FilePath $parts.Exe -Wait -PassThru
    }
    if ($process.ExitCode -ne 0) {
        throw "Uninstaller exited with code $($process.ExitCode)"
    }

    $remainingPath = Get-LmStudioInstallPath
    $pathsToVerify = @($installPath, $remainingPath) | Where-Object { $_ } | Select-Object -Unique
    foreach ($pathToVerify in $pathsToVerify) {
        $remainingExe = Join-Path $pathToVerify 'LM Studio.exe'
        if (Test-Path -LiteralPath $remainingExe) {
            throw "Uninstaller exited successfully but LM Studio.exe still exists at $pathToVerify"
        }
    }

    Remove-InstallerState
    Write-Ok "LM Studio uninstalled."
}

function Show-Info {
    $state = Get-LmStudioState
    Write-Host ""
    if ($state.IsInstalled) {
        Write-Host "  Installed version: $(if ($state.Version) { $state.Version } else { '(unknown)' })" -ForegroundColor Green
        Write-Host "  Install path:      $($state.Path)" -ForegroundColor Green
        Write-Host "  State directory:   $script:StateDir" -ForegroundColor Green
        Write-Host "  Executable:        $(Join-Path $state.Path 'LM Studio.exe')" -ForegroundColor Green
    }
    else {
        Write-Host "  LM Studio does not appear to be installed." -ForegroundColor Yellow
    }
    Write-Host ""
}

function Show-Check {
    $arch = Get-WindowsArchToken
    $latest = Get-LatestVersion -Arch $arch
    $state = Get-LmStudioState
    $installed = if ($state.IsInstalled) { $state.Version } else { $null }
    $pathOnly = $state.IsInstalled -and -not $state.Version
    if ($pathOnly) { $installed = '(present, version unknown)' }

    Write-Host ""
    if ($installed) {
        Write-Host "  Installed: $installed" -ForegroundColor Green
    }
    else {
        Write-Host "  Installed: (none)" -ForegroundColor Yellow
    }
    if ($latest) {
        Write-Host "  Latest:    $latest" -ForegroundColor Green
        if (-not $pathOnly -and $installed) {
            $comparison = (ConvertTo-VersionObject -Value $installed).CompareTo(
                (ConvertTo-VersionObject -Value $latest)
            )
            Write-Host ""
            if ($comparison -lt 0) {
                Write-Host "  An update is available. Run without 'check' to upgrade." -ForegroundColor Yellow
            }
            elseif ($comparison -eq 0) {
                Write-Host "  You are up to date." -ForegroundColor Green
            }
            else {
                Write-Host "  Your installed build is newer than the current public release." -ForegroundColor Cyan
            }
        }
    }
    else {
        Write-Host "  Latest:    (could not fetch - check https://lmstudio.ai/download)" -ForegroundColor Yellow
        Write-Host ""
        throw 'Could not determine latest LM Studio version.'
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
    if ($script:HelpRequested -or $script:RequestedSubcommand -eq 'help') {
        Show-Usage
        return
    }

    if (-not $script:QuietOutput) {
        Write-Host ""
        Write-Host "======================================================="
        Write-Host "         LM Studio Installer / Updater (Windows)       "
        Write-Host "======================================================="
        Write-Host ""
    }

    switch ($script:RequestedSubcommand) {
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

    $target = $script:RequestedVersion
    if (-not $target) {
        $latest = Get-LatestVersion -Arch $arch
        if ($latest) {
            Write-Info "Latest detected version: $latest"
            if ($script:NonInteractive) {
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
            if ($script:NonInteractive) {
                throw 'Could not determine a version in non-interactive mode; specify -Version.'
            }
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

    $state = Get-LmStudioState
    $installedVersion = if ($state.IsInstalled) { $state.Version } else { $null }
    if ($installedVersion -eq $target) {
        Write-WarnMsg "Version $target is already installed."
        if (-not $script:NonInteractive) {
            $re = Read-Host "Reinstall anyway? (y/n)"
            if ($re -notmatch '^[Yy]$') {
                Write-Info "Cancelled."
                return
            }
        }
    }
    elseif ($installedVersion) {
        Write-Info "Upgrading $installedVersion -> $target"
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
