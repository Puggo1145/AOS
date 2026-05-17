#!/usr/bin/env bash
# Build a polished Notch Agent distribution DMG.
#
# The final image stores a Finder install window with a custom background,
# the app icon, and an Applications shortcut positioned for drag-install.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VOL_NAME="Notch Agent"
DIST_DIR="$REPO_ROOT/dist"
TMP_ROOT="$REPO_ROOT/.dist/dmg"
APP_BUNDLE="$TMP_ROOT/Notch Agent.app"
RW_DMG="$TMP_ROOT/notch-agent-rw.dmg"
MOUNT_POINT="/Volumes/$VOL_NAME"
BACKGROUND_DIR=".background"
BACKGROUND_FILE="background.png"

if [ -e "$MOUNT_POINT" ]; then
  echo "error: $MOUNT_POINT is already mounted. Eject it before building the DMG." >&2
  exit 1
fi

rm -rf "$TMP_ROOT"
mkdir -p "$TMP_ROOT" "$DIST_DIR"

if [ "${NOTCH_SKIP_APP_BUILD:-0}" != "1" ]; then
  NOTCH_BUILD_CONFIG="${NOTCH_BUILD_CONFIG:-release}" \
    NOTCH_APP_BUNDLE_PATH="$APP_BUNDLE" \
    ./Scripts/build-app.sh
fi

if [ ! -d "$APP_BUNDLE" ]; then
  echo "error: $APP_BUNDLE does not exist. Run Scripts/build-app.sh first." >&2
  exit 1
fi

APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_BUNDLE/Contents/Info.plist")"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw "$APP_BUNDLE/Contents/Info.plist")"
ARCH="$(uname -m)"
DMG_NAME="Notch-Agent-${APP_VERSION}-${BUILD_NUMBER}-${ARCH}.dmg"
FINAL_DMG="$DIST_DIR/$DMG_NAME"
rm -f "$FINAL_DMG"

detach_mount() {
  if hdiutil info | grep -Fq "$MOUNT_POINT"; then
    hdiutil detach "$MOUNT_POINT" >/dev/null
  fi
}
trap detach_mount EXIT

hdiutil create \
  -size 220m \
  -fs "Journaled HFS+" \
  -volname "$VOL_NAME" \
  -ov \
  "$RW_DMG" >/dev/null

hdiutil attach \
  -readwrite \
  -mountpoint "$MOUNT_POINT" \
  "$RW_DMG" >/dev/null

cp -R "$APP_BUNDLE" "$MOUNT_POINT/"
ln -s /Applications "$MOUNT_POINT/Applications"
mkdir -p "$MOUNT_POINT/$BACKGROUND_DIR"

swift - "$MOUNT_POINT/$BACKGROUND_DIR/$BACKGROUND_FILE" <<'SWIFT'
import AppKit

let outputPath = CommandLine.arguments[1]
let size = NSSize(width: 720, height: 460)
let image = NSImage(size: size)

image.lockFocus()

let bounds = NSRect(origin: .zero, size: size)
NSColor.white.setFill()
bounds.fill()

let title = "Install Notch Agent"
let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 30, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 0.13, alpha: 1)
]
title.draw(at: NSPoint(x: 236, y: 374), withAttributes: titleAttributes)

let subtitle = "Drag the app into Applications"
let subtitleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 16, weight: .medium),
    .foregroundColor: NSColor(calibratedWhite: 0.36, alpha: 1)
]
subtitle.draw(at: NSPoint(x: 252, y: 344), withAttributes: subtitleAttributes)

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 288, y: 222))
arrow.line(to: NSPoint(x: 432, y: 222))
arrow.move(to: NSPoint(x: 414, y: 240))
arrow.line(to: NSPoint(x: 432, y: 222))
arrow.line(to: NSPoint(x: 414, y: 204))
NSColor(calibratedWhite: 0.42, alpha: 1).setStroke()
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.stroke()

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("failed to render DMG background")
}

try png.write(to: URL(fileURLWithPath: outputPath))
SWIFT

SetFile -a V "$MOUNT_POINT/$BACKGROUND_DIR"
xattr -cr "$MOUNT_POINT"

osascript <<APPLESCRIPT
set backgroundImage to POSIX file "$MOUNT_POINT/$BACKGROUND_DIR/$BACKGROUND_FILE" as alias
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {120, 100, 840, 560}
    set viewOptions to icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 104
    set background picture of viewOptions to backgroundImage
    set sidebar width of container window to 0
    set position of item "Notch Agent.app" of container window to {170, 244}
    set position of item "Applications" of container window to {550, 244}
    update without registering applications
    close container window
    open
  end tell
end tell
APPLESCRIPT

sleep 1
sync
detach_mount
trap - EXIT

hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL_DMG" >/dev/null
hdiutil verify "$FINAL_DMG" >/dev/null
rm -rf "$TMP_ROOT"
rmdir "$REPO_ROOT/.dist" 2>/dev/null || true

echo "Built $FINAL_DMG"
