#!/bin/bash
# Builds Folio.app from the Swift package (no Xcode project needed).
#   scripts/build.sh            # release build → build/Folio.app
#   scripts/build.sh install    # …and copy to /Applications (or ~/Applications)
#   scripts/build.sh debug      # debug build
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG=release
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    debug) CONFIG=debug ;;
    install) INSTALL=1 ;;
  esac
done

swift build -c "$CONFIG" --product Folio
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Folio"

APP=build/Folio.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Folio"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/ChatRenderer "$APP/Contents/Resources/ChatRenderer"
# App icon: build AppIcon.icns from the 1024 px master (Resources/Icon/AppIcon.svg → AppIcon-1024.png).
ICON_SRC=Resources/Icon/AppIcon-1024.png
ICNS=build/AppIcon.icns
if [ -f "$ICON_SRC" ] && { [ ! -f "$ICNS" ] || [ "$ICON_SRC" -nt "$ICNS" ]; }; then
  SET=build/AppIcon.iconset
  rm -rf "$SET" && mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_SRC" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$ICON_SRC" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$ICNS"
  rm -rf "$SET"
fi
[ -f "$ICNS" ] && cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature with the hardened runtime so Gatekeeper and Keychain treat the app consistently.
codesign --force --sign - --options runtime --timestamp=none "$APP" >/dev/null
echo "Built $APP"

if [ "$INSTALL" = 1 ]; then
  DEST=/Applications
  [ -w "$DEST" ] || DEST="$HOME/Applications"
  mkdir -p "$DEST"
  rm -rf "$DEST/Folio.app"
  cp -R "$APP" "$DEST/"
  # Register with Launch Services so "Open With" and default-app settings see it.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/Folio.app" || true
  echo "Installed to $DEST/Folio.app"
fi
