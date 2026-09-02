#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
swift Scripts/render-icon.swift Resources/AppIcon.png
ICON_STAGE=$(mktemp -d /private/tmp/project-templates-icon.XXXXXX)
ICON_SET="$ICON_STAGE/AppIcon.iconset"
mkdir -p "$ICON_SET"
for POINTS in 16 32 128 256 512; do
  sips -z "$POINTS" "$POINTS" Resources/AppIcon.png --out "$ICON_SET/icon_${POINTS}x${POINTS}.png" >/dev/null
  PIXELS=$((POINTS * 2))
  sips -z "$PIXELS" "$PIXELS" Resources/AppIcon.png --out "$ICON_SET/icon_${POINTS}x${POINTS}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_SET" -o Resources/AppIcon.icns
print "Built Resources/AppIcon.icns from the original editable Swift drawing."
