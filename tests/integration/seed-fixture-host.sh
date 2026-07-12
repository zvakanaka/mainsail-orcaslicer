#!/usr/bin/env bash
# Seeds a minimal fake Klipper/Moonraker host so install.sh's detection and
# service-restart logic has something real to act on, without needing an
# actual Klipper/Moonraker install. Run as the "printer" user inside the
# testhost container (has passwordless sudo).
set -euo pipefail

echo "[seed] Creating fake printer_data/config..."
mkdir -p "$HOME/printer_data/config"
cat > "$HOME/printer_data/config/moonraker.conf" << 'EOF'
[server]
host: 0.0.0.0
port: 7125
EOF

echo "[seed] Creating fake moonraker components dir..."
mkdir -p "$HOME/moonraker-env/lib/python3.11/site-packages/moonraker/components"

echo "[seed] Registering a stub moonraker.service..."
sudo tee /etc/systemd/system/moonraker.service > /dev/null << 'EOF'
[Unit]
Description=Stub Moonraker for integration testing

[Service]
ExecStart=/bin/sleep infinity
Restart=always

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now moonraker

echo "[seed] Fixture host ready."
