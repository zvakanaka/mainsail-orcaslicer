load 'helpers/load'

setup() {
    setup_test_env
    MOONRAKER_CONF="$FAKE_HOME/printer_data/config/moonraker.conf"
}

teardown() {
    teardown_test_env
}

@test "install.sh run twice does not duplicate the [orcaslicer] section" {
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    count="$(grep -c '^\[orcaslicer\]' "$MOONRAKER_CONF")"
    [ "$count" -eq 1 ]
}

@test "install.sh run twice does not duplicate the [update_manager orcaslicer_plugin] section" {
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    count="$(grep -c '^\[update_manager orcaslicer_plugin\]' "$MOONRAKER_CONF")"
    [ "$count" -eq 1 ]
}

@test "install.sh preserves pre-existing moonraker.conf content" {
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    grep -q '^\[server\]' "$MOONRAKER_CONF"
    grep -q '^\[authorization\]' "$MOONRAKER_CONF"
}
