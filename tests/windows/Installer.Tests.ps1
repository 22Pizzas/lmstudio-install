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
        $installPath = Join-Path $TestDrive 'verified-install'
        New-Item -ItemType Directory -Path $installPath | Out-Null
        Set-Content -LiteralPath (Join-Path $installPath 'LM Studio.exe') -Value executable
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        Mock Get-LmStudioInstallPath { $installPath }
        Mock Set-RecordedVersion {}

        { Install-LmStudio -InstallerPath "$TestDrive\i.exe" -Ver 1.2.3 } | Should -Not -Throw
        Should -Invoke Set-RecordedVersion -ParameterFilter { $Ver -eq '1.2.3' } -Times 1 -Exactly
    }

    It 'keeps state when the uninstaller fails' {
        New-Item -ItemType Directory -Path $script:StateDir | Out-Null
        Set-Content -LiteralPath $script:VersionFile -Value '1.2.3'
        Mock Get-LmStudioUninstallCommand { '"C:\LM Studio\uninstall.exe" /allusers' }
        Mock Get-LmStudioInstallPath { $null }
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
        $script:InstallPathCalls = 0
        Mock Get-LmStudioUninstallCommand { '"C:\LM Studio\uninstall.exe" /allusers' }
        Mock Get-LmStudioInstallPath {
            $script:InstallPathCalls++
            if ($script:InstallPathCalls -eq 1) { return $installPath }
            return $null
        }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }

        { Invoke-Uninstall } | Should -Not -Throw
        Test-Path -LiteralPath $script:StateDir | Should -BeFalse
        Should -Invoke Start-Process -ParameterFilter { $ArgumentList -match '/S' } -Times 1 -Exactly
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
