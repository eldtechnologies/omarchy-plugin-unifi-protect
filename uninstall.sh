#!/bin/bash
# Remove the UniFi Protect plugin. --purge also deletes the API key and state.

set -euo pipefail

plugin_id="com.eldtechnologies.unifi-protect"
plugin_dir="$HOME/.config/omarchy/plugins/$plugin_id"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/eld-unifi-protect"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/eld-unifi-protect"
# Only the private runtime directory; never guess a shared path like /tmp.
runtime_dir="${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/eld-unifi-protect}"
helper="$plugin_dir/bin/eld-unifi-protect"

purge=${1:-}
if [[ $purge != "--purge" && $purge != "--keep-config" && -t 0 ]]; then
  read -rp "Delete the stored API keys, recordings logins and state too? [y/N] " answer
  [[ $answer == [yY]* ]] && purge="--purge"
fi

# Take the plugin out of the shell first, so its panel cannot start anything
# again; then stop what runs in the background (and, when purging, sign
# recordings sessions out on the consoles); only then delete files.
omarchy plugin disable "$plugin_id" 2>/dev/null || true
omarchy-shell shell rescanPlugins 2>/dev/null || true
streams=""
if [[ -x $helper ]]; then
  streams=$("$helper" enabled-streams 2>/dev/null || true)
  if [[ $purge == "--purge" ]]; then
    "$helper" stop --sign-out || true
  else
    "$helper" stop || true
  fi
fi

if [[ -L $plugin_dir ]]; then rm "$plugin_dir"; else rm -rf "$plugin_dir"; fi
rm -f "$HOME/.local/bin/eld-unifi-protect"
[[ -n $runtime_dir ]] && rm -rf "$runtime_dir"
omarchy-shell shell rescanPlugins 2>/dev/null || true

if [[ $purge == "--purge" ]]; then
  rm -rf "$config_dir" "$state_dir"
  # API keys and recordings logins stored in the desktop keyring. A locked
  # keyring keeps its items without a word, so check what is left.
  kept=0
  if command -v secret-tool >/dev/null; then
    for service in eld-unifi-protect eld-unifi-protect-login; do
      # Exit 1 with nothing on stderr: nothing (unlocked) to clear. Anything
      # on stderr: the keyring could not be reached.
      if ! err=$(secret-tool clear service "$service" 2>&1) && [[ -n $err ]]; then
        echo "Could not clear $service from the keyring: $err" >&2
        kept=1
      elif [[ -n $(secret-tool search --all service "$service" 2>/dev/null) ]]; then
        echo "The keyring kept items for $service (it may be locked)." >&2
        kept=1
      fi
    done
  fi
  if [[ $kept == 1 ]]; then
    echo "Removed, except what the keyring kept: unlock it and run"
    echo "  secret-tool clear service eld-unifi-protect; secret-tool clear service eld-unifi-protect-login"
  else
    echo "Removed."
  fi
  echo "Revoke the API key on the console too, and delete any local recordings account:"
  echo "deleting the local copy does not revoke them."
else
  echo "Removed. Your config is still in $config_dir"
fi
if [[ -n $streams ]]; then
  echo
  echo "$streams"
else
  echo "Streams the plugin switched on stay on in Protect (camera → Settings → Advanced)."
fi
echo "Desktop notifications it showed may still be in your notification history"
echo "(Omarchy: ~/.local/state/omarchy/notifications)."
