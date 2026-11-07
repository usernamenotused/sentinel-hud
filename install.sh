#!/bin/bash
# Install the Sentinel HUD from a git checkout, without building a package.
#
#   ./install.sh            standalone Quickshell install (any wlroots-style compositor)
#   ./install.sh --omarchy  Omarchy: theme + shell plugin
#   ./install.sh --uninstall
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
data="${XDG_DATA_HOME:-$HOME/.local/share}/sentinel-hud"
conf="${XDG_CONFIG_HOME:-$HOME/.config}/sentinel-hud"
bin="$HOME/.local/bin"
files=(shell.qml Hud.qml NetMap.qml hud.sh netmap.sh sentinel-hud)

need() {
  local missing=()
  for c in qs jq ip ss journalctl; do command -v "$c" >/dev/null || missing+=("$c"); done
  if (( ${#missing[@]} )); then
    echo "Missing: ${missing[*]}"
    echo "On Arch: sudo pacman -S --needed quickshell jq iproute2 pacman-contrib"
    exit 1
  fi
}

seed_config() {
  mkdir -p "$conf"
  [[ -f $conf/config ]] || cp "$here/config.example" "$conf/config"
  [[ -f $conf/sweep-networks.example ]] || cp "$here/sweep-networks.example" "$conf/"
}

case "${1:-}" in
--omarchy)
  command -v omarchy >/dev/null || { echo "omarchy not found; run ./install.sh without --omarchy"; exit 1; }
  themes="$HOME/.config/omarchy/themes/sentinel"
  mkdir -p "$themes"
  cp -r "$here/theme/." "$themes/"
  echo "Theme installed to $themes"

  plugins="$HOME/.config/omarchy/plugins"
  if ! omarchy plugin list --json 2>/dev/null | jq -e 'map(select(.id == "sentinel.hud")) | length > 0' >/dev/null; then
    mkdir -p "$plugins"
    ln -sfn "$here" "$plugins/sentinel.hud"
    echo "Plugin linked to $plugins/sentinel.hud"
  fi
  omarchy plugin enable sentinel.hud >/dev/null 2>&1 || true
  seed_config
  echo "Done. Switch to it with: omarchy theme set sentinel"
  ;;
--uninstall)
  rm -rf "$data" "$bin/sentinel-hud"
  echo "Removed $data and $bin/sentinel-hud (kept $conf)"
  ;;
"")
  need
  mkdir -p "$data" "$bin"
  for f in "${files[@]}"; do install -m "$([[ $f == *.sh || $f == sentinel-hud ]] && echo 755 || echo 644)" "$here/$f" "$data/$f"; done
  mkdir -p "$data/demo" && cp "$here"/demo/*.json "$data/demo/"
  ln -sfn "$data/sentinel-hud" "$bin/sentinel-hud"
  seed_config
  cat <<MSG
Installed to $data
Run it now:   sentinel-hud
Autostart it from your compositor config:
  Hyprland (hyprland.conf):  exec-once = sentinel-hud
  Sway (config):             exec sentinel-hud
  niri (config.kdl):         spawn-at-startup "sentinel-hud"
Settings: $conf/config
MSG
  ;;
*)
  sed -n '2,7p' "$0"; exit 1 ;;
esac
