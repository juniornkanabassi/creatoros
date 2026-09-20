#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
build_icon() {
  local INPUT="$1" OUTPUT="$2" ICON_STAGE ICON_SET POINTS PIXELS
  [[ -f "$INPUT" ]] || { print -u2 "$INPUT is missing."; exit 1; }
  ICON_STAGE=$(mktemp -d /private/tmp/project-templates-icon.XXXXXX)
  ICON_SET="$ICON_STAGE/AppIcon.iconset"
  mkdir -p "$ICON_SET"
  for POINTS in 16 32 128 256 512; do
    sips -z "$POINTS" "$POINTS" "$INPUT" --out "$ICON_SET/icon_${POINTS}x${POINTS}.png" >/dev/null
    PIXELS=$((POINTS * 2))
    sips -z "$PIXELS" "$PIXELS" "$INPUT" --out "$ICON_SET/icon_${POINTS}x${POINTS}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICON_SET" -o "$OUTPUT"
}

build_icon Resources/AppIcon.png Resources/AppIcon.icns
build_icon Resources/AppIconAlpha.png Resources/AppIconAlpha.icns
print "Built stable and alpha ICNS files from the checked-in PNG artwork."
