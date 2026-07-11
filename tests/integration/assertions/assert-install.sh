#!/usr/bin/env bash
# Asserts install.sh left the fixture host in the expected state.
# Run as the "printer" user, after `bash /repo/install.sh`.
set -euo pipefail

REPO=/repo
COMPONENTS_DIR="$HOME/moonraker-env/lib/python3.11/site-packages/moonraker/components"
MOONRAKER_CONF="$HOME/printer_data/config/moonraker.conf"
NAVI_JSON="$HOME/printer_data/config/.theme/navi.json"

fail() { echo "[assert-install] FAIL: $1" >&2; exit 1; }
pass() { echo "[assert-install] ok: $1"; }

podman ps --format '{{.Names}}' | grep -qx orcaslicer-api \
    || fail "orcaslicer-api container is not running"
pass "container running"

systemctl --user is-enabled --quiet container-orcaslicer-api.service \
    || fail "systemd unit is not enabled"
pass "systemd unit enabled"

grep -q '^\[orcaslicer\]' "$MOONRAKER_CONF" || fail "moonraker.conf missing [orcaslicer]"
grep -q '^\[update_manager orcaslicer_plugin\]' "$MOONRAKER_CONF" \
    || fail "moonraker.conf missing [update_manager orcaslicer_plugin]"
pass "moonraker.conf sections present"

[[ -f "$NAVI_JSON" ]] || fail "navi.json not created"
python3 -c "
import json
navi = json.load(open('$NAVI_JSON'))
assert any(e.get('title') == 'Slicer' for e in navi), 'Slicer entry missing'
" || fail "navi.json missing Slicer entry"
pass "navi.json has Slicer entry"

[[ -L "$COMPONENTS_DIR/orcaslicer.py" ]] || fail "orcaslicer.py symlink missing"
[[ "$(readlink -f "$COMPONENTS_DIR/orcaslicer.py")" == "$REPO/src/orcaslicer.py" ]] \
    || fail "orcaslicer.py symlink points at the wrong file"
[[ -L "$COMPONENTS_DIR/slicer_ui.html" ]] || fail "slicer_ui.html symlink missing"
pass "component symlinks correct"

echo "[assert-install] all checks passed"
