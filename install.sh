#!/usr/bin/env bash
# Install the Alt-Tab thumbnail switcher into an Omarchy / Hyprland config.
#
# Symlinks this repo's two files into ~/.config and adds the two loader lines to
# ~/.config/hypr/hyprland.lua and ~/.config/hypr/autostart.lua. Safe to re-run.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
config=${XDG_CONFIG_HOME:-$HOME/.config}

link() {
  local target=$1 path=$2
  if [[ -L $path ]]; then
    [[ $(readlink -f "$path") == "$(readlink -f "$target")" ]] && { echo "ok    $path"; return; }
    echo "error $path is a symlink to something else: $(readlink "$path")" >&2
    exit 1
  fi
  if [[ -e $path ]]; then
    mv "$path" "$path.bak.$(date +%s)"
    echo "moved $path aside"
  fi
  mkdir -p "$(dirname "$path")"
  ln -s "$target" "$path"
  echo "link  $path"
}

require_line() {
  local file=$1 needle=$2 block=$3
  if grep -qF "$needle" "$file" 2>/dev/null; then
    echo "ok    $file already loads the switcher"
    return
  fi
  printf '%s\n' "$block" >> "$file"
  echo "patch $file"
}

link "$repo/hypr/switcher.lua" "$config/hypr/switcher.lua"
link "$repo/quickshell/omarchy-switcher" "$config/quickshell/omarchy-switcher"

require_line "$config/hypr/hyprland.lua" 'require("hypr.switcher")' '
-- Alt-Tab window switcher with live thumbnails.
require("hypr.switcher")'

require_line "$config/hypr/autostart.lua" 'qs -c omarchy-switcher' '
-- Thumbnail overlay for the ALT+TAB switcher (see hypr/switcher.lua).
o.exec_on_start("qs -c omarchy-switcher -n -d")'

echo
echo "Starting the overlay and reloading Hyprland..."
pkill -f 'qs -c omarchy-switcher' 2>/dev/null || true
setsid qs -c omarchy-switcher -n -d >/dev/null 2>&1 </dev/null || {
  echo "error could not start quickshell (is it installed?)" >&2
  exit 1
}
hyprctl reload >/dev/null
errors=$(hyprctl configerrors)
if [[ -n ${errors//[[:space:]]/} ]]; then
  echo "error hyprctl configerrors is not clean:" >&2
  echo "$errors" >&2
  exit 1
fi

echo "done. Hold ALT and press TAB."
