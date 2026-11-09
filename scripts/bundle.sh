#!/usr/bin/env bash
# Builds build/wm.app.
#
# Accessibility permission is tied to the code signature. With ad-hoc signing every
# rebuild looks like a new app to macOS and the permission has to be granted again.
# Signing with a stable identity avoids that. The identity is, in order:
#   1. $CODESIGN_IDENTITY
#   2. a keychain identity named "wm Local Signing" (if present)
#   3. ad-hoc ("-")
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
LOCAL_IDENTITY="wm Local Signing"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    IDENTITY="$CODESIGN_IDENTITY"
elif security find-identity -p codesigning 2>/dev/null | grep -q "\"$LOCAL_IDENTITY\""; then
    IDENTITY="$LOCAL_IDENTITY"
else
    IDENTITY="-"
fi

swift build -c "$CONFIGURATION"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

APP="build/wm.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/wm" "$APP/Contents/MacOS/wm"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Support/Info.plist "$APP/Contents/Info.plist"
# Stamp the build so you can tell installs apart (Get Info / About).
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d.%H%M%S)" "$APP/Contents/Info.plist"
codesign --force --sign "$IDENTITY" "$APP"

if [[ "$IDENTITY" == "-" ]]; then
    echo "Built $APP (ad-hoc signed: Accessibility must be re-granted after each update)"
else
    echo "Built $APP (signed with \"$IDENTITY\")"
fi
