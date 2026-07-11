# Shared bats setup: sandboxes $HOME, mocks external commands, and gives
# tests a place to log/inspect calls and control mock behavior.
#
# Sourced via: load 'helpers/load'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MOCK_PATH_DIR="$REPO_ROOT/tests/unit/helpers/mock-path"

setup_test_env() {
    FAKE_HOME="$(mktemp -d)"
    MOCK_LOG="$(mktemp)"
    export FAKE_HOME MOCK_LOG
    export HOME="$FAKE_HOME"

    # Real system tools (git, python3, coreutils, etc.) stay on PATH behind
    # the mocks, since only specific commands are faked out below.
    export PATH="$MOCK_PATH_DIR:$PATH"

    # No real sleeping in tests; install.sh honors this override.
    export OS_TEST_SLEEP=0

    # Default mock behavior — individual tests override before invoking
    # install.sh / uninstall.sh.
    export MOCK_PODMAN_BUILD_EXIT=0
    export MOCK_HEALTH_OK=true
    export MOCK_DF_AVAIL_MB=20000
    export MOCK_SYSTEMCTL_MOONRAKER_ACTIVE=true

    mkdir -p "$FAKE_HOME/printer_data/config"
    mkdir -p "$FAKE_HOME/moonraker-env/lib/python3.11/site-packages/moonraker/components"
    cp "$REPO_ROOT/tests/fixtures/moonraker.conf.sample" "$FAKE_HOME/printer_data/config/moonraker.conf"
}

teardown_test_env() {
    rm -rf "$FAKE_HOME"
    rm -f "$MOCK_LOG"
}

mock_calls() {
    # Print logged invocations of a given command, e.g. `mock_calls podman`
    grep "^$1 " "$MOCK_LOG" || true
}

fixture() {
    cat "$REPO_ROOT/tests/fixtures/$1"
}
