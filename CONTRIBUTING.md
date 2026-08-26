# Contributing to lmstudio-install

Thanks for your interest in improving the LM Studio installers.

This repository provides cross-platform scripts that install the **LM Studio desktop app** (not the headless `llmster` daemon):

| File | Platform |
|------|----------|
| `lm-studio-install.sh` | Linux (AppImage) |
| `lm-studio-install.ps1` | Windows (official `.exe`) |

## Ways to contribute

- Bug reports and install failures (OS, arch, version, logs)
- Fixes for download URL / version-detection drift when LM Studio changes releases
- Platform support (e.g. macOS) and packaging improvements
- Docs, examples, and translation of user-facing messages
- Safer install/uninstall paths and better validation

## Development setup

1. Fork and clone the repo.
2. Make scripts executable on Linux:

   ```bash
   chmod +x lm-studio-install.sh
   ```

3. Prefer testing against a non-production path when possible:

   ```bash
   # Linux
   LMS_INSTALL_DIR="$HOME/.local/share/lm-studio-test" ./lm-studio-install.sh -y
   ```

   On Windows, use a throwaway user profile or VM if you need full install tests; the installer writes under Program Files / LocalAppData.

## Coding guidelines

### Shell (`lm-studio-install.sh`)

- Keep `set -euo pipefail`.
- Prefer `curl` as the baseline network tool; keep wget/aria2c as optional accelerators.
- Do not hardcode a single release version as “latest”; resolve via the official redirect when possible.
- Verify the official SHA-512 sidecar before extraction; keep ELF magic and minimum size as defense in depth.
- Preserve canonical path checks, managed ownership markers, and rollback state around every destructive operation.
- Treat `-y` as strictly non-interactive; it does not weaken validation or ownership checks.

### PowerShell (`lm-studio-install.ps1`)

- Target Windows PowerShell 5.1+ (and preferably PowerShell 7).
- Use `Set-StrictMode -Version Latest` and clear error handling.
- Verify SHA-512 and the `Element Labs Inc.` Authenticode publisher; keep PE/MZ + minimum size as defense in depth.
- Use silent install only when `-Yes` is passed. A silent failure must return failure, never retry interactively.
- Treat cached version state as non-authoritative and preserve it until install/uninstall success is verified.
- Avoid requiring admin unless the underlying installer does.

## Local verification

Run the checks for the platform you changed. Cross-platform changes should run both suites.

```bash
bash -n lm-studio-install.sh
shellcheck -x -e SC2034,SC1090,SC1091 lm-studio-install.sh
bats tests/linux/installer.bats
```

```powershell
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    "$PWD\lm-studio-install.ps1", [ref]$tokens, [ref]$errors
)
if ($errors) { $errors; exit 1 }
Invoke-ScriptAnalyzer .\lm-studio-install.ps1 -Severity Error,Warning
Invoke-Pester .\tests\windows\Installer.Tests.ps1 -Output Detailed
```

Behavior tests use temporary directories and mocks; they must not download or execute real installers or uninstall the developer's LM Studio installation.

### Documentation

- Update `README.md` when flags, subcommands, or install paths change.
- Keep Linux and Windows sections in sync for shared concepts (`info`, `check`, `uninstall`).

## Pull requests

1. Create a focused branch (`fix/version-detect`, `feat/macos`, etc.).
2. Keep commits small and descriptive.
3. Describe:
   - What changed and why
   - How you tested (OS, arch, interactive vs `-y`)
   - Any risk (sudo/SUID, PATH changes, uninstall)
4. Do not commit large binaries, installers, or personal logs.

## Issues

Use the issue templates when possible:

- **Bug report** — install/upgrade/uninstall failures
- **Feature request** — new platforms, flags, or workflow improvements

Before opening a duplicate, search existing issues and check whether the problem is upstream (LM Studio download hosts, AppImage runtime, Windows installer).

## Security

Do not file public issues for vulnerabilities that could enable remote code execution or privilege escalation via these scripts. See [SECURITY.md](SECURITY.md).

## Code of conduct

Participation is governed by our [Code of Conduct](CODE_OF_CONDUCT.md).

## License

By contributing, you agree that your contributions will be licensed under the MIT License (see [LICENSE](LICENSE)).
