# LM Studio Installer

Cross-platform installers for the **LM Studio desktop app** (GUI), not the headless `llmster` daemon.

Official one-liners on [lmstudio.ai/download](https://lmstudio.ai/download) (`install.sh` / `install.ps1`) install **llmster**. This repo installs the full application:

| Platform | Script | Package |
|----------|--------|---------|
| Linux | `lm-studio-install.sh` | AppImage → `~/.local/share/lm-studio` |
| Windows | `lm-studio-install.ps1` | Official `.exe` installer |

## Linux

### Requirements

- **Required:** `curl`, `file`, `od` (coreutils)
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
| `-y, --yes` | Non-interactive; accept prompts |
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

- `LMS_INSTALL_DIR` — override install directory (default: `~/.local/share/lm-studio`)

### What it does

1. Detects arch (`x64` / `arm64`) and latest version via official download redirect  
2. Downloads from `installers.lmstudio.ai`  
3. Validates ELF magic + minimum size  
4. Extracts AppImage, creates `~/.local/bin` symlinks and a desktop entry  
5. Optionally configures `chrome-sandbox` (SUID) with sudo  
6. Backs up and rolls back on failed upgrades  

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
| `-Yes`, `-y` | Non-interactive; silent install when possible |
| `-Quiet`, `-q` | Suppress informational output |
| `-Help`, `-h` | Show help |

### Subcommands

Same as Linux: `info`, `check`, `uninstall`, or no subcommand to install/upgrade.

### What it does

1. Detects arch (`x64` / `arm64`) and latest version via official download redirect  
2. Downloads `LM-Studio-<ver>-<arch>.exe` from official servers  
3. Validates PE/MZ header + minimum size  
4. Runs the installer (`/S` when `-Yes`)  
5. Records version under `%LOCALAPPDATA%\lm-studio-installer`  
6. Uninstall uses the Windows registry uninstaller when available  

## Security

LM Studio does **not** publish official installer checksums. These scripts verify:

- **Linux:** ELF magic bytes + minimum file size (50 MB floor)  
- **Windows:** PE/MZ header + minimum file size (50 MB floor)  

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

```bash
sudo chown root:root ~/.local/share/lm-studio/chrome-sandbox
sudo chmod 4755 ~/.local/share/lm-studio/chrome-sandbox
```

**Windows: execution policy**

```powershell
Set-ExecutionPolicy -Scope Process Bypass
# or:
powershell -ExecutionPolicy Bypass -File .\lm-studio-install.ps1 -Yes
```

**Rollback (Linux failed upgrade)**

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
