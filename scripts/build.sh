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
mkdir -p "$HOME/Applications"
osascript -e 'tell application id "com.beatrgb.app" to quit' 2>/dev/null || true
sleep 1
rm -rf "$HOME/Applications/BeatRGB.app"
cp -R "$APP" "$HOME/Applications/"
echo "▸ Installed $HOME/Applications/BeatRGB.app"
