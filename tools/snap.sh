#!/bin/zsh
# Render hidden content on disposable data, then fail on missing states or layout defects.
set -euo pipefail
cd "${0:A:h:h}"
build_root=${1:-/private/tmp/bama/build-creatoros}
output=${2:-$build_root/snapshots}
mkdir -p "$build_root" "$output"
build_root=${build_root:A}
output=${output:A}
home_dir=$(mktemp -d /private/tmp/creatoros-snapshot-home.XXXXXX)
trap 'rm -rf "$home_dir"' EXIT
export CREATOROS_TEST_HOME="$home_dir" CFFIXED_USER_HOME="$home_dir"
mkdir -p "$CREATOROS_TEST_HOME/Library/Preferences"
export CONTENT_TEMPLATE_CHECK_ROOT="$build_root"
export CONTENT_TEMPLATE_CHECK_SOURCE=Scripts/check-snapshots.swift
export SNAPSHOT_OUTPUT="$output"
export APP_SNAPSHOT=1
export CREATOROS_AGENT_SCREEN=1
started=$(date +%s)
zsh Scripts/check-durable-save.sh "$build_root"
# A stale PNG must not make a missing capture look successful. Every named surface needs
# a fresh, non-empty light/dark PNG and matching layout file; the two palettes must differ.
python3 - "$output" "$started" <<'PY'
import pathlib, sys
root, started = pathlib.Path(sys.argv[1]), int(sys.argv[2])
surfaces = ['projects', 'pipeline', 'pipeline-live', 'templates',
            'settings-formats', 'settings-naming', 'settings-pipeline', 'settings-locations',
            'about', 'new-project', 'browser-icon', 'browser-list', 'browser-column', 'projects-error',
            'projects-empty', 'pipeline-empty', 'pipeline-live-empty', 'templates-empty']
for name in surfaces:
    images = []
    for mode in ('light', 'dark'):
        for suffix in ('.png', '-layout.json'):
            path = root / (name + '-' + mode + suffix)
            assert path.is_file() and path.stat().st_size > 0, 'Missing snapshot artifact: ' + str(path)
            assert path.stat().st_mtime >= started, 'Stale snapshot artifact: ' + str(path)
        images.append((root / (name + '-' + mode + '.png')).read_bytes())
        assert images[-1].startswith(b'\x89PNG\r\n\x1a\n'), 'Invalid PNG: ' + name
    assert images[0] != images[1], 'Light and dark captures are identical: ' + name
print('PASS complete fresh light/dark coverage:', len(surfaces) * 2, 'snapshots')
PY
zsh tools/grid-lint.sh
swift tools/check-layout.swift "$output"/*-layout.json
print "Content-only snapshots and layout checks passed: $output"
print "Window compositing, focus and native gestures remain unverified."
