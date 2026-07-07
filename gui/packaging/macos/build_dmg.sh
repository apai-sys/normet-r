#!/usr/bin/env bash
# Build normet-r.app with PyInstaller and package it into a compressed DMG.
#
# The app is a Qt front-end only: it requires R (with the normet package)
# to be installed on the target machine — R is NOT bundled.
#
# Usage:  gui/packaging/macos/build_dmg.sh [python]

set -euo pipefail

PY="${1:-python3}"
HERE="$(cd "$(dirname "$0")" && pwd)"
GUI_DIR="$(cd "$HERE/../.." && pwd)"     # …/normet-r/gui
DIST="$GUI_DIR/dist/macos"               # matches the workflow's gui/dist/macos/*.dmg upload path
APP_NAME="Normet"
VERSION="$("$PY" -c 'import importlib.metadata as m; print(m.version("normet-r-gui"))')"

echo "==> Building $APP_NAME $VERSION with $("$PY" --version 2>&1)"
cd "$GUI_DIR"

"$PY" -m PyInstaller "$GUI_DIR/packaging/launcher.py" \
    --name "$APP_NAME" \
    --windowed \
    --noconfirm \
    --clean \
    --distpath "$DIST" \
    --workpath "$GUI_DIR/build/pyinstaller" \
    --specpath "$GUI_DIR/build/pyinstaller" \
    --icon "$GUI_DIR/packaging/assets/normet.icns" \
    --osx-bundle-identifier "org.apai-sys.normet-r" \
    --collect-submodules normet_r_gui \
    --add-data "$GUI_DIR/normet_r_gui/bridge.R:normet_r_gui" \
    --exclude-module tkinter \
    --exclude-module IPython \
    --exclude-module pytest

APP="$DIST/$APP_NAME.app"
[ -d "$APP" ] || { echo "ERROR: $APP not produced"; exit 1; }

echo "==> Staging DMG contents"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="$DIST/${APP_NAME}-${VERSION}-macos-$(uname -m).dmg"
rm -f "$DMG"

echo "==> Creating $DMG"
hdiutil create -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG"

echo "==> Done: $DMG"
du -sh "$DMG"
