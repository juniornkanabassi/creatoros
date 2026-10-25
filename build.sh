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
cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
# Sparkle, found through the app's rpath @executable_path/../Frameworks; ditto keeps its symlinks.
[[ -d "$BIN_PATH/Sparkle.framework" ]] || { print -u2 "No Sparkle.framework in $BIN_PATH"; exit 1; }
mkdir -p "$APP_PATH/Contents/Frameworks"
/usr/bin/ditto "$BIN_PATH/Sparkle.framework" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
cp "$ICON_SOURCE" "$APP_PATH/Contents/Resources/AppIcon.icns"
# Finder/File Provider can attach FinderInfo to this newly made bundle directory.
# Remove it only from our generated app root, never from imported template data.
if /usr/bin/xattr -p com.apple.FinderInfo "$APP_PATH" >/dev/null 2>&1; then
  /usr/bin/xattr -d com.apple.FinderInfo "$APP_PATH"
fi
# Releases are Developer ID signed with the hardened runtime, notarised and stapled, so they open on any Mac
# (the same certificate and "JuniorOS" notarytool profile as Video Prompter and Talk & Read). The α channel,
# and any Mac without the certificate, signs ad hoc. CREATOROS_NOTARISE=0 skips notarisation for a quick local build.
DEV_ID_SHA="C297CD17464A0EF6C93704A59BC2E1D4D1759400"
NOTARY_PROFILE="${CREATOROS_NOTARY_PROFILE:-JuniorOS}"
SIGN_ID="-"
# CREATOROS_LOCAL_SIGNING=1 signs ad hoc even with the certificate present, as a Mac without it would.
if [[ "$APP_CHANNEL" != "α" && -z "${CREATOROS_LOCAL_SIGNING:-}" ]] && /usr/bin/security find-identity -v -p codesigning 2>/dev/null | grep -q "$DEV_ID_SHA"; then SIGN_ID="$DEV_ID_SHA"; fi
SIGN_OPTS=(--force --options runtime --sign "$SIGN_ID")
[[ "$SIGN_ID" == "-" ]] || SIGN_OPTS+=(--timestamp)   # notarisation needs Apple's secure timestamp
# Inside-out with no --deep: the bundled CLI first, under its own identifier, then the app.
/usr/bin/codesign "${SIGN_OPTS[@]}" --identifier com.juniornkanabassi.CreatorOS.cli "$APP_PATH/Contents/MacOS/creatoros"
# Updates only in a Developer ID build with a real public key. Any other build has no feed, so the app starts no
# updater and shows no Check for Updates item (Updates.swift), and can never replace itself with a release.
PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
if [[ "$SIGN_ID" != "$DEV_ID_SHA" || -z "$PUBLIC_KEY" || "$PUBLIC_KEY" == REPLACE_WITH_* ]]; then
  /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" -c "Delete :SUPublicEDKey" "$APP_PATH/Contents/Info.plist"
  print "Updates off in this build (no Developer ID identity, or SUPublicEDKey is not set)"
fi
# Sparkle's nested code inside-out, as its documentation gives for apps outside the App Store, then the framework.
# The XPC services keep their own entitlements. No --deep on the app: it would re-sign all of this.
SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework"
/usr/bin/codesign "${SIGN_OPTS[@]}" "$SPARKLE/Versions/B/Autoupdate"
/usr/bin/codesign "${SIGN_OPTS[@]}" "$SPARKLE/Versions/B/Updater.app"
for xpc in "$SPARKLE"/Versions/B/XPCServices/*.xpc(N); do
  /usr/bin/codesign "${SIGN_OPTS[@]}" --preserve-metadata=entitlements "$xpc"
done
/usr/bin/codesign "${SIGN_OPTS[@]}" "$SPARKLE"
# Hardened runtime only loads Sparkle when it shares the app's Team ID. A local identity (self-signed or ad hoc) has
# none, so only those builds turn library validation off; Developer ID builds keep it.
ENTITLEMENT_OPTS=()
if [[ "$SIGN_ID" != "$DEV_ID_SHA" ]]; then
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$BUILD_STAGE/local.entitlements" >/dev/null
  ENTITLEMENT_OPTS=(--entitlements "$BUILD_STAGE/local.entitlements")
fi
/usr/bin/codesign "${SIGN_OPTS[@]}" "${ENTITLEMENT_OPTS[@]}" "$APP_PATH"
/usr/bin/codesign --verify --strict "$APP_PATH/Contents/MacOS/creatoros"
/usr/bin/codesign --verify --strict "$APP_PATH"
print "Signed with: $SIGN_ID"
NOTARISED=0
if [[ "$SIGN_ID" != "-" && "${CREATOROS_NOTARISE:-1}" == 1 ]]; then
  /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$BUILD_STAGE/notarise.zip"
  /usr/bin/xcrun notarytool submit "$BUILD_STAGE/notarise.zip" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m | tee "$BUILD_STAGE/notarise.log"
  grep -q "status: Accepted" "$BUILD_STAGE/notarise.log" || { print -u2 "Notarisation was not accepted (see the log above). Work kept at $BUILD_STAGE."; exit 1; }
  /usr/bin/xcrun stapler staple "$APP_PATH"
  /usr/bin/xcrun stapler validate "$APP_PATH"
  /usr/sbin/spctl --assess --type execute -vv "$APP_PATH"
  NOTARISED=1
  print "Notarised and stapled"
fi
mkdir -p "$OUTPUT_ROOT"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
# The website download is a disk image of the same stapled app, signed, notarised and stapled itself.
if (( NOTARISED )); then
  DMG_PATH="$OUTPUT_ROOT/$APP_NAME $APP_VERSION.dmg"
  [[ ! -e "$DMG_PATH" ]] || { /bin/rm -f "$ARCHIVE_PATH"; print -u2 "Refusing to overwrite $DMG_PATH; $ARCHIVE_PATH removed again."; exit 1; }
  DMG_STAGE="$BUILD_STAGE/dmg"
  TMP_DMG="$BUILD_STAGE/$APP_NAME $APP_VERSION.dmg"
  mkdir -p "$DMG_STAGE"
  /usr/bin/ditto "$APP_PATH" "$DMG_STAGE/$APP_NAME.app"
  /bin/ln -s /Applications "$DMG_STAGE/Applications"
  /usr/bin/hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$DMG_STAGE" -format UDZO "$TMP_DMG"
  /usr/bin/codesign --force --timestamp --sign "$SIGN_ID" "$TMP_DMG"
  /usr/bin/xcrun notarytool submit "$TMP_DMG" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m | tee "$BUILD_STAGE/notarise-dmg.log"
  grep -q "status: Accepted" "$BUILD_STAGE/notarise-dmg.log" || { /bin/rm -f "$ARCHIVE_PATH"; print -u2 "Disk image notarisation was not accepted (see the log above); $ARCHIVE_PATH removed again."; exit 1; }
  /usr/bin/xcrun stapler staple "$TMP_DMG"
  /usr/bin/xcrun stapler validate "$TMP_DMG"
  /usr/sbin/spctl -a -vv -t open --context context:primary-signature "$TMP_DMG"
  /bin/cp -n "$TMP_DMG" "$DMG_PATH"
  print "Disk image: ${DMG_PATH:A}"
fi
if (( NOTARISED )); then print "Developer ID signed, notarised and stapled app: ${APP_PATH:A}"
elif [[ "$SIGN_ID" == "-" ]]; then print "Local ad-hoc-signed development app: ${APP_PATH:A}"
else print "Developer ID signed app, not notarised (CREATOROS_NOTARISE=0): ${APP_PATH:A}"; fi
print "Archive for installation outside file-provider folders: ${ARCHIVE_PATH:A}"
