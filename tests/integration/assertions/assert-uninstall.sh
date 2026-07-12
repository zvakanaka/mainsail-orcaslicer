#!/usr/bin/env bash
# Asserts uninstall.sh fully reversed the install.
# Run as the "printer" user, after uninstall.sh.
set -euo pipefail

COMPONENTS_DIR="$HOME/moonraker-env/lib/python3.11/site-packages/moonraker/components"
MOONRAKER_CONF="$HOME/printer_data/config/moonraker.conf"
NAVI_JSON="$HOME/printer_data/config/.theme/navi.json"

fail() { echo "[assert-uninstall] FAIL: $1" >&2; exit 1; }
pass() { echo "[assert-uninstall] ok: $1"; }

if podman ps -a --format '{{.Names}}' | grep -qx orcaslicer-api; then
    fail "orcaslicer-api container still exists"
fi
pass "container removed"

if systemctl --user list-unit-files container-orcaslicer-api.service &>/dev/null \
    && systemctl --user is-enabled --quiet container-orcaslicer-api.service 2>/dev/null; then
    fail "systemd unit still enabled"
fi
[[ ! -f "$HOME/.config/systemd/user/container-orcaslicer-api.service" ]] \
    || fail "systemd unit file still present"
pass "systemd unit removed"

! grep -q '^\[orcaslicer\]' "$MOONRAKER_CONF" || fail "moonraker.conf still has [orcaslicer]"
! grep -q '^\[update_manager orcaslicer_plugin\]' "$MOONRAKER_CONF" \
    || fail "moonraker.conf still has [update_manager orcaslicer_plugin]"
pass "moonraker.conf sections removed"

if [[ -f "$NAVI_JSON" ]]; then
    python3 -c "
import json
navi = json.load(open('$NAVI_JSON'))
assert not any(e.get('title') == 'Slicer' for e in navi), 'Slicer entry still present'
"
fi
pass "navi.json Slicer entry removed"

[[ ! -e "$COMPONENTS_DIR/orcaslicer.py" ]] || fail "orcaslicer.py symlink still present"
[[ ! -e "$COMPONENTS_DIR/slicer_ui.html" ]] || fail "slicer_ui.html symlink still present"
pass "component symlinks removed"

echo "[assert-uninstall] all checks passed"
