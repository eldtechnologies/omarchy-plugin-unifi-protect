#!/bin/bash
# Capture the README screenshots from the real UI, on demo data.
#
#   tools/screenshots.sh
#
# Needs Hyprland, grim, ImageMagick and the plugin running in the bar. It
# switches to an empty workspace (so only the wallpaper is behind the
# plugin), turns demo mode on, captures each view cropped to the plugin, then
# returns to your workspace and turns demo mode off again. Demo images come
# from docs/demo/; see docs/demo/README.md.

set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cli="$repo/bin/eld-unifi-protect"
out="$repo/docs/screenshots"
ipc=(omarchy-shell com.eldtechnologies.unifi-protect)
runtime="${XDG_RUNTIME_DIR:?}/eld-unifi-protect"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

monitor=$(hyprctl monitors -j | python3 -c 'import json,sys; m=[m for m in json.load(sys.stdin) if m["focused"]][0]; print(m["name"], m["scale"], m["reserved"][1])')
read -r output scale bar_top <<<"$monitor"
bar_px=$(python3 -c "print(int(($bar_top) * $scale) + 2)")
home_ws=$(hyprctl activeworkspace -j | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')
empty_ws=$(hyprctl workspaces -j | python3 -c 'import json,sys; used={w["name"] for w in json.load(sys.stdin) if w["windows"]}; print(next(str(n) for n in range(10, 30) if str(n) not in used))')

goto() { hyprctl dispatch "hl.dsp.focus({ workspace = \"$1\" })" >/dev/null; sleep 1; }
shot() { grim -o "$output" "$1"; }
seen_alerts() { printf '{"ackedAt": %s}\n' "$(python3 -c "import time; print(time.time() - $1)")" >"$runtime/alerts-ack.json"; }

cleanup() {
  "${ipc[@]}" close >/dev/null 2>&1 || true
  "$cli" wall --no-toggle >/dev/null 2>&1 && "$cli" wall >/dev/null 2>&1 || true
  goto "$home_ws"
  "$cli" demo off >/dev/null
}
trap 'cleanup; rm -rf "$work"' EXIT

# Crop a capture to what changed against the empty-workspace baseline, below
# the bar, with a little margin.
crop_panel() {
  local name=$1 bbox
  bbox=$(magick "$work/base.png" "$work/$name.png" -compose difference -composite \
           -crop "+0+$bar_px" +repage -colorspace gray -threshold 6% -format '%@' info:)
  python3 - "$bbox" "$bar_px" <<'PY' >"$work/geometry"
import re, sys
w, h, x, y = map(int, re.match(r"(\d+)x(\d+)\+(\d+)\+(\d+)", sys.argv[1]).groups())
pad = 24
print(f"{w + 2 * pad}x{h + 2 * pad}+{max(0, x - pad)}+{max(0, y + int(sys.argv[2]) - pad)}")
PY
  magick "$work/$name.png" -crop "$(cat "$work/geometry")" +repage -resize '1400x>' "$out/$name.png"
  echo "  $out/$name.png"
}

echo "demo mode on…"
"$cli" demo on >/dev/null
goto "$empty_ws"
"${ipc[@]}" close >/dev/null 2>&1 || true
sleep 2
shot "$work/base.png"

echo "panel: camera grid"
seen_alerts 0                         # nothing unseen: opens on the grid
"${ipc[@]}" open >/dev/null; sleep 5; shot "$work/panel-grid.png"; "${ipc[@]}" close >/dev/null; sleep 1
crop_panel panel-grid

echo "panel: alert log"
seen_alerts 1200                      # the last 20 minutes are unseen
"${ipc[@]}" open >/dev/null; sleep 4; shot "$work/panel-alerts.png"; "${ipc[@]}" close >/dev/null; sleep 1
crop_panel panel-alerts

echo "panel: live view"
"${ipc[@]}" live "Front Door" >/dev/null; sleep 6; shot "$work/panel-live.png"; "${ipc[@]}" close >/dev/null; sleep 1
crop_panel panel-live

echo "camera wall"
"$cli" wall --mode window >/dev/null; sleep 9; shot "$work/wall.png"; "$cli" wall >/dev/null; sleep 1
magick "$work/wall.png" -resize '1600x>' "$out/wall.png"
magick "$work/wall.png" -resize '1600x900^' -gravity center -extent 1600x900 "$repo/preview.png"
echo "  $out/wall.png"
echo "  $repo/preview.png"
