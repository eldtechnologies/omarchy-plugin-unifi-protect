#!/bin/bash
# Install the UniFi Protect plugin into the Omarchy shell.
#
#   ./install.sh          copy the plugin into ~/.config/omarchy/plugins
#   ./install.sh --link   symlink this checkout instead (for development)

set -euo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
plugin_id="com.eldtechnologies.unifi-protect"
plugins_root="$HOME/.config/omarchy/plugins"
plugin_dir="$plugins_root/$plugin_id"

mkdir -p "$plugins_root"

if [[ ${1:-} == "--link" ]]; then
  if [[ -e $plugin_dir && ! -L $plugin_dir ]]; then
    echo "$plugin_dir exists and is not a symlink; remove it first." >&2
    exit 1
  fi
  ln -sfn "$source_dir" "$plugin_dir"
  echo "Linked. The shell does not watch through symlinks: run 'omarchy restart shell' after QML edits."
else
  [[ -L $plugin_dir ]] && rm "$plugin_dir"
  mkdir -p "$plugin_dir/bin"
  for file in manifest.json BarWidget.qml Panel.qml LICENSE README.md CHANGELOG.md; do
    install -m 644 "$source_dir/$file" "$plugin_dir/$file"
  done
  install -m 755 "$source_dir/bin/eld-unifi-protect" "$plugin_dir/bin/eld-unifi-protect"
  mkdir -p "$plugin_dir/wall"
  install -m 644 "$source_dir/wall/shell.qml" "$plugin_dir/wall/shell.qml"
fi

if ! command -v mpv >/dev/null; then
  echo "Note: mpv is not installed; the pop-out player needs it (omarchy pkg add mpv)."
fi

mkdir -p "$HOME/.local/bin"
ln -sf "$plugin_dir/bin/eld-unifi-protect" "$HOME/.local/bin/eld-unifi-protect"

omarchy plugin validate "$source_dir"
omarchy-shell shell rescanPlugins
omarchy plugin enable "$plugin_id" --section right

if [[ -r "${XDG_CONFIG_HOME:-$HOME/.config}/eld-unifi-protect/config.json" ]]; then
  printf '\n%s\n' "UniFi Protect is in the bar."
else
  printf '\n%s\n' "UniFi Protect is in the bar. Click it and choose Run setup,"
  printf '%s\n' "or run: eld-unifi-protect setup"
fi
