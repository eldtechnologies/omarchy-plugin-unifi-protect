#!/bin/bash
# Remove the UniFi Protect plugin. --purge also deletes the API key and state.

set -euo pipefail

plugin_id="com.eldtechnologies.unifi-protect"
plugin_dir="$HOME/.config/omarchy/plugins/$plugin_id"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/eld-unifi-protect"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/eld-unifi-protect"
# Only the private runtime directory; never guess a shared path like /tmp.
runtime_dir="${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/eld-unifi-protect}"

omarchy plugin disable "$plugin_id" 2>/dev/null || true
if [[ -L $plugin_dir ]]; then rm "$plugin_dir"; else rm -rf "$plugin_dir"; fi
rm -f "$HOME/.local/bin/eld-unifi-protect"
[[ -n $runtime_dir ]] && rm -rf "$runtime_dir"
omarchy-shell shell rescanPlugins 2>/dev/null || true

purge=${1:-}
if [[ $purge != "--purge" && $purge != "--keep-config" && -t 0 ]]; then
  read -rp "Delete the stored API key and state too? [y/N] " answer
  [[ $answer == [yY]* ]] && purge="--purge"
fi
if [[ $purge == "--purge" ]]; then
  rm -rf "$config_dir" "$state_dir"
  echo "Removed. Revoke the API key on the console too: deleting the local copy does not revoke it."
else
  echo "Removed. Your config is still in $config_dir"
fi
