# Changelog

All notable changes to this plugin. The version is set in `manifest.json`;
`eld-unifi-protect --version` reads it from there.

## Unreleased

Security-focused hardening release.

### Security

- **Private details stay out of command lines,** which every local user can
  read. Notifications no longer run `notify-send` with the camera, console
  and time for as long as they are shown; the helper sends them to the
  notification service over D-Bus itself, and accepts "Watch live" only
  from that service. mpv gets its title and video on stdin; the panel
  passes event times in the environment and the console name typed at
  setup on stdin. What command lines still carry are ids (a console's short
  id, made from its name, and Protect's camera ids) and, during setup, a
  console's address.
- **Stream relay.** Players' URLs no longer contain the camera's Protect
  stream alias, only a random route id the relay maps back privately, and
  the relay serves only your own user, so a URL seen elsewhere (in the
  system journal, say) is useless to anyone else. It never lets a console
  redirect a player out of the encrypted tunnel (it passes only
  well-formed, non-redirect responses naming itself), holds no API keys,
  picks up removed consoles and new certificates within seconds, gets a
  fresh token every start, never exits right after a URL is handed out,
  and limits connections that have not shown the token.
- **Consoles are untrusted:** responses, event-stream messages, snapshots,
  thumbnails and event lists are size- and time-limited; times, shapes and
  addresses are checked; text is shown as plain text (a camera name written
  as HTML could make the wall load an image from anywhere) and stripped of
  terminal escape sequences. Snapshots and thumbnails share memory
  budgets. A console can no longer pose as, hide or change the settings of
  another console's camera, and a console's alerts can no longer be dated
  so they are never cleared; a flood of alerts is capped at ten new ones
  per camera per minute.
- **Setup:** a changed console certificate must be confirmed explicitly and
  the API key typed again (`trust-cert` is for a fingerprint checked on the
  console itself, and `--pin` replaces `--yes`); addresses are checked
  before they reach a command line or DNS, so a pasted key goes nowhere.
- **Recordings sign-in:** a rejected password is never retried, even after
  a reboot, until you sign in again (UniFi OS locks accounts after
  repeated failures); a new login is tried in memory and kept, as one
  step, only once it works; `logout`, `remove`, a new login and
  `uninstall.sh --purge` sign the old session out on the console, and say
  so when the console does not confirm it.
- **Files and processes:** files are created with their final permissions
  (cameras.json is now 0600; `clip -o` writes 0600 and never through a
  link); shared files are changed under a lock across processes; the wall
  toggle only ever signals the wall it started; demo mode no longer touches
  your settings or alert log; `uninstall.sh` takes the plugin out of the
  shell first, stops what it started (new `stop` command), lists the
  streams it switched on in Protect (new `enabled-streams`), and reports
  keyring entries a locked keyring kept.
- **CI** actions are pinned to commits and kept current by Dependabot.

### Fixed

- The camera wall recovers when its streams drop: a retry with the same URL
  used to freeze on the last frame instead of reconnecting, and after
  repeated failures it now asks for a fresh URL, backing off up to a minute.
- `snapshot -o` accepts a bare file name.
- `alert --clear` now empties the log right away while the listener runs.

### Upgrading

Versions up to 0.4.1 put each camera's Protect stream alias in the player
URL, and the panel's video player writes that URL to the system journal,
where other accounts in the `adm`, `wheel` or `systemd-journal` groups can
read it, across reboots. The alias alone lets anyone on your network watch
that camera. If other people have accounts on your computer, get new aliases
by turning each camera's RTSPS stream off and on again in Protect (camera →
Settings → Advanced), and optionally trim old journal entries with
`journalctl --vacuum-time`.

## 0.4.1 — 2026-10-12

### Security

- Alert event IDs from a console's event stream are checked before they name
  the alert's snapshot file, and alert snapshots are only ever read or written
  inside the plugin's alert folder. Before, a console sending an ID with a
  path in it could overwrite a JPEG file elsewhere in your home directory.
  Reported in the marketplace review. (#28)

## 0.4.0 — 2026-10-12

### Added

- **Recordings.** `R` (or **Recordings**) in a camera's live view lists what
  it detected in the last 24 hours, with thumbnails, and plays the newest at
  once. Enter plays another, Space pauses, ←/→ and the progress bar seek, and
  a REC badge shows the time on screen. `P` opens the clip in mpv. Clicking
  an alert in the alert log plays its recording. (#23)
- Recordings need a local UniFi account per console, signed in from the panel
  or with `eld-unifi-protect login`; the password goes to the keyring. New
  commands `login`, `logout`, `recordings` and `clip` (`--play`, `-o`), and a
  `recordings` IPC call. (#23)

### Changed

- **Sound when one camera is shown.** The live view, an enlarged wall camera
  and the pop-out player now start with sound; the grid and wall tiles stay
  silent. `M` mutes and carries over while flipping cameras. New `sound`
  setting (default `true`) to start muted instead. (#22)
- README: a recordings screenshot, and every screenshot retaken. (#25)

### Fixed

- Sound in the panel and the wall follows the system's default output.
  Before, it stayed on whatever was the default when the shell started, so a
  headset connected later heard nothing. (#24)
- Flipping quickly between cameras in the live view could show "could not
  open the stream" until the next camera started playing. (#23)

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
