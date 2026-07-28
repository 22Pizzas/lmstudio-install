#!/bin/bash
# ===========================================================================
# LM Studio Installation / Update Script
# ===========================================================================
#
# OVERVIEW
# --------
# This script automates the installation and management of LM Studio,
# a local LLM (Large Language Model) inference platform for Linux.
#
# It handles:
#   - Downloading the latest version from official LM Studio servers
#   - Extracting and installing to ~/.local/share/lm-studio
#   - Creating system integration (desktop entry, symlinks)
#   - Automatic version detection and upgrade support
#   - Rollback to previous version if installation fails
#
# FEATURES
# --------
#   ✓ Auto-detect latest version from lmstudio.ai
#   ✓ Parallel downloads with aria2c (if available)
#   ✓ Automatic backup before upgrades
#   ✓ Rollback on failure (restores previous version)
#   ✓ Desktop entry for application menus
#   ✓ GPU detection (NVIDIA, AMD ROCm)
#   ✓ Architecture support: x64, arm64
#   ✓ Non-interactive mode with -y flag
#
# USAGE EXAMPLES
# --------------
#   # Interactive install (auto-detect latest version)
#   ./lm-studio-install.sh
#
#   # Non-interactive with specific version
#   ./lm-studio-install.sh -v 0.4.8-1 -y
#
#   # Show installed version
#   ./lm-studio-install.sh info
#
#   # Check for updates
#   ./lm-studio-install.sh check
#
#   # Uninstall completely
#   ./lm-studio-install.sh uninstall -y
#
# REQUIREMENTS
# -----------
#   Minimum: curl, file, od (coreutils)
#   Optional: wget (fallback downloader), aria2c (faster parallel downloads),
#             sudo (for chrome-sandbox SUID; app may still run without it),
#             timeout (prevents hung AppImage extract)
#   Tested: Debian, Ubuntu, Fedora, Arch Linux
#
# TROUBLESHOOTING
# ---------------
#   Q: "Missing packages: curl ..." error
#   A: Install curl and coreutils
#      Debian/Ubuntu: sudo apt install curl file coreutils
#      Fedora:        sudo dnf install curl file coreutils
#      Arch:          sudo pacman -S curl file coreutils
#
#   Q: "lm-studio command not found"
#   A: ~/.local/bin not in PATH. Add to ~/.bashrc:
#      export PATH="$HOME/.local/bin:$PATH"
#      Then: source ~/.bashrc
#
#   Q: Installation failed, how do I recover?
#   A: The script creates automatic backups in ~/.local/share/lm-studio.bak
#      Restore manually:
#        rm -rf ~/.local/share/lm-studio
#        mv ~/.local/share/lm-studio.bak ~/.local/share/lm-studio
#
# NOTE
# ----
#   Official one-liners at lmstudio.ai/install.sh install *llmster* (headless
#   daemon), not the full desktop app. This script installs the GUI AppImage.
#
# ===========================================================================

set -euo pipefail

# ===============================
# CONFIGURATION
# ===============================
readonly INSTALL_DIR="${LMS_INSTALL_DIR:-${HOME}/.local/share/lm-studio}"
readonly BIN_DIR="${HOME}/.local/bin"
readonly DESKTOP_DIR="${HOME}/.local/share/applications"
readonly VERSION_FILE="${INSTALL_DIR}/.installed_version"
readonly BACKUP_DIR="${INSTALL_DIR}.bak"

# Minimum expected AppImage size (bytes). Real builds are hundreds of MB;
# this guards against truncated downloads that still pass ELF magic checks.
readonly MIN_APPIMAGE_BYTES=$((50 * 1024 * 1024))   # 50 MB floor

# ===============================
# COLORS
# ===============================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# ===============================
# COMMAND-LINE FLAGS & STATE
# ===============================
OPT_YES=false
OPT_VERSION=""
OPT_QUIET=false
OPT_SUBCOMMAND=""
USE_ARIA2=false

# ===============================
# CLEANUP TRAP & ROLLBACK
# ===============================
# TEMP_FILES tracks paths to delete on exit.
# BACKUP_CREATED is owned exclusively by main(); functions signal intent via
# return values rather than mutating it directly.
TEMP_FILES=()
BACKUP_CREATED=false

# temp_track() — Add a path to the cleanup list
temp_track() { TEMP_FILES+=("$1"); }

# temp_untrack() — Remove an exact path from the cleanup list (proper element removal)
# FIX: The original used substring replacement ("${array[@]/pattern/}") which corrupts
# entries that share substrings and leaves empty elements that become "rm -rf ''" calls.
# This function does an exact-match filter instead.
temp_untrack() {
    local target="$1"
    local new_list=()
    local entry
    for entry in "${TEMP_FILES[@]}"; do
        [[ "$entry" != "$target" ]] && new_list+=("$entry")
    done
    TEMP_FILES=("${new_list[@]+"${new_list[@]}"}")
}

# cleanup() — Runs on EXIT/INT/TERM; deletes temp files and optionally rolls back
cleanup() {
    local exit_code=$?
    local f
    for f in "${TEMP_FILES[@]}"; do
        [[ -n "$f" ]] && rm -rf "$f" 2>/dev/null || true
    done

    if [[ $exit_code -ne 0 && "$BACKUP_CREATED" == true && -d "$BACKUP_DIR" ]]; then
        log_warn "Rolling back to previous installation..."
        rm -rf "${INSTALL_DIR:?}" 2>/dev/null || true
        mv "$BACKUP_DIR" "$INSTALL_DIR" 2>/dev/null || true
        log_info "Rollback complete."
    elif [[ "$BACKUP_CREATED" == true && -d "$BACKUP_DIR" ]]; then
        rm -rf "${BACKUP_DIR:?}" 2>/dev/null || true
    fi

    if [[ $exit_code -ne 0 ]]; then
        echo -e "${RED}Installation failed.${NC}" >&2
    fi
    exit $exit_code
}
trap cleanup EXIT INT TERM

# ===============================
# LOGGING
# ===============================
log_info()    { $OPT_QUIET || echo -e "${CYAN}ℹ${NC} $*" >&2; }
log_warn()    { echo -e "${YELLOW}⚠${NC} $*" >&2; }
log_error()   { echo -e "${RED}✗${NC} $*" >&2; }
log_success() { $OPT_QUIET || echo -e "${GREEN}✓${NC} $*" >&2; }

# ===============================
# ARGUMENT PARSING & HELP
# ===============================
usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") [OPTIONS] [SUBCOMMAND]

Subcommands:
  (none)       Install or upgrade LM Studio
  uninstall    Remove LM Studio and all created files
  info         Show installed version and paths
  check        Check if a newer version is available

Options:
  -v, --ver VERSION   Target version to install (e.g. 0.4.8-1)
  -y, --yes           Non-interactive: accept all prompts automatically
  -q, --quiet         Suppress informational output
  -h, --help          Show this help message

Environment:
  LMS_INSTALL_DIR     Override installation directory (default: ~/.local/share/lm-studio)
EOF
    exit 0
}

# FIX: Removed the entire embedded lmstudio-beta-updater.sh that was pasted
# inside this case statement, which made the script syntactically broken.
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            uninstall|info|check)
                OPT_SUBCOMMAND="$1" ;;
            -v|--ver)
                shift; OPT_VERSION="${1:-}" ;;
            -y|--yes)
                OPT_YES=true ;;
            -q|--quiet)
                OPT_QUIET=true ;;
            -h|--help)
                usage ;;
            *)
                log_error "Unknown argument: $1"
                usage ;;
        esac
        shift
    done
}

# ===============================
# SUBCOMMAND IMPLEMENTATIONS
# ===============================
cmd_info() {
    echo ""
    if [[ -f "$VERSION_FILE" ]]; then
        local ver; ver=$(cat "$VERSION_FILE")
        echo -e "  ${GREEN}Installed version:${NC} $ver"
        echo -e "  ${GREEN}Install directory:${NC} $INSTALL_DIR"
        echo -e "  ${GREEN}Launcher symlink: ${NC} ${BIN_DIR}/lm-studio"
        [[ -L "${BIN_DIR}/lms" ]] && echo -e "  ${GREEN}CLI symlink:      ${NC} ${BIN_DIR}/lms"
        echo -e "  ${GREEN}Desktop entry:    ${NC} ${DESKTOP_DIR}/lm-studio.desktop"
    else
        echo -e "  ${YELLOW}LM Studio does not appear to be installed.${NC}"
    fi
    echo ""
}

cmd_uninstall() {
    if [[ ! -d "$INSTALL_DIR" ]]; then
        log_warn "LM Studio does not appear to be installed at $INSTALL_DIR"
        exit 0
    fi
    local ver="(unknown)"
    [[ -f "$VERSION_FILE" ]] && ver=$(cat "$VERSION_FILE")
    echo ""
    log_warn "This will remove LM Studio $ver and all associated files."

    if ! $OPT_YES; then
        read -rp "Are you sure? (yes/no): " response
        [[ "$response" =~ ^[Yy][Ee][Ss]$ ]] || { log_info "Cancelled."; exit 0; }
    fi

    rm -rf "${INSTALL_DIR:?}"
    rm -f "${BIN_DIR}/lm-studio" "${BIN_DIR}/lms"
    rm -f "${DESKTOP_DIR}/lm-studio.desktop"
    command -v update-desktop-database >/dev/null 2>&1 && \
        update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true

    log_success "LM Studio uninstalled."
}

cmd_check() {
    # Capture stderr separately so fetch errors surface to the user instead
    # of being silently swallowed by 2>/dev/null.
    local latest fetch_err arch
    arch=$(detect_architecture 2>/dev/null || echo "x64")
    fetch_err=$(mktemp)
    temp_track "$fetch_err"
    latest=$(fetch_latest_version "$arch" 2>"$fetch_err") || true
    if [[ -s "$fetch_err" ]]; then
        log_warn "Version fetch warning: $(cat "$fetch_err")"
    fi

    local installed=""
    [[ -f "$VERSION_FILE" ]] && installed=$(cat "$VERSION_FILE")

    echo ""
    if [[ -n "$installed" ]]; then
        echo -e "  Installed: ${GREEN}${installed}${NC}"
    else
        echo -e "  Installed: ${YELLOW}(none)${NC}"
    fi
    if [[ -n "$latest" ]]; then
        echo -e "  Latest:    ${GREEN}${latest}${NC}"
        if [[ -n "$installed" && "$installed" != "$latest" ]]; then
            echo -e "\n  ${YELLOW}An update may be available.${NC} Run without 'check' to upgrade."
        elif [[ "$installed" == "$latest" ]]; then
            echo -e "\n  ${GREEN}You are up to date.${NC}"
        fi
    else
        echo -e "  Latest:    ${YELLOW}(could not fetch — check https://lmstudio.ai/download)${NC}"
    fi
    echo ""
}

# ===============================
# DEPENDENCIES & SYSTEM CHECKS
# ===============================
check_dependencies() {
    log_info "Checking dependencies..."
    local missing=()
    local cmd
    # curl is required; wget is optional (curl can download too).
    # sudo is only needed later for chrome-sandbox and is handled there.
    for cmd in curl file od; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing packages: ${missing[*]}"
        echo "Debian/Ubuntu: sudo apt install curl file coreutils -y" >&2
        echo "Fedora:        sudo dnf install curl file coreutils -y" >&2
        echo "Arch:          sudo pacman -S curl file coreutils" >&2
        exit 1
    fi

    if command -v aria2c >/dev/null 2>&1; then
        USE_ARIA2=true
        log_info "aria2c detected — faster downloads enabled"
    else
        USE_ARIA2=false
    fi

    if ! command -v wget >/dev/null 2>&1; then
        log_info "wget not found — using curl for downloads"
    fi
    if ! command -v timeout >/dev/null 2>&1; then
        log_warn "timeout not found — AppImage extract will run without a time limit"
    fi
}

detect_architecture() {
    case "$(uname -m)" in
        x86_64)  echo "x64"   ;;
        aarch64) echo "arm64" ;;
        *)       log_error "Unsupported architecture: $(uname -m)"; exit 1 ;;
    esac
}

# ===============================
# VERSION HANDLING & RETRIEVAL
# ===============================
validate_version() {
    local v="$1"
    if [[ ! "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$ ]]; then
        log_error "Invalid version format: $v"
        echo "Example: 0.4.8-1" >&2
        return 1
    fi
}

# fetch_latest_version() — Resolve the current release by following the official
# "latest" redirect. Scraping the download HTML is unreliable (many unrelated
# version-like strings appear on the page).
fetch_latest_version() {
    local arch="${1:-x64}"
    local final=""
    local url="https://lmstudio.ai/download/latest/linux/${arch}"

    # Prefer the redirect target: .../LM-Studio-0.4.20-1-x64.AppImage
    final=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --max-time 15 "$url" 2>/dev/null) || true
    if [[ -n "$final" && "$final" =~ LM-Studio-([0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?)- ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi

    # Fallback: scrape page for LM-Studio-X.Y.Z filenames only
    local page
    page=$(curl -fsSL --max-time 12 "https://lmstudio.ai/download" 2>/dev/null) || {
        log_warn "Could not reach lmstudio.ai — check your network connection." >&2
        return 0
    }
    local ver
    ver=$(echo "$page" | grep -oE 'LM-Studio-[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?' | head -1 | sed 's/^LM-Studio-//') || true
    if [[ -n "$ver" ]]; then
        echo "$ver"
        return 0
    fi

    # Last resort: first 0.x.y token (LM Studio desktop is currently 0.x)
    echo "$page" | grep -oE '0\.[0-9]+\.[0-9]+(-[0-9]+)?' | head -1 || true
}

prompt_version() {
    local arch="${1:-x64}"
    echo "" >&2
    local latest; latest=$(fetch_latest_version "$arch" 2>/dev/null)
    if [[ -n "$latest" ]]; then
        log_info "Latest detected version: ${latest}"
        if $OPT_YES; then
            echo "$latest"
            return
        fi
        # Default to latest when the user presses Enter
        echo "Press Enter to install ${latest}, or type another version (e.g. 0.4.8-1):" >&2
        read -r version
        if [[ -z "$version" ]]; then
            echo "$latest"
            return
        fi
        validate_version "$version" || exit 1
        echo "$version"
        return
    fi

    log_warn "Could not auto-detect latest version."
    log_info "Check https://lmstudio.ai/download for the current release."
    echo "Enter the exact version to install (e.g. 0.4.20-1):" >&2
    read -r version
    [[ -z "$version" ]] && { log_error "No version entered."; exit 1; }
    validate_version "$version" || exit 1
    echo "$version"
}

show_security_warning() {
    echo "" >&2
    log_warn "══════════════════════════════════════════════════════"
    log_warn " SECURITY NOTICE"
    log_warn "══════════════════════════════════════════════════════"
    echo "" >&2
    echo "  This script will download LM Studio and use sudo" >&2
    echo "  to configure chrome-sandbox (SUID root)." >&2
    echo "  LM Studio does not publish official checksums." >&2
    echo "  Downloads are verified only by ELF magic bytes and" >&2
    echo "  minimum file size — not a cryptographic signature." >&2
    echo "" >&2

    if $OPT_YES; then
        log_info "Skipping confirmation (--yes)"
        return
    fi

    read -rp "Continue? (yes/no): " response
    [[ "$response" =~ ^[Yy][Ee][Ss]$ ]] || { log_info "Cancelled."; exit 0; }
}

# check_existing_installation() — Handle existing installs and create a backup
# FIX: No longer sets BACKUP_CREATED itself. Returns exit code 2 to signal
# that a backup was made, letting main() own the flag. This removes the hidden
# side-effect that made rollback logic hard to follow.
check_existing_installation() {
    local version="$1"

    if [[ -d "$INSTALL_DIR" && -f "$VERSION_FILE" ]]; then
        local installed; installed=$(cat "$VERSION_FILE")
        if [[ "$installed" == "$version" ]]; then
            log_warn "Version $version is already installed."
            if ! $OPT_YES; then
                read -rp "Reinstall anyway? (y/n): " reinstall
                [[ "$reinstall" =~ ^[Yy]$ ]] || { log_info "Cancelled."; exit 0; }
            fi
        else
            log_info "Upgrading $installed → $version"
        fi
        log_info "Backing up current installation..."
        rm -rf "${BACKUP_DIR:?}" 2>/dev/null || true
        cp -a "$INSTALL_DIR" "$BACKUP_DIR"
        log_success "Backup created at $BACKUP_DIR"
        rm -rf "${INSTALL_DIR:?}"
        return 2   # Signal: backup was created
    fi
    return 0       # Signal: no backup needed
}

# ===============================
# DOWNLOAD & VALIDATION
# ===============================

# validate_download() — Verify the downloaded file is a plausible AppImage
# FIX: Added minimum size check (MIN_APPIMAGE_BYTES) so a truncated download
# that starts with ELF bytes but is only a few kilobytes doesn't pass validation.
validate_download() {
    local file="$1"

    [[ -s "$file" ]] || { log_error "Downloaded file is empty."; return 1; }

    # Guard against server returning an HTML error page instead of a binary
    if file "$file" | grep -q "HTML"; then
        log_error "Got an HTML error page — wrong version or server error?"
        return 1
    fi

    # ELF magic: 0x7F 0x45 0x4C 0x46
    local magic
    magic=$(od -An -tx1 -N4 "$file" | tr -d ' \n')
    if [[ ! "$magic" =~ ^7f454c46 ]]; then
        log_error "Not a valid ELF/AppImage binary (magic: $magic)."
        return 1
    fi

    # Minimum size check — catches partial downloads that pass the magic test
    local actual_size
    actual_size=$(wc -c < "$file")
    if [[ "$actual_size" -lt "$MIN_APPIMAGE_BYTES" ]]; then
        log_error "File is suspiciously small (${actual_size} bytes). Download may be incomplete."
        return 1
    fi

    log_success "Download validated (ELF magic OK, size ${actual_size} bytes)"
}

# download_file() — Shared downloader: aria2c → wget → curl
download_file() {
    local url="$1"
    local dest="$2"
    local downloaded=false

    if $USE_ARIA2; then
        if aria2c -x 8 -s 8 --allow-overwrite=true \
            -d "$(dirname "$dest")" -o "$(basename "$dest")" "$url" >&2; then
            downloaded=true
            log_success "Downloaded with aria2c"
        else
            log_warn "aria2c failed, trying next downloader..."
        fi
    fi

    if ! $downloaded && command -v wget >/dev/null 2>&1; then
        if $OPT_QUIET; then
            wget -q -O "$dest" "$url" >&2 && downloaded=true
        else
            wget --show-progress -O "$dest" "$url" >&2 && downloaded=true
        fi
        if $downloaded; then
            log_success "Downloaded with wget"
        else
            log_warn "wget failed, trying curl..."
        fi
    fi

    if ! $downloaded; then
        if $OPT_QUIET; then
            curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url" || {
                log_error "Download failed."; return 1
            }
        else
            curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$dest" "$url" || {
                log_error "Download failed."; return 1
            }
        fi
        log_success "Downloaded with curl"
    fi
}

download_appimage() {
    local version="$1"
    local arch="$2"
    local appimage_name="LM-Studio-${version}-${arch}.AppImage"
    local url="https://installers.lmstudio.ai/linux/${arch}/${version}/${appimage_name}"

    log_info "Downloading v${version} (${arch})..."
    $OPT_QUIET || echo "  URL: $url" >&2

    local tmp; tmp=$(mktemp)
    temp_track "$tmp"

    download_file "$url" "$tmp" || return 1
    validate_download "$tmp" || return 1

    local appimage_out; appimage_out="$(dirname "$tmp")/${appimage_name}"
    mv "$tmp" "$appimage_out"
    temp_untrack "$tmp"
    temp_track "$appimage_out"

    echo "$appimage_out"
}

# ===============================
# INSTALLATION & SYSTEM SETUP
# ===============================

# extract_and_install() — Extract AppImage and install to INSTALL_DIR
# FIX: No longer sets BACKUP_CREATED=false. The caller (main) owns that flag.
# FIX: Added a 5-minute timeout on AppImage extraction to prevent infinite hangs.
# FIX: chrome-sandbox SUID is set only after verifying the file's inode hasn't
#      changed between extraction and chmod, closing the race window.
extract_and_install() {
    local appimage_file="$1"
    local version="$2"

    log_info "Extracting AppImage (this may take a minute)..."
    chmod +x "$appimage_file"

    local extract_tmp; extract_tmp=$(mktemp -d)
    temp_track "$extract_tmp"

    # Wrap extraction in timeout when available so a hung AppImage doesn't block forever.
    local extract_rc=0
    if command -v timeout >/dev/null 2>&1; then
        timeout 300 bash -c "cd '$extract_tmp' && '$appimage_file' --appimage-extract" \
            >/dev/null 2>&1 || extract_rc=$?
    else
        (cd "$extract_tmp" && "$appimage_file" --appimage-extract) >/dev/null 2>&1 || extract_rc=$?
    fi
    if [[ $extract_rc -ne 0 ]]; then
        log_error "AppImage extraction failed or timed out."
        return 1
    fi

    local extracted="${extract_tmp}/squashfs-root"
    [[ -d "$extracted" ]] || { log_error "squashfs-root not found after extraction."; return 1; }

    log_info "Installing to ${INSTALL_DIR}..."
    mkdir -p "$(dirname "$INSTALL_DIR")"
    mv "$extracted" "$INSTALL_DIR"
    temp_untrack "$extract_tmp"
    rm -rf "${extract_tmp:?}" 2>/dev/null || true

    rm -f "$appimage_file" 2>/dev/null || true
    temp_untrack "$appimage_file"

    # FIX: Capture the inode of chrome-sandbox before handing it to sudo.
    # If the inode after the chown differs, another process swapped the file
    # during the window between mv and chmod — abort rather than grant SUID
    # to an unexpected binary.
    local sandbox="${INSTALL_DIR}/chrome-sandbox"
    if [[ -f "$sandbox" ]]; then
        if command -v sudo >/dev/null 2>&1; then
            log_info "Configuring chrome-sandbox (requires sudo)..."
            local inode_before inode_after
            inode_before=$(stat -c '%i' "$sandbox" 2>/dev/null || stat -f '%i' "$sandbox")
            if sudo chown root:root "$sandbox" 2>/dev/null; then
                inode_after=$(stat -c '%i' "$sandbox" 2>/dev/null || stat -f '%i' "$sandbox")
                if [[ "$inode_before" != "$inode_after" ]]; then
                    log_error "chrome-sandbox inode changed during chown — aborting SUID setup."
                    log_error "The installation directory may have been tampered with."
                    return 1
                fi
                sudo chmod 4755 "$sandbox"
                log_success "chrome-sandbox configured (SUID root)"
            else
                log_warn "Could not configure chrome-sandbox (sudo denied or failed)."
                log_warn "You may need: sudo chown root:root '$sandbox' && sudo chmod 4755 '$sandbox'"
                log_warn "Or launch with --no-sandbox if your environment allows it."
            fi
        else
            log_warn "sudo not found — skipping chrome-sandbox SUID setup."
            log_warn "LM Studio may require: chrome-sandbox owned by root with mode 4755"
        fi
    fi

    echo "$version" > "$VERSION_FILE"
}

create_symlinks() {
    log_info "Creating symlinks in ~/.local/bin..."
    mkdir -p "$BIN_DIR"

    ln -sf "${INSTALL_DIR}/lm-studio" "${BIN_DIR}/lm-studio"
    log_success "lm-studio → ${BIN_DIR}/lm-studio"

    if [[ -f "${INSTALL_DIR}/lms" ]]; then
        ln -sf "${INSTALL_DIR}/lms" "${BIN_DIR}/lms"
        log_success "lms (CLI) → ${BIN_DIR}/lms"
    fi

    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        log_warn "~/.local/bin is not in your PATH."
        echo "  Fix permanently:" >&2
        echo "    echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc && source ~/.bashrc" >&2
    fi
}

create_desktop_entry() {
    log_info "Creating desktop entry..."
    mkdir -p "$DESKTOP_DIR"

    # FIX: Limit icon search depth to avoid slow traversal on large installs.
    local icon_path="${INSTALL_DIR}/lm-studio.png"
    if [[ ! -f "$icon_path" ]]; then
        icon_path=$(find "${INSTALL_DIR}" -maxdepth 3 -name "lm-studio.png" -type f \
                        2>/dev/null | head -1)
    fi
    [[ -n "$icon_path" ]] || icon_path="lm-studio"

    cat > "${DESKTOP_DIR}/lm-studio.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=LM Studio
Comment=Run LLMs locally
Exec=${BIN_DIR}/lm-studio
Icon=${icon_path}
Terminal=false
Categories=Development;Science;
StartupWMClass=lm-studio
Keywords=AI;LLM;Machine Learning;
EOF

    chmod +x "${DESKTOP_DIR}/lm-studio.desktop"
    command -v update-desktop-database >/dev/null 2>&1 && \
        update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    log_success "Desktop entry created"
}

post_install_info() {
    echo "" >&2
    if command -v nvidia-smi >/dev/null 2>&1; then
        local gpu; gpu=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
        [[ -n "$gpu" ]] && log_info "NVIDIA GPU detected: ${gpu}"
    elif command -v rocminfo >/dev/null 2>&1; then
        log_info "ROCm detected — AMD GPU acceleration may be available."
    else
        log_info "No GPU tooling detected — CPU inference only."
    fi
}

# ===============================
# MAIN ENTRY POINT
# ===============================
main() {
    parse_args "$@"

    $OPT_QUIET || {
        echo "" >&2
        echo "╔══════════════════════════════════════════════════════╗" >&2
        echo "║         LM Studio Installer / Updater                ║" >&2
        echo "╚══════════════════════════════════════════════════════╝" >&2
        echo "" >&2
    }

    case "$OPT_SUBCOMMAND" in
        info)      cmd_info;                   exit 0 ;;
        uninstall) cmd_uninstall;              exit 0 ;;
        check)     check_dependencies
                   cmd_check;                  exit 0 ;;
    esac

    check_dependencies
    local arch; arch=$(detect_architecture)
    log_success "Architecture: $arch"

    local version
    if [[ -n "$OPT_VERSION" ]]; then
        validate_version "$OPT_VERSION" || exit 1
        version="$OPT_VERSION"
    else
        version=$(prompt_version "$arch")
    fi
    log_success "Target version: $version"

    show_security_warning

    # FIX: check_existing_installation now signals backup status via return code
    # rather than mutating BACKUP_CREATED itself. main() owns the flag.
    local check_rc=0
    check_existing_installation "$version" || check_rc=$?
    if [[ $check_rc -eq 2 ]]; then
        BACKUP_CREATED=true
    fi

    local appimage_file
    appimage_file=$(download_appimage "$version" "$arch")
    extract_and_install "$appimage_file" "$version"

    # Disarm rollback: installation succeeded, backup is no longer needed.
    BACKUP_CREATED=false

    create_symlinks
    create_desktop_entry
    post_install_info

    echo "" >&2
    log_success "LM Studio v${version} installed successfully!"
    echo "  Launch with:   lm-studio" >&2
    echo "  CLI tools:     lms --help" >&2
    echo "  Uninstall:     $(basename "$0") uninstall" >&2
    echo "" >&2
}

# ===========================================================================
# EXIT CODES
# ----------
#   0  Success
#   1  General error (missing deps, invalid version, download failure, etc.)
#   2  User cancelled
# ===========================================================================
main "$@"