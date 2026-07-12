load 'helpers/load'

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

@test "install.sh finds the venv-style moonraker components dir" {
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Moonraker components at: $FAKE_HOME/moonraker-env/lib/python3.11/site-packages/moonraker/components"* ]]
}

@test "install.sh finds the source-install moonraker components dir when present" {
    rm -rf "$FAKE_HOME/moonraker-env"
    mkdir -p "$FAKE_HOME/moonraker/moonraker/components"
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Moonraker components at: $FAKE_HOME/moonraker/moonraker/components"* ]]
}

@test "install.sh dies when no moonraker components dir can be found" {
    rm -rf "$FAKE_HOME/moonraker-env"
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Cannot find Moonraker components directory"* ]]
}

@test "install.sh symlinks the component and UI file into the detected dir" {
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    components_dir="$FAKE_HOME/moonraker-env/lib/python3.11/site-packages/moonraker/components"
    [ -L "$components_dir/orcaslicer.py" ]
    [ -L "$components_dir/slicer_ui.html" ]
    [ "$(readlink -f "$components_dir/orcaslicer.py")" = "$REPO_ROOT/src/orcaslicer.py" ]
}
