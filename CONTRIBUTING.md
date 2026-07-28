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
- Validate downloads (ELF magic + minimum size) before extraction.
- Avoid destructive paths without confirmation unless `-y` is set.
- Run `bash -n lm-studio-install.sh` before submitting.

### PowerShell (`lm-studio-install.ps1`)

- Target Windows PowerShell 5.1+ (and preferably PowerShell 7).
- Use `Set-StrictMode -Version Latest` and clear error handling.
- Validate PE/MZ + minimum size before running installers.
- Prefer silent install only when `-Yes` is passed; fall back to interactive on failure.
- Avoid requiring admin unless the underlying installer does.

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
