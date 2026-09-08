#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
BUILD_ROOT="${CONTENT_TEMPLATE_BUILD_ROOT:-/private/tmp/creatoros-build}"
OUTPUT_ROOT="${CONTENT_TEMPLATE_OUTPUT_ROOT:-../Outputs}"
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
APP_NAME=$(/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' Resources/Info.plist)
APP_CHANNEL=$(/usr/libexec/PlistBuddy -c 'Print CreatorOSChannel' Resources/Info.plist)
ARCHIVE_PATH="$OUTPUT_ROOT/$APP_NAME $APP_VERSION $APP_CHANNEL.zip"
if [[ -e "$ARCHIVE_PATH" ]]; then
  print -u2 "Build destination already exists. Choose a fresh CONTENT_TEMPLATE_OUTPUT_ROOT; this script never replaces a delivered app."
  exit 1
fi
swift build --scratch-path "$BUILD_ROOT" -c release --product ProjectTemplates
BIN_PATH=$(swift build --scratch-path "$BUILD_ROOT" -c release --show-bin-path)
BUILD_STAGE=$(mktemp -d /private/tmp/content-template-package.XXXXXX)
APP_PATH="$BUILD_STAGE/$APP_NAME.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH/ProjectTemplates" "$APP_PATH/Contents/MacOS/ProjectTemplates"
cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_PATH/Contents/Resources/AppIcon.icns"
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
