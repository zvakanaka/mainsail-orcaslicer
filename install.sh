#!/usr/bin/env bash
# install.sh — One-command installer for the OrcaSlicer Mainsail plugin
#
# Installs:
#   1. Podman + orcaslicer-web container (port 127.0.0.1:5000)
#   2. Moonraker component (orcaslicer.py + slicer_ui.html)
#   3. Mainsail custom nav entry ("Slicer" tab)
#
# Safe to re-run (idempotent).
#
# Usage:
#   bash install.sh
#
set -euo pipefail

# ── Paths & constants ──────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ORCAWEB_DIR="$HOME/orcaslicer-web"
ORCAWEB_REPO="https://github.com/zvakanaka/orcaslicer-web.git"
ORCAWEB_BRANCH="arm"
PROFILES_DIR="$HOME/orcaslicer-profiles"
CONTAINER_NAME="orcaslicer-api"
CONTAINER_IMAGE="orcaslicer-api"
CONTAINER_PORT="127.0.0.1:5000:5000"

MOONRAKER_CONF="$HOME/printer_data/config/moonraker.conf"
THEME_DIR="$HOME/printer_data/config/.theme"
NAVI_JSON="$THEME_DIR/navi.json"

# Service name for the generated systemd unit
SYSTEMD_UNIT="container-${CONTAINER_NAME}.service"
SYSTEMD_DIR="$HOME/.config/systemd/user"

# ── Colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERR ]${NC}  $*" >&2; }
die()   { err "$@"; exit 1; }

# ── Pre-flight checks ─────────────────────────────────────────────────────
info "Running pre-flight checks..."

ARCH="$(uname -m)"
if [[ "$ARCH" != "aarch64" ]]; then
    warn "Expected aarch64 architecture, found $ARCH. Proceeding anyway."
fi

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" != "debian" ]] || [[ "${VERSION_ID:-}" != "11" ]]; then
        warn "Expected Debian 11, found ${PRETTY_NAME:-unknown}. Proceeding anyway."
    fi
fi

if ! systemctl is-active --quiet moonraker 2>/dev/null; then
    warn "Moonraker service not detected. Install may not be complete."
fi

# ── Phase 1: Podman ───────────────────────────────────────────────────────
info "Checking Podman..."
if command -v podman &>/dev/null; then
    ok "Podman already installed ($(podman --version))"
else
    info "Installing Podman..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq podman
    ok "Podman installed"
fi

# ── Phase 2: Clone orcaslicer-web ─────────────────────────────────────────
info "Checking orcaslicer-web source..."
if [[ -d "$ORCAWEB_DIR/.git" ]]; then
    info "Updating existing clone..."
    git -C "$ORCAWEB_DIR" fetch origin "$ORCAWEB_BRANCH" --quiet
    git -C "$ORCAWEB_DIR" checkout "$ORCAWEB_BRANCH" --quiet
    git -C "$ORCAWEB_DIR" pull --quiet
    ok "orcaslicer-web updated"
else
    info "Cloning orcaslicer-web ($ORCAWEB_BRANCH branch)..."
    git clone --branch "$ORCAWEB_BRANCH" --single-branch \
        "$ORCAWEB_REPO" "$ORCAWEB_DIR"
    ok "orcaslicer-web cloned to $ORCAWEB_DIR"
fi

# ── Phase 3: Build container image ────────────────────────────────────────
info "Building container image (this may take several minutes on first run)..."
podman build -t "$CONTAINER_IMAGE" "$ORCAWEB_DIR"
ok "Container image built"

# ── Phase 4: Create profile volume directory ──────────────────────────────
mkdir -p "$PROFILES_DIR"
ok "Profile directory ready at $PROFILES_DIR"

# ── Phase 5: Start container ──────────────────────────────────────────────
info "Starting container..."
# Stop and remove existing container if present (idempotent)
podman stop "$CONTAINER_NAME" 2>/dev/null || true
podman rm "$CONTAINER_NAME" 2>/dev/null || true

podman run -d \
    --name "$CONTAINER_NAME" \
    -p "$CONTAINER_PORT" \
    -v "$PROFILES_DIR:/data" \
    --restart unless-stopped \
    "$CONTAINER_IMAGE"
ok "Container started on $CONTAINER_PORT"

# ── Phase 6: Systemd user unit ────────────────────────────────────────────
info "Setting up systemd user service..."
mkdir -p "$SYSTEMD_DIR"

# Generate the unit file
pushd "$SYSTEMD_DIR" >/dev/null
podman generate systemd --name "$CONTAINER_NAME" \
    --restart-policy=always --files --new >/dev/null
popd >/dev/null

systemctl --user daemon-reload
systemctl --user enable --now "$SYSTEMD_UNIT"

# Enable linger so user services start without login
loginctl enable-linger "$USER"
ok "Systemd service enabled ($SYSTEMD_UNIT)"

# ── Phase 7: Wait for orcaslicer-web health ───────────────────────────────
info "Waiting for orcaslicer-web to become healthy..."
HEALTH_OK=false
for i in $(seq 1 60); do
    if curl -sf http://localhost:5000/api/health >/dev/null 2>&1; then
        HEALTH_OK=true
        break
    fi
    sleep 1
    printf "."
done
echo

if $HEALTH_OK; then
    ok "orcaslicer-web is healthy"
else
    warn "orcaslicer-web did not respond within 60s."
    warn "Check: podman logs $CONTAINER_NAME"
    warn "Continuing with Moonraker setup anyway..."
fi

# ── Phase 8: Detect Moonraker components directory ────────────────────────
info "Detecting Moonraker components directory..."
MOONRAKER_COMPONENTS=""

# Check standard source install locations
for candidate in \
    "$HOME/moonraker/moonraker/components" \
    "$HOME/moonraker-env/lib/python*/site-packages/moonraker/components" \
    ; do
    # Use glob expansion for wildcard paths
    for expanded in $candidate; do
        if [[ -d "$expanded" ]]; then
            MOONRAKER_COMPONENTS="$expanded"
            break 2
        fi
    done
done

# Fall back to pip show
if [[ -z "$MOONRAKER_COMPONENTS" ]]; then
    # Try to find moonraker package via pip in the moonraker venv
    for pip_bin in \
        "$HOME/moonraker-env/bin/pip" \
        "$HOME/moonraker-env/bin/pip3" \
        ; do
        if [[ -x "$pip_bin" ]]; then
            PKG_DIR="$("$pip_bin" show moonraker 2>/dev/null | \
                       grep -i '^Location:' | awk '{print $2}')"
            if [[ -n "$PKG_DIR" && -d "$PKG_DIR/moonraker/components" ]]; then
                MOONRAKER_COMPONENTS="$PKG_DIR/moonraker/components"
                break
            fi
        fi
    done
fi

if [[ -z "$MOONRAKER_COMPONENTS" ]]; then
    die "Cannot find Moonraker components directory. Is Moonraker installed?"
fi
ok "Moonraker components at: $MOONRAKER_COMPONENTS"

# ── Phase 9: Install Moonraker component ──────────────────────────────────
info "Installing Moonraker component..."
COMPONENT_SRC="$REPO_DIR/src/orcaslicer.py"
UI_SRC="$REPO_DIR/src/slicer_ui.html"
COMPONENT_DST="$MOONRAKER_COMPONENTS/orcaslicer.py"
UI_DST="$MOONRAKER_COMPONENTS/slicer_ui.html"

# Symlink component (allows updates via git pull)
ln -sf "$COMPONENT_SRC" "$COMPONENT_DST"
ln -sf "$UI_SRC" "$UI_DST"
ok "Component symlinked: $COMPONENT_DST -> $COMPONENT_SRC"

# ── Phase 10: Patch moonraker.conf ────────────────────────────────────────
info "Checking moonraker.conf..."
if [[ ! -f "$MOONRAKER_CONF" ]]; then
    die "moonraker.conf not found at $MOONRAKER_CONF"
fi

if grep -q '^\[orcaslicer\]' "$MOONRAKER_CONF" 2>/dev/null; then
    ok "moonraker.conf already has [orcaslicer] section"
else
    info "Adding [orcaslicer] section to moonraker.conf..."
    cat >> "$MOONRAKER_CONF" << 'EOF'

[orcaslicer]
# URL of the orcaslicer-web container (localhost only)
orcaslicer_url: http://localhost:5000
# Timeout for slice requests in seconds
request_timeout: 300
# Moonraker gcodes directory (default matches standard KIAUH install)
gcodes_path: ~/printer_data/gcodes
EOF
    ok "moonraker.conf updated"
fi

# ── Phase 11: Mainsail custom navigation ──────────────────────────────────
info "Setting up Mainsail custom navigation..."
mkdir -p "$THEME_DIR"

SLICER_ENTRY='{
    "title": "Slicer",
    "href": "/server/orcaslicer/ui",
    "target": "_self",
    "position": 45,
    "icon": "M12,2L2,22H22L12,2M12,5.8L18.4,20H5.6L12,5.8Z"
  }'

if [[ -f "$NAVI_JSON" ]]; then
    # Parse existing navi.json and append Slicer entry if not already present
    if python3 -c "
import json, sys
with open('$NAVI_JSON') as f:
    navi = json.load(f)
# Check if Slicer entry already exists
for entry in navi:
    if entry.get('title') == 'Slicer':
        sys.exit(0)
# Append new entry
navi.append(json.loads('''$SLICER_ENTRY'''))
with open('$NAVI_JSON', 'w') as f:
    json.dump(navi, f, indent=2)
    f.write('\n')
sys.exit(0)
" 2>/dev/null; then
        ok "navi.json updated (existing entries preserved)"
    else
        warn "Could not parse existing navi.json, backing up and recreating"
        cp "$NAVI_JSON" "$NAVI_JSON.bak"
        echo "[$SLICER_ENTRY]" | python3 -m json.tool > "$NAVI_JSON"
        ok "navi.json recreated (backup at navi.json.bak)"
    fi
else
    echo "[$SLICER_ENTRY]" | python3 -m json.tool > "$NAVI_JSON"
    ok "navi.json created"
fi

# ── Phase 12: Add update_manager entry ────────────────────────────────────
if grep -q '^\[update_manager orcaslicer_plugin\]' "$MOONRAKER_CONF" 2>/dev/null; then
    ok "update_manager entry already exists"
else
    info "Adding update_manager entry..."
    cat >> "$MOONRAKER_CONF" << EOF

[update_manager orcaslicer_plugin]
type: git_repo
origin: https://github.com/zvakanaka/orcaslicer-klipper-module.git
path: $REPO_DIR
primary_branch: main
managed_services: moonraker
install_script: install.sh
EOF
    ok "update_manager entry added"
fi

# ── Phase 13: Restart Moonraker ──────────────────────────────────────────
info "Restarting Moonraker..."
sudo systemctl restart moonraker
ok "Moonraker restarted"

# ── Phase 14: Verify Moonraker endpoint ───────────────────────────────────
info "Waiting for Moonraker orcaslicer endpoint..."
MR_OK=false
for i in $(seq 1 30); do
    if curl -sf http://localhost:7125/server/orcaslicer/health >/dev/null 2>&1; then
        MR_OK=true
        break
    fi
    sleep 1
    printf "."
done
echo

if $MR_OK; then
    ok "Moonraker orcaslicer endpoint is live"
else
    warn "Moonraker endpoint did not respond within 30s."
    warn "Check: sudo journalctl -u moonraker -n 50"
fi

# ── Done ──────────────────────────────────────────────────────────────────
PRINTER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Installation complete!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo
echo -e "  Open Mainsail in your browser:"
echo -e "    ${CYAN}http://${PRINTER_IP:-<printer-ip>}${NC}"
echo
echo -e "  Look for the ${YELLOW}Slicer${NC} tab in the sidebar."
echo
echo -e "  Next steps:"
echo -e "    1. Export profiles from OrcaSlicer desktop"
echo -e "    2. Upload them in the Slicer tab"
echo -e "    3. Upload an STL/3MF and click Slice"
echo
echo -e "  Troubleshooting:"
echo -e "    Container logs:  podman logs $CONTAINER_NAME"
echo -e "    Moonraker logs:  sudo journalctl -u moonraker -n 50"
echo -e "    Container status: podman ps"
echo
