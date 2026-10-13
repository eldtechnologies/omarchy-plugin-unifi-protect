#!/bin/bash
# Capture the README screenshots from the real UI, on demo data.
#
#   tools/screenshots.sh [workspace]
#
# Needs Hyprland, grim, ImageMagick and the plugin running in the bar. It
# switches to an empty workspace (the one given, else the first free one from
# 10 up), so only the wallpaper is behind the plugin, turns demo mode on,
# captures each view cropped to the plugin, then returns to your workspace and turns demo mode off again. Demo images come
# from docs/demo/; see docs/demo/README.md.

set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cli="$repo/bin/eld-unifi-protect"
out="$repo/docs/screenshots"
ipc=(omarchy-shell com.eldtechnologies.unifi-protect)
runtime="${XDG_RUNTIME_DIR:?}/eld-unifi-protect"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"   # written only after every capture passes its checks

monitor=$(hyprctl monitors -j | python3 -c 'import json,sys; m=[m for m in json.load(sys.stdin) if m["focused"]][0]; print(m["name"], m["scale"], m["reserved"][1])')
read -r output scale bar_top <<<"$monitor"
bar_px=$(python3 -c "print(int(($bar_top) * $scale) + 2)")
home_ws=$(hyprctl activeworkspace -j | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')
if [[ ! $home_ws =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "your current workspace has an unusual name; switch to a numbered one first" >&2
  exit 1
fi
used_ws=$(hyprctl workspaces -j | python3 -c 'import json,sys; print(" ".join(w["name"] for w in json.load(sys.stdin) if w["windows"]))')
if [[ -n ${1:-} ]]; then
  empty_ws=$1
  if [[ ! $empty_ws =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "workspace: a number or a plain name" >&2
    exit 1
  fi
  if [[ " $used_ws " == *" $empty_ws "* ]]; then
    echo "workspace $empty_ws has windows on it; pick an empty one" >&2
    exit 1
  fi
else
  empty_ws=$(python3 -c 'import sys; used=set(sys.argv[1].split()); print(next(str(n) for n in range(10, 30) if str(n) not in used))' "$used_ws")
fi

goto() { hyprctl dispatch "hl.dsp.focus({ workspace = \"$1\" })" >/dev/null; sleep 1; }
active_ws() { hyprctl activeworkspace -j | python3 -c 'import json,sys; w=json.load(sys.stdin); print(w["name"], w["monitor"])'; }

# Never capture anything but the empty workspace, on the monitor grim
# captures: if something switched away (a window asking for attention, a
# click), or the workspace lives on another monitor, stop before saving.
guard() {
  if [[ $(active_ws) != "$empty_ws $output" ]]; then
    echo "aborted: the screen left workspace $empty_ws on $output during capture; nothing was saved" >&2
    exit 1
  fi
}
# Demo data only: never capture while your real cameras are showing.
demo_guard() {
  if [[ $("$cli" demo status) != "demo mode on" ]]; then
    echo "aborted: demo mode is not on; nothing was saved" >&2
    exit 1
  fi
  # And the alert log on screen holds only demo alerts.
  if ! python3 - "$runtime/alerts.json" <<'PY'
import json, sys
alerts = json.load(open(sys.argv[1])).get("alerts", [])
sys.exit(0 if all(str(a.get("id", "")).startswith("demo-") for a in alerts) else 1)
PY
  then
    echo "aborted: the alert log holds real alerts; nothing was saved" >&2
    exit 1
  fi
}
shot() { demo_guard; guard; grim -o "$output" "$1"; guard; }
# Demo mode sets your own alert log (and which alerts you have seen) aside
# and puts it back when it ends, so the script can write the demo's freely.
ack="$runtime/alerts-ack.json"
seen_alerts() { printf '{"ackedAt": %s}\n' "$(python3 -c "import time; print(time.time() - $1)")" >"$ack"; }

demo_started=0
cleanup() {
  "${ipc[@]}" close >/dev/null 2>&1 || true
  "$cli" wall --close >/dev/null 2>&1 || true
  goto "$home_ws" || true
  # Only end demo mode if this script turned it on.
  if [[ $demo_started == 1 ]]; then "$cli" demo off >/dev/null || true; fi
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
  # A crop near full screen means more than the plugin changed: refuse it.
  python3 - "$(cat "$work/geometry")" "$(magick identify -format '%w' "$work/base.png")" <<'PY' || exit 1
import re, sys
width = int(re.match(r"(\d+)x", sys.argv[1]).group(1))
if width > 0.7 * int(sys.argv[2]):
    sys.exit(f"aborted: the {sys.argv[1]} crop is not just the plugin; nothing was saved")
PY
  magick "$work/$name.png" -crop "$(cat "$work/geometry")" +repage -resize '1400x>' "$work/out-$name.png"
}

echo "demo mode on…"
if [[ $("$cli" demo status) == "demo mode on" ]]; then
  echo "demo mode is already on; turn it off first so this script owns it" >&2
  exit 1
fi
demo_started=1
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

echo "panel: recordings"
"${ipc[@]}" recordings "Front Door" >/dev/null; sleep 9; shot "$work/panel-recordings.png"; "${ipc[@]}" close >/dev/null; sleep 1
crop_panel panel-recordings

echo "camera wall"
"$cli" wall --mode window >/dev/null; sleep 9; shot "$work/wall.png"; "$cli" wall >/dev/null; sleep 1
magick "$work/wall.png" -resize '1600x>' "$work/out-wall.png"
magick "$work/wall.png" -resize '1600x900^' -gravity center -extent 1600x900 "$work/out-preview.png"

# Every shot passed its checks: only now write into the repository.
# Photo-heavy views as JPEG (a fraction of the size), the text-heavy log as PNG.
for name in panel-grid panel-live panel-recordings wall; do
  magick "$work/out-$name.png" -quality 88 "$out/$name.jpg"
  echo "  $out/$name.jpg"
done
magick "$work/out-panel-alerts.png" -strip "$out/panel-alerts.png"
echo "  $out/panel-alerts.png"
magick "$work/out-preview.png" -quality 85 "$repo/preview.jpg"
echo "  $repo/preview.jpg"
