#!/bin/zsh
# Normal local gate: zsh test.sh <built CreatorOS.app> <matching archive.zip>
# CI source-only gate: zsh test.sh --source-only
set -euo pipefail
cd "${0:A:h}"
source_only=0
if [[ ${1:-} == --source-only ]]; then source_only=1; shift; fi
if (( source_only )); then
    (( $# == 0 )) || { print -u2 'Usage: zsh test.sh --source-only'; exit 2; }
else
    (( $# == 2 )) || { print -u2 'Usage: zsh test.sh <built CreatorOS.app> <matching archive.zip>'; exit 2; }
    app=${1:A}; archive=${2:A}
    [[ -d "$app" && -f "$archive" && "$app" != /Applications/* ]] || {
        print -u2 'Use a disposable built app and its archive, never an installed app.'; exit 2;
    }
fi
work=$(mktemp -d /private/tmp/creatoros-test.XXXXXX)
trap 'rm -rf "$work"' EXIT
build=${CREATOROS_TEST_SCRATCH:-$work/build}
mkdir -p "$build"
build=${build:A}
keep_snapshots=${+SNAPSHOT_OUTPUT}
output=${SNAPSHOT_OUTPUT:-$work/snapshots}
mkdir -p "$output"
output=${output:A}
step() { print "CHECK $1"; shift; "$@"; }
# Resolve and compile before isolating Foundation home; no application is launched by a build.
step 'Build all debug targets and tests' swift build --scratch-path "$build" --build-tests
bin=$(swift build --scratch-path "$build" --show-bin-path)
objects="$build"
[[ ! -d "$bin/TemplateCore.build" ]] || objects="$bin"
export PYTHONDONTWRITEBYTECODE=1
export CREATOROS_TEST_HOME="$work/home" CFFIXED_USER_HOME="$work/home"
mkdir -p "$CREATOROS_TEST_HOME/Library/Preferences" "$work/harness"
export CREATOROS_AGENT_SCREEN=1 CONTENT_TEMPLATE_CHECK_ROOT="$work/harness"
step 'SwiftPM offscreen regression' swift test --scratch-path "$build" --skip-build
step 'CoreChecks' "$bin/CoreChecks"
step 'Durable save and native providers' zsh Scripts/check-durable-save.sh "$objects"
if (( source_only )); then
    step 'AppModel and control actions' env CONTENT_TEMPLATE_CHECK_SOURCE=Scripts/check-control-model.swift zsh Scripts/check-durable-save.sh "$objects"
    step 'Invisible launch isolation' python3 Scripts/check-invisible-launch.py "$bin"
else
    step 'Control socket and AppModel' python3 Scripts/check-control.py "$app" "$build"
    step 'Packaged CLI and MCP' python3 Scripts/check-ai-control.py "$app"
    step 'Unbundled CLI and MCP' python3 Scripts/check-ai-control.py "$bin/ProjectTemplates"
    step 'Headless and invisible reveal' python3 Scripts/check-headless.py "$app"
    step 'Invisible launch isolation' python3 Scripts/check-invisible-launch.py "$app"
    step 'Isolated defaults ordinary launch' zsh Scripts/check-isolated-defaults.sh "$app"
    step 'Isolated defaults headless launch' zsh Scripts/check-isolated-defaults.sh "$app" --headless
fi
step 'Failed isolation cleanup' python3 Scripts/test-isolation-cleanup.py
step 'Preferences cleanup' python3 Scripts/instances.py
step 'Backup unit suite' python3 -B -m unittest discover -s Scripts -p test_notion_backup.py
step 'Backup security' python3 Scripts/check-backup-security.py
step 'Offscreen snapshots, grid and layout' zsh tools/snap.sh "$objects" "$output"
if (( ! source_only )); then
    step 'Packaged signature' codesign --verify --deep --strict "$app"
    export CONTENT_TEMPLATE_INSTALL_ROOT="$work/install"
    step 'Fresh disposable install' zsh install.sh "$archive"
    step 'Replacement disposable install' zsh install.sh "$archive"
fi
print 'RESULT ALL CHECK GROUPS PASSED'
if (( keep_snapshots )); then print "Snapshots: $output"
else print 'Temporary snapshots verified and removed on exit.'; fi
