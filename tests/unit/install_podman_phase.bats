load 'helpers/load'

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

@test "install.sh dies when disk space is below the 4GB threshold" {
    export MOCK_DF_AVAIL_MB=2000
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"need at least 4GB"* ]]
}

@test "install.sh proceeds when disk space is above the 4GB threshold" {
    export MOCK_DF_AVAIL_MB=20000
    export MOCK_PODMAN_BUILD_EXIT=0
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Container image built"* ]]
}

@test "install.sh surfaces the build log tail and exits nonzero on build failure" {
    export MOCK_PODMAN_BUILD_EXIT=1
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Container build failed"* ]]
    [[ "$output" == *"mock build log line"* ]]
}
