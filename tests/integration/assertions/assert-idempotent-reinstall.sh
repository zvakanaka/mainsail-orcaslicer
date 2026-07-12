#!/usr/bin/env bash
# Asserts a second install.sh run didn't duplicate anything.
# Run as the "printer" user, after install.sh has been run twice.
set -euo pipefail

MOONRAKER_CONF="$HOME/printer_data/config/moonraker.conf"
NAVI_JSON="$HOME/printer_data/config/.theme/navi.json"

fail() { echo "[assert-idempotent-reinstall] FAIL: $1" >&2; exit 1; }
pass() { echo "[assert-idempotent-reinstall] ok: $1"; }

count=$(grep -c '^\[orcaslicer\]' "$MOONRAKER_CONF")
[[ "$count" -eq 1 ]] || fail "[orcaslicer] section appears $count times"
pass "[orcaslicer] section not duplicated"

count=$(grep -c '^\[update_manager orcaslicer_plugin\]' "$MOONRAKER_CONF")
[[ "$count" -eq 1 ]] || fail "[update_manager orcaslicer_plugin] section appears $count times"
pass "[update_manager orcaslicer_plugin] section not duplicated"

slicer_count=$(python3 -c "
import json
navi = json.load(open('$NAVI_JSON'))
print(sum(1 for e in navi if e.get('title') == 'Slicer'))
")
[[ "$slicer_count" -eq 1 ]] || fail "navi.json has $slicer_count Slicer entries"
pass "navi.json Slicer entry not duplicated"

echo "[assert-idempotent-reinstall] all checks passed"
