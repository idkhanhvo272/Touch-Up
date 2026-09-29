#!/bin/bash
# Builds Touch Up, signs it with a local development identity and installs it to /Applications.
#
#   SIGN_IDENTITY="Apple Development: Name (XXXXXXXXXX)" scripts/install-local.sh
#
# or put that SIGN_IDENTITY line in scripts/signing.local.env, which is gitignored.
#
# The app and TouchUpCore.framework must share one Team ID: with hardened runtime, dyld refuses
# to load an ad-hoc signed framework. Keep the same identity across builds so the Accessibility
# and Input Monitoring grants carry over.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "${SIGN_IDENTITY:-}" ] && [ -f "$REPO/scripts/signing.local.env" ]; then
    source "$REPO/scripts/signing.local.env"
fi

: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to a codesigning identity (see: security find-identity -v -p codesigning)}"
DERIVED="${DERIVED_DATA:-$REPO/build/DerivedData}"
BUILT="$DERIVED/Build/Products/Release/Touch Up.app"
TARGET="/Applications/Touch Up.app"

xcodebuild -project "$REPO/Touch Up.xcodeproj" -scheme "Touch Up" -configuration Release \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
    ONLY_ACTIVE_ARCH=YES build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

osascript -e 'quit app "Touch Up"' 2>/dev/null || true
sleep 1

rm -rf "$TARGET"
ditto "$BUILT" "$TARGET"

# Another copy with the same bundle ID confuses System Settings when granting permissions.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$BUILT" || true

codesign -f -s "$SIGN_IDENTITY" -o runtime --timestamp=none "$TARGET/Contents/Frameworks/TouchUpCore.framework"
codesign -f -s "$SIGN_IDENTITY" -o runtime --timestamp=none \
    --entitlements "$REPO/Touch Up/Touch_Up.entitlements" "$TARGET"
codesign --verify --deep --strict "$TARGET"

open "$TARGET"
echo "Installed and launched $TARGET"
