#!/usr/bin/env bash
# Builds wm and installs it to /Applications/wm.app, replacing and relaunching
# any running copy. Run again after every change.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="${INSTALL_DIR:-/Applications}/wm.app"

./scripts/bundle.sh release

# SIGTERM lets wm bring windows parked on other workspaces back on screen first.
if pkill -TERM -f "wm.app/Contents/MacOS/wm"; then
    for _ in {1..50}; do
        pgrep -f "wm.app/Contents/MacOS/wm" >/dev/null || break
        sleep 0.1
    done
fi

rm -rf "$DEST"
ditto build/wm.app "$DEST"
open "$DEST"
echo "Installed and launched $DEST"
