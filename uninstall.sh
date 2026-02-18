#!/usr/bin/env bash
# uninstall.sh — Removes the OrcaSlicer Mainsail plugin
#
# Reverses everything install.sh sets up:
#   1. Stops and removes the container + systemd service
#   2. Removes Moonraker component symlinks
#   3. Removes moonraker.conf sections ([orcaslicer] + [update_manager])
#   4. Removes Mainsail custom nav entry
#   5. Optionally removes orcaslicer-web clone and profile data
#
# Usage:
#   bash uninstall.sh
#
set -euo pipefail

# ── Paths & constants ──────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ORCAWEB_DIR="$HOME/orcaslicer-web"
PROFILES_DIR="$HOME/orcaslicer-profiles"
CONTAINER_NAME="orcaslicer-api"
CONTAINER_IMAGE="orcaslicer-api"

MOONRAKER_CONF="$HOME/printer_data/config/moonraker.conf"
THEME_DIR="$HOME/printer_data/config/.theme"
NAVI_JSON="$THEME_DIR/navi.json"

SYSTEMD_UNIT="container-${CONTAINER_NAME}.service"
SYSTEMD_DIR="$HOME/.config/systemd/user"

# ── Colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERR ]${NC}  $*" >&2; }

# ── Confirmation ───────────────────────────────────────────────────────────
echo
echo -e "${YELLOW}This will remove the OrcaSlicer Mainsail plugin.${NC}"
echo
echo "  The following will be removed:"
echo "    - Systemd service ($SYSTEMD_UNIT)"
echo "    - Podman container and image ($CONTAINER_NAME)"
echo "    - Moonraker component symlinks"
echo "    - moonraker.conf [orcaslicer] and [update_manager] sections"
echo "    - Mainsail Slicer nav entry"
echo
read -rp "Continue? [y/N] " CONFIRM
if [[ "${CONFIRM,,}" != "y" ]]; then
    echo "Aborted."
    exit 0
fi

# ── Phase 1: Stop and remove systemd service ─────────────────────────────
info "Stopping systemd service..."
if systemctl --user is-active --quiet "$SYSTEMD_UNIT" 2>/dev/null; then
    systemctl --user stop "$SYSTEMD_UNIT"
    ok "Service stopped"
else
    ok "Service already stopped"
fi

if systemctl --user is-enabled --quiet "$SYSTEMD_UNIT" 2>/dev/null; then
    systemctl --user disable "$SYSTEMD_UNIT"
    ok "Service disabled"
fi

if [[ -f "$SYSTEMD_DIR/$SYSTEMD_UNIT" ]]; then
    rm "$SYSTEMD_DIR/$SYSTEMD_UNIT"
    systemctl --user daemon-reload
    ok "Service unit removed"
else
    ok "Service unit already absent"
fi

# ── Phase 2: Remove Podman container and image ───────────────────────────
info "Removing Podman container and image..."
podman stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
podman rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
podman rmi "$CONTAINER_IMAGE" >/dev/null 2>&1 || true
podman system prune -f >/dev/null 2>&1 || true
ok "Container and image removed"

# ── Phase 3: Remove Moonraker component symlinks ─────────────────────────
info "Removing Moonraker component symlinks..."
REMOVED_SYMLINKS=false

# Search the same locations the installer checks
for candidate in \
    "$HOME/moonraker/moonraker/components" \
    "$HOME/moonraker-env/lib/python*/site-packages/moonraker/components" \
    ; do
    for expanded in $candidate; do
        if [[ -d "$expanded" ]]; then
            for file in orcaslicer.py slicer_ui.html; do
                target="$expanded/$file"
                if [[ -L "$target" ]]; then
                    rm "$target"
                    REMOVED_SYMLINKS=true
                    ok "Removed symlink: $target"
                fi
            done
        fi
    done
done

# Also check via pip
if ! $REMOVED_SYMLINKS; then
    for pip_bin in \
        "$HOME/moonraker-env/bin/pip" \
        "$HOME/moonraker-env/bin/pip3" \
        ; do
        if [[ -x "$pip_bin" ]]; then
            PKG_DIR="$("$pip_bin" show moonraker 2>/dev/null | \
                       grep -i '^Location:' | awk '{print $2}')" || true
            if [[ -n "${PKG_DIR:-}" && -d "$PKG_DIR/moonraker/components" ]]; then
                for file in orcaslicer.py slicer_ui.html; do
                    target="$PKG_DIR/moonraker/components/$file"
                    if [[ -L "$target" ]]; then
                        rm "$target"
                        ok "Removed symlink: $target"
                    fi
                done
                break
            fi
        fi
    done
fi

ok "Component symlinks cleaned up"

# ── Phase 4: Remove moonraker.conf sections ──────────────────────────────
if [[ -f "$MOONRAKER_CONF" ]]; then
    info "Cleaning moonraker.conf..."
    CONF_CHANGED=false

    # Remove [orcaslicer] section (header through next section or EOF)
    if grep -q '^\[orcaslicer\]' "$MOONRAKER_CONF" 2>/dev/null; then
        python3 -c "
import re, sys
with open('$MOONRAKER_CONF') as f:
    text = f.read()
# Remove the [orcaslicer] section (up to the next [section] or EOF)
text = re.sub(r'\n*\[orcaslicer\][^\[]*', '', text)
with open('$MOONRAKER_CONF', 'w') as f:
    f.write(text.strip() + '\n')
"
        CONF_CHANGED=true
        ok "Removed [orcaslicer] section"
    fi

    # Remove [update_manager orcaslicer_plugin] section
    if grep -q '^\[update_manager orcaslicer_plugin\]' "$MOONRAKER_CONF" 2>/dev/null; then
        python3 -c "
import re, sys
with open('$MOONRAKER_CONF') as f:
    text = f.read()
text = re.sub(r'\n*\[update_manager orcaslicer_plugin\][^\[]*', '', text)
with open('$MOONRAKER_CONF', 'w') as f:
    f.write(text.strip() + '\n')
"
        CONF_CHANGED=true
        ok "Removed [update_manager orcaslicer_plugin] section"
    fi

    if ! $CONF_CHANGED; then
        ok "moonraker.conf already clean"
    fi
else
    warn "moonraker.conf not found at $MOONRAKER_CONF, skipping"
fi

# ── Phase 5: Remove Mainsail Slicer nav entry ────────────────────────────
if [[ -f "$NAVI_JSON" ]]; then
    info "Removing Slicer entry from navi.json..."
    if python3 -c "
import json, sys
with open('$NAVI_JSON') as f:
    navi = json.load(f)
filtered = [e for e in navi if e.get('title') != 'Slicer']
if len(filtered) == len(navi):
    sys.exit(0)  # nothing to remove
if filtered:
    with open('$NAVI_JSON', 'w') as f:
        json.dump(filtered, f, indent=2)
        f.write('\n')
else:
    # No entries left, remove the file
    import os
    os.remove('$NAVI_JSON')
sys.exit(0)
" 2>/dev/null; then
        ok "Slicer nav entry removed"
    else
        warn "Could not parse navi.json, leaving it as-is"
    fi
else
    ok "navi.json not present, nothing to remove"
fi

# ── Phase 6: Restart Moonraker ───────────────────────────────────────────
if systemctl is-active --quiet moonraker 2>/dev/null; then
    info "Restarting Moonraker..."
    sudo systemctl restart moonraker
    ok "Moonraker restarted"
fi

# ── Phase 7: Optional cleanup ────────────────────────────────────────────
echo
echo -e "${YELLOW}Optional cleanup:${NC}"
echo

# orcaslicer-web clone
if [[ -d "$ORCAWEB_DIR" ]]; then
    read -rp "  Remove orcaslicer-web clone ($ORCAWEB_DIR)? [y/N] " RM_WEB
    if [[ "${RM_WEB,,}" == "y" ]]; then
        rm -rf "$ORCAWEB_DIR"
        ok "Removed $ORCAWEB_DIR"
    else
        info "Kept $ORCAWEB_DIR"
    fi
fi

# Profile data
if [[ -d "$PROFILES_DIR" ]]; then
    read -rp "  Remove slicer profiles ($PROFILES_DIR)? [y/N] " RM_PROFILES
    if [[ "${RM_PROFILES,,}" == "y" ]]; then
        rm -rf "$PROFILES_DIR"
        ok "Removed $PROFILES_DIR"
    else
        info "Kept $PROFILES_DIR"
    fi
fi

# Build log
if [[ -f "/tmp/orcaslicer-build.log" ]]; then
    rm -f "/tmp/orcaslicer-build.log"
    ok "Removed build log"
fi

# ── Done ──────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  OrcaSlicer plugin has been uninstalled.${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo
echo -e "  System packages (podman, uidmap, slirp4netns) were ${YELLOW}not${NC} removed."
echo -e "  Remove them manually if no longer needed:"
echo -e "    ${CYAN}sudo apt-get remove podman uidmap slirp4netns${NC}"
echo
