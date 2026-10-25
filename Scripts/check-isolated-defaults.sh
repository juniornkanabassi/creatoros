#!/bin/zsh
# An isolated (--data-directory) launch must write nothing to the app's own defaults domain. AppKit and SwiftUI
# save window and split-view frames there, which for the stable app is Junior's production preferences.
# The check runs a copy of the packaged app under a throwaway bundle identifier, so the domain it inspects is
# disposable and the real com.juniornkanabassi.CreatorOS preferences are never read or written.
# Usage: zsh Scripts/check-isolated-defaults.sh <packaged CreatorOS.app>
set -euo pipefail
app="${1:?usage: check-isolated-defaults.sh <CreatorOS.app>}"
id="local.projecttemplates.isolation-check-$$"
stage=$(mktemp -d /private/tmp/cos-defaults-check.XXXXXX)
root=$(mktemp -d /private/tmp/cos-defaults-root.XXXXXX)
pid=""
cleanup() {
  [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  # Sweep anything still running on this run's own throwaway data directory (never an instance without one).
  for stray in $(/usr/bin/pgrep -f -- "ProjectTemplates --data-directory $root" || true); do kill "$stray" 2>/dev/null || true; done
  for _ in {1..50}; do /usr/bin/pgrep -f -- "ProjectTemplates --data-directory $root" >/dev/null || break; sleep 0.1; done
  defaults delete "$id" >/dev/null 2>&1 || true
  rm -f ~/Library/Preferences/"$id".plist
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
# --display-name runs the test-window positioning path, which moves the window after it opens. Prefer a screen other
# than the one the window opens on, so the move is real; print its name and its top-left-origin rectangle. The app
# picks the first screen with the given name, so only a screen that is the first of its name is a usable target.
target=$(/usr/bin/swift -e '
import AppKit
let screens = NSScreen.screens
let usable = screens.filter { s in screens.first { $0.localizedName == s.localizedName } == s }
let s = usable.first { $0 != NSScreen.main } ?? screens[0], f = s.frame, h = screens[0].frame.height
print("\(Int(f.minX)) \(Int(h - f.maxY)) \(Int(f.maxX)) \(Int(h - f.minY)) \(s.localizedName)")')
display=${target#* * * * }
[[ -n "$display" ]] || { print -u2 "FAIL could not read a display name"; exit 1; }
# A foreground launch and a normal quit, as in real use: SwiftUI saves the frame itself on the way out.
"$stage/CreatorOS.app/Contents/MacOS/ProjectTemplates" --data-directory "$root" --display-name "$display" >/dev/null 2>&1 &
pid=$!
for _ in {1..100}; do [[ -S "$root/control.sock" ]] && break; sleep 0.1; done
[[ -S "$root/control.sock" ]] || { print -u2 "FAIL isolated app did not start"; exit 1; }
type=$(/usr/bin/lsappinfo info -app "$pid" 2>/dev/null | sed -n 's/.*type="\([A-Za-z]*\)".*/\1/p' | head -1)
[[ "$type" == "UIElement" || "$type" == "BackgroundOnly" ]] || { print -u2 "FAIL the isolated app has a Dock tile (ApplicationType=$type)"; exit 1; }
sleep 3   # let the window open, position itself and autosave if it is going to
# The window must have moved onto the target display, or the positioning path was skipped and a PASS proves nothing.
/usr/bin/swift -e '
import CoreGraphics
let a = CommandLine.arguments, pid = Int(a[1])!, r = a[2].split(separator: " ").prefix(4).map { Double($0)! }
let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
let bounds = windows.compactMap { w -> [String: Double]? in
  guard w[kCGWindowOwnerPID as String] as? Int == pid, w[kCGWindowLayer as String] as? Int == 0,
        let b = w[kCGWindowBounds as String] as? [String: Double], b["Width"]! > 500 else { return nil }
  return b
}
if bounds.contains(where: { $0["Width"] == 1111 }) { print("FAIL the test window took the saved production-style frame, so autosave is attached"); exit(1) }
let placed = bounds.contains { b in
  let x = b["X"]! + b["Width"]! / 2, y = b["Y"]! + b["Height"]! / 2
  return x >= r[0] && x <= r[2] && y >= r[1] && y <= r[3]
}
if !placed { print("FAIL the test window was not positioned on the target display"); exit(1) }' "$pid" "$target"
/usr/bin/swift -e 'import AppKit; _ = NSRunningApplication(processIdentifier: pid_t(CommandLine.arguments[1])!)?.terminate()' "$pid"
for _ in {1..100}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$pid" 2>/dev/null && { print -u2 "FAIL isolated app did not quit"; exit 1; }
pid=""
/usr/bin/pgrep -f -- "ProjectTemplates --data-directory $root" >/dev/null && { print -u2 "FAIL a test instance is still running on $root"; exit 1; }
after=$(defaults export "$id" - | plutil -convert json -o - -)
if [[ "$after" != "$seeded" ]]; then
  print -u2 "FAIL isolated launch changed its app defaults domain:"; print -u2 -- "$after" | cut -c1-400; exit 1
fi
print "PASS isolated launch leaves the app defaults domain untouched"
