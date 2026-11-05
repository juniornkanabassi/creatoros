#!/bin/zsh
# Render only hidden app content, on disposable data. Never opens, orders or activates a window.
set -euo pipefail
cd "${0:A:h:h}"
build_root=${1:-/private/tmp/bama/build-creatoros}
output=${2:-$build_root/snapshots}
mkdir -p "$build_root" "$output"
export CONTENT_TEMPLATE_CHECK_ROOT="$build_root"
export CONTENT_TEMPLATE_CHECK_SOURCE=Scripts/check-snapshots.swift
export SNAPSHOT_OUTPUT="$output"
export APP_SNAPSHOT=1
zsh Scripts/check-durable-save.sh "$build_root"
print "Content-only snapshots: $output"
print "Window compositing, focus and native gestures remain unverified."
