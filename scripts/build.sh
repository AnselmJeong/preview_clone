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
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi

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
