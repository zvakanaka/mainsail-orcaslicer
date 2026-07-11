load 'helpers/load'

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

@test "install.sh warns but continues on unsupported architecture" {
    export MOCK_UNAME_M="riscv64"
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Unsupported architecture: riscv64"* ]]
}

@test "install.sh does not warn about arch on x86_64" {
    export MOCK_UNAME_M="x86_64"
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Unsupported architecture"* ]]
}

@test "install.sh warns but continues when moonraker service is not active" {
    export MOCK_SYSTEMCTL_MOONRAKER_ACTIVE=false
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Moonraker service not detected"* ]]
}
