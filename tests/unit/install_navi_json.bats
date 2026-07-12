load 'helpers/load'

setup() {
    setup_test_env
    NAVI_JSON="$FAKE_HOME/printer_data/config/.theme/navi.json"
}

teardown() {
    teardown_test_env
}

slicer_entry_count() {
    python3 -c "
import json
with open('$NAVI_JSON') as f:
    navi = json.load(f)
print(sum(1 for e in navi if e.get('title') == 'Slicer'))
"
}

@test "install.sh creates navi.json with a Slicer entry when none exists" {
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [ -f "$NAVI_JSON" ]
    [ "$(slicer_entry_count)" -eq 1 ]
}

@test "install.sh appends the Slicer entry without disturbing existing entries" {
    mkdir -p "$(dirname "$NAVI_JSON")"
    cp "$REPO_ROOT/tests/fixtures/navi.json.sample" "$NAVI_JSON"
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [ "$(slicer_entry_count)" -eq 1 ]
    grep -q '"Dashboard"' "$NAVI_JSON"
}

@test "install.sh run twice does not duplicate the Slicer entry" {
    mkdir -p "$(dirname "$NAVI_JSON")"
    cp "$REPO_ROOT/tests/fixtures/navi.json.sample" "$NAVI_JSON"
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [ "$(slicer_entry_count)" -eq 1 ]
}

@test "install.sh backs up and recreates a malformed navi.json" {
    mkdir -p "$(dirname "$NAVI_JSON")"
    cp "$REPO_ROOT/tests/fixtures/navi.json.malformed" "$NAVI_JSON"
    run bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [ -f "$NAVI_JSON.bak" ]
    [ "$(slicer_entry_count)" -eq 1 ]
}
