#!/bin/bash
# Build the custom Atoll fork (Release), signed with a local Apple Development
# identity, and optionally install it over /Applications/Atoll.app.
#
#   scripts/build-custom.sh            build + verify only
#   scripts/build-custom.sh --install  also back up the installed app, replace it and relaunch
#
# Signing: a stable identity (not ad-hoc) keeps macOS privacy permissions
# (Accessibility, Screen Recording, …) valid across rebuilds. Set
#   ATOLL_SIGN_IDENTITY  SHA-1 of the identity (two certs can share one name)
#   ATOLL_TEAM_ID        its team (OU of the certificate)
# in the environment or in scripts/custom-build.local.env (git-ignored).
#
# Needs Xcode with the Metal Toolchain: xcodebuild -downloadComponent MetalToolchain

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ -f scripts/custom-build.local.env ]; then
    # shellcheck disable=SC1091
    source scripts/custom-build.local.env
fi

: "${ATOLL_SIGN_IDENTITY:?set ATOLL_SIGN_IDENTITY (security find-identity -v -p codesigning)}"
: "${ATOLL_TEAM_ID:?set ATOLL_TEAM_ID (the OU of that certificate)}"

DERIVED="$ROOT/build/DerivedData"
APP="$DERIVED/Build/Products/Release/Atoll.app"
LOG="$ROOT/build/release.log"
mkdir -p "$ROOT/build"

echo "▸ Building Release (log: build/release.log)…"
if ! xcodebuild build \
    -project DynamicIsland.xcodeproj \
    -scheme DynamicIsland \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGN_IDENTITY="$ATOLL_SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$ATOLL_TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    PROVISIONING_PROFILE_SPECIFIER="" \
    > "$LOG" 2>&1; then
    grep -E 'error:' "$LOG" | sort -u | head -30
    echo "✗ Build failed"
    exit 1
fi

# The release workflow copies these in after export; keep the local app identical.
HUD_DEST="$APP/Contents/Resources/BluetoothHUDAnimations"
if ! ls "$HUD_DEST"/*.mov > /dev/null 2>&1; then
    echo "▸ Adding BluetoothHUDAnimations and re-signing…"
    mkdir -p "$HUD_DEST"
    cp -n DynamicIsland/BluetoothHUDAnimations/*.mov "$HUD_DEST/"
    ENTITLEMENTS="$(mktemp -t atoll-entitlements).plist"
    codesign -d --entitlements :- "$APP" > "$ENTITLEMENTS" 2>/dev/null
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$ATOLL_SIGN_IDENTITY" "$APP"
    rm -f "$ENTITLEMENTS"
fi

codesign --verify --deep --strict "$APP"
VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
echo "✓ Built Atoll $VERSION (custom) → ${APP#"$ROOT"/}"

[ "${1:-}" = "--install" ] || exit 0

INSTALLED="/Applications/Atoll.app"
if [ -d "$INSTALLED" ]; then
    BACKUP="$ROOT/build/backup/Atoll-$(defaults read "$INSTALLED/Contents/Info.plist" CFBundleShortVersionString)-$(date +%Y%m%d-%H%M%S).app"
    mkdir -p "$(dirname "$BACKUP")"
    echo "▸ Backing up the installed app → ${BACKUP#"$ROOT"/}"
    ditto "$INSTALLED" "$BACKUP"
fi

if pgrep -x Atoll > /dev/null; then
    echo "▸ Quitting Atoll…"
    osascript -e 'quit app id "com.Ebullioscopic.Atoll"' > /dev/null 2>&1 || true
    for _ in $(seq 1 20); do pgrep -x Atoll > /dev/null || break; sleep 0.25; done
    pkill -x Atoll 2>/dev/null || true
fi

echo "▸ Installing to $INSTALLED…"
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
open "$INSTALLED"
echo "✓ Installed and launched"
