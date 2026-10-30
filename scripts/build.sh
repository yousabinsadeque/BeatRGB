#!/bin/zsh
# Builds BeatRGB, runs the unit tests, and installs the app to ~/Applications.
# Build products live in ~/Library/Caches/BeatRGB because iCloud-synced folders (like Desktop)
# attach extended attributes that make code signing fail.
set -euo pipefail
cd "$(dirname "$0")/.."
CACHE="$HOME/Library/Caches/BeatRGB"
CONFIG="${1:-Release}"

xattr -cr . 2>/dev/null || true

echo "▸ Unit tests"
(cd BeatRGBKit && swift test --scratch-path "$CACHE/spm" 2>&1 | tail -1)

echo "▸ Generating Xcode project"
xcodegen generate --quiet

echo "▸ Building $CONFIG"
xcodebuild -project BeatRGB.xcodeproj -scheme BeatRGB -configuration "$CONFIG" \
  -derivedDataPath "$CACHE/DerivedData" build 2>&1 | grep -E "error:|BUILD" | grep -v iOSSimulator

APP="$CACHE/DerivedData/Build/Products/$CONFIG/BeatRGB.app"

# macOS ties privacy permissions (Screen Recording, Input Monitoring) to the signing identity, and it
# would not match ad-hoc signatures even with a fixed designated requirement. Sign with the local
# self-signed "BeatRGB Local Signing" certificate when it is in the keychain so the identity stays the
# same across rebuilds; otherwise fall back to ad-hoc.
IDENTITY="BeatRGB Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" --preserve-metadata=entitlements "$APP" 2>&1 | grep -v "replacing existing signature" || true
else
  echo "▸ '$IDENTITY' certificate not found — signing ad-hoc (privacy permissions may not stick)"
  codesign --force --sign - --preserve-metadata=entitlements \
    -r='designated => identifier "com.beatrgb.app"' "$APP" 2>&1 | grep -v "replacing existing signature" || true
fi
mkdir -p "$HOME/Applications"
osascript -e 'tell application id "com.beatrgb.app" to quit' 2>/dev/null || true
sleep 1
rm -rf "$HOME/Applications/BeatRGB.app"
cp -R "$APP" "$HOME/Applications/"
# Keep Launch Services (and so System Settings' privacy lists) pointed at the installed copy, not the
# build product, or a permission can end up granted to the wrong copy.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$APP" 2>/dev/null || true
"$LSREGISTER" -f "$HOME/Applications/BeatRGB.app"
echo "▸ Installed $HOME/Applications/BeatRGB.app"
