# LM Studio Installer Safety and Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make both standalone installers fail safely, verify official artifacts cryptographically, report versions accurately, and cover destructive and recovery paths with automated regression tests.

**Architecture:** Keep the two public scripts standalone and preserve their existing CLI. Add a source-only test seam, small pure helpers for version/path/command handling, and transactional state that is changed only after each filesystem or process operation succeeds. Linux integration files become ownership-aware; Windows treats its version file as a cache rather than proof of installation.

**Tech Stack:** Bash, Bats, PowerShell 5.1+, Pester 5, ShellCheck, PSScriptAnalyzer, GitHub Actions.

**Spec:** `README.md` and `SECURITY.md`, plus the verified audit findings below.

## Global Constraints

- Continue installing the LM Studio desktop GUI, not `llmster`.
- Preserve Linux x64/arm64 and Windows x64/arm64 support.
- Preserve `info`, `check`, `uninstall`, version pinning, quiet mode, and interactive/non-interactive operation.
- Keep Linux's default install directory at `~/.local/share/lm-studio` and honor `LMS_INSTALL_DIR` only after validating it.
- Keep Windows compatible with Windows PowerShell 5.1 and PowerShell 7+.
- Download application artifacts and checksums only from `lmstudio.ai` and `installers.lmstudio.ai`.
- Never perform a real install, uninstall, SUID change, or registry mutation in automated tests.
- All destructive tests must use a freshly created temporary home and assert that the resolved target remains inside it.
- Do not silently weaken checksum, signature, path, or ownership failures.

---

## Verified Audit Findings

| Priority | Finding | Evidence / root cause |
|---|---|---|
| P0 | Linux can recursively delete an arbitrary `LMS_INSTALL_DIR`, including `$HOME`. | `cmd_uninstall` uses `rm -rf "${INSTALL_DIR:?}"`; `:?` rejects only empty strings. An isolated reproduction with `LMS_INSTALL_DIR=$HOME` deleted the whole temporary home. |
| P0 | A failed Linux backup copy can still delete the live installation. | `check_existing_installation` is invoked on the left of `||`, which disables Bash `errexit` inside the function. A mocked `cp` failure continued to `rm -rf`, returned status 2, and left neither install nor backup. |
| P0 | Both scripts execute artifacts without available SHA-512 verification. | Current official `.sha512` sidecars return HTTP 200 for Linux and Windows x64/arm64. The scripts still rely only on a 50 MB floor and ELF/MZ bytes, and the docs incorrectly say checksums are unavailable. |
| P1 | Linux's SUID race check does not cover the final `chmod`. | The script compares inodes around `sudo chown`, then performs a separate path-based `sudo chmod 4755`; the directory remains user-owned and the path can be swapped between those operations. |
| P1 | Linux disables rollback before launcher/desktop integration succeeds. | `BACKUP_CREATED=false` is assigned before `create_symlinks` and `create_desktop_entry`. A mocked launcher failure left the new install and old `.bak` instead of restoring the old install. |
| P1 | Linux install/uninstall overwrites or removes unrelated integration files. | `ln -sf` and unconditional `rm -f` affect `~/.local/bin/lm-studio`, `lms`, and `lm-studio.desktop` without checking ownership. Temporary user files at those paths were deleted by the reproduction. |
| P1 | Windows reports the installed build incorrectly. | The installed app has `ProductVersion=0.4.21.0` and `FileVersion=0.4.21+2`. The script reads ProductVersion first and does not accept `+`, reporting `0.4.21-0` and a false update against latest `0.4.21-2`. |
| P1 | Windows erases state after an uninstaller failure. | A mocked uninstaller exit 23 still removed `$StateDir` and completed with an “uninstalled (or removal attempted)” success message. |
| P1 | Windows `-Yes` can unexpectedly become interactive. | A mocked silent installer failure caused a second `Start-Process` call without `/S`; automation can hang waiting for GUI input. |
| P1 | Windows fallback uninstall can recursively delete an untrusted registry path. | A fuzzy `*LM Studio*` registry match can supply `InstallLocation`; when no uninstaller is found, that path is passed directly to recursive `Remove-Item`. |
| P2 | Linux failed downloads leak temporary files. | `download_appimage` mutates `TEMP_FILES` inside command substitution, so the mutations occur in a subshell. A failed validation left one file and the parent tracked zero. |
| P2 | Linux nests a new AppImage inside an existing unversioned install. | Existing directories are handled only when `.installed_version` exists. Otherwise `mv squashfs-root "$INSTALL_DIR"` creates `$INSTALL_DIR/squashfs-root`. |
| P2 | Successful Linux upgrades retain a large `.bak`, and uninstall does not remove it. | Main clears `BACKUP_CREATED` without removing the backup; the success reproduction left the old tree in place. |
| P2 | Windows stale state can be presented as an installed app. | `Get-RecordedVersion` trusts the state file before checking for an executable; `Show-Info` treats either value as proof of installation. |
| P2 | Linux CLI/status edge cases are misleading. | Unknown arguments exit 0; documented cancellation status 2 is never used; unsupported `check` architectures silently fall back to x64; version comparison tests equality only. |
| P2 | CI cannot catch these behaviors. | CI runs syntax, lint, help/info/check smoke tests, and an endpoint redirect check, but no isolated install, rollback, ownership, checksum, or process-outcome tests. |

## File Structure

- `lm-studio-install.sh` — standalone Linux entry point and implementation; add test seam, safety helpers, integrity verification, and transaction handling.
- `lm-studio-install.ps1` — standalone Windows entry point and implementation; add test seam, normalized discovery, integrity/signature verification, and safe process handling.
- `tests/linux/installer.bats` — Linux behavioral regression suite using temporary homes and mocked external commands.
- `tests/windows/Installer.Tests.ps1` — Windows behavioral regression suite using Pester mocks and `$TestDrive`.
- `.github/workflows/ci.yml` — run Bats and Pester in addition to existing lint/smoke checks.
- `README.md`, `SECURITY.md`, `CONTRIBUTING.md` — document checksums, safe path rules, ownership behavior, exit codes, and test commands.

---

### Task 1: Add a source-only test seam and regression harnesses

**Files:**
- Modify: `lm-studio-install.sh:780`
- Modify: `lm-studio-install.ps1:693-699`
- Create: `tests/linux/installer.bats`
- Create: `tests/windows/Installer.Tests.ps1`
- Modify: `.github/workflows/ci.yml:18-96`

**Interfaces:**
- Consumes: existing `main` / `Invoke-Main` and all current helper functions.
- Produces: `LMS_INSTALLER_SOURCE_ONLY=1`, which loads functions but never invokes the CLI; Bats and Pester entry points used by later tasks.

- [ ] **Step 1: Add failing source-only smoke tests**

```bash
@test "source-only mode does not invoke main" {
  export LMS_INSTALLER_SOURCE_ONLY=1
  run bash -c 'source "$1"; declare -F main' _ "$PROJECT_ROOT/lm-studio-install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"main"* ]]
}
```

```powershell
Describe 'source-only mode' {
    It 'loads Invoke-Main without executing it' {
        $env:LMS_INSTALLER_SOURCE_ONLY = '1'
        . "$PSScriptRoot\..\..\lm-studio-install.ps1"
        (Get-Command Invoke-Main -CommandType Function) | Should -Not -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail because both scripts execute their entry points**

Run: `bats tests/linux/installer.bats`

Expected: FAIL because sourcing reaches `main "$@"`.

Run: `Invoke-Pester -Path tests/windows/Installer.Tests.ps1 -Output Detailed`

Expected: FAIL because dot-sourcing reaches `Invoke-Main`.

- [ ] **Step 3: Guard both entry points without changing normal CLI behavior**

```bash
if [[ "${LMS_INSTALLER_SOURCE_ONLY:-0}" != "1" ]]; then
    main "$@"
fi
```

```powershell
if ($env:LMS_INSTALLER_SOURCE_ONLY -ne '1') {
    try {
        Invoke-Main
    }
    catch {
        Write-ErrMsg $_.Exception.Message
        exit 1
    }
}
```

- [ ] **Step 4: Add guarded temporary-home setup to Bats and `$TestDrive` setup to Pester**

```bash
setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  TEST_ROOT="$(mktemp -d)"
  export HOME="$TEST_ROOT/home"
  export TMPDIR="$TEST_ROOT/tmp"
  export LMS_INSTALL_DIR="$HOME/.local/share/lm-studio"
  export LMS_INSTALLER_SOURCE_ONLY=1
  mkdir -p "$HOME" "$TMPDIR"
  source "$PROJECT_ROOT/lm-studio-install.sh"
  trap - EXIT INT TERM
}

teardown() {
  [[ "$TEST_ROOT" == /tmp/* ]] || return 1
  rm -rf -- "$TEST_ROOT"
}
```

```powershell
BeforeAll {
    $env:LMS_INSTALLER_SOURCE_ONLY = '1'
    . "$PSScriptRoot\..\..\lm-studio-install.ps1"
}
AfterAll { Remove-Item Env:LMS_INSTALLER_SOURCE_ONLY -ErrorAction SilentlyContinue }
```

- [ ] **Step 5: Wire Bats and Pester 5 into CI**

```yaml
- name: Install Linux test tools
  run: sudo apt-get update && sudo apt-get install -y shellcheck bats
- name: Linux behavior tests
  run: bats tests/linux/installer.bats
```

```yaml
- name: Install Pester 5
  shell: pwsh
  run: Install-Module Pester -MinimumVersion 5.5.0 -Force -Scope CurrentUser
- name: Windows behavior tests
  shell: pwsh
  run: Invoke-Pester -Path .\tests\windows\Installer.Tests.ps1 -CI -Output Detailed
```

- [ ] **Step 6: Run syntax, lint, and both test suites**

Run: `bash -n lm-studio-install.sh && shellcheck -x -e SC2034,SC1090,SC1091 lm-studio-install.sh && bats tests/linux/installer.bats`

Run: `Invoke-ScriptAnalyzer .\lm-studio-install.ps1 -Severity Error,Warning; Invoke-Pester .\tests\windows\Installer.Tests.ps1 -Output Detailed`

Expected: all tests pass; only pre-existing non-blocking `Write-Host` analyzer warnings may remain.

- [ ] **Step 7: Commit the harness**

```bash
git add lm-studio-install.sh lm-studio-install.ps1 tests .github/workflows/ci.yml
git commit -m "test: add isolated installer behavior suites"
```

---

### Task 2: Make Linux paths and integration ownership safe

**Files:**
- Modify: `lm-studio-install.sh:85-93,224-262,442-464,646-696`
- Modify: `tests/linux/installer.bats`

**Interfaces:**
- Consumes: `INSTALL_DIR`, `BACKUP_DIR`, `BIN_DIR`, `DESKTOP_DIR`.
- Produces: `validate_install_paths() -> 0|1`, `is_managed_install() -> 0|1`, `validate_install_target() -> 0|1`, `remove_owned_link(path,target)`, and desktop marker `X-LMStudio-Installer-Managed=true`.

- [ ] **Step 1: Add failing tests for `$HOME`, `/`, unversioned installs, foreign launchers, and foreign desktop entries**

```bash
@test "rejects HOME as LMS_INSTALL_DIR" {
  run env HOME="$HOME" LMS_INSTALL_DIR="$HOME" LMS_INSTALLER_SOURCE_ONLY=1 \
    bash -c 'source "$1"; trap - EXIT INT TERM; validate_install_paths' \
    _ "$PROJECT_ROOT/lm-studio-install.sh"
  [ "$status" -ne 0 ]
}

@test "refuses an existing unversioned install" {
  mkdir -p "$INSTALL_DIR"
  touch "$INSTALL_DIR/lm-studio"
  run validate_install_target
  [ "$status" -ne 0 ]
  [ -e "$INSTALL_DIR/lm-studio" ]
}

@test "uninstall preserves a foreign launcher" {
  mkdir -p "$INSTALL_DIR" "$BIN_DIR"
  touch "$INSTALL_DIR/.lmstudio-installer-managed"
  printf foreign > "$BIN_DIR/lm-studio"
  OPT_YES=true
  run cmd_uninstall
  [ "$status" -eq 0 ]
  [ "$(cat "$BIN_DIR/lm-studio")" = foreign ]
}
```

- [ ] **Step 2: Run the focused tests and verify the current destructive behavior**

Run: `bats --filter 'rejects HOME|unversioned|foreign' tests/linux/installer.bats`

Expected: FAIL; the current implementation accepts/deletes these targets.

- [ ] **Step 3: Canonicalize and reject broad install targets before any subcommand**

```bash
validate_install_paths() {
    command -v realpath >/dev/null 2>&1 || {
        log_error "realpath is required for safe path validation."
        return 1
    }
    [[ "$INSTALL_DIR" == /* ]] || { log_error "LMS_INSTALL_DIR must be absolute."; return 1; }
    local resolved_home resolved_install
    resolved_home=$(realpath -m -- "$HOME")
    resolved_install=$(realpath -m -- "$INSTALL_DIR")
    case "$resolved_install" in
        /|"$resolved_home"|"$resolved_home/.local"|"$resolved_home/.local/share"|"$resolved_home/.local/bin"|"$resolved_home/.local/share/applications")
            log_error "Unsafe install directory: $resolved_install"
            return 1 ;;
    esac
    [[ "$resolved_install" != "$(realpath -m -- "$BIN_DIR")" ]] || return 1
    [[ "$resolved_install" != "$(realpath -m -- "$DESKTOP_DIR")" ]] || return 1
}
```

Call `validate_install_paths` immediately after `parse_args`, before `info`, `check`, or `uninstall` can reach cleanup logic.

- [ ] **Step 4: Require a managed marker for replacement/removal and migrate only verifiable legacy installs**

```bash
readonly MANAGED_MARKER="${INSTALL_DIR}/.lmstudio-installer-managed"

is_managed_install() {
    [[ -f "$MANAGED_MARKER" ]] && return 0
    [[ -f "$VERSION_FILE" && -x "${INSTALL_DIR}/lm-studio" ]]
}

validate_install_target() {
    [[ ! -e "$INSTALL_DIR" ]] && return 0
    is_managed_install || {
        log_error "Refusing to modify an existing install not managed by this script: $INSTALL_DIR"
        return 1
    }
}
```

If `$INSTALL_DIR` exists and `validate_install_target` fails, abort without moving, deleting, or nesting anything. Treat a legacy version file plus executable as managed without mutating it during `info`; write the new marker only after the next successful extraction.

- [ ] **Step 5: Refuse to overwrite foreign links/files and mark the desktop entry**

```bash
ensure_owned_link_slot() {
    local path="$1" expected="$2"
    [[ ! -e "$path" && ! -L "$path" ]] && return 0
    [[ -L "$path" && "$(readlink -f -- "$path")" == "$(readlink -f -- "$expected")" ]] && return 0
    log_error "Refusing to overwrite unowned path: $path"
    return 1
}

remove_owned_link() {
    local path="$1" expected="$2"
    [[ -L "$path" && "$(readlink -f -- "$path")" == "$(readlink -f -- "$expected")" ]] && rm -f -- "$path"
}
```

Add `X-LMStudio-Installer-Managed=true` to the desktop entry. Before overwrite/removal, require that exact line with `grep -Fxq`.

- [ ] **Step 6: Run all Linux tests and lint**

Run: `bash -n lm-studio-install.sh && shellcheck -x -e SC2034,SC1090,SC1091 lm-studio-install.sh && bats tests/linux/installer.bats`

Expected: PASS, including assertions that foreign files and broad directories survive.

- [ ] **Step 7: Commit Linux path safety**

```bash
git add lm-studio-install.sh tests/linux/installer.bats
git commit -m "fix: guard Linux install and integration paths"
```

---

### Task 3: Make Linux upgrades and temporary files transactional

**Files:**
- Modify: `lm-studio-install.sh:114-163,438-567,573-644,713-771`
- Modify: `tests/linux/installer.bats`

**Interfaces:**
- Consumes: managed-path checks from Task 2.
- Produces: `prepare_existing_install(version) -> 0|1`, global `BACKUP_CREATED`, global `NEW_INSTALL_CREATED`, global `DOWNLOADED_APPIMAGE`, and a single `EXIT` cleanup path.

- [ ] **Step 1: Add failing tests for backup-copy failure, launcher failure rollback, successful backup cleanup, and download cleanup**

```bash
make_managed_install() {
  local version="$1"
  mkdir -p "$INSTALL_DIR"
  printf '#!/bin/sh\n' > "$INSTALL_DIR/lm-studio"
  chmod +x "$INSTALL_DIR/lm-studio"
  printf '%s\n' "$version" > "$VERSION_FILE"
  printf 'schema=1\n' > "$MANAGED_MARKER"
}

run_mocked_main() {
  set -e
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  check_dependencies() { :; }
  detect_architecture() { echo x64; }
  show_security_warning() { :; }
  download_appimage() {
    DOWNLOADED_APPIMAGE="$TMPDIR/mock.AppImage"
    printf mock > "$DOWNLOADED_APPIMAGE"
  }
  extract_and_install() {
    mkdir -p "$INSTALL_DIR"
    printf '#!/bin/sh\n' > "$INSTALL_DIR/lm-studio"
    chmod +x "$INSTALL_DIR/lm-studio"
    printf '%s\n' "$2" > "$VERSION_FILE"
    printf 'schema=1\n' > "$MANAGED_MARKER"
  }
  main "$@"
}

@test "backup copy failure preserves the live install" {
  make_managed_install 1.0.0
  cp() { return 9; }
  run prepare_existing_install 2.0.0
  [ "$status" -ne 0 ]
  [ -e "$INSTALL_DIR/lm-studio" ]
  [ ! -e "$BACKUP_DIR" ]
}

@test "successful upgrade removes its backup" {
  make_managed_install 1.0.0
  create_symlinks() { :; }
  create_desktop_entry() { :; }
  post_install_info() { :; }
  run run_mocked_main -v 2.0.0 -y
  [ "$status" -eq 0 ]
  [ "$(cat "$VERSION_FILE")" = 2.0.0 ]
  [ ! -e "$BACKUP_DIR" ]
}

@test "integration failure restores the previous install" {
  make_managed_install 1.0.0
  create_symlinks() { return 7; }
  run run_mocked_main -v 2.0.0 -y
  [ "$status" -eq 7 ]
  [ "$(cat "$VERSION_FILE")" = 1.0.0 ]
  [ ! -e "$BACKUP_DIR" ]
}

@test "failed validation leaves no temporary AppImage" {
  download_file() { printf partial > "$2"; }
  validate_download() { return 1; }
  run download_appimage 2.0.0 x64
  [ "$status" -ne 0 ]
  [ "$(find "$TEST_ROOT" -type f -name '*.AppImage' | wc -l)" -eq 0 ]
}
```

- [ ] **Step 2: Verify all four transaction tests fail on the current code**

Run: `bats --filter 'backup copy|integration failure|successful upgrade|failed validation' tests/linux/installer.bats`

Expected: FAIL with the audit's reproduced states.

- [ ] **Step 3: Replace nonzero “backup created” signaling with explicit guarded operations**

```bash
prepare_existing_install() {
    local version="$1"
    [[ -d "$INSTALL_DIR" ]] || return 0
    is_managed_install || { log_error "Existing install is not managed by this script."; return 1; }
    if [[ -e "$BACKUP_DIR" ]]; then
        [[ -f "$BACKUP_DIR/.lmstudio-installer-managed" ||
           ( -f "$BACKUP_DIR/.installed_version" && -x "$BACKUP_DIR/lm-studio" ) ]] || {
            log_error "Refusing to replace an unowned backup path: $BACKUP_DIR"
            return 1
        }
        rm -rf -- "${BACKUP_DIR:?}" || return 1
    fi
    cp -a -- "$INSTALL_DIR" "$BACKUP_DIR" || {
        log_error "Could not create backup; existing installation was not changed."
        return 1
    }
    BACKUP_CREATED=true
    rm -rf -- "${INSTALL_DIR:?}" || return 1
}
```

Do not call this function in an `if`, `!`, `&&`, or `||` context. Call it as a simple command so `set -e` remains active.

- [ ] **Step 4: Keep transaction flags armed through integration and clean them explicitly on success**

```bash
prepare_existing_install "$version"
download_appimage "$version" "$arch"
extract_and_install "$DOWNLOADED_APPIMAGE" "$version"
NEW_INSTALL_CREATED=true
create_symlinks
create_desktop_entry
post_install_info
if [[ "$BACKUP_CREATED" == true ]]; then
    rm -rf -- "${BACKUP_DIR:?}"
fi
BACKUP_CREATED=false
NEW_INSTALL_CREATED=false
```

Cleanup must remove a partial new install when `NEW_INSTALL_CREATED=true`, restore a backup when `BACKUP_CREATED=true`, and preserve the original exit status.

- [ ] **Step 5: Remove command-substitution state loss from AppImage downloads**

```bash
DOWNLOADED_APPIMAGE=""
download_appimage() {
    local version="$1" arch="$2" tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/LM-Studio.${version}.${arch}.XXXXXX.AppImage")
    temp_track "$tmp"
    download_file "$(get_appimage_url "$version" "$arch")" "$tmp"
    validate_download "$tmp"
    DOWNLOADED_APPIMAGE="$tmp"
}
```

Use `download_appimage "$version" "$arch"` directly, never `$(download_appimage "$version" "$arch")`.

- [ ] **Step 6: Use one EXIT trap and signal wrappers to prevent recursive cleanup**

```bash
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM
    # remove tracked temporary paths, then rollback/partial cleanup
    exit "$exit_code"
}
```

- [ ] **Step 7: Run transaction tests, the full suite, and ShellCheck**

Run: `bats tests/linux/installer.bats && shellcheck -x -e SC2034,SC1090,SC1091 lm-studio-install.sh`

Expected: PASS; no install or backup is lost in any failure test.

- [ ] **Step 8: Commit Linux transaction fixes**

```bash
git add lm-studio-install.sh tests/linux/installer.bats
git commit -m "fix: make Linux upgrades transactional"
```

---

### Task 4: Verify SHA-512 artifacts and harden Linux sandbox setup

**Files:**
- Modify: `lm-studio-install.sh:301-331,470-644`
- Modify: `lm-studio-install.ps1:284-383,388-448,671-676`
- Modify: `tests/linux/installer.bats`
- Modify: `tests/windows/Installer.Tests.ps1`

**Interfaces:**
- Consumes: versioned artifact URLs already generated by both scripts.
- Produces: `verify_sha512(file,url)`, PowerShell `Test-Sha512`, PowerShell `Test-LmStudioSignature`, and Linux `configure_chrome_sandbox`.

- [ ] **Step 1: Add failing checksum tests for match, mismatch, malformed sidecar, and missing sidecar**

```bash
@test "rejects a mismatched SHA-512 sidecar" {
  printf payload > "$TEST_ROOT/app.AppImage"
  fetch_text() { printf '%0128d\n' 0; }
  run verify_sha512 "$TEST_ROOT/app.AppImage" 'https://installers.lmstudio.ai/app.AppImage'
  [ "$status" -ne 0 ]
}
```

```powershell
It 'rejects a mismatched SHA-512 sidecar' {
    Set-Content -LiteralPath "$TestDrive\installer.exe" -Value payload -NoNewline
    Mock Invoke-TextDownload { '0' * 128 }
    { Test-Sha512 -Path "$TestDrive\installer.exe" -ArtifactUrl 'https://installers.lmstudio.ai/installer.exe' } |
        Should -Throw '*SHA-512 mismatch*'
}
```

- [ ] **Step 2: Verify the tests fail because no checksum functions exist**

Run: `bats --filter 'SHA-512' tests/linux/installer.bats`

Run: `Invoke-Pester tests/windows/Installer.Tests.ps1 -Output Detailed`

Expected: FAIL with missing-command/function errors.

- [ ] **Step 3: Implement fail-closed SHA-512 verification against `<artifact>.sha512`**

```bash
verify_sha512() {
    local file="$1" artifact_url="$2" expected actual
    expected=$(curl -fsSL --retry 3 --max-time 30 "${artifact_url}.sha512") || {
        log_error "Official SHA-512 sidecar is unavailable."
        return 1
    }
    [[ "$expected" =~ ^[[:xdigit:]]{128}$ ]] || { log_error "Malformed SHA-512 sidecar."; return 1; }
    read -r actual _ < <(sha512sum -- "$file")
    [[ "${actual,,}" == "${expected,,}" ]] || { log_error "SHA-512 mismatch."; return 1; }
}
```

```powershell
function Test-Sha512 {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ArtifactUrl)
    $expected = (Invoke-TextDownload -Url "$ArtifactUrl.sha512").Trim()
    if ($expected -notmatch '^[A-Fa-f0-9]{128}$') { throw 'Malformed SHA-512 sidecar.' }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA512).Hash
    if ($actual -ine $expected) { throw 'SHA-512 mismatch.' }
}
```

Keep ELF/MZ and minimum-size checks as defense in depth, but run SHA-512 before executing or extracting.

- [ ] **Step 4: Add and implement Windows Authenticode publisher verification**

```powershell
function Test-LmStudioSignature {
    param([Parameter(Mandatory)][string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid') { throw "Invalid Authenticode signature: $($signature.Status)" }
    if ($signature.SignerCertificate.Subject -notmatch '(?:^|, )O=Element Labs Inc\.(?:,|$)') {
        throw "Unexpected installer publisher: $($signature.SignerCertificate.Subject)"
    }
}
```

Pester must mock valid, invalid, unsigned, and wrong-publisher results. Do not pin a certificate thumbprint because legitimate code-signing certificates rotate.

- [ ] **Step 5: Replace the two-command SUID sequence with one root helper using an opened file descriptor and expected inode**

```bash
configure_chrome_sandbox() {
    local sandbox="$1" expected
    expected=$(stat -Lc '%d:%i' -- "$sandbox") || return 1
    sudo bash -c '
      set -euo pipefail
      exec 9<"$1"
      [[ "$(stat -Lc "%d:%i" /proc/self/fd/9)" == "$2" ]] || exit 73
      chown root:root /proc/self/fd/9
      chmod 4755 /proc/self/fd/9
      [[ "$(stat -Lc "%u:%g:%a" /proc/self/fd/9)" == "0:0:4755" ]]
    ' bash "$sandbox" "$expected"
}
```

Mock `sudo` in Bats and assert that inode mismatch exits 73 without invoking `chmod`. Remove the existing claim that comparing only around `chown` closes the race.

- [ ] **Step 6: Add `sha512sum` to Linux dependencies and run all integrity tests**

Run: `bats tests/linux/installer.bats && Invoke-Pester tests/windows/Installer.Tests.ps1 -Output Detailed`

Expected: PASS for matching fixtures; mismatch/malformed/missing/signature failures all fail closed.

- [ ] **Step 7: Commit artifact verification**

```bash
git add lm-studio-install.sh lm-studio-install.ps1 tests
git commit -m "fix: verify LM Studio artifacts before execution"
```

---

### Task 5: Correct Windows discovery, process, and uninstall behavior

**Files:**
- Modify: `lm-studio-install.ps1:187-282,409-564,617-676`
- Modify: `tests/windows/Installer.Tests.ps1`

**Interfaces:**
- Consumes: checksum/signature helpers from Task 4.
- Produces: `ConvertTo-LmStudioVersion(string) -> string|null`, `Get-LmStudioRegistryEntry()`, `Get-LmStudioState()`, and `Split-UninstallCommand(string)`.

- [ ] **Step 1: Add failing normalization and live-state tests**

```powershell
It 'normalizes plus build metadata' {
    ConvertTo-LmStudioVersion '0.4.21+2' | Should -Be '0.4.21-2'
}
It 'prefers FileVersion over ProductVersion' {
    Get-VersionFromInfo ([pscustomobject]@{ FileVersion='0.4.21+2'; ProductVersion='0.4.21.0' }) |
        Should -Be '0.4.21-2'
}
It 'does not treat a cache-only version as installed' {
    Mock Get-LmStudioInstallPath { $null }
    Mock Get-RecordedVersion { '1.2.3' }
    (Get-LmStudioState).IsInstalled | Should -BeFalse
}
```

- [ ] **Step 2: Add failing process tests**

```powershell
It 'never retries interactively when Yes is set' {
    $script:Yes = $true
    Mock Start-Process { [pscustomobject]@{ ExitCode=9 } }
    { Install-LmStudio -InstallerPath "$TestDrive\i.exe" -Ver 1.2.3 } | Should -Throw '*code 9*'
    Should -Invoke Start-Process -Times 1 -Exactly
}
It 'keeps state when the uninstaller fails' {
    $script:StateDir = Join-Path $TestDrive 'state'
    New-Item -ItemType Directory -Path $script:StateDir | Out-Null
    Mock Start-Process { [pscustomobject]@{ ExitCode=23 } }
    { Invoke-Uninstall } | Should -Throw '*code 23*'
    Test-Path $script:StateDir | Should -BeTrue
}
It 'never recursively removes a registry InstallLocation fallback' {
    Mock Get-LmStudioUninstallCommand { $null }
    Mock Get-LmStudioInstallPath { 'C:\unexpected\registry-path' }
    Mock Remove-Item {}
    { Invoke-Uninstall } | Should -Throw '*valid registry uninstaller*'
    Should -Invoke Remove-Item -ParameterFilter { $Recurse } -Times 0 -Exactly
}
```

- [ ] **Step 3: Normalize registry and file versions with build-aware precedence**

```powershell
function ConvertTo-LmStudioVersion {
    param([string]$Value)
    if ($Value -match '^([0-9]+\.[0-9]+\.[0-9]+)(?:[.+-]([0-9]+))?') {
        return $(if ($Matches[2]) { "$($Matches[1])-$($Matches[2])" } else { $Matches[1] })
    }
    return $null
}
function Get-VersionFromInfo {
    param($Info)
    foreach ($candidate in @($Info.FileVersion, $Info.ProductVersion)) {
        $normalized = ConvertTo-LmStudioVersion $candidate
        if ($normalized) { return $normalized }
    }
    return $null
}
```

Prefer an exact registry record and treat the cache as a fallback only when an executable is present.

```powershell
function Get-LmStudioRegistryEntry {
    $roots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($key in Get-ChildItem $root -ErrorAction SilentlyContinue) {
            $entry = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
            if ($entry.DisplayName -match '^LM Studio(?:\s|$)' -and $entry.Publisher -eq 'LM Studio') {
                return $entry
            }
        }
    }
    return $null
}

function Get-LmStudioState {
    $path = Get-LmStudioInstallPath
    $cached = Get-RecordedVersion
    if (-not $path -or -not (Test-Path -LiteralPath (Join-Path $path 'LM Studio.exe'))) {
        return [pscustomobject]@{ IsInstalled=$false; Path=$null; Version=$null; CachedVersion=$cached }
    }
    $entry = Get-LmStudioRegistryEntry
    $version = if ($entry) { ConvertTo-LmStudioVersion $entry.DisplayVersion } else { $null }
    if (-not $version) { $version = Get-ExeFileVersion -ExePath (Join-Path $path 'LM Studio.exe') }
    if (-not $version) { $version = $cached }
    return [pscustomobject]@{ IsInstalled=$true; Path=$path; Version=$version; CachedVersion=$cached }
}
```

Refactor both `Get-LmStudioInstallPath` and `Get-LmStudioUninstallCommand` to consume `Get-LmStudioRegistryEntry`; remove their independent fuzzy `*LM Studio*` registry scans.

- [ ] **Step 4: Treat `-Yes` as strictly non-interactive and verify installation before recording state**

If silent `Start-Process` exits nonzero, throw immediately. After exit zero, require `Get-LmStudioInstallPath` and `LM Studio.exe` to exist before `Set-RecordedVersion`.

```powershell
if ($Yes -and $proc.ExitCode -ne 0) { throw "Silent installer exited with code $($proc.ExitCode)" }
$installPath = Get-LmStudioInstallPath
if (-not $installPath -or -not (Test-Path -LiteralPath (Join-Path $installPath 'LM Studio.exe'))) {
    throw 'Installer exited successfully but LM Studio.exe was not found.'
}
Set-RecordedVersion -Ver $Ver
```

- [ ] **Step 5: Parse uninstall commands without `cmd /c`, reject ambiguous records, and fail on nonzero exit**

```powershell
function Split-UninstallCommand {
    param([Parameter(Mandatory)][string]$Command)
    if ($Command -match '^\s*"(?<Exe>[^"]+\.exe)"\s*(?<Args>.*)$' -or
        $Command -match '^\s*(?<Exe>.+?\.exe)\s*(?<Args>.*)$') {
        return [pscustomobject]@{ Exe=$Matches.Exe; Args=$Matches.Args.Trim() }
    }
    throw "Unsupported uninstall command: $Command"
}
```

Use `Start-Process -FilePath $parts.Exe -ArgumentList $parts.Args -Wait -PassThru`. Remove the raw `cmd.exe /c` branch and remove recursive deletion of registry-derived `InstallLocation`; if no valid uninstaller exists, stop with manual instructions.

- [ ] **Step 6: Remove state only after verified uninstall success**

After exit zero, re-run discovery. If `LM Studio.exe` remains, throw and retain state. Only then remove `$StateDir` and print success.

```powershell
if ($process.ExitCode -ne 0) { throw "Uninstaller exited with code $($process.ExitCode)" }
$remainingPath = Get-LmStudioInstallPath
if ($remainingPath -and (Test-Path -LiteralPath (Join-Path $remainingPath 'LM Studio.exe'))) {
    throw "Uninstaller exited successfully but LM Studio.exe still exists at $remainingPath"
}
if (Test-Path -LiteralPath $script:StateDir) {
    Remove-Item -LiteralPath $script:StateDir -Recurse -Force
}
Write-Ok 'LM Studio uninstalled.'
```

- [ ] **Step 7: Run Pester, parser, and analyzer**

Run: `Invoke-Pester tests/windows/Installer.Tests.ps1 -Output Detailed`

Run: `$e=$null;$t=$null;[void][Management.Automation.Language.Parser]::ParseFile("$PWD\lm-studio-install.ps1",[ref]$t,[ref]$e); if($e){$e;exit 1}; Invoke-ScriptAnalyzer .\lm-studio-install.ps1 -Severity Error,Warning`

Expected: Pester and parser pass; no new analyzer errors or warnings.

- [ ] **Step 8: Commit Windows reliability fixes**

```bash
git add lm-studio-install.ps1 tests/windows/Installer.Tests.ps1
git commit -m "fix: make Windows install state authoritative"
```

---

### Task 6: Correct cross-platform CLI and update semantics

**Files:**
- Modify: `lm-studio-install.sh:176-296,333-414,713-780`
- Modify: `lm-studio-install.ps1:93-176,529-564,585-699`
- Modify: `tests/linux/installer.bats`
- Modify: `tests/windows/Installer.Tests.ps1`

**Interfaces:**
- Consumes: normalized version strings from Task 5.
- Produces: three-way version comparison (`older`, `equal`, `newer`) and consistent exit statuses: 0 success/cancel, 1 operational/usage failure.

- [ ] **Step 1: Add failing tests for unknown arguments, missing `-v`, unsupported architecture, newer installed builds, and redirect parse failure**

```bash
@test "unknown arguments fail" {
  run "$PROJECT_ROOT/lm-studio-install.sh" --not-a-real-option
  [ "$status" -eq 1 ]
}
@test "check rejects unsupported architecture" {
  detect_architecture() { return 1; }
  run cmd_check
  [ "$status" -eq 1 ]
}
```

```powershell
It 'reports an installed build newer than latest as ahead' {
    Mock Get-LmStudioState { [pscustomobject]@{IsInstalled=$true;Version='0.4.22-1'} }
    Mock Get-LatestVersion { '0.4.21-2' }
    Show-Check 6>&1 | Out-String | Should -Match 'newer than the current public release'
}
```

- [ ] **Step 2: Give Bash usage errors a nonzero path and validate option values immediately**

```bash
usage() {
    local rc="${1:-0}"
    cat >&2 <<EOF
Usage: $(basename "$0") [OPTIONS] [SUBCOMMAND]
Subcommands: uninstall | info | check
Options: -v, --ver VERSION | -y, --yes | -q, --quiet | -h, --help
Environment: LMS_INSTALL_DIR overrides the validated installation directory.
EOF
    exit "$rc"
}
# unknown option
log_error "Unknown argument: $1"
usage 1
# -v/--ver
[[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { log_error "$1 requires VERSION"; usage 1; }
```

Use exit 0 for explicit user cancellation and update the obsolete comment claiming cancellation is status 2.

- [ ] **Step 3: Remove x64 fallback and generic page-token fallback**

`cmd_check` must call `detect_architecture` directly. Both latest-version functions may parse only the final official redirect or an `LM-Studio-<version>` token; remove the “first `0.x.y` token” fallback so another product/version cannot be selected.

- [ ] **Step 4: Add build-aware three-way comparison**

```powershell
function ConvertTo-VersionObject {
    param([string]$Value)
    $parts = $Value -split '-', 2
    $build = if ($parts.Count -eq 2) { [int]$parts[1] } else { 0 }
    return [version]"$($parts[0]).$build"
}
```

Use numeric component comparison in Bash rather than lexicographic string ordering.

```bash
compare_versions() {
    local left="$1" right="$2" lbase lbuild rbase rbuild
    lbase="${left%%-*}"; lbuild="${left#*-}"; [[ "$lbuild" == "$left" ]] && lbuild=0
    rbase="${right%%-*}"; rbuild="${right#*-}"; [[ "$rbuild" == "$right" ]] && rbuild=0
    local IFS=. la lb lc ra rb rc
    read -r la lb lc <<< "$lbase"
    read -r ra rb rc <<< "$rbase"
    local lv rv
    for lv in "$la" "$lb" "$lc" "$lbuild"; do [[ "$lv" =~ ^[0-9]+$ ]] || return 2; done
    for rv in "$ra" "$rb" "$rc" "$rbuild"; do [[ "$rv" =~ ^[0-9]+$ ]] || return 2; done
    la=$((10#$la)); lb=$((10#$lb)); lc=$((10#$lc)); lbuild=$((10#$lbuild))
    ra=$((10#$ra)); rb=$((10#$rb)); rc=$((10#$rc)); rbuild=$((10#$rbuild))
    if (( la != ra )); then (( la < ra )) && echo -1 || echo 1
    elif (( lb != rb )); then (( lb < rb )) && echo -1 || echo 1
    elif (( lc != rc )); then (( lc < rc )) && echo -1 || echo 1
    elif (( lbuild != rbuild )); then (( lbuild < rbuild )) && echo -1 || echo 1
    else echo 0
    fi
}
```

Report “up to date,” “update available,” or “installed build is newer than the current public release.”

- [ ] **Step 5: Run focused CLI tests and both full suites**

Run: `bats tests/linux/installer.bats`

Run: `Invoke-Pester tests/windows/Installer.Tests.ps1 -Output Detailed`

Expected: PASS with no network calls in unit tests.

- [ ] **Step 6: Commit CLI corrections**

```bash
git add lm-studio-install.sh lm-studio-install.ps1 tests
git commit -m "fix: normalize installer CLI and update checks"
```

---

### Task 7: Synchronize documentation and perform final verification

**Files:**
- Modify: `README.md:64-145`
- Modify: `SECURITY.md:12-55`
- Modify: `CONTRIBUTING.md:27-67`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: final behavior and commands from Tasks 1-6.
- Produces: accurate user/security documentation and the final CI gate.

- [ ] **Step 1: Replace the obsolete checksum warning**

Document that each artifact is verified against its official `<artifact>.sha512` sidecar; Windows additionally requires a valid Authenticode signature from `Element Labs Inc.`; ELF/MZ and size checks remain secondary corruption checks.

- [ ] **Step 2: Document path and ownership rules**

State that Linux refuses `/`, `$HOME`, `.local` roots, existing unowned install directories, foreign launcher files, and foreign desktop entries. State that uninstall removes only managed artifacts and that failed upgrades restore the previous managed install.

- [ ] **Step 3: Document exact CLI outcomes**

Describe `-Yes` as strictly non-interactive, cancellation as exit 0, usage/operational errors as exit 1, build-aware update messages, and checksum/signature failures as fatal.

- [ ] **Step 4: Add local test commands to CONTRIBUTING**

```text
bash -n lm-studio-install.sh
shellcheck -x -e SC2034,SC1090,SC1091 lm-studio-install.sh
bats tests/linux/installer.bats
Invoke-ScriptAnalyzer .\lm-studio-install.ps1 -Severity Error,Warning
Invoke-Pester .\tests\windows\Installer.Tests.ps1 -Output Detailed
```

- [ ] **Step 5: Run the complete local verification matrix**

Run: `bash -n lm-studio-install.sh`

Run: `docker run --rm -v "$PWD:/mnt:ro" koalaman/shellcheck:stable -x -e SC2034,SC1090,SC1091 /mnt/lm-studio-install.sh`

Run: `bats tests/linux/installer.bats`

Run: PowerShell AST parse, PSScriptAnalyzer, then `Invoke-Pester tests/windows/Installer.Tests.ps1 -Output Detailed`.

Run: `lm-studio-install.ps1 -Help`, `lm-studio-install.ps1 info`, and mocked/offline `check` tests. Do not run real install or uninstall on the development machine.

Expected: all commands pass; repository status shows only the intended script, test, workflow, and documentation changes.

- [ ] **Step 6: Re-check live official metadata without downloading installers**

HEAD the four `https://lmstudio.ai/download/latest/<os>/<arch>` endpoints and assert their final names match the strict version regex. GET only the four `.sha512` sidecars and assert exactly 128 hexadecimal characters.

- [ ] **Step 7: Commit documentation and final CI adjustments**

```bash
git add README.md SECURITY.md CONTRIBUTING.md .github/workflows/ci.yml
git commit -m "docs: describe verified installer safety model"
```

## Final Acceptance Criteria

- Every P0/P1/P2 finding in this plan has a named regression test.
- No broad or unowned filesystem path reaches recursive deletion.
- A failed backup cannot alter the current installation.
- Any failure through launcher and desktop integration restores the prior installation.
- Temporary artifacts are cleaned on success, failure, interrupt, and termination.
- SHA-512 mismatch/missing/malformed sidecars stop both installers before execution or extraction.
- Windows requires valid Element Labs Authenticode and never falls back to GUI when `-Yes` is set.
- Windows reports `0.4.21+2` as `0.4.21-2` and does not claim a false update.
- Failed Windows uninstall retains state and returns failure.
- Linux never overwrites/removes foreign launchers or desktop entries.
- Bash syntax, ShellCheck, Bats, PowerShell parse, PSScriptAnalyzer, and Pester all pass in CI.
