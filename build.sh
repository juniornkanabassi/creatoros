#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
BUILD_ROOT="${CONTENT_TEMPLATE_BUILD_ROOT:-${TMPDIR:-/private/tmp}/creatoros-build}"
OUTPUT_ROOT="${CONTENT_TEMPLATE_OUTPUT_ROOT:-../Outputs}"
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
APP_NAME=$(/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' Resources/Info.plist)
APP_CHANNEL=$(/usr/libexec/PlistBuddy -c 'Print CreatorOSChannel' Resources/Info.plist)
ICON_SOURCE="Resources/AppIcon.icns"
if [[ "$APP_CHANNEL" == "α" ]]; then ICON_SOURCE="Resources/AppIconAlpha.icns"; fi
[[ -f "$ICON_SOURCE" ]] || { print -u2 "Channel icon is missing: $ICON_SOURCE"; exit 1; }
CHANNEL_SUFFIX="${APP_CHANNEL:+ $APP_CHANNEL}"
ARCHIVE_PATH="$OUTPUT_ROOT/$APP_NAME $APP_VERSION$CHANNEL_SUFFIX.zip"
if [[ -e "$ARCHIVE_PATH" ]]; then
  print -u2 "Build destination already exists. Choose a fresh CONTENT_TEMPLATE_OUTPUT_ROOT; this script never replaces a delivered app."
  exit 1
fi
swift build --scratch-path "$BUILD_ROOT" -c release --product ProjectTemplates
swift build --scratch-path "$BUILD_ROOT" -c release --product creatoros
BIN_PATH=$(swift build --scratch-path "$BUILD_ROOT" -c release --show-bin-path)
BUILD_STAGE=$(mktemp -d /private/tmp/content-template-package.XXXXXX)
APP_PATH="$BUILD_STAGE/$APP_NAME.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH/ProjectTemplates" "$APP_PATH/Contents/MacOS/ProjectTemplates"
cp "$BIN_PATH/creatoros" "$APP_PATH/Contents/MacOS/creatoros"
mkdir -p "$APP_PATH/Contents/Resources/mcp"
cp mcp/creatoros-mcp.mjs "$APP_PATH/Contents/Resources/mcp/"
/usr/bin/codesign --force --sign - "$APP_PATH/Contents/MacOS/creatoros"
cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
cp "$ICON_SOURCE" "$APP_PATH/Contents/Resources/AppIcon.icns"
# Finder/File Provider can attach FinderInfo to this newly made bundle directory.
# Remove it only from our generated app root, never from imported template data.
if /usr/bin/xattr -p com.apple.FinderInfo "$APP_PATH" >/dev/null 2>&1; then
  /usr/bin/xattr -d com.apple.FinderInfo "$APP_PATH"
fi
/usr/bin/codesign --force --sign - "$APP_PATH"
/usr/bin/codesign --verify --strict "$APP_PATH"
mkdir -p "$OUTPUT_ROOT"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
print "Local ad-hoc-signed development app: ${APP_PATH:A}"
print "Archive for installation outside file-provider folders: ${ARCHIVE_PATH:A}"
