# OrcaSlicer Klipper Module

Slice STL and 3MF files directly from Mainsail — no desktop slicer needed.

This project integrates [orcaslicer-web](https://github.com/zvakanaka/orcaslicer-web) into the Mainsail web interface via a Moonraker component. A "Slicer" tab appears in the Mainsail sidebar where you can upload profiles, drop in a model, and slice. The resulting GCODE lands in your G-Code Files list automatically.

> [!WARNING]
> This project is in early stages and has NOT been fully tested

## Architecture

```
Browser (Mainsail)
    |
    |  "Slicer" tab in sidebar
    v
Moonraker  :7125
    |  /server/orcaslicer/* proxy
    v
orcaslicer-web  :5000  (Podman container, localhost only)
    |
    v
OrcaSlicer aarch64 CLI + Xvfb
```

- **No Mainsail fork** — uses Mainsail's custom navigation (`.theme/navi.json`)
- **No CORS issues** — the slicer UI is served by Moonraker itself (same origin)
- **No external dependencies** — the UI is a single self-contained HTML file

## Requirements

- BIQU CB1 or similar aarch64 board running Debian 11
- Klipper + Moonraker + Mainsail (standard KIAUH install)
- Internet access (for initial container build)
- ~3 GB free disk space

## Installation

SSH into your printer and run:

```bash
git clone https://github.com/zvakanaka/orcaslicer-klipper-module.git ~/orcaslicer-klipper-module
bash ~/orcaslicer-klipper-module/install.sh
```

The installer handles everything:

1. Installs Podman (if missing)
2. Clones and builds the orcaslicer-web container
3. Starts the container on `127.0.0.1:5000` with a systemd user service
4. Symlinks the Moonraker component into place
5. Adds the `[orcaslicer]` section to `moonraker.conf`
6. Adds the "Slicer" entry to Mainsail's sidebar navigation
7. Restarts Moonraker and verifies everything is working

The script is idempotent — safe to re-run.

First run takes several minutes due to the container build (downloads OrcaSlicer aarch64 nightly).

## Usage

### 1. Export profiles from OrcaSlicer desktop

On your laptop/desktop, open OrcaSlicer and export your configured profiles:

- **Printer:** Printer menu > Export Printer Presets
- **Process:** Process menu > Export Preset
- **Filament:** Filament menu > Export Preset

Each produces a `.json` file.

### 2. Upload profiles

Open Mainsail and click **Slicer** in the sidebar. Use the profile tabs (Printer / Process / Filament) to upload each `.json` file.

### 3. Slice

1. Drop an STL or 3MF file onto the upload area
2. Select your printer, process, and filament profiles from the dropdowns
3. Click **Slice**
4. When complete, the GCODE appears in Mainsail's **G-Code Files** tab
5. Print as normal

## What gets installed

| Item | Location |
|------|----------|
| Podman | System package |
| orcaslicer-web source | `~/orcaslicer-web/` |
| Container image | Podman local storage |
| Profile data | `~/orcaslicer-profiles/` |
| Systemd user service | `~/.config/systemd/user/` |
| Moonraker component | Symlinked into Moonraker's components dir |
| moonraker.conf section | `~/printer_data/config/moonraker.conf` |
| Mainsail nav entry | `~/printer_data/config/.theme/navi.json` |

## Configuration

The `[orcaslicer]` section in `moonraker.conf`:

```ini
[orcaslicer]
orcaslicer_url: http://localhost:5000
request_timeout: 300
gcodes_path: ~/printer_data/gcodes
```

## Updates

An `[update_manager]` entry is added automatically. Updates appear in Mainsail's Update Manager alongside Klipper and Moonraker.

## Troubleshooting

**"Slicer" tab not appearing**
- Check that `~/printer_data/config/.theme/navi.json` exists
- Hard-refresh the browser (Ctrl+Shift+R)

**Slicer page shows "Offline"**
- Check the container: `podman ps` and `podman logs orcaslicer-api`
- Check the service: `systemctl --user status container-orcaslicer-api`

**Slice fails**
- Check container logs: `podman logs orcaslicer-api`
- Ensure profiles are compatible (same OrcaSlicer version)

**GCODE not appearing in file list**
- Check Moonraker logs: `sudo journalctl -u moonraker -n 50`
- Verify gcodes path: `ls ~/printer_data/gcodes/`

**Container build fails**
- Ensure internet access
- Check disk space: `df -h`
