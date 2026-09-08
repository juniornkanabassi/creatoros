#!/bin/zsh
set -euo pipefail
SOURCE_ROOT="${0:A:h}"
OUTPUT_ROOT="${CONTENT_TEMPLATE_OUTPUT_ROOT:-$SOURCE_ROOT/../Outputs}"
INSTALL_ROOT="${CONTENT_TEMPLATE_INSTALL_ROOT:-/Applications}"
APP_NAME=$(/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' "$SOURCE_ROOT/Resources/Info.plist")
APP_CHANNEL=$(/usr/libexec/PlistBuddy -c 'Print CreatorOSChannel' "$SOURCE_ROOT/Resources/Info.plist")
DEST="$INSTALL_ROOT/$APP_NAME.app"
ARCHIVE="${1:-}"
EXPECTED_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SOURCE_ROOT/Resources/Info.plist")
EXPECTED_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SOURCE_ROOT/Resources/Info.plist")
[[ "$EXPECTED_ID" == "local.creatoros.alpha" && "$APP_NAME" == "CreatorOS Alpha" ]] || { print -u2 "This installer only installs CreatorOS Alpha; the stable app is protected."; exit 1; }
if (( $# > 1 )); then print -u2 "Usage: zsh install.sh [CreatorOS Alpha <version> α.zip]"; exit 2; fi
if [[ -z "$ARCHIVE" ]]; then ARCHIVE="$OUTPUT_ROOT/$APP_NAME $EXPECTED_VERSION $APP_CHANNEL.zip"; fi
[[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] || { print -u2 "No CreatorOS Alpha archive found. Pass a ZIP path or run build.sh first."; exit 1; }
for APP_PID in ${(f)$(pgrep -x ProjectTemplates || true)}; do
  if [[ "$(ps -p "$APP_PID" -o comm=)" == "$DEST/Contents/MacOS/ProjectTemplates" ]]; then print -u2 "CreatorOS Alpha is running. Quit it before installing; this installer will not kill it."; exit 1; fi
done
mkdir -p "$INSTALL_ROOT"
[[ ! -L "$DEST" ]] || { print -u2 "Refusing to replace symlink $DEST."; exit 1; }
WORK=$(mktemp -d "$INSTALL_ROOT/.content-template-install.XXXXXX")
STAGE="$WORK/$APP_NAME.app"; BACKUP="$INSTALL_ROOT/.$APP_NAME.app.previous.$RANDOM"
cleanup() { rm -rf "$WORK"; }; trap cleanup EXIT
/usr/bin/ditto -x -k --sequesterRsrc "$ARCHIVE" "$WORK"
[[ -d "$STAGE" ]] || { print -u2 "Archive does not contain $APP_NAME.app at its root."; exit 1; }
ACTUAL_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$STAGE/Contents/Info.plist")
ACTUAL_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$STAGE/Contents/Info.plist")
[[ "$ACTUAL_ID" == "$EXPECTED_ID" ]] || { print -u2 "Bundle identifier mismatch: $ACTUAL_ID"; exit 1; }
[[ "$ACTUAL_VERSION" == "$EXPECTED_VERSION" ]] || { print -u2 "Archive version $ACTUAL_VERSION does not match source version $EXPECTED_VERSION."; exit 1; }
/usr/bin/codesign --verify --strict "$STAGE"
if [[ -e "$DEST" ]]; then /bin/mv "$DEST" "$BACKUP"; fi
if ! /bin/mv "$STAGE" "$DEST"; then
  if [[ -e "$BACKUP" ]] && /bin/mv "$BACKUP" "$DEST"; then print -u2 "Could not install $DEST; the previous app was restored."; else print -u2 "Could not install $DEST and could not restore the previous app. It remains at $BACKUP."; fi
  exit 1
fi
if ! /usr/bin/codesign --verify --strict "$DEST"; then
  /bin/rm -rf "$DEST"
  if [[ -e "$BACKUP" ]] && /bin/mv "$BACKUP" "$DEST"; then print -u2 "Installed signature verification failed; the previous app was restored."; else print -u2 "Installed signature verification failed and the previous app could not be restored. It remains at $BACKUP."; fi
  exit 1
fi
if [[ -e "$BACKUP" ]]; then /bin/rm -rf "$BACKUP"; fi
print "Installed $APP_NAME $ACTUAL_VERSION $APP_CHANNEL at $DEST"
