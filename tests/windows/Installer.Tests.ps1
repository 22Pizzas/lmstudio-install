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
