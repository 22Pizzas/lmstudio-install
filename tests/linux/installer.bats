#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
    TEST_ROOT="$(mktemp -d)"
    export HOME="$TEST_ROOT/home"
    export TMPDIR="$TEST_ROOT/tmp"
    export LMS_INSTALL_DIR="$HOME/.local/share/lm-studio"
    export LMS_INSTALLER_SOURCE_ONLY=1
    INSTALL_DIR="$LMS_INSTALL_DIR"
    BIN_DIR="$HOME/.local/bin"
    DESKTOP_DIR="$HOME/.local/share/applications"
    mkdir -p "$HOME" "$TMPDIR"
}

teardown() {
    [[ "$TEST_ROOT" == /tmp/* ]] || return 1
    rm -rf -- "$TEST_ROOT"
}

make_managed_install() {
    local version="${1:-1.0.0}"
    mkdir -p "$INSTALL_DIR"
    printf '#!/usr/bin/env bash\n' > "$INSTALL_DIR/lm-studio"
    chmod +x "$INSTALL_DIR/lm-studio"
    printf '%s\n' "$version" > "$INSTALL_DIR/.installed_version"
    printf 'schema=1\n' > "$INSTALL_DIR/.lmstudio-installer-managed"
}

@test "source-only mode loads functions without invoking main" {
    run env LMS_INSTALLER_SOURCE_ONLY=1 bash -c 'source "$1"; declare -F main' _ \
        "$PROJECT_ROOT/lm-studio-install.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"main" ]]
}

@test "rejects HOME as LMS_INSTALL_DIR" {
    run env HOME="$HOME" LMS_INSTALL_DIR="$HOME" LMS_INSTALLER_SOURCE_ONLY=1 \
        bash -c 'source "$1"; trap - EXIT INT TERM; declare -F validate_install_paths >/dev/null || { echo "Missing required installer function: validate_install_paths" >&2; exit 99; }; validate_install_paths' _ \
        "$PROJECT_ROOT/lm-studio-install.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"Unsafe install directory"* ]]
}

@test "rejects root as LMS_INSTALL_DIR" {
    run env HOME="$HOME" LMS_INSTALL_DIR=/ LMS_INSTALLER_SOURCE_ONLY=1 \
        bash -c 'source "$1"; trap - EXIT INT TERM; declare -F validate_install_paths >/dev/null || { echo "Missing required installer function: validate_install_paths" >&2; exit 99; }; validate_install_paths' _ \
        "$PROJECT_ROOT/lm-studio-install.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"Unsafe install directory"* ]]
}

@test "rejects a relative LMS_INSTALL_DIR" {
    run env HOME="$HOME" LMS_INSTALL_DIR=lm-studio LMS_INSTALLER_SOURCE_ONLY=1 \
        bash -c 'source "$1"; trap - EXIT INT TERM; validate_install_paths' _ \
        "$PROJECT_ROOT/lm-studio-install.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"must be an absolute path"* ]]
}

@test "refuses an existing unversioned install" {
    mkdir -p "$INSTALL_DIR"
    printf original > "$INSTALL_DIR/lm-studio"

    run bash -c 'source "$1"; trap - EXIT INT TERM; declare -F validate_install_target >/dev/null || { echo "Missing required installer function: validate_install_target" >&2; exit 99; }; validate_install_target' _ \
        "$PROJECT_ROOT/lm-studio-install.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *"not managed by this script"* ]]
    [ "$(cat "$INSTALL_DIR/lm-studio")" = original ]
}

@test "install refuses to overwrite a foreign launcher" {
    make_managed_install
    mkdir -p "$BIN_DIR"
    printf foreign > "$BIN_DIR/lm-studio"

    run bash -c 'source "$1"; trap - EXIT INT TERM; create_symlinks' _ \
        "$PROJECT_ROOT/lm-studio-install.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$BIN_DIR/lm-studio")" = foreign ]
}

@test "install refuses to overwrite a foreign desktop entry" {
    make_managed_install
    mkdir -p "$DESKTOP_DIR"
    printf foreign > "$DESKTOP_DIR/lm-studio.desktop"

    run bash -c 'source "$1"; trap - EXIT INT TERM; create_desktop_entry' _ \
        "$PROJECT_ROOT/lm-studio-install.sh"

    [ "$status" -eq 1 ]
    [ "$(cat "$DESKTOP_DIR/lm-studio.desktop")" = foreign ]
}

@test "uninstall preserves foreign integration files" {
    make_managed_install
    mkdir -p "$BIN_DIR" "$DESKTOP_DIR"
    printf foreign-launcher > "$BIN_DIR/lm-studio"
    printf foreign-cli > "$BIN_DIR/lms"
    printf foreign-desktop > "$DESKTOP_DIR/lm-studio.desktop"
    run bash -c 'source "$1"; trap - EXIT INT TERM; OPT_YES=true; cmd_uninstall' _ \
        "$PROJECT_ROOT/lm-studio-install.sh"

    [ "$status" -eq 0 ]
    [ "$(cat "$BIN_DIR/lm-studio")" = foreign-launcher ]
    [ "$(cat "$BIN_DIR/lms")" = foreign-cli ]
    [ "$(cat "$DESKTOP_DIR/lm-studio.desktop")" = foreign-desktop ]
}

@test "uninstall removes an installer-managed backup" {
    make_managed_install 1.0.0
    mkdir -p "${INSTALL_DIR}.bak"
    printf '#!/usr/bin/env bash\n' > "${INSTALL_DIR}.bak/lm-studio"
    chmod +x "${INSTALL_DIR}.bak/lm-studio"
    printf '0.9.0\n' > "${INSTALL_DIR}.bak/.installed_version"
    printf 'schema=1\n' > "${INSTALL_DIR}.bak/.lmstudio-installer-managed"

    run bash -c 'source "$1"; trap - EXIT INT TERM; OPT_YES=true; cmd_uninstall' _ \
        "$PROJECT_ROOT/lm-studio-install.sh"

    [ "$status" -eq 0 ]
    [ ! -e "$INSTALL_DIR" ]
    [ ! -e "${INSTALL_DIR}.bak" ]
}

@test "backup copy failure preserves the live install" {
    make_managed_install 1.0.0

    run bash -c '
        source "$1"
        cp() { return 9; }
        check_dependencies() { :; }
        detect_architecture() { echo x64; }
        show_security_warning() { :; }
        download_appimage() { return 8; }
        main -v 2.0.0 -y
    ' _ "$PROJECT_ROOT/lm-studio-install.sh"

    [ "$status" -ne 0 ]
    [ "$(cat "$INSTALL_DIR/.installed_version")" = 1.0.0 ]
    [ -x "$INSTALL_DIR/lm-studio" ]
    [ ! -e "${INSTALL_DIR}.bak" ]
}

@test "successful upgrade removes its backup" {
    make_managed_install 1.0.0

    run env MOCK_INTEGRATION_RC=0 bash -c '
        source "$1"
        check_dependencies() { :; }
        detect_architecture() { echo x64; }
        show_security_warning() { :; }
        download_appimage() {
            DOWNLOADED_APPIMAGE="$TMPDIR/mock.AppImage"
            printf mock > "$DOWNLOADED_APPIMAGE"
            printf "%s\n" "$DOWNLOADED_APPIMAGE"
        }
        extract_and_install() {
            mkdir -p "$INSTALL_DIR"
            printf "#!/usr/bin/env bash\n" > "$INSTALL_DIR/lm-studio"
            chmod +x "$INSTALL_DIR/lm-studio"
            printf "%s\n" "$2" > "$VERSION_FILE"
            printf "schema=1\n" > "$MANAGED_MARKER"
        }
        create_symlinks() { return "$MOCK_INTEGRATION_RC"; }
        create_desktop_entry() { :; }
        post_install_info() { :; }
        main -v 2.0.0 -y
    ' _ "$PROJECT_ROOT/lm-studio-install.sh"

    [ "$status" -eq 0 ]
    [ "$(cat "$INSTALL_DIR/.installed_version")" = 2.0.0 ]
    [ ! -e "${INSTALL_DIR}.bak" ]
}

@test "integration failure restores the previous install" {
    make_managed_install 1.0.0

    run env MOCK_INTEGRATION_RC=7 bash -c '
        source "$1"
        check_dependencies() { :; }
        detect_architecture() { echo x64; }
        show_security_warning() { :; }
        download_appimage() {
            DOWNLOADED_APPIMAGE="$TMPDIR/mock.AppImage"
            printf mock > "$DOWNLOADED_APPIMAGE"
            printf "%s\n" "$DOWNLOADED_APPIMAGE"
        }
        extract_and_install() {
            mkdir -p "$INSTALL_DIR"
            printf "#!/usr/bin/env bash\n" > "$INSTALL_DIR/lm-studio"
            chmod +x "$INSTALL_DIR/lm-studio"
            printf "%s\n" "$2" > "$VERSION_FILE"
            printf "schema=1\n" > "$MANAGED_MARKER"
        }
        create_symlinks() { return "$MOCK_INTEGRATION_RC"; }
        create_desktop_entry() { :; }
        post_install_info() { :; }
        main -v 2.0.0 -y
    ' _ "$PROJECT_ROOT/lm-studio-install.sh"

    [ "$status" -eq 7 ]
    [ "$(cat "$INSTALL_DIR/.installed_version")" = 1.0.0 ]
    [ ! -e "${INSTALL_DIR}.bak" ]
}

@test "failed validation leaves no temporary download" {
    run bash -c '
        source "$1"
        check_dependencies() { :; }
        detect_architecture() { echo x64; }
        show_security_warning() { :; }
        download_file() { printf partial > "$2"; }
        validate_download() { return 1; }
        main -v 2.0.0 -y
    ' _ "$PROJECT_ROOT/lm-studio-install.sh"

    [ "$status" -ne 0 ]
    [ "$(find "$TMPDIR" -type f | wc -l)" -eq 0 ]
}
