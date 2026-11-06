#!/bin/zsh
# An isolated (--data-directory) launch must write nothing to the app's own defaults domain. AppKit and SwiftUI
# save window and split-view frames there, which for the stable app is Junior's production preferences.
# The check runs a copy of the packaged app under a throwaway bundle identifier, so the domain it inspects is
# disposable and the real com.juniornkanabassi.CreatorOS preferences are never read or written.
# Both variants run with --agent-screen --background, so nothing appears on screen or takes focus.
# Usage: zsh Scripts/check-isolated-defaults.sh <packaged CreatorOS.app> [--headless]
set -euo pipefail
app="${1:?usage: check-isolated-defaults.sh <CreatorOS.app> [--headless]}"
headless=${2:-}
[[ -z "$headless" || "$headless" == --headless ]] || { print -u2 "Unknown option: $headless"; exit 1; }
id="local.projecttemplates.isolation-check-$$"
stage=$(mktemp -d /private/tmp/cos-defaults-check.XXXXXX)
root=$(mktemp -d /private/tmp/cos-defaults-root.XXXXXX)
# The isolated launch keeps its interface state in this root's own suite (AppRuntime.defaultsSuite); removed in cleanup.
suite=local.creatoros.alpha.$(print -rn -- "$root" | /usr/bin/base64)
pid=""
cleanup() {
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || true
    for _ in {1..50}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
    for _ in {1..50}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then
      print -u2 "FAIL child $pid is still alive; retaining preferences and fixtures at $root and $stage"
      return 1
    fi
    wait "$pid" 2>/dev/null || true
  fi
  defaults delete "$id" >/dev/null 2>&1 || true
  rm -f ~/Library/Preferences/"$id".plist
  /usr/bin/defaults delete "$suite" >/dev/null 2>&1 || true
  rm -f ~/Library/Preferences/"$suite".plist
  rm -rf "$stage" "$root"
}
trap cleanup EXIT
/usr/bin/ditto "$app" "$stage/CreatorOS.app"
/usr/libexec/PlistBuddy -c "Set CFBundleIdentifier $id" "$stage/CreatorOS.app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$stage/CreatorOS.app" >/dev/null 2>&1
# Seed a saved main-window frame of a size nothing else uses, as Junior's real preferences have one. An isolated window
# that adopts it has autosave attached, and AppKit will later write the frame back, so the check fails on it.
frame_key='NSWindow Frame SwiftUI.WindowGroup<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<ProjectTemplates.MainView, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<ProjectTemplates.AppModel>>>, SwiftUI._FlexFrameLayout>, SwiftUI._AppearanceActionModifier>>-1-AppWindow-1'
defaults write "$id" "$frame_key" "100 100 1111 777 0 0 1512 900 "
seeded=$(defaults export "$id" - | plutil -convert json -o - -)
# A windowed launch and a normal quit, as in real use: SwiftUI saves the frame itself on the way out. --agent-screen keeps
# that window ordered in but transparent and click-through, and --background keeps focus where it is.
launch_flags=(--agent-screen --background)
variant=windowed
[[ "$headless" != --headless ]] || { launch_flags+=(--headless); variant=headless; }
"$stage/CreatorOS.app/Contents/MacOS/ProjectTemplates" "${launch_flags[@]}" --data-directory "$root" >/dev/null 2>&1 &
pid=$!
for _ in {1..100}; do [[ -S "$root/control.sock" ]] && break; sleep 0.1; done
[[ -S "$root/control.sock" ]] || { print -u2 "FAIL isolated app did not start"; exit 1; }
type=$(/usr/bin/lsappinfo info -app "$pid" 2>/dev/null | sed -n 's/.*type="\([A-Za-z]*\)".*/\1/p' | head -1)
[[ "$type" == "UIElement" || "$type" == "BackgroundOnly" ]] || { print -u2 "FAIL the isolated app has a Dock tile (ApplicationType=$type)"; exit 1; }
sleep 3   # let the window open and autosave if it is going to
# No window may be visible, and the main window must not have adopted the seeded frame. The windowed variant must have
# its main window ordered in, or the frame check proves nothing.
/usr/bin/swift -e '
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!, windowed = CommandLine.arguments[2] == "windowed"
let windows = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
  .filter { $0[kCGWindowOwnerPID as String] as? Int == pid }
if windows.contains(where: { ($0[kCGWindowIsOnscreen as String] as? Bool ?? false) && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0 }) {
  print("FAIL the isolation check showed a window"); exit(1)
}
let bounds = windows.compactMap { w -> [String: Double]? in
  guard w[kCGWindowLayer as String] as? Int == 0, let b = w[kCGWindowBounds as String] as? [String: Double], b["Width"]! > 500 else { return nil }
  return b
}
if bounds.contains(where: { $0["Width"] == 1111 }) { print("FAIL the test window took the saved production-style frame, so autosave is attached"); exit(1) }
if windowed && bounds.isEmpty { print("FAIL the windowed isolation check has no main window, so the frame check proves nothing"); exit(1) }' "$pid" "$variant"
print "PASS isolated launch showed no window and refused the saved frame"
/usr/bin/swift -e 'import AppKit; _ = NSRunningApplication(processIdentifier: pid_t(CommandLine.arguments[1])!)?.terminate()' "$pid"
for _ in {1..100}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$pid" 2>/dev/null && { print -u2 "FAIL isolated app did not quit"; exit 1; }
pid=""
after=$(defaults export "$id" - | plutil -convert json -o - -)
if [[ "$after" != "$seeded" ]]; then
  print -u2 "FAIL isolated launch changed its app defaults domain:"; print -u2 -- "$after" | cut -c1-400; exit 1
fi
print "PASS isolated launch leaves the app defaults domain untouched"
