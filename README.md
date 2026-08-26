# LM Studio Installer

[![CI](https://github.com/22Pizzas/lmstudio-install/actions/workflows/ci.yml/badge.svg)](https://github.com/22Pizzas/lmstudio-install/actions/workflows/ci.yml)

Cross-platform installers for the **LM Studio desktop app** (GUI), not the headless `llmster` daemon.

Official one-liners on [lmstudio.ai/download](https://lmstudio.ai/download) (`install.sh` / `install.ps1`) install **llmster**. This repo installs the full application:

| Platform | Script | Package |
|----------|--------|---------|
| Linux | `lm-studio-install.sh` | AppImage → `~/.local/share/lm-studio` |
| Windows | `lm-studio-install.ps1` | Official `.exe` installer |

## Linux

### Requirements

- **Required:** `curl`, `file`, `od`, `sha512sum` (the latter two are provided by coreutils)
- **Optional:** `wget`, `aria2c` (faster downloads), `sudo` (chrome-sandbox SUID), `timeout`

### Usage

```bash
chmod +x lm-studio-install.sh

# Interactive install (auto-detect latest version)
./lm-studio-install.sh

# Non-interactive with specific version
./lm-studio-install.sh -v 0.4.20-1 -y

# Show installed version
./lm-studio-install.sh info

# Check for updates
./lm-studio-install.sh check

# Uninstall completely
./lm-studio-install.sh uninstall -y
```

### Flags

| Flag | Description |
|------|-------------|
| `-v, --ver <version>` | Version to install (e.g. `0.4.20-1`) |
| `-y, --yes` | Strictly non-interactive; accept prompts without GUI fallback |
| `-q, --quiet` | Suppress informational output |
| `-h, --help` | Show help |

### Subcommands

| Command | Description |
|---------|-------------|
| *(none)* | Install or upgrade |
| `info` | Show installed version and paths |
| `check` | Compare installed vs latest |
| `uninstall` | Remove LM Studio and desktop integration |

### Environment

- `LMS_INSTALL_DIR` — override the absolute install directory (default: `~/.local/share/lm-studio`). Broad paths such as `/`, `$HOME`, and `.local` roots are rejected.

### What it does

1. Detects arch (`x64` / `arm64`) and latest version via official download redirect  
2. Downloads from `installers.lmstudio.ai`  
3. Verifies the official `<artifact>.sha512` sidecar, then checks ELF magic + minimum size
4. Extracts AppImage, creates `~/.local/bin` symlinks and a desktop entry  
5. Optionally configures `chrome-sandbox` (SUID) with sudo  
6. Backs up and rolls back on failed upgrades, including launcher/desktop integration failures

The Linux installer marks the application, launchers, and desktop entry it owns. It refuses to replace an existing unowned install directory or foreign integration files, and uninstall removes only managed artifacts.

## Windows

### Requirements

- Windows 10/11, PowerShell 5.1+ (or PowerShell 7+)
- Network access to `lmstudio.ai` / `installers.lmstudio.ai`

### Usage

```powershell
# If needed, allow local scripts for this session:
Set-ExecutionPolicy -Scope Process Bypass

# Interactive install (auto-detect latest)
.\lm-studio-install.ps1

# Non-interactive with specific version
.\lm-studio-install.ps1 -Version 0.4.20-1 -Yes

# Show installed version / path
.\lm-studio-install.ps1 info

# Check for updates
.\lm-studio-install.ps1 check

# Uninstall
.\lm-studio-install.ps1 uninstall -Yes
```

### Flags

| Flag | Description |
|------|-------------|
| `-Version`, `-v`, `-ver` | Version to install (e.g. `0.4.20-1`) |
| `-Yes`, `-y` | Strictly non-interactive; silent install with no GUI retry |
| `-Quiet`, `-q` | Suppress informational output |
| `-Help`, `-h` | Show help |

### Subcommands

Same as Linux: `info`, `check`, `uninstall`, or no subcommand to install/upgrade.

### What it does

1. Detects arch (`x64` / `arm64`) and latest version via official download redirect  
2. Downloads `LM-Studio-<ver>-<arch>.exe` from official servers  
3. Verifies the official `<artifact>.sha512` sidecar, a valid Authenticode signature from `Element Labs Inc.`, and PE/MZ + minimum size
4. Runs the installer (`/S` when `-Yes`)  
5. Confirms the live `LM Studio.exe` version matches the requested release before recording managed state under `%LOCALAPPDATA%\lm-studio-installer`
6. Correlates exact registry records with the live install path, rejects ambiguous installs, and retains state if uninstall fails

The Windows state directory has an ownership marker. Uninstall removes only
known installer artifacts, refuses reparse-point state paths, and preserves any
unrelated files found there.

## Security

Both scripts fail closed unless the downloaded artifact matches LM Studio's official SHA-512 sidecar:

- **Linux:** SHA-512, ELF magic bytes, and a 50 MB minimum-size check
- **Windows:** SHA-512, valid Authenticode from `Element Labs Inc.`, PE/MZ bytes, and a 50 MB minimum-size check

Missing, malformed, or mismatched sidecars are fatal. Windows also rejects unsigned, invalidly signed, or unexpected-publisher installers. The magic and size checks remain defense-in-depth corruption checks.

Update checks compare all numeric version and build components and report one of: up to date, update available, or installed build newer than the public release. Explicit cancellation exits successfully (`0`); usage and operational failures exit `1`.

Always prefer downloads from `lmstudio.ai` / `installers.lmstudio.ai`. Review the scripts before running them, especially when piping remote code to a shell.

## Version detection

Latest version is resolved by following:

- Linux: `https://lmstudio.ai/download/latest/linux/<arch>`
- Windows: `https://lmstudio.ai/download/latest/win32/<arch>`

Versioned artifacts follow:

```text
https://installers.lmstudio.ai/linux/<arch>/<ver>/LM-Studio-<ver>-<arch>.AppImage
https://installers.lmstudio.ai/win32/<arch>/<ver>/LM-Studio-<ver>-<arch>.exe
```

## Troubleshooting

**Linux: `lm-studio: command not found`**

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
```

**Linux: chrome-sandbox / startup issues**

The installer configures `chrome-sandbox` through an open file descriptor and
verifies its inode before changing ownership or mode. If `sudo` is denied or
unavailable, resolve that access issue and rerun the installer; do not repair
the sandbox with a separate path-based `chown`/`chmod` sequence.

**Windows: execution policy**

```powershell
Set-ExecutionPolicy -Scope Process Bypass
# or:
powershell -ExecutionPolicy Bypass -File .\lm-studio-install.ps1 -Yes
```

**Rollback (Linux failed upgrade)**

Rollback is automatic. If automatic restoration itself cannot complete, the managed backup remains at `~/.local/share/lm-studio.bak` for manual recovery:

```bash
rm -rf ~/.local/share/lm-studio
mv ~/.local/share/lm-studio.bak ~/.local/share/lm-studio
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

Security issues: see [SECURITY.md](SECURITY.md) (prefer private advisories over public issues).

## License

Installer scripts and docs in this repository are licensed under the [MIT License](LICENSE).

LM Studio itself is a separate product and is subject to the [LM Studio terms of use](https://lmstudio.ai/terms).
