#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/WiFi Monitor.app"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
BUNDLE_ID="${PRODUCT_BUNDLE_IDENTIFIER:-com.local.wifimonitor}"

cd "$ROOT"
swift build -c release --product "WiFi Monitor"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/WiFi Monitor" "$APP/Contents/MacOS/WiFiMonitor"
cp Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
"/usr/libexec/PlistBuddy" -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
"/usr/libexec/PlistBuddy" -c "Set :CFBundleShortVersionString ${MARKETING_VERSION:-0.2.0}" "$APP/Contents/Info.plist"
"/usr/libexec/PlistBuddy" -c "Set :CFBundleVersion ${CURRENT_PROJECT_VERSION:-2}" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --strict "$APP"
printf 'Built %s\n' "$APP"
