#!/bin/bash
# Builds LionMessages and wraps the binary into build/Lion Messages.app.
# Usage: scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Lion Messages.app"
BUNDLE_ID="local.personal.LionMessages"

cd "$ROOT"
swift build -c "$CONFIG" --product LionMessages
BIN="$(swift build -c "$CONFIG" --show-bin-path)/LionMessages"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LionMessages"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Lion Messages</string>
    <key>CFBundleDisplayName</key><string>Lion Messages</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>LionMessages</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Lion Messages asks Messages.app to send the messages you type.</string>
    <key>NSContactsUsageDescription</key>
    <string>Lion Messages shows contact names instead of phone numbers and email addresses. Contacts never leave this Mac.</string>
</dict>
</plist>
PLIST

# Sign with a stable identity when one exists, so Full Disk Access / Automation grants
# survive rebuilds. Ad-hoc signing works too, but macOS may ask again after each rebuild.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk 'NR==1 && /\)/ {print $2}')}"
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP" && echo "Signed with identity $IDENTITY"
else
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" && echo "Ad-hoc signed"
fi

echo "Built: $APP"
