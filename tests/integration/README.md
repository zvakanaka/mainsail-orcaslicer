# Layer 2 — podman/systemd integration tests

Runs `install.sh` and `uninstall.sh` for real (no mocks) against a disposable
"fake Klipper host": a container with genuine systemd as PID 1 and nested
rootless Podman, so `systemctl --user`, `loginctl enable-linger`, and the
real `orcaslicer-web` container build/run all execute against the genuine
thing instead of a stand-in.

## Layout

- `Containerfile.testhost` — systemd-enabled Debian bookworm image with
  nested podman, uidmap/slirp4netns/fuse-overlayfs, and a non-root `printer`
  user with passwordless sudo (mirrors a real KIAUH install).
- `seed-fixture-host.sh` — creates a fake `~/printer_data/config/moonraker.conf`,
  a fake `moonraker/components` directory, and a stub system-level
  `moonraker.service` (just `sleep infinity`), so install.sh's detection and
  restart logic has something real to act on without a full Moonraker.
- `run-integration.sh` — orchestrator: seed → install → assert → reinstall →
  assert (idempotency) → uninstall → assert. Dumps `podman logs`,
  `systemctl --user status`, and the build log on any failure.
- `assertions/` — one script per phase (`assert-install.sh`,
  `assert-idempotent-reinstall.sh`, `assert-uninstall.sh`).

## Running locally

```bash
podman build -t orcaslicer-testhost -f tests/integration/Containerfile.testhost tests/integration

podman run -d --name orcaslicer-integration-test --privileged --systemd=always \
    -v "$(pwd)":/repo:Z orcaslicer-testhost

podman exec orcaslicer-integration-test \
    su - printer -c "bash /repo/tests/integration/run-integration.sh"

podman rm -f orcaslicer-integration-test
```

The real `orcaslicer-web` container build happens inside the fixture host,
so this takes as long as a real `install.sh` run on hardware (the project's
own README estimates ~20-30 minutes for the first build).

## The nested-podman gotcha

`--privileged --systemd=always` is required on the *outer* `podman run` —
without `--privileged`, the inner rootless `podman build`/`podman run`
inside the fixture host fails with
`newuidmap: write to uid_map failed: Operation not permitted`, because the
outer container doesn't have enough capability to set up the inner
container's user namespace.

Even with `--privileged`, the `printer` user's `/etc/subuid`/`/etc/subgid`
entries must fit *inside the outer container's own local uid space*
(roughly 65536 ids, inherited from whatever range the host's rootless
Podman delegated to the outer container) — they cannot reuse real host
subuid values like `100000:65536`. Notably, `useradd -m` on Debian
auto-assigns a default subuid/subgid entry that doesn't fit this local
space and breaks nested builds; the Containerfile explicitly strips that
default and replaces it with a single entry (`printer:2000:63000`) sized to
fit. This is the fix if you ever see `newuidmap`/`newgidmap` failures with
`Invalid argument` or `Operation not permitted` while modifying this image.

## Known gap

Phase 14 of `install.sh` polls the real Moonraker `/server/orcaslicer/health`
endpoint over HTTP. The fixture host's `moonraker.service` is just a
`sleep infinity` stub (no real Moonraker/HTTP server), so this poll times
out and `install.sh` prints a warning — it does not fail the script (matches
real `install.sh` behavior when Moonraker is slow to pick up the new
component). The assertions do not require this endpoint to respond.

## CI

Wired into `.github/workflows/integration.yml`: nightly cron, manual
dispatch, and on version tags. Not run on every push/PR — the real
container build is too slow for that cadence (Layers 0/1 in
`lint-and-unit.yml` cover that instead).
