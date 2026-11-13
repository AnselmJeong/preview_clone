#!/bin/bash
# Runs the FolioCore unit tests (Swift Testing).
# With full Xcode, plain `swift test` works. With only the Command Line Tools, the
# Testing framework lives outside the default search path and its Foundation
# cross-import overlay ships without a module, so point the compiler at it and
# disable cross-import overlays.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV_DIR="$(xcode-select -p)"
if [[ "$DEV_DIR" == *CommandLineTools* ]]; then
  F="$DEV_DIR/Library/Developer/Frameworks"
  exec swift test \
    -Xswiftc -F"$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F" "$@"
fi
exec swift test "$@"
