#!/usr/bin/env bash
# Install Iwatch desktop integration (icon + launcher) for the current user so
# it shows up in the GNOME dock / app grid with the proper icon. Run from the
# project root after `flutter build linux`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_ID="io.github.papito0x1.iwatch"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"

# 1. icons
for png in "$ROOT"/linux/packaging/icons/hicolor/*/apps/"$APP_ID.png"; do
  size_dir="$(basename "$(dirname "$(dirname "$png")")")"
  dest="$DATA/icons/hicolor/$size_dir/apps"
  mkdir -p "$dest"
  cp "$png" "$dest/"
done

# 2. desktop entry — point Exec at the built binary (absolute path)
BIN="$ROOT/build/linux/x64/release/bundle/iwatch"
[ -x "$BIN" ] || BIN="$ROOT/build/linux/x64/debug/bundle/iwatch"
mkdir -p "$DATA/applications"
sed "s|^Exec=iwatch|Exec=$BIN|" \
  "$ROOT/linux/packaging/$APP_ID.desktop" > "$DATA/applications/$APP_ID.desktop"

# 3. refresh caches (best-effort)
gtk-update-icon-cache -q -t -f "$DATA/icons/hicolor" 2>/dev/null || true
update-desktop-database -q "$DATA/applications" 2>/dev/null || true

echo "Installed Iwatch launcher and icons under $DATA"
