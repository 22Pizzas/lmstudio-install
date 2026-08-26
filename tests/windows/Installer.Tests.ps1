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
