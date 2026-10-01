import Foundation
import TemplateCore

func securityChecks(base: URL) throws {
    let fm = FileManager.default
    let root = base.appendingPathComponent("Security")
    let oddIcon = root.appendingPathComponent("Icon\r")
    try put(Data("keep".utf8), at: oddIcon.appendingPathComponent("payload.txt"))
    let stripped = try IconService.strip(project: root)
    try check(!stripped.failed.isEmpty && Data(contentsOf: oddIcon.appendingPathComponent("payload.txt")) == Data("keep".utf8), "strip refuses Icon CR directories without removing their contents")
    let source = root.appendingPathComponent("Template")
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    try put(Data(), at: source.appendingPathComponent("Icon\r"))
    let restore = try IconService.restore(template: source, fields: ProjectFields(number: "001", format: "Short", title: "Test"), onto: root)
    try check(!restore.failed.isEmpty && Data(contentsOf: oddIcon.appendingPathComponent("payload.txt")) == Data("keep".utf8), "failed restore keeps an existing Icon CR directory it did not create")
    let runtime = try AppRuntime.production(stableRoot: root.appendingPathComponent("Library"))
    try fm.createDirectory(at: runtime.root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("Destination")
    try fm.createDirectory(at: target, withIntermediateDirectories: true)
    try rejects("drop cannot move library root with a writable parent") { _ = try BrowserTransfer.transfer([runtime.root], into: target, runtime: runtime) }
    try rejects("drop cannot move ancestor of library") { _ = try BrowserTransfer.transfer([root], into: base, runtime: runtime) }
    for suffix in ["terminal", "fileloc", "webloc", "inetloc", "jar", "mobileconfig", "mpkg"] {
        try check(ProjectBrowser.unsafeExtensions.contains(suffix), "browser refuses launchable ." + suffix)
    }
}
