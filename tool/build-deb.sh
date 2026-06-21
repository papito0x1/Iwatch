#!/usr/bin/env bash
# Build a .deb installer for Iwatch from the release bundle.
#
#   flutter build linux --release
#   ./tool/build-deb.sh
#
# Produces dist/iwatch_<version>_amd64.deb
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_ID="io.github.papito0x1.iwatch"
BIN="iwatch"
VERSION="$(grep -m1 '^version:' pubspec.yaml | sed 's/version:[[:space:]]*//; s/+.*//')"
ARCH="amd64"
BUNDLE="build/linux/x64/release/bundle"

[ -d "$BUNDLE" ] || { echo "Release bundle missing — run: flutter build linux --release"; exit 1; }

PKG="$ROOT/dist/${BIN}_${VERSION}_${ARCH}"
rm -rf "$PKG"
mkdir -p "$PKG/DEBIAN" \
         "$PKG/usr/lib/$BIN" \
         "$PKG/usr/bin" \
         "$PKG/usr/share/applications" \
         "$PKG/usr/share/metainfo"

# 1. app bundle -> /usr/lib/iwatch, launcher symlink on PATH
cp -r "$BUNDLE/." "$PKG/usr/lib/$BIN/"
ln -sf "../lib/$BIN/$BIN" "$PKG/usr/bin/$BIN"

# 2. icons
for png in linux/packaging/icons/hicolor/*/apps/"$APP_ID.png"; do
  size_dir="$(basename "$(dirname "$(dirname "$png")")")"
  dest="$PKG/usr/share/icons/hicolor/$size_dir/apps"
  mkdir -p "$dest"
  cp "$png" "$dest/"
done

# 3. desktop entry
cp "linux/packaging/$APP_ID.desktop" "$PKG/usr/share/applications/"

# 4. control + post-install icon cache refresh
INSTALLED_KB="$(du -sk "$PKG/usr" | cut -f1)"
cat > "$PKG/DEBIAN/control" <<EOF
Package: $BIN
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Maintainer: papito0x1 <papito0x1@users.noreply.github.com>
Installed-Size: $INSTALLED_KB
Depends: libgtk-3-0, libglib2.0-0, libstdc++6, zlib1g
Recommends: xdg-utils
Description: Iwatch — native Ubuntu Solana wallet watcher
 A native Ubuntu (Flutter + Yaru) desktop app for watching a Solana wallet's
 token holdings and total value in real time, styled after GNOME Resources.
EOF

cat > "$PKG/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi
EOF
chmod 0755 "$PKG/DEBIAN/postinst"

# 5. build
dpkg-deb --build --root-owner-group "$PKG" >/dev/null
echo "Built: $PKG.deb"
