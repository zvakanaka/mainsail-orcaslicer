# OrcaSlicer Mainsail Plugin - Requirements Document

## Executive Summary

Integrate the existing orcaslicer-web Flask application into the Mainsail web interface running on a BIQU CB1 (aarch64, Debian 11). Rather than reimplementing slicing functionality, this project:

1. Runs orcaslicer-web as a Podman container on the printer mainboard (port 5000)
2. Adds a thin Moonraker component that proxies requests from Mainsail to orcaslicer-web
3. Adds a custom iframe page to Mainsail's `.theme` directory — **no Mainsail fork required**

A single `install.sh` script handles everything end-to-end. A novice user should be able to go from a fresh Mainsail install to slicing in one command.

---

## 1. Project Overview

### 1.1 Target Hardware & OS
- **Board:** BIQU CB1 (aarch64)
- **OS:** Debian 11 (Bullseye)
- **Existing stack:** Klipper + Moonraker + Mainsail (standard KIAUH install)
- **Container runtime:** Podman

### 1.2 Current State
- **orcaslicer-web** (`arm` branch) — standalone Flask app, not yet running
- Provides HTTP API for STL/3MF → GCODE conversion
- Uses OrcaSlicer aarch64 nightly Flatpak + Xvfb for headless operation
- Stores profiles (printer, process, filament) as JSON in `/data/profiles/`
- **Not modified** — used exactly as-is

### 1.3 Target State
- orcaslicer-web running as a Podman container, auto-started via systemd
- Moonraker component proxying its API under `/server/orcaslicer/...`
- Custom iframe page visible as a "Slicer" tab in Mainsail sidebar
- GCODE output automatically placed in `~/printer_data/gcodes/`

### 1.4 Architecture

```
[Browser / Mainsail UI]
        |
        | Mainsail sidebar → custom iframe page
        |   iframe src: http://<printer-ip>:7125/server/orcaslicer/ui
        v
[Moonraker  :7125]
        |
        | HTTP proxy to localhost:5000
        v
[orcaslicer-web Flask  :5000  (Podman container)]
        |
        | CLI subprocess
        v
[OrcaSlicer aarch64 binary + Xvfb]
```

### 1.5 Terminology
- **Moonraker Component** — `moonraker/components/orcaslicer.py`, proxies API and serves iframe
- **Mainsail Custom Page** — `.theme/navi.json` entry pointing to the Moonraker-served iframe
- **orcaslicer-web** — upstream Flask app; black box, never modified

---

## 2. Setting Up orcaslicer-web on the Klipper Host

The `install.sh` script handles this automatically. This section documents what it does.

> **Warning:** orcaslicer-web is in early stages. The upstream author has not verified generated GCODE for actual printing. Use with caution.

### 2.1 What the Script Does

1. Installs Podman if not present (`apt-get install -y podman`)
2. Clones `https://github.com/zvakanaka/orcaslicer-web` (`arm` branch) to `~/orcaslicer-web`
3. Builds the container image (`podman build -t orcaslicer-api .`)
   - The build downloads the OrcaSlicer aarch64 nightly Flatpak and extracts it via `ostree` inside the build stage — no host-level flatpak needed
   - Build takes several minutes on first run due to download size
4. Creates a host-path volume directory at `~/orcaslicer-profiles`
5. Starts the container:
   ```bash
   podman run -d \
     --name orcaslicer-api \
     -p 127.0.0.1:5000:5000 \
     -v ~/orcaslicer-profiles:/data \
     --restart unless-stopped \
     orcaslicer-api
   ```
   Note: bound to `127.0.0.1` only — not exposed on the network
6. Generates and installs a systemd user unit for auto-start:
   ```bash
   podman generate systemd --name orcaslicer-api --restart-policy=always \
     --files --new
   mkdir -p ~/.config/systemd/user
   mv container-orcaslicer-api.service ~/.config/systemd/user/
   systemctl --user enable --now container-orcaslicer-api.service
   loginctl enable-linger $USER
   ```

### 2.2 Profile Storage

Profiles persist on the host at `~/orcaslicer-profiles/profiles/{printer,process,filament}/`. This survives container rebuilds and updates.

### 2.3 Container Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ORCASLICER_BIN` | `/opt/orcaslicer/AppRun` | Path to OrcaSlicer binary inside container |
| `PROFILES_DIR` | `/data/profiles` | Profile storage root (mapped to host) |
| `TEMP_DIR` | `/tmp/slicing` | Temp dir for slice jobs |
| `FLASK_HOST` | `0.0.0.0` | Flask bind address inside container |
| `FLASK_PORT` | `5000` | Flask port |
| `DISPLAY` | `:99` | Xvfb virtual display |

---

## 3. Technical Architecture

### 3.1 Moonraker Component (`orcaslicer.py`)

**Location:** Auto-detected at install time. The script checks for `~/moonraker/moonraker/components/` (source install) and falls back to the path reported by `pip show moonraker` (virtualenv/pip install). The component file is symlinked so updates to the repo propagate automatically.

**Responsibilities:**
- Proxy all orcaslicer-web API endpoints under Moonraker's HTTP server
- After a successful slice, move the GCODE into `~/printer_data/gcodes/` via Moonraker's file manager (making it immediately visible in Mainsail's G-Code Files tab)
- Serve the custom slicer UI page at `GET /server/orcaslicer/ui` — a self-contained HTML/CSS/JS file that calls the Moonraker proxy endpoints directly; this is what the Mainsail custom nav entry points to
- Return HTTP 503 with a clear message if orcaslicer-web is unreachable
- Pass through HTTP 409 from orcaslicer-web when the slicer is already busy

**Configuration added to `moonraker.conf`:**
```ini
[orcaslicer]
# URL of the orcaslicer-web container (localhost only)
orcaslicer_url: http://localhost:5000
# Timeout for slice requests in seconds
request_timeout: 300
# Moonraker gcodes directory (default matches standard KIAUH install)
gcodes_path: ~/printer_data/gcodes
```

**API endpoint mapping:**

| Moonraker endpoint | Method | Proxied to orcaslicer-web | Notes |
|--------------------|--------|--------------------------|-------|
| `/server/orcaslicer/ui` | GET | — | Serves custom slicer UI page (HTML/CSS/JS) |
| `/server/orcaslicer/health` | GET | `GET /api/health` | Health check |
| `/server/orcaslicer/status` | GET | `GET /api/slice/status` | Busy / idle |
| `/server/orcaslicer/profiles/{type}` | GET | `GET /api/profiles/{type}` | List profiles |
| `/server/orcaslicer/profiles/{type}` | POST | `POST /api/profiles/{type}` | Upload profile JSON |
| `/server/orcaslicer/profiles/{type}/{name}` | GET | `GET /api/profiles/{type}/{name}` | Download profile |
| `/server/orcaslicer/profiles/{type}/{name}` | PUT | `PUT /api/profiles/{type}/{name}` | Replace profile |
| `/server/orcaslicer/profiles/{type}/{name}` | PATCH | `PATCH /api/profiles/{type}/{name}` | Rename profile |
| `/server/orcaslicer/profiles/{type}/{name}` | DELETE | `DELETE /api/profiles/{type}/{name}` | Delete profile |
| `/server/orcaslicer/slice` | POST | `POST /api/slice` | Slice; on success moves GCODE to gcodes dir |

`{type}` is one of: `printer`, `process`, `filament`

### 3.2 Mainsail Custom Navigation (No Fork Required)

Mainsail supports custom sidebar entries via a `navi.json` file placed in `~/printer_data/config/.theme/`. The sidebar entry links to the custom UI page served by the Moonraker component — no Mainsail fork, no build toolchain.

**`~/printer_data/config/.theme/navi.json`:**
```json
[
  {
    "title": "Slicer",
    "href": "/server/orcaslicer/ui",
    "target": "_self",
    "position": 45,
    "icon": "M12,2L2,22H22L12,2M12,5.8L18.4,20H5.6L12,5.8Z"
  }
]
```

### 3.3 Custom Slicer UI Page (`slicer_ui.html`)

**What it is:** A single self-contained HTML file (`src/slicer_ui.html`) served by the Moonraker component at `GET /server/orcaslicer/ui`. It communicates exclusively with the Moonraker proxy endpoints — it never contacts orcaslicer-web directly. No iframe of orcaslicer-web; no external dependencies; no build step.

**Why not embed orcaslicer-web's own UI:** orcaslicer-web's frontend is unstyled relative to Mainsail and would look visually out of place. The custom page provides a purpose-built workflow with consistent visual design.

#### Visual Design

- **Color scheme:** Dark background (`#1e1e1e`) with slightly lighter card surfaces (`#2a2a2a`), red primary accent (`#e53935`), light grey text (`#e0e0e0`), muted secondary text (`#9e9e9e`)
- **Typography:** System font stack (`-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif`), consistent with most browser UIs including Mainsail
- **Buttons:** Rounded (`border-radius: 4px`), red fill for primary actions (Slice, Upload), ghost/outline style for secondary actions (Delete, Rename), minimum 44px height for touch targets
- **Cards/panels:** Slightly elevated surface color with a subtle border (`1px solid #3a3a3a`), `border-radius: 8px`, comfortable padding
- **Layout:** Single-column on mobile, two-column (profiles sidebar + slice panel) on wider screens; CSS flexbox, no framework

#### Page Structure & Workflow

```
┌─────────────────────────────────────────┐
│  [OrcaSlicer icon]  Slicer              │  ← header bar (dark, red accent)
├─────────────────┬───────────────────────┤
│  PROFILES       │  SLICE                │
│  ┌───────────┐  │  Model file           │
│  │ Printer   │  │  [  Choose file... ]  │
│  │ Process   │  │                       │
│  │ Filament  │  │  Printer profile  ▼   │
│  └───────────┘  │  Process profile  ▼   │
│                 │  Filament profile ▼   │
│  [profile list] │                       │
│  + Upload       │  [ Slice ]            │
│                 │                       │
│                 │  ── Results ──        │
│                 │  output.gcode ✓       │
│                 │  Ready in G-Code Files│
└─────────────────┴───────────────────────┘
```

#### UI Components

**Profile Panel (left / top on mobile):**
- Three tabs: Printer | Process | Filament
- Per-tab: list of uploaded profiles (name + delete button)
- "Upload Profile" button opens a file picker (`.json` only)
- Upload posts to `POST /server/orcaslicer/profiles/{type}`
- Delete calls `DELETE /server/orcaslicer/profiles/{type}/{name}` with a confirmation prompt

**Slice Panel (right / below on mobile):**
- File picker for STL/3MF (drag-and-drop supported, touch-friendly)
- Three `<select>` dropdowns populated from the profile lists
- "Slice" button: disabled until file + all three profiles selected; red fill when active
- During slicing: button replaced with a pulsing status indicator + elapsed timer (polls `GET /server/orcaslicer/status` every 2s)
- On success: green confirmation card showing the output filename and "Find it in G-Code Files"
- On error: red error card with the message from Moonraker (e.g. "Slicer is busy", "orcaslicer-web unreachable")

#### No-iframe approach — CORS non-issue

Because the custom page is served by Moonraker itself (same origin as all its API calls), there are no cross-origin restrictions. The page calls `fetch('/server/orcaslicer/...')` with relative URLs — always same-origin.

---

## 4. Implementation Phases

### Phase 1: orcaslicer-web Container Setup
**Goal:** orcaslicer-web running and verified on the CB1

**Deliverables:**
- `install.sh` section: Podman install, git clone, `podman build`, `podman run`, systemd unit
- Verification step in script: polls `http://localhost:5000/api/health` with retries and prints pass/fail

**Success Criteria:**
- `curl http://localhost:5000/api/health` returns OK on the printer

### Phase 2: Moonraker Proxy Component
**Goal:** All API endpoints accessible through Moonraker

**Deliverables:**
- `moonraker/components/orcaslicer.py`
- `moonraker.conf` snippet
- `src/slicer_ui.html` — custom UI page served at `/server/orcaslicer/ui`
- Post-slice GCODE move to `~/printer_data/gcodes/`
- 503 and 409 error handling with user-readable messages returned as JSON

**Success Criteria:**
- `curl http://localhost:7125/server/orcaslicer/health` returns OK
- `POST /server/orcaslicer/slice` results in GCODE appearing in Mainsail's file list

### Phase 3: Mainsail Custom Navigation
**Goal:** "Slicer" tab visible in Mainsail sidebar, orcaslicer-web UI embedded

**Deliverables:**
- `install.sh` section: parses existing `navi.json` (if any) and appends the Slicer entry; writes new file if none exists
- Creates `.theme/` directory if it doesn't exist
- Uses Python/jq to merge JSON arrays so existing custom nav entries are preserved

**Success Criteria:**
- "Slicer" appears in Mainsail sidebar after page refresh
- Clicking it shows the orcaslicer-web UI embedded in Mainsail without opening a new tab
- No browser console CORS errors

### Phase 4: Full install.sh & User Guide
**Goal:** Single-command novice install with clear feedback

**`install.sh` full sequence:**
1. Check OS (warn if not Debian 11 on aarch64)
2. Install Podman if missing
3. Clone orcaslicer-web (`arm` branch)
4. Build container image (with progress output)
5. Create `~/orcaslicer-profiles` directory
6. Start container bound to `127.0.0.1:5000`
7. Install systemd user unit + enable linger
8. Poll health endpoint (up to 60s, with spinner)
9. Detect Moonraker components directory (source install or pip) and symlink `orcaslicer.py`
10. Patch `moonraker.conf` (add `[orcaslicer]` block if not present)
11. Parse existing `navi.json` (if any), append Slicer entry, write to `.theme/` directory
12. Restart Moonraker (`sudo systemctl restart moonraker`)
13. Poll `http://localhost:7125/server/orcaslicer/health` (up to 30s)
14. Print success message with printer IP and next steps

**Deliverables:**
- `install.sh` — idempotent (safe to re-run)
- `update_manager` block for Moonraker update system
- `USER_GUIDE.md` — covers full workflow (see §6)
- `TROUBLESHOOTING.md`

---

## 5. Installation Model

### One-Command Install
```bash
curl -fsSL https://raw.githubusercontent.com/zvakanaka/mainsail-orcaslicer/main/install.sh | bash
```
Or via SSH:
```bash
git clone https://github.com/zvakanaka/mainsail-orcaslicer.git ~/mainsail-orcaslicer
bash ~/mainsail-orcaslicer/install.sh
```

### Prerequisites (already present on standard KIAUH CB1 install)
- Debian 11, aarch64
- Klipper + Moonraker + Mainsail running
- Internet access (for Podman install and OrcaSlicer Flatpak download during build)
- ~3 GB free disk space (container image)

### What `install.sh` Installs / Modifies
| Item | Location | Notes |
|------|----------|-------|
| Podman | system | via `apt-get` if missing |
| orcaslicer-web source | `~/orcaslicer-web/` | git clone |
| orcaslicer-web container image | Podman local storage | built from source |
| Profile data | `~/orcaslicer-profiles/` | host-mounted volume |
| systemd unit | `~/.config/systemd/user/` | user-level service |
| Moonraker component | Auto-detected: `~/moonraker/moonraker/components/` (source) or pip package components dir | Symlinked from repo |
| moonraker.conf block | `~/printer_data/config/moonraker.conf` | appended if missing |
| Mainsail nav entry | `~/printer_data/config/.theme/navi.json` | Parsed and appended; existing entries preserved |

### Update Management
```ini
[update_manager orcaslicer_plugin]
type: git_repo
origin: https://github.com/zvakanaka/mainsail-orcaslicer.git
path: ~/mainsail-orcaslicer
primary_branch: main
managed_services: moonraker
install_script: install.sh
```

---

## 6. User Guide (content outline for `USER_GUIDE.md`)

### 6.1 Installation
- Run the install command over SSH
- Wait for the build to complete (~5–10 min first time)
- Open Mainsail in browser and look for "Slicer" in the sidebar

### 6.2 Exporting Profiles from OrcaSlicer (Desktop)
1. Open OrcaSlicer on your desktop/laptop
2. Configure your printer, process (print settings), and filament as desired
3. Export each profile:
   - **Printer:** `Printer` menu → `Export Printer Presets`
   - **Process:** `Process` menu → `Export Preset`
   - **Filament:** `Filament` menu → `Export Preset`
4. Each export produces a `.json` file

### 6.3 Uploading Profiles
1. Open Mainsail → click "Slicer" in the sidebar
2. In the orcaslicer-web UI, click the profile type tab (Printer / Process / Filament)
3. Upload the corresponding `.json` file exported from OrcaSlicer

### 6.4 Slicing a Model
1. In the Slicer tab, upload your STL or 3MF file
2. Select the Printer, Process, and Filament profiles
3. Click "Slice"
4. When complete, the GCODE appears automatically in Mainsail's G-Code Files tab
5. Print as normal from the G-Code Files tab

### 6.5 Troubleshooting (outline for `TROUBLESHOOTING.md`)
- **"Slicer" tab not appearing** — Check `.theme/navi.json` exists; hard-refresh browser (Ctrl+Shift+R)
- **Blank iframe / connection refused** — Check orcaslicer-web container: `podman ps`, `systemctl --user status container-orcaslicer-api`
- **Slice fails** — Check container logs: `podman logs orcaslicer-api`
- **GCODE not in file list** — Check Moonraker logs: `sudo journalctl -u moonraker -n 50`
- **Build fails during install** — Ensure internet access; check disk space (`df -h`)

---

## 7. Key Decisions & Rationale

| Decision | Rationale |
|----------|-----------|
| No Mainsail fork — use custom nav + Moonraker-served custom page | Novice-friendly: works with stock Mainsail; no build toolchain needed |
| Custom HTML/CSS/JS page instead of embedding orcaslicer-web's UI | orcaslicer-web's frontend is visually inconsistent with Mainsail; custom page provides a purpose-built, on-theme workflow |
| Custom page served by Moonraker (same origin as all API calls) | No cross-origin issues; `fetch()` uses relative URLs; no CORS config needed anywhere |
| No external JS/CSS framework in the custom page | Ships as a single `.html` file; no build step; no CDN dependency on the printer |
| Bind orcaslicer-web to `127.0.0.1:5000` only | Security: not exposed on the network; Moonraker is the only entry point |
| Use Podman (not Docker) | Confirmed runtime; rootless containers work better on CB1 Debian 11 |
| Move GCODE to `~/printer_data/gcodes/` in Moonraker component | File appears in Mainsail immediately; no extra user steps |
| `install.sh` also sets up orcaslicer-web | Single command for novice users; no manual prereqs |
| Systemd user unit + `loginctl enable-linger` | Container auto-starts without root; survives reboots |
| Host-path volume at `~/orcaslicer-profiles/` | Profiles survive container rebuilds; easy to back up |

---

## 8. Technology Stack

- **Backend:** Python 3.8+, Moonraker component framework, `aiohttp` for async proxy
- **Frontend:** Mainsail custom navigation (`navi.json`) + single self-contained `slicer_ui.html` served by Moonraker; plain HTML/CSS/JS, no framework, no build step
- **Container runtime:** Podman (rootless, user-level systemd)
- **Slicer runtime:** orcaslicer-web `arm` branch, OrcaSlicer aarch64 nightly Flatpak inside container
- **Target hardware:** BIQU CB1, aarch64, Debian 11
- **Development machine:** Laptop (x86_64); deploy target is printer mainboard (aarch64)

---

## 9. Success Criteria

### Must-Have (MVP):
- Single `install.sh` takes a fresh CB1 Mainsail install to working slicer
- "Slicer" tab appears in Mainsail sidebar with no manual browser config
- User can upload profiles, slice a model, and find GCODE in G-Code Files — all without leaving Mainsail
- No cross-origin errors in browser console
- Container auto-starts after reboot

### Should-Have:
- Install script is idempotent (safe to re-run)
- Clear error messages if orcaslicer-web is down
- Moonraker update_manager entry for future updates

### Nice-to-Have:
- WebSocket progress updates during slicing
- GCODE preview
- Fluidd support

