import Foundation
import TemplateCore

func relinkChecks(base: URL) throws {
    let fm = FileManager.default
    let oldRoot = base.appendingPathComponent("Relink/Old drive/01 Video Project Archive/01 Recordings/01 Longs")
    let folder = oldRoot.appendingPathComponent("231 — Long — Moved project")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    var record = try ProjectRecord(url: folder, format: "Long")
    try check(record.folderCreated != nil && record.effectiveDate == record.folderCreated, "registration captures the folder creation date")
    try check(!record.isPinned, "records start unpinned")
    record.pinned = true
    try check(record.isPinned, "pin flag reads back")
    let newRoot = base.appendingPathComponent("Relink/New drive/Archive")
    let moved = newRoot.appendingPathComponent("01 Longs/231 — Long — Moved project")
    try fm.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.moveItem(at: folder, to: moved)
    try check(Relinker.candidates(for: record, roots: []).isEmpty, "no roots means no guessing")
    let candidates = Relinker.candidates(for: record, roots: [newRoot])
    try check(candidates.map(\.path) == [moved.resolvingSymlinksInPath().path], "moved folder is found by name under a known root")
    let decoy = newRoot.appendingPathComponent("03 Media/231 — Long — Moved project")
    try fm.createDirectory(at: decoy, withIntermediateDirectories: true)
    try check(Relinker.candidates(for: record, roots: [newRoot]).count == 1, "media folders are skipped during the search")
    try fm.createSymbolicLink(at: newRoot.appendingPathComponent("link"), withDestinationURL: moved)
    try check(Relinker.candidates(for: record, roots: [newRoot]).count == 1, "symbolic links are not offered as candidates")
    try record.relocate(to: candidates[0])
    try check(record.path == candidates[0].path && record.previousPaths?.first?.hasSuffix("01 Longs/231 — Long — Moved project") == true && record.folderCreated != nil, "relinking records the old path and keeps the creation date")
    let cancelled = Cancellation(); cancelled.cancel()
    try check(Relinker.candidates(for: record, roots: [newRoot], cancellation: cancelled).isEmpty, "pre-cancellation stops direct candidates as well as the walk")
    let otherRoot = base.appendingPathComponent("Relink/Depth check")
    let depthFour = otherRoot.appendingPathComponent("a/b/c/" + record.name)
    try fm.createDirectory(at: depthFour, withIntermediateDirectories: true)
    try check(Relinker.candidates(for: record, roots: [otherRoot]).count == 1, "search includes folders exactly at the depth limit")
}
