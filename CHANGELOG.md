# Changelog

All notable changes to this plugin. The version is set in `manifest.json`;
`eld-unifi-protect --version` reads it from there.

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
