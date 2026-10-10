# UniFi Protect for Omarchy

Your UniFi Protect cameras in the Omarchy bar: a grid of auto-refreshing
snapshots, live video right in the panel, a fullscreen camera wall, and a
pop-out player. Works with several consoles at once, such as a gateway and a
dedicated NVR.

In the bar it is a single camera icon. It turns your theme's urgent colour
when a camera is offline, and gets a small dot when a console could not be
reached on the last poll.

Version 0.1.0 · [Changelog](CHANGELOG.md) · MIT licensed · by ELD Technologies

> **Unofficial.** This is an independent community plugin. It is not made,
> endorsed, or supported by Ubiquiti Inc. or by the Omarchy project.

## Requirements

- Omarchy with the Quickshell-based Omarchy shell
- A UniFi console running **UniFi Protect 5.3 or newer** (for the official
  Integration API): Dream Machine, Cloud Gateway, UNVR, and so on
- `python3` (ships with Omarchy; the helper uses the standard library only)
- `secret-tool` from `libsecret` and a keyring such as `gnome-keyring` (both
  ship with Omarchy) to keep API keys in the keyring; optional, see below
- `qt6-multimedia-ffmpeg` for live video (ships with Omarchy)
- `mpv`, optional, for the pop-out player: `omarchy pkg add mpv`

## Install

```bash
omarchy plugin add https://github.com/eldtechnologies/omarchy-plugin-unifi-protect --enable
```

Then click the camera icon in the bar and choose **Run setup**.

Or install from a checkout. This also puts the `eld-unifi-protect` command on
your `PATH`:

```bash
git clone https://github.com/eldtechnologies/omarchy-plugin-unifi-protect
cd omarchy-plugin-unifi-protect
./install.sh
eld-unifi-protect setup
```

### Connecting a console

Setup runs inside the panel (**Run setup**, or **Add console** later); the
same steps are available in a terminal with `eld-unifi-protect setup`. It asks
for the console's address, shows the fingerprint of its TLS certificate for
you to confirm, then asks for an API key. In the panel, the key goes from a
password field to the helper on stdin and the field is cleared at once; it is
never written to a file, a log or a command line.

Create the key **on the console itself**, not on unifi.ui.com:

1. Open `https://<console-ip>` and sign in.
2. Click **Integrations** at the bottom of the left sidebar. On older UniFi OS
   it is under Settings: scroll the row of tabs sideways.
3. **Create API Key** and copy it. It is shown only once.

Paste it into the setup prompt with **Super + V**. The prompt is hidden like
a password, so nothing appears as you paste. Keys created in the cloud Site
Manager at unifi.ui.com are a different kind, and consoles reject them with
HTTP 401.

### Several consoles

Each UniFi console runs its own Protect with its own API key; a gateway's key
does not work on an NVR. Run setup once per console, or click **Add console**
in the panel. All cameras land in one grid, labelled with their console.

A camera moved from one console to another stays listed on the old one as
disconnected. Cameras are matched by MAC address and the connected copy wins,
so these leftovers never hide a live camera.

```bash
eld-unifi-protect consoles          # list them
eld-unifi-protect setup             # same address + empty key = just rename it
eld-unifi-protect remove nvr
```

## Using it

### Bar and panel

| Where | Action | Effect |
|-------|--------|--------|
| Bar | Left click | Open the panel |
| Bar | Middle click | Refresh |
| Bar | Right click | Open Protect in the browser |
| Grid | Click / Enter | Live view in the panel |
| Grid | Arrows / hjkl | Move the selection |
| Grid | `1`–`9` | Live view of camera N |
| Grid | `W` | Camera wall |
| Grid / live | `P` | Pop out to mpv |
| Live | ← / → | Previous / next camera |
| Live | `M` | Toggle sound |
| Live | Double-click | Pop out |
| Live | Esc | Back to the grid |

### Camera wall

**Wall** in the panel header, or `W`, shows every visible camera live. Click
a camera or press `1`–`9` to enlarge it at high quality. ←/→ flips cameras,
`M` toggles sound, Esc goes back to the grid, and Esc (or `Q`) again closes
the wall. Streams that drop reconnect on their own.

It opens in one of two modes, set with `wallMode`:

- **`window`** (default): a maximized window. It keeps the bar visible and
  stays on its workspace, so Super+number switches away and back while the
  cameras keep running. On Hyprland the plugin registers a runtime rule that
  maximizes only this window (matched by its title, "UniFi Protect Wall"); it
  writes nothing to your config.
- **`overlay`**: covers the whole screen, above every workspace, and holds the
  keyboard until you close it. Good for a dedicated monitoring screen.

`eld-unifi-protect wall --mode overlay` picks a mode for one launch.

The wall runs as its own Quickshell process, not inside the Omarchy shell, so
a video decoder fault can never take down the bar or the lock screen.

### Hiding cameras

Hover a tile and click the crossed-out eye to hide that camera. **Hide
offline** hides every camera that is not connected. Hidden cameras leave the
grid, the wall, and the bar's health colour; **Show hidden** brings them back
into view so you can unhide them. Hiding follows a camera by MAC address, so
it survives a move to another console.

```bash
eld-unifi-protect hide "G6 PTZ"
eld-unifi-protect unhide "G6 PTZ"     # or: unhide --all
eld-unifi-protect hide-offline on     # off / toggle
```

### Keybindings and scripts

```bash
eld-unifi-protect wall                  # toggle the camera wall
omarchy-shell com.eldtechnologies.unifi-protect toggle
omarchy-shell com.eldtechnologies.unifi-protect live "Front Door"
eld-unifi-protect cameras               # list cameras and their ids
eld-unifi-protect live <camera-id>      # straight to mpv
```

For example, in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + C", "Camera wall", "eld-unifi-protect wall")
o.bind("SUPER + SHIFT + ALT + C", "Camera wall (overlay)", "eld-unifi-protect wall --mode overlay")
```

### Pop-out player

`P` (or double-click in live view) opens the camera in its own mpv window at
high quality. Scroll to zoom in on a detail, horizontal scroll or
Ctrl+arrows to pan, and Ctrl+0 to reset; `f` toggles fullscreen and `q`
closes it. If the stream drops, the window reconnects on its own.

The mpv window uses the app id `eld-unifi-protect`, for window rules.

## Configuration

Widget settings live in `~/.config/omarchy/shell.json` and reload on save:

| Key | Default | Meaning |
|-----|---------|---------|
| `snapshotIntervalSec` | `3` | Snapshot refresh while the panel is open |
| `columns` | `2` | Grid columns |
| `liveQuality` | `medium` | Stream for the in-panel live view |
| `popoutQuality` | `high` | Stream for the mpv window |
| `wallMode` | `window` | Camera wall as a maximized `window` or a full-screen `overlay` |

```json
{ "id": "com.eldtechnologies.unifi-protect", "columns": 3, "liveQuality": "high" }
```

The plugin's own files:

| Path | Contents |
|------|----------|
| Desktop keyring (Secret Service) | API keys, when a keyring is available |
| `~/.config/eld-unifi-protect/config.json` | Consoles and pinned certificates; API keys only if there is no keyring (mode 0600) |
| `~/.config/eld-unifi-protect/cameras.json` | Hidden cameras (no secrets) |
| `~/.local/state/eld-unifi-protect/state.json` | Last camera list |
| `$XDG_RUNTIME_DIR/eld-unifi-protect/` | Snapshots and stream URLs (tmpfs, gone on reboot) |

## How it works

The Omarchy shell never speaks HTTP and never sees an API key. The helper
`bin/eld-unifi-protect` talks to the Protect Integration API
(`/proxy/protect/integration/v1`), writes camera state and snapshots to disk,
and resolves stream URLs. The panel watches those files and plays the
streams.

- **API keys** are stored in your desktop keyring (Secret Service, through
  `secret-tool`), encrypted at rest, whenever one is available; otherwise in
  `config.json`, readable only by you. They are passed to `secret-tool` on
  stdin, never as arguments. `eld-unifi-protect migrate-keys` moves existing
  keys into the keyring (`--to file` moves them back), and `doctor` shows
  where each console's key lives.
- **Traffic:** while the panel is closed, one camera-list poll per console per
  minute. Snapshots are fetched only while the panel is open on the grid.
- **TLS:** consoles use self-signed certificates. Setup pins each console's
  certificate fingerprint, and every API request checks it before the key is
  sent. If a console's certificate legitimately changes (firmware update,
  factory reset), run `eld-unifi-protect trust-cert`.
- **Video is encrypted end to end on your network.** Protect serves video
  as RTSPS (port 7441) behind the same self-signed certificate. FFmpeg, inside
  both QtMultimedia and mpv, refuses unverified TLS and cannot be given the
  pinned certificate, so players connect to a small relay instead:

  ```
  player --plain RTSP, 127.0.0.1 only--> relay --TLS, pinned cert--> console:7441
  ```

  The relay checks the same pinned certificate as the API, forces all media
  over the encrypted TCP connection (it refuses UDP, and FFmpeg falls back),
  listens only on 127.0.0.1, and requires a random per-session token in every
  URL, so other local users cannot borrow it. It starts on demand and exits
  after a minute without viewers. The only unencrypted hop is loopback inside
  your machine.
- **Streams get switched on:** if a camera has no stream yet for the quality
  you open, the plugin enables one, the same as turning on RTSP in the
  camera's Protect settings. It stays enabled.
- **Rate limits:** requests that get HTTP 429 wait and retry, and stream URLs
  are cached for the session.

`eld-unifi-protect doctor` checks every console end to end.

### Performance

Video is decoded on the GPU (VA-API) by both QtMultimedia and mpv; the
helper only moves encrypted bytes. Measured on an Intel N100:

| Workload | CPU, share of one core |
|---|---|
| Wall, 6 cameras (720p tiles, GPU decode, no tile audio) | ~17% |
| Relay, TLS for those 6 streams | ~4% |
| One 4K stream, GPU decode | ~4% |
| One 4K stream, CPU decode (what mpv does without `--hwdec`) | ~35% |

The helper is Python on purpose: plugins install by `git clone` with no
build step, so readable source with no dependencies beats a compiled binary,
and the relay is not the bottleneck: it sustains over 2 Gbit/s on the same
machine, against roughly 30 Mbit/s for a busy wall.

## Removing it

If you installed with `omarchy plugin add`:

```bash
omarchy plugin remove com.eldtechnologies.unifi-protect
rm -rf ~/.config/eld-unifi-protect ~/.local/state/eld-unifi-protect
secret-tool clear service eld-unifi-protect
```

`omarchy plugin remove` deletes only the plugin folder, so the last two lines
are needed to delete your settings and API keys (the last one clears keys
held in the keyring).

If you installed with `./install.sh`, run `./uninstall.sh` from the checkout.
It also removes the `eld-unifi-protect` command and asks whether to delete your
API keys (`--purge` says yes, `--keep-config` says no).

Either way, revoke the API keys on each console as well: deleting the local
copy does not revoke them.

## Developing

`./install.sh --link` symlinks your checkout into the plugin directory. The
shell's file watcher does not follow that symlink, so after editing
`Panel.qml` or `BarWidget.qml`, run `omarchy restart shell`. Changes to
`bin/eld-unifi-protect` and `wall/shell.qml` take effect the next time they
run.

The version is set in `manifest.json` only; `eld-unifi-protect --version` reads
it from there. Record changes in `CHANGELOG.md`.

Run the tests (standard library only; they never touch your real config,
keys or consoles):

```bash
python3 -m unittest discover -s tests -v
```

They include an end-to-end test of the stream relay against a fake TLS
console. CI runs them, plus a manifest check and `shellcheck`, on every pull
request. To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Disclaimer

This software is provided **as is, without warranty of any kind**, and ELD
Technologies accepts no liability for any damage or loss arising from its
use. See [LICENSE](LICENSE) for the full terms. In particular:

- It is not a security or monitoring system. Do not rely on it to record,
  detect, or alert on anything; use UniFi Protect itself for that.
- It stores console API keys on your machine (in your keyring, or in a file
  readable only by you) and can
  enable RTSPS streams on your cameras. You are responsible for deciding
  whether that is acceptable for your network.
- It uses UniFi Protect's Integration API, which Ubiquiti may change at any
  time.

UniFi, UniFi Protect and Ubiquiti are trademarks of Ubiquiti Inc. Omarchy
belongs to its authors. These names are used here only to describe what this
plugin works with.

## License

MIT © 2026 ELD Technologies. See [LICENSE](LICENSE).
