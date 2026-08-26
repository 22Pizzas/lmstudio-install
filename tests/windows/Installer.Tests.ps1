Describe 'source-only mode' {
    BeforeAll {
        $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:InstallerUnderTest = Join-Path $script:ProjectRoot 'lm-studio-install.ps1'
        $env:LMS_INSTALLER_SOURCE_ONLY = '1'
        . $script:InstallerUnderTest
    }

    AfterAll {
        Remove-Item Env:LMS_INSTALLER_SOURCE_ONLY -ErrorAction SilentlyContinue
    }

    It 'loads functions without invoking the entry point' {
        $output = . $script:InstallerUnderTest 6>&1
        $output | Should -BeNullOrEmpty
        Get-Command Invoke-Main -CommandType Function | Should -Not -BeNullOrEmpty
    }
}

Describe 'artifact integrity' {
    BeforeAll {
        $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:InstallerUnderTest = Join-Path $script:ProjectRoot 'lm-studio-install.ps1'
        $env:LMS_INSTALLER_SOURCE_ONLY = '1'
        . $script:InstallerUnderTest

        if (-not (Get-Command Invoke-TextDownload -CommandType Function -ErrorAction SilentlyContinue)) {
            function Invoke-TextDownload { throw 'Missing required installer function: Invoke-TextDownload' }
        }
    }

    AfterAll {
        Remove-Item Env:LMS_INSTALLER_SOURCE_ONLY -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Set-Content -LiteralPath "$TestDrive\installer.exe" -Value payload -NoNewline
    }

    It 'decodes byte-array sidecar responses as ASCII text' {
        Mock Invoke-WebRequest {
            [pscustomobject]@{ Content = [System.Text.Encoding]::ASCII.GetBytes(('a' * 128)) }
        }

        Invoke-TextDownload -Url 'https://installers.lmstudio.ai/installer.exe.sha512' |
            Should -Be ('a' * 128)
    }

    It 'accepts a matching SHA-512 sidecar' {
        $script:ChecksumResponse = (Get-FileHash -LiteralPath "$TestDrive\installer.exe" -Algorithm SHA512).Hash
        Mock Invoke-TextDownload { $script:ChecksumResponse }

        { Test-Sha512 -Path "$TestDrive\installer.exe" -ArtifactUrl 'https://installers.lmstudio.ai/installer.exe' } |
            Should -Not -Throw
    }

    It 'rejects a mismatched SHA-512 sidecar' {
        $script:ChecksumResponse = '0' * 128
        Mock Invoke-TextDownload { $script:ChecksumResponse }

        { Test-Sha512 -Path "$TestDrive\installer.exe" -ArtifactUrl 'https://installers.lmstudio.ai/installer.exe' } |
            Should -Throw '*SHA-512 mismatch*'
    }

    It 'rejects a malformed SHA-512 sidecar' {
        $script:ChecksumResponse = 'malformed'
        Mock Invoke-TextDownload { $script:ChecksumResponse }

        { Test-Sha512 -Path "$TestDrive\installer.exe" -ArtifactUrl 'https://installers.lmstudio.ai/installer.exe' } |
            Should -Throw '*Malformed SHA-512 sidecar*'
    }

    It 'rejects a missing SHA-512 sidecar' {
        Mock Invoke-TextDownload { throw 'sidecar missing' }

        { Test-Sha512 -Path "$TestDrive\installer.exe" -ArtifactUrl 'https://installers.lmstudio.ai/installer.exe' } |
            Should -Throw '*sidecar missing*'
    }

    It 'accepts a valid Element Labs signature' {
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{
                Status = 'Valid'
                SignerCertificate = [pscustomobject]@{ Subject = 'CN=LM Studio, O=Element Labs Inc., L=San Francisco, S=California, C=US' }
            }
        }

        { Test-LmStudioSignature -Path "$TestDrive\installer.exe" } | Should -Not -Throw
    }

    It 'rejects an invalid Authenticode signature' {
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'HashMismatch'; SignerCertificate = $null }
        }

        { Test-LmStudioSignature -Path "$TestDrive\installer.exe" } |
            Should -Throw '*Invalid Authenticode signature*'
    }

    It 'rejects an unsigned installer' {
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null }
        }

        { Test-LmStudioSignature -Path "$TestDrive\installer.exe" } |
            Should -Throw '*Invalid Authenticode signature*'
    }

    It 'rejects a valid signature from the wrong publisher' {
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{
                Status = 'Valid'
                SignerCertificate = [pscustomobject]@{ Subject = 'CN=Unexpected Publisher, O=Other Company, C=US' }
            }
        }

        { Test-LmStudioSignature -Path "$TestDrive\installer.exe" } |
            Should -Throw '*Unexpected installer publisher*'
    }
}

Describe 'Windows state and process reliability' {
    BeforeAll {
        $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:InstallerUnderTest = Join-Path $script:ProjectRoot 'lm-studio-install.ps1'
        $env:LMS_INSTALLER_SOURCE_ONLY = '1'
        . $script:InstallerUnderTest
    }

    AfterAll {
        Remove-Item Env:LMS_INSTALLER_SOURCE_ONLY -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $script:NonInteractive = $true
        $script:QuietOutput = $true
        $script:StateDir = Join-Path $TestDrive ("state-{0}" -f [guid]::NewGuid())
        $script:VersionFile = Join-Path $script:StateDir 'installed_version.txt'
        $script:StateMarker = Join-Path $script:StateDir '.lmstudio-installer-managed'
        $script:DownloadDir = Join-Path $script:StateDir 'downloads'
        Mock Start-Sleep {}
    }

    It 'normalizes plus build metadata' {
        ConvertTo-LmStudioVersion '0.4.21+2' | Should -Be '0.4.21-2'
    }

    It 'prefers FileVersion over ProductVersion' {
        Get-VersionFromInfo ([pscustomobject]@{ FileVersion = '0.4.21+2'; ProductVersion = '0.4.21.0' }) |
            Should -Be '0.4.21-2'
    }

    It 'does not treat a cache-only version as installed' {
        Mock Get-LmStudioInstallPath { $null }
        Mock Get-RecordedVersion { '1.2.3' }

        $state = Get-LmStudioState

        $state.IsInstalled | Should -BeFalse
        $state.Version | Should -BeNullOrEmpty
        $state.CachedVersion | Should -Be '1.2.3'
    }

    It 'marks state created by the installer' {
        Set-RecordedVersion -Ver '1.2.3'

        Test-Path -LiteralPath $script:StateMarker | Should -BeTrue
    }

    It 'rejects similarly named registry products' {
        Mock Test-Path { $true } -ParameterFilter { -not $LiteralPath }
        Mock Get-ChildItem { @([pscustomobject]@{ PSPath = 'registry::helper' }) }
        Mock Get-ItemProperty {
            [pscustomobject]@{
                DisplayName = 'My LM Studio Helper'
                Publisher = 'Unrelated Publisher'
                UninstallString = 'C:\Helper\uninstall.exe'
            }
        }

        Get-LmStudioRegistryEntry | Should -BeNullOrEmpty
    }

    It 'uses UninstallString when the optional quiet command is absent' {
        Mock Get-LmStudioRegistryEntry {
            [pscustomobject]@{ UninstallString = '"C:\LM Studio\uninstall.exe" /allusers' }
        }

        Get-LmStudioUninstallCommand | Should -Be '"C:\LM Studio\uninstall.exe" /allusers'
    }

    It 'correlates duplicate registry entries with the live install path' {
        $livePath = 'C:\Program Files\LM Studio'
        Mock Get-LmStudioRegistryRecord {
            @(
                [pscustomobject]@{
                    DisplayName = 'LM Studio'
                    Publisher = 'LM Studio'
                    InstallLocation = 'C:\Users\old\AppData\Local\Programs\LM Studio'
                    DisplayVersion = '0.4.20+1'
                    UninstallString = '"C:\Users\old\AppData\Local\Programs\LM Studio\Uninstall LM Studio.exe" /currentuser'
                },
                [pscustomobject]@{
                    DisplayName = 'LM Studio'
                    Publisher = 'LM Studio'
                    InstallLocation = $livePath
                    DisplayVersion = '0.4.21+2'
                    UninstallString = '"C:\Program Files\LM Studio\Uninstall LM Studio.exe" /allusers'
                }
            )
        }

        $entry = Get-LmStudioRegistryEntry -InstallPath $livePath

        $entry.DisplayVersion | Should -Be '0.4.21+2'
    }

    It 'splits a quoted uninstall command without a command shell' {
        $parts = Split-UninstallCommand '"C:\Program Files\LM Studio\Uninstall LM Studio.exe" /allusers /S'

        $parts.Exe | Should -Be 'C:\Program Files\LM Studio\Uninstall LM Studio.exe'
        $parts.Args | Should -Be '/allusers /S'
    }

    It 'splits an unquoted executable and arguments' {
        $parts = Split-UninstallCommand 'C:\Tools\uninstall.exe /currentuser'

        $parts.Exe | Should -Be 'C:\Tools\uninstall.exe'
        $parts.Args | Should -Be '/currentuser'
    }

    It 'never retries interactively when Yes is set' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 9 } }

        { Install-LmStudio -InstallerPath "$TestDrive\i.exe" -Ver 1.2.3 } |
            Should -Throw '*code 9*'
        Should -Invoke Start-Process -Times 1 -Exactly
        Should -Invoke Start-Process -ParameterFilter { $ArgumentList -eq '/S' } -Times 1 -Exactly
    }

    It 'records state only after the installed executable is found' {
        $installPath = Join-Path $TestDrive 'install'
        New-Item -ItemType Directory -Path $installPath | Out-Null
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        Mock Get-LmStudioInstallPath { $installPath }
        Mock Set-RecordedVersion {}

        { Install-LmStudio -InstallerPath "$TestDrive\i.exe" -Ver 1.2.3 } |
            Should -Throw '*LM Studio.exe was not found*'
        Should -Invoke Set-RecordedVersion -Times 0 -Exactly
    }

    It 'records state after a verified successful install' {
        $script:ExpectedInstallPath = Join-Path $TestDrive 'verified-install'
        New-Item -ItemType Directory -Path $script:ExpectedInstallPath | Out-Null
        Set-Content -LiteralPath (Join-Path $script:ExpectedInstallPath 'LM Studio.exe') -Value executable
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        Mock Get-LmStudioInstallPath { $script:ExpectedInstallPath }
        Mock Get-ExeFileVersion { '1.2.3' }
        Mock Set-RecordedVersion {}

        { Install-LmStudio -InstallerPath "$TestDrive\i.exe" -Ver 1.2.3 } | Should -Not -Throw
        Should -Invoke Set-RecordedVersion -ParameterFilter { $Ver -eq '1.2.3' } -Times 1 -Exactly
    }

    It 'does not record state when the installed version differs from the request' {
        $script:ExpectedInstallPath = Join-Path $TestDrive 'wrong-version-install'
        New-Item -ItemType Directory -Path $script:ExpectedInstallPath | Out-Null
        Set-Content -LiteralPath (Join-Path $script:ExpectedInstallPath 'LM Studio.exe') -Value executable
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        Mock Get-LmStudioInstallPath { $script:ExpectedInstallPath }
        Mock Get-ExeFileVersion { '0.4.21-2' }
        Mock Set-RecordedVersion {}

        { Install-LmStudio -InstallerPath "$TestDrive\i.exe" -Ver 9.9.9 } |
            Should -Throw '*expected version 9.9.9*found 0.4.21-2*'
        Should -Invoke Set-RecordedVersion -Times 0 -Exactly
    }

    It 'keeps state when the uninstaller fails' {
        New-Item -ItemType Directory -Path $script:StateDir | Out-Null
        Set-Content -LiteralPath $script:VersionFile -Value '1.2.3'
        Set-Content -LiteralPath $script:StateMarker -Value 'schema=1'
        Mock Get-LmStudioUninstallCommand { '"C:\LM Studio\uninstall.exe" /allusers' }
        Mock Get-LmStudioInstallPath { 'C:\LM Studio' }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 23 } }

        { Invoke-Uninstall } | Should -Throw '*code 23*'
        Test-Path -LiteralPath $script:StateDir | Should -BeTrue
    }

    It 'keeps state when the executable remains after a zero exit' {
        $installPath = Join-Path $TestDrive 'still-installed'
        New-Item -ItemType Directory -Path $installPath | Out-Null
        Set-Content -LiteralPath (Join-Path $installPath 'LM Studio.exe') -Value executable
        New-Item -ItemType Directory -Path $script:StateDir | Out-Null
        Set-Content -LiteralPath $script:VersionFile -Value '1.2.3'
        Mock Get-LmStudioUninstallCommand { '"C:\LM Studio\uninstall.exe" /allusers' }
        Mock Get-LmStudioInstallPath { $installPath }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }

        { Invoke-Uninstall } | Should -Throw '*still exists*'
        Test-Path -LiteralPath $script:StateDir | Should -BeTrue
    }

    It 'removes state after a verified successful uninstall' {
        $installPath = Join-Path $TestDrive 'removed-install'
        New-Item -ItemType Directory -Path $installPath | Out-Null
        Set-Content -LiteralPath (Join-Path $installPath 'LM Studio.exe') -Value executable
        New-Item -ItemType Directory -Path $script:StateDir | Out-Null
        Set-Content -LiteralPath $script:VersionFile -Value '1.2.3'
        Set-Content -LiteralPath $script:StateMarker -Value 'schema=1'
        $script:InstallPathCalls = 0
        Mock Get-LmStudioUninstallCommand { '"C:\LM Studio\uninstall.exe" /allusers' }
        Mock Get-LmStudioInstallPath {
            $script:InstallPathCalls++
            if ($script:InstallPathCalls -eq 1) { return $installPath }
            return $null
        }
        Mock Start-Process {
            Remove-Item -LiteralPath (Join-Path $installPath 'LM Studio.exe') -Force
            [pscustomobject]@{ ExitCode = 0 }
        }

        { Invoke-Uninstall } | Should -Not -Throw
        Test-Path -LiteralPath $script:StateDir | Should -BeFalse
        Should -Invoke Start-Process -ParameterFilter { $ArgumentList -match '/S' } -Times 1 -Exactly
    }

    It 'preserves unrelated files in the state directory after uninstall' {
        $installPath = Join-Path $TestDrive 'removed-install-with-unrelated-state'
        New-Item -ItemType Directory -Path $installPath | Out-Null
        Set-Content -LiteralPath (Join-Path $installPath 'LM Studio.exe') -Value executable
        New-Item -ItemType Directory -Path $script:StateDir | Out-Null
        Set-Content -LiteralPath $script:VersionFile -Value '1.2.3'
        Set-Content -LiteralPath $script:StateMarker -Value 'schema=1'
        $unrelated = Join-Path $script:StateDir 'keep-me.txt'
        Set-Content -LiteralPath $unrelated -Value 'user data'
        $script:InstallPathCalls = 0
        Mock Get-LmStudioUninstallCommand { '"C:\LM Studio\uninstall.exe" /allusers' }
        Mock Get-LmStudioInstallPath {
            $script:InstallPathCalls++
            if ($script:InstallPathCalls -eq 1) { return $installPath }
            return $null
        }
        Mock Start-Process {
            Remove-Item -LiteralPath (Join-Path $installPath 'LM Studio.exe') -Force
            [pscustomobject]@{ ExitCode = 0 }
        }

        { Invoke-Uninstall } | Should -Not -Throw
        Test-Path -LiteralPath $unrelated | Should -BeTrue
        Test-Path -LiteralPath $script:VersionFile | Should -BeFalse
        Test-Path -LiteralPath $script:StateMarker | Should -BeFalse
    }

    It 'refuses to clean a reparse-point state directory' {
        New-Item -ItemType Directory -Path $script:StateDir | Out-Null
        Mock Get-Item { [pscustomobject]@{ Attributes = [IO.FileAttributes]::ReparsePoint } }
        Mock Remove-Item {}

        { Remove-InstallerState } | Should -Throw '*reparse point*'
        Should -Invoke Remove-Item -Times 0 -Exactly
    }

    It 'checks the original install path after the registry entry disappears' {
        $installPath = Join-Path $TestDrive 'orphaned-install'
        New-Item -ItemType Directory -Path $installPath | Out-Null
        Set-Content -LiteralPath (Join-Path $installPath 'LM Studio.exe') -Value executable
        New-Item -ItemType Directory -Path $script:StateDir | Out-Null
        Set-Content -LiteralPath $script:VersionFile -Value '1.2.3'
        $script:InstallPathCalls = 0
        Mock Get-LmStudioUninstallCommand { '"C:\LM Studio\uninstall.exe" /allusers' }
        Mock Get-LmStudioInstallPath {
            $script:InstallPathCalls++
            if ($script:InstallPathCalls -eq 1) { return $installPath }
            return $null
        }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }

        { Invoke-Uninstall } | Should -Throw '*still exists*'
        Test-Path -LiteralPath $script:StateDir | Should -BeTrue
    }

    It 'never recursively removes a registry InstallLocation fallback' {
        Mock Get-LmStudioUninstallCommand { $null }
        Mock Get-LmStudioInstallPath { 'C:\unexpected\registry-path' }
        Mock Get-RecordedVersion { '1.2.3' }
        Mock Remove-Item {}

        { Invoke-Uninstall } | Should -Throw '*valid registry uninstaller*'
        Should -Invoke Remove-Item -ParameterFilter { $Recurse } -Times 0 -Exactly
    }
}

Describe 'Windows update semantics' {
    BeforeAll {
        $script:ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:InstallerUnderTest = Join-Path $script:ProjectRoot 'lm-studio-install.ps1'
        $env:LMS_INSTALLER_SOURCE_ONLY = '1'
        . $script:InstallerUnderTest
        $script:QuietOutput = $true
    }

    AfterAll {
        Remove-Item Env:LMS_INSTALLER_SOURCE_ONLY -ErrorAction SilentlyContinue
    }

    It 'ignores unrelated version tokens in download content' {
        Get-VersionFromArtifactText '<html>Unrelated product 0.9.9</html>' |
            Should -BeNullOrEmpty
    }

    It 'parses only an LM Studio artifact version' {
        Get-VersionFromArtifactText 'href="LM-Studio-0.4.21-2-x64.exe"' |
            Should -Be '0.4.21-2'
    }

    It 'returns no latest version when redirect and page contain only unrelated tokens' {
        Mock Resolve-LatestRedirect { 'https://example.test/other-product-0.9.9.exe' }
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = '<html>Other product 0.9.9</html>' } }

        Get-LatestVersion -Arch x64 | Should -BeNullOrEmpty
    }

    It 'verifies checksum and signature before launching the installer' {
        $script:NonInteractive = $true
        $script:RequestedSubcommand = ''
        $script:RequestedVersion = '1.2.3'
        $script:HelpRequested = $false
        $script:DownloadDir = Join-Path $TestDrive 'ordered-download'
        $script:Order = New-Object 'System.Collections.Generic.List[string]'
        Mock Get-WindowsArchToken { 'x64' }
        Mock Get-LmStudioState {
            [pscustomobject]@{ IsInstalled = $false; Path = $null; Version = $null; CachedVersion = $null }
        }
        Mock Show-SecurityNotice {}
        Mock Invoke-FileDownload {}
        Mock Test-PeExecutable { $true }
        Mock Test-Sha512 { $script:Order.Add('sha') }
        Mock Test-LmStudioSignature { $script:Order.Add('signature') }
        Mock Install-LmStudio { $script:Order.Add('install') }
        Mock Show-GpuInfo {}

        Invoke-Main

        ($script:Order -join ',') | Should -Be 'sha,signature,install'
    }

    It 'never prompts when non-interactive latest lookup fails' {
        $script:NonInteractive = $true
        $script:RequestedSubcommand = ''
        $script:RequestedVersion = ''
        $script:HelpRequested = $false
        Mock Get-WindowsArchToken { 'x64' }
        Mock Get-LatestVersion { $null }
        Mock Read-Host { throw 'Read-Host was called' }

        { Invoke-Main } | Should -Throw '*specify -Version*'
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'fails check when the latest version cannot be determined' {
        Mock Get-WindowsArchToken { 'x64' }
        Mock Get-LatestVersion { $null }
        Mock Get-LmStudioState {
            [pscustomobject]@{ IsInstalled = $true; Path = 'C:\LM Studio'; Version = '0.4.21-2'; CachedVersion = $null }
        }

        { Show-Check } | Should -Throw '*Could not determine latest*'
    }

    It 'compares numeric build versions' {
        (ConvertTo-VersionObject '0.4.21-10').CompareTo((ConvertTo-VersionObject '0.4.21-2')) |
            Should -BeGreaterThan 0
    }

    It 'reports an installed build newer than latest as ahead' {
        Mock Get-WindowsArchToken { 'x64' }
        Mock Get-LatestVersion { '0.4.21-2' }
        Mock Get-LmStudioState {
            [pscustomobject]@{ IsInstalled = $true; Path = 'C:\LM Studio'; Version = '0.4.22-1'; CachedVersion = $null }
        }

        Show-Check 6>&1 | Out-String | Should -Match 'newer than the current public release'
    }

    It 'reports an available update only when installed is older' {
        Mock Get-WindowsArchToken { 'x64' }
        Mock Get-LatestVersion { '0.4.21-2' }
        Mock Get-LmStudioState {
            [pscustomobject]@{ IsInstalled = $true; Path = 'C:\LM Studio'; Version = '0.4.20-9'; CachedVersion = $null }
        }

        Show-Check 6>&1 | Out-String | Should -Match 'update is available'
    }

    It 'reports up to date only when versions are equal' {
        Mock Get-WindowsArchToken { 'x64' }
        Mock Get-LatestVersion { '0.4.21-2' }
        Mock Get-LmStudioState {
            [pscustomobject]@{ IsInstalled = $true; Path = 'C:\LM Studio'; Version = '0.4.21-2'; CachedVersion = $null }
        }

        Show-Check 6>&1 | Out-String | Should -Match 'up to date'
    }
}
