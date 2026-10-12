# Changelog

All notable changes to this plugin. The version is set in `manifest.json`;
`eld-unifi-protect --version` reads it from there.

## Unreleased

### Added

- **Recordings.** `R` (or **Recordings**) in a camera's live view lists what
  it detected in the last 24 hours, with thumbnails, and plays the newest at
  once. Enter plays another, Space pauses, ←/→ and the progress bar seek, and
  a REC badge shows the time on screen. `P` opens the clip in mpv. Clicking
  an alert in the alert log plays its recording.
- Recordings need a local UniFi account per console, signed in from the panel
  or with `eld-unifi-protect login`; the password goes to the keyring. New
  commands `login`, `logout`, `recordings` and `clip` (`--play`, `-o`), and a
  `recordings` IPC call.

### Changed

- **Sound when one camera is shown.** The live view, an enlarged wall camera
  and the pop-out player now start with sound; the grid and wall tiles stay
  silent. `M` mutes and carries over while flipping cameras. New `sound`
  setting (default `true`) to start muted instead.

### Fixed
- Sound in the panel and the wall follows the system's default output. Before,
  it stayed on whatever was the default when the shell started, so a headset
  connected later heard nothing.

## 0.3.0 — 2026-10-11

### Added

- **Camera alerts.** Arm a camera (the bell on its tile, or
  `eld-unifi-protect alert`) and the plugin listens to that console's event
  stream for a person, a vehicle or a doorbell ring (also animal, package,
  motion). One connection per console, over the same pinned TLS as
  everything else. (#16)
- **The bar icon pulses** in the urgent colour until you open the panel;
  the tile that alerted gets a border and a badge ("Person · 2 min ago").
  `alertStatus` IPC for scripts. (#17)
- **Desktop notifications** with a snapshot from the moment and a "Watch
  live" button; at most one per camera per minute; on by default. (#18)
- **Alert log** in the panel: what was seen, where, when and for how long,
  with snapshots; unseen alerts marked; Clear. (#19)
- **Demo mode** (`eld-unifi-protect demo on`): made-up consoles and
  cameras for screenshots, development and trying the plugin without
  UniFi hardware. **Screenshots** in the README, from the real UI on
  AI-generated demo images. (#20)

### Fixed

- Tiles could stay on "Loading" on first run, until the panel was
  reopened. (#20)
- The LIVE badge covered the camera's burned-in timestamp. (#20)
- Opening live view from the alert log left the log's buttons in the
  header. (#20)

## 0.2.0 — 2026-10-11

### Fixed

- **Stream relay hangs and rare crashes.** Each relay session used one TLS
  connection from two threads, which OpenSSL forbids; about one session in
  seven could hang, and the relay occasionally crashed. The relay now runs
  on a single asyncio event loop. (#11)
- The runtime directory could be created readable by other users (0755).
  (#3)

### Security

- The relay token no longer appears on mpv's command line, where any local
  user could read it. (#2)
- A private runtime directory is required; the `/tmp` fallback is gone.
  (#3)
- Names and camera IDs from consoles are treated as untrusted: control
  characters are stripped, and an ID that could escape the snapshot folder
  is refused. (#7)
- API keys are stored in the desktop keyring when one is available;
  `eld-unifi-protect migrate-keys` moves existing keys there. (#4)
- Private vulnerability reporting and a `SECURITY.md`. (#10)

### Added

- **Camera wall as a maximized window** (the new default) that keeps
  workspace switching and the bar; the full-screen overlay remains as
  `wallMode: overlay`. (#1)
- **Setup inside the panel**: address, certificate check and API key,
  without a terminal. (#13)
- **Favourite camera**, picture **framing** (fill or fit) and snapshot
  **refresh** presets. (#12)
- **Read-only mode**: `eld-unifi-protect read-only on` never changes
  anything on the consoles. (#9)
- Pop-out player: scroll to zoom, Ctrl+arrows to pan, automatic reconnect.
  (#5)
- The panel shows the plugin version, linking to its release notes. (#14)
- Tests, including an end-to-end relay test, and CI on every pull request.
  (#10)

### Changed

- Incomplete snapshots are rejected instead of shown half-drawn. (#6)
- API-key guidance no longer claims that Site Manager keys are rejected.
  (#8)

## 0.1.0 — 2026-10-10

First release.

- Bar widget with a camera-health colour and a stale-reading dot.
- Panel with a grid of auto-refreshing snapshots, keyboard navigation, and
  live video in the panel (QtMultimedia, low-latency mode).
- Pop-out player in mpv.
- Fullscreen camera wall in its own process: enlarge a camera, flip between
  cameras, sound toggle, automatic reconnect.
- Several consoles (for example a gateway and an NVR), each with its own API
  key; cameras that moved between consoles are matched by MAC address.
- Hide individual cameras, or every offline camera.
- `eld-unifi-protect` CLI: setup, consoles, remove, cameras, hide, unhide,
  hide-offline, wall, live, stream, snapshot, relay, trust-cert, doctor.
- TLS certificate pinning for the API; the API key never enters the shell.
- Encrypted video: a local relay carries every stream to the console over
  TLS with the pinned certificate; players only ever talk to 127.0.0.1.
- GPU video decoding in the mpv pop-out (`--hwdec=auto-safe`); wall tiles
  skip audio decoding.
- Rate-limit handling (HTTP 429 retry) and cached stream URLs.
