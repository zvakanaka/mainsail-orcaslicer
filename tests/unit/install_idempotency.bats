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

@test "install.sh defaults debug to False in [orcaslicer]" {
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    grep -q '^debug: False$' "$MOONRAKER_CONF"
}

@test "install.sh --debug sets debug: True on a fresh install" {
    run bash "$REPO_ROOT/install.sh" --debug
    [ "$status" -eq 0 ]
    grep -q '^debug: True$' "$MOONRAKER_CONF"
    count="$(grep -c '^debug:' "$MOONRAKER_CONF")"
    [ "$count" -eq 1 ]
}

@test "install.sh --debug flips an existing debug: False to True without duplicating the section" {
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    grep -q '^debug: False$' "$MOONRAKER_CONF"

    run bash "$REPO_ROOT/install.sh" --debug
    [ "$status" -eq 0 ]
    grep -q '^debug: True$' "$MOONRAKER_CONF"
    count="$(grep -c '^\[orcaslicer\]' "$MOONRAKER_CONF")"
    [ "$count" -eq 1 ]
    count="$(grep -c '^debug:' "$MOONRAKER_CONF")"
    [ "$count" -eq 1 ]
}

@test "install.sh without --debug on a rerun does not disable a previously-enabled debug mode" {
    run bash "$REPO_ROOT/install.sh" --debug
    [ "$status" -eq 0 ]
    grep -q '^debug: True$' "$MOONRAKER_CONF"

    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    grep -q '^debug: True$' "$MOONRAKER_CONF"
}
