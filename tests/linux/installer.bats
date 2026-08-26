#!/usr/bin/env bats

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

@test "source-only mode loads functions without invoking main" {
    run env LMS_INSTALLER_SOURCE_ONLY=1 bash -c 'source "$1"; declare -F main' _ \
        "$PROJECT_ROOT/lm-studio-install.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"main" ]]
}
