# LM Studio Installer

This repository contains the LM Studio installation script.

## Usage

Run `./lm-studio-install.sh` to install LM Studio.

### Flags

- `-v, --ver <version>` : Specify a version to install (e.g., `-v 0.4.8-1`)
- `-y, --yes` : Non-interactive mode, automatically confirm prompts
- `-q, --quiet` : Suppress informational output
- `-h, --help` : Show help message

### Subcommands

- `info` : Show installed version
- `check` : Check for updates
- `uninstall` : Uninstall LM Studio

### Examples

```bash
# Interactive install (auto-detect latest version)
./lm-studio-install.sh

# Non-interactive with specific version
./lm-studio-install.sh -v 0.4.8-1 -y

# Show installed version
./lm-studio-install.sh info

# Check for updates
./lm-studio-install.sh check

# Uninstall completely
./lm-studio-install.sh uninstall -y
```