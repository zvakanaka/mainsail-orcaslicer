#!/usr/bin/env bash
# Orchestrates the full install -> assert -> reinstall -> assert -> uninstall
# -> assert cycle against a real (nested) podman + systemd fixture host.
# Run as the "printer" user inside the testhost container, e.g.:
#
#   podman run --privileged --systemd=always -v $(pwd):/repo:Z \
#       testhost su - printer -c /repo/tests/integration/run-integration.sh
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO=/repo

dump_diagnostics() {
    echo "──── DIAGNOSTICS ────────────────────────────────────────"
    echo "-- podman ps -a --"
    podman ps -a 2>&1
    echo "-- podman logs orcaslicer-api --"
    podman logs orcaslicer-api 2>&1 | tail -50
    echo "-- systemctl --user status container-orcaslicer-api --"
    systemctl --user status container-orcaslicer-api 2>&1
    echo "-- /tmp/orcaslicer-build.log (tail) --"
    tail -50 /tmp/orcaslicer-build.log 2>&1
    echo "────────────────────────────────────────────────────────"
}

run_step() {
    local desc="$1"; shift
    echo "──── $desc ────"
    if ! "$@"; then
        echo "[run-integration] FAILED: $desc" >&2
        dump_diagnostics
        exit 1
    fi
}

run_step "Seed fixture host" bash "$SCRIPT_DIR/seed-fixture-host.sh"
run_step "install.sh (first run)" bash "$REPO/install.sh"
run_step "Assert install state" bash "$SCRIPT_DIR/assertions/assert-install.sh"
run_step "install.sh (second run, idempotency)" bash "$REPO/install.sh"
run_step "Assert idempotent reinstall" bash "$SCRIPT_DIR/assertions/assert-idempotent-reinstall.sh"
run_step "uninstall.sh" bash -c "printf 'y\ny\ny\n' | bash '$REPO/uninstall.sh'"
run_step "Assert uninstall state" bash "$SCRIPT_DIR/assertions/assert-uninstall.sh"

echo "──── ALL INTEGRATION CHECKS PASSED ────"
