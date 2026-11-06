// Read-only 0.2-second sampler. Executable identities catch test apps even after their launchers exit.
import AppKit
import CoreGraphics
import Darwin

let runner = pid_t(CommandLine.arguments[1])!
let stop = CommandLine.arguments[2]
let report = CommandLine.arguments[3]
let sourceRoot = URL(fileURLWithPath: CommandLine.arguments[4]).resolvingSymlinksInPath().path + "/"
func processes() -> [pid_t] {
    var ids = [pid_t](repeating: 0, count: 32768)
    let count = proc_listallpids(&ids, Int32(ids.count * MemoryLayout<pid_t>.size))
    return Array(ids.prefix(max(0, Int(count)))).filter { $0 > 0 }
}
func executable(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
}
func windows() -> [[String: Any]] {
    guard let result = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
        fatalError("Cannot read the on-screen window list")
    }
    return result.filter { ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0 }
}
func identity(_ window: [String: Any]) -> String {
    "\(window[kCGWindowOwnerPID as String] ?? -1):\(window[kCGWindowNumber as String] ?? -1)"
}
let existingPIDs = Set(processes())
let baselineWindows = Set(windows().map(identity))
let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
var owned: Set<pid_t> = [runner]
var samples = 0
var visible: [[String: Any]] = []
var other: [[String: Any]] = []
var focus: [[String: Any]] = []
func sample() {
    samples += 1
    var parents: [pid_t: pid_t] = [:]
    for pid in processes() {
        var info = proc_bsdinfo()
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 {
            parents[pid] = pid_t(info.pbi_ppid)
        }
        if !existingPIDs.contains(pid) {
            let path = executable(pid), name = (path as NSString).lastPathComponent
            if ["ProjectTemplates", "CoreChecks", "xctest", "CreatorOSTests"].contains(name)
                || path.hasPrefix(sourceRoot) || path.hasPrefix("/private/tmp/creatoros-durable-check.") {
                owned.insert(pid)
            }
        }
    }
    var added = true
    while added {
        added = false
        for (pid, parent) in parents where owned.contains(parent) && !owned.contains(pid) {
            owned.insert(pid); added = true
        }
    }
    for window in windows() {
        let pid = pid_t(window[kCGWindowOwnerPID as String] as? Int ?? -1)
        let row: [String: Any] = ["sample": samples, "pid": Int(pid), "owner": window[kCGWindowOwnerName as String] ?? "",
                                  "alpha": window[kCGWindowAlpha as String] ?? 1, "window": window[kCGWindowNumber as String] ?? -1]
        if owned.contains(pid) { visible.append(row) }
        else if !baselineWindows.contains(identity(window)) { other.append(row) }
    }
    let current = NSWorkspace.shared.frontmostApplication?.processIdentifier
    if current != frontmost {
        focus.append(["sample": samples, "pid": current.map(Int.init) ?? -1, "owned": current.map { owned.contains($0) } ?? false])
    }
}
sample()
print("READY"); fflush(stdout)
while !FileManager.default.fileExists(atPath: stop) {
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    sample()
}
let result: [String: Any] = ["samples": samples, "intervalSeconds": 0.2, "runnerPID": Int(runner),
                           "trackedPIDs": owned.sorted(), "baselineFrontmostPID": frontmost.map(Int.init) ?? -1,
                           "windowsSeen": visible.count, "focusChanges": focus.count,
                           "ownedFocusChanges": focus.filter { $0["owned"] as? Bool == true }.count,
                           "visibleWindows": visible, "frontmostChanges": focus, "unrelatedNewWindows": other]
try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: report))
print("WINDOWS \(visible.count) FOCUS_CHANGES \(focus.count) SAMPLES \(samples)")
exit(visible.isEmpty && focus.isEmpty && frontmost != nil ? 0 : 1)
