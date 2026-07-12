load 'helpers/load'

setup() {
    setup_test_env
    MOONRAKER_CONF="$FAKE_HOME/printer_data/config/moonraker.conf"
    NAVI_JSON="$FAKE_HOME/printer_data/config/.theme/navi.json"
    COMPONENTS_DIR="$FAKE_HOME/moonraker-env/lib/python3.11/site-packages/moonraker/components"
    SYSTEMD_UNIT="$FAKE_HOME/.config/systemd/user/container-orcaslicer-api.service"
}

teardown() {
    teardown_test_env
}

@test "uninstall.sh reverses a full install" {
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [ -L "$COMPONENTS_DIR/orcaslicer.py" ]
    [ -f "$SYSTEMD_UNIT" ]
    grep -q '^\[orcaslicer\]' "$MOONRAKER_CONF"

    run bash -c "printf 'y\ny\ny\n' | bash '$REPO_ROOT/uninstall.sh'"
    [ "$status" -eq 0 ]

    [ ! -e "$COMPONENTS_DIR/orcaslicer.py" ]
    [ ! -e "$COMPONENTS_DIR/slicer_ui.html" ]
    [ ! -f "$SYSTEMD_UNIT" ]
    ! grep -q '^\[orcaslicer\]' "$MOONRAKER_CONF"
    ! grep -q '^\[update_manager orcaslicer_plugin\]' "$MOONRAKER_CONF"
    [ ! -d "$FAKE_HOME/orcaslicer-web" ]
    [ ! -d "$FAKE_HOME/orcaslicer-profiles" ]
}

@test "uninstall.sh removes the Slicer nav entry but keeps other entries" {
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    mkdir -p "$(dirname "$NAVI_JSON")"
    python3 -c "
import json
with open('$NAVI_JSON') as f:
    navi = json.load(f)
navi.append({'title': 'Dashboard', 'href': '/'})
with open('$NAVI_JSON', 'w') as f:
    json.dump(navi, f)
"

    run bash -c "printf 'y\ny\ny\n' | bash '$REPO_ROOT/uninstall.sh'"
    [ "$status" -eq 0 ]

    ! grep -q '"Slicer"' "$NAVI_JSON"
    grep -q '"Dashboard"' "$NAVI_JSON"
}

@test "uninstall.sh is a safe no-op when nothing was installed" {
    run bash -c "printf 'y\n' | bash '$REPO_ROOT/uninstall.sh'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already stopped"* ]]
    [[ "$output" == *"already absent"* ]]
}

@test "uninstall.sh aborts cleanly when the user declines confirmation" {
    run bash -c "printf 'n\n' | bash '$REPO_ROOT/uninstall.sh'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Aborted"* ]]
}
