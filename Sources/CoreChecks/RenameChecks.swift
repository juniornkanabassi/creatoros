import Foundation
import Darwin
import TemplateCore

func renameChecks(base: URL, iconData: Data) throws {
    let area = base.appendingPathComponent("Rename")
    let runtime = try AppRuntime(root: area)
    let root = area.appendingPathComponent("001 — Short — Old")
    let bytes = Data("opaque".utf8)
    try put(bytes, at: root.appendingPathComponent("02 Project Files/001 — Short — Old.prproj"))
    try put(bytes, at: root.appendingPathComponent("03 Media/Old.mov"))
    try put(bytes, at: root.appendingPathComponent("Old.rtfd/Old.txt"))
    try put(Data("# 001 — Short — Old\nBody\n".utf8), at: root.appendingPathComponent("01 Documents/Old.md"))
    try put(Data("# 001 — Short — Old\r\nBody mentions 001 — Short — Old\r\n".utf8), at: root.appendingPathComponent("01 Documents/Windows.md"))
    try put(bytes, at: root.appendingPathComponent(".Old"))
    try IconService.apply(iconData, to: root)
    try FinderTags.write([FinderTags.Tag(name: "Keep", colour: .blue)], to: root)
    let tag = try IconService.attribute(FinderTags.attribute, at: root)
    let iconBefore = try IconService.attribute("com.apple.ResourceFork", at: root.appendingPathComponent("Icon\r"))
    let finderBefore = try IconService.attribute("com.apple.FinderInfo", at: root)
    var record = try ProjectRecord(url: root, format: "Short"); record.notes = "keep"; record.pinned = true
    let plan = try ProjectRename.plan(record: record, number: "002", campaign: "", title: "New", updateHeadings: true, runtime: runtime)
    try check(plan.changes.last?.path == "" && plan.changes.first?.heading == true, "rename heading first and project last")
    let result = try ProjectRename.apply(plan, runtime: runtime)
    try check(Data(contentsOf: result.newRoot.appendingPathComponent("02 Project Files/002 — Short — New.prproj")) == bytes, "rename preserves opaque bytes")
    try check(Data(contentsOf: result.newRoot.appendingPathComponent("03 Media/Old.mov")) == bytes && Data(contentsOf: result.newRoot.appendingPathComponent("New.rtfd/Old.txt")) == bytes, "rename excludes media and package internals")
    try check(String(contentsOf: result.newRoot.appendingPathComponent("01 Documents/New.md"), encoding: .utf8) == "# 002 — Short — New\nBody\n", "rename optional first heading only")
    try check(try Data(contentsOf: result.newRoot.appendingPathComponent("01 Documents/Windows.md")) == Data("# 002 — Short — New\r\nBody mentions 001 — Short — Old\r\n".utf8), "rename CRLF heading preserves body bytes")
    try check(IconService.attribute("com.apple.ResourceFork", at: result.newRoot.appendingPathComponent("Icon\r")) == iconBefore && IconService.attribute("com.apple.FinderInfo", at: result.newRoot) == finderBefore && IconService.attribute("com.apple.metadata:_kMDItemUserTags", at: result.newRoot) == tag, "rename preserves Finder icons and unrelated tags")
    try check(FileManager.default.fileExists(atPath: result.manifest.path), "rename manifest exists")
    try record.relocate(to: result.newRoot)
    try check(record.notes == "keep" && record.isPinned && record.previousPaths?.contains(root.path) == true, "rename record relocation retains metadata and old path")
    try ProjectRename.revert(result)
    try check(Data(contentsOf: root.appendingPathComponent("02 Project Files/001 — Short — Old.prproj")) == bytes && String(contentsOf: root.appendingPathComponent("01 Documents/Old.md"), encoding: .utf8).hasPrefix("# 001 — Short — Old"), "rename revert restores names and headings")
    let original = try ProjectRecord(url: root, format: "Short")
    try rejects("rename case-only refused") { _ = try ProjectRename.plan(record: original, number: "001", campaign: "", title: "OLD", runtime: runtime) }
    try rejects("rename case-only child refused before moving") { _ = try ProjectRename.plan(record: original, number: "002", campaign: "", title: "OLD", runtime: runtime) }
    try rejects("rename unsafe name refused") { _ = try ProjectRename.plan(record: original, number: "001", campaign: "", title: "CON", runtime: runtime) }
    try put(bytes, at: root.appendingPathComponent("New.md"))
    try put(bytes, at: root.appendingPathComponent("Old.md"))
    try rejects("rename collision refused") { _ = try ProjectRename.plan(record: original, number: "002", campaign: "", title: "New", runtime: runtime) }
    try FileManager.default.removeItem(at: root.appendingPathComponent("New.md"))
    let locked = root.appendingPathComponent("Old locked.txt")
    try put(bytes, at: locked)
    let rollbackPlan = try ProjectRename.plan(record: original, number: "002", campaign: "", title: "New", updateHeadings: true, runtime: runtime)
    guard chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0 else { throw AppFailure("Cannot prepare locked-file rollback check.") }
    defer { _ = chflags(locked.path, 0) }
    try rejects("rename mid-way failure rolls back") { _ = try ProjectRename.apply(rollbackPlan, runtime: runtime) }
    try check(Data(contentsOf: root.appendingPathComponent("02 Project Files/001 — Short — Old.prproj")) == bytes && String(contentsOf: root.appendingPathComponent("01 Documents/Old.md"), encoding: .utf8).hasPrefix("# 001 — Short — Old"), "rename forced rollback restores earlier names and heading")
    guard chflags(locked.path, 0) == 0 else { throw AppFailure("Cannot unlock fixture.") }
    let stale = try ProjectRename.plan(record: original, number: "002", campaign: "", title: "New", runtime: runtime)
    try put(bytes, at: root.appendingPathComponent("Old extra.txt"))
    try rejects("rename stale reviewed list refused") { _ = try ProjectRename.apply(stale, runtime: runtime) }
    try check(FileManager.default.fileExists(atPath: root.path), "rename stale plan leaves original root")
}
