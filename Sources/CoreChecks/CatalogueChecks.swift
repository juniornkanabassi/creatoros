import Foundation
import AppKit
import TemplateCore

func catalogueChecks(base: URL) throws {
    let base = base.resolvingSymlinksInPath()
    let fm = FileManager.default
    let collection = base.appendingPathComponent("Catalogue collection")
    let root = collection.appendingPathComponent("01 Longs/019 — Long — Original title")
    try put(Data("video fixture, not a real movie".utf8), at: root.appendingPathComponent("04 Exports/01 Video/Final.mp4"))
    try put(Data(), at: root.appendingPathComponent("01 Documents/notes.txt"))
    try put(Data(), at: root.appendingPathComponent("03 Media/raw.mov"))
    try put(Data(), at: root.appendingPathComponent("04 Exports/Project.rtfd/internal.mp4"))
    try put(Data(), at: root.appendingPathComponent("Review Deliveries/custom.mov"))
    try fm.createSymbolicLink(at: root.appendingPathComponent("04 Exports/outside"), withDestinationURL: base)
    let legacy = collection.appendingPathComponent("Legacy podcast")
    try put(Data(), at: legacy.appendingPathComponent("edit/file.prproj"))
    try put(Data(), at: legacy.appendingPathComponent("assets/readme.txt"))
    try put(Data(), at: legacy.appendingPathComponent("Deliverables/Episode.MOV"))
    try put(Data(), at: collection.appendingPathComponent("Raw Footage/not a project.mov"))
    let discovered = try Catalogue.discover(root: collection)
    try check(discovered.projects.count == 2, "catalogue recognises numbered and legacy structures")
    var record = try discovered.projects.first { URL(fileURLWithPath: $0.path).lastPathComponent == root.lastPathComponent }.unwrap("Missing fixture project \(root.path); found \(discovered.projects.map(\.path))")
    try check(record.format == "Long", "catalogue infers format from path")
    try check(record.exports?.map(\.relativePath) == ["04 Exports/01 Video/Final.mp4"], "catalogue excludes raw footage, packages and symlinks")
    try check(record.finalExportPath == nil, "filename Final never automatically approves an export")
    try check(record.scanNotes?.contains(where: { $0.contains("symbolic link") }) == true, "catalogue reports skipped links")
    try check(discovered.projects.first { $0.format == "Podcast" }?.exports?.count == 1, "catalogue indexes legacy deliverables case-insensitively")
    record.exportFolders = ["Review Deliveries"]
    record = try Catalogue.indexExports(record, root: root)
    try check(record.exports?.count == 2, "custom export subfolder is indexed")
    record.finalExportPath = "Review Deliveries/custom.mov"
    try check(record.markedFinals == ["Review Deliveries/custom.mov"], "legacy single final selection is retained")
    record.finalExportPaths = ["Review Deliveries/custom.mov", "04 Exports/01 Video/Final.mp4"]
    try check(record.markedFinals.count == 2, "multiple approved finals can coexist in one project")
    record.previousPaths = ["/Volumes/Previous Drive/Old Project"]
    let id = record.id
    var merged = Catalogue.merge(discovered.projects, into: [record])
    try check(merged.count == 2 && merged.first?.id == id, "rescan deduplicates without replacing record identity")
    try check(merged.first?.finalExportPath == record.finalExportPath && merged.first?.previousPaths == record.previousPaths, "rescan preserves final choice and location history")
    try check(merged.first?.markedFinals == record.markedFinals, "rescan preserves multiple final choices")
    try check(merged.first?.exports?.count == 2, "collection scan preserves custom export index")
    merged = Catalogue.merge([], into: merged)
    try check(merged.count == 2, "empty or disconnected collection does not delete catalogue")
    try check(record.searchableText.contains("Previous Drive") && !record.searchableText.contains("custom.mov"), "search includes previous locations but not the retired export index")
    let moved = collection.appendingPathComponent("Moved Long project")
    try fm.moveItem(at: root, to: moved)
    try record.relocate(to: moved)
    try check(record.id == id && record.previousPaths?.contains(where: { $0.hasSuffix(root.lastPathComponent) }) == true, "locating moved folder preserves identity and records old path")
    try check(record.finalExportPath == "Review Deliveries/custom.mov", "relative final reference survives relocation")
    let inspected = Catalogue.inspect(record)
    try check(inspected.available && inspected.record.exports?.count == 2, "relocated project resolves and refreshes exports")
    record.bookmark = nil; record.path = "/Volumes/ProjectTemplates-Unmounted-Fixture/project"
    record.volumePath = "/Volumes/ProjectTemplates-Unmounted-Fixture"
    record.volumeName = "Test offline drive"
    let offline = Catalogue.inspect(record)
    try check(!offline.available && offline.status.contains("Drive unavailable"), "offline drive has an explicit reconnect state")
    try check(offline.record.exports == record.exports && offline.record.finalExportPath == record.finalExportPath, "offline inspection preserves cached exports and final")
    try check(offline.record.markedFinals == record.markedFinals, "offline inspection preserves multiple finals")
    for relative in ["../outside.mp4", "/tmp/outside.mp4", "a//b", "a/./b", "04 Exports/outside/file.mp4"] {
        try rejects("unsafe export reference \(relative)") { _ = try Catalogue.safeChild(relative, under: moved) }
    }
    let cancel = Cancellation(); cancel.cancel()
    try rejects("catalogue scan is cancellable") { _ = try Catalogue.discover(root: collection, cancellation: cancel) }
    let migration = LibraryStore(root: base.appendingPathComponent("Schema migration"))
    var old = Library(); old.schema = 1; old.projects = [record]
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
    json.removeValue(forKey: "locations")
    var projects = json["projects"] as! [[String: Any]]
    for key in ["previousPaths", "exports", "exportFolders", "finalExportPath", "finalExportPaths", "lastIndexed", "volumeName", "volumeID", "volumePath", "scanNotes"] { projects[0].removeValue(forKey: key) }
    json["projects"] = projects
    let original = try JSONSerialization.data(withJSONObject: json)
    try put(original, at: migration.file)
    let migrated = try migration.load()
    try check(migrated.schema == Library.currentSchema && migrated.projects.first?.exports == nil && migrated.sets.isEmpty, "schema-one library decodes without new optional fields")
    try migration.save(migrated)
    try check(Data(contentsOf: migration.root.appendingPathComponent("library-before-schema-2.json")) == original, "schema migration preserves byte-exact original backup")
    try migration.save(migrated)
    try check(Data(contentsOf: migration.root.appendingPathComponent("library-before-schema-2.json")) == original, "later saves do not overwrite migration backup")
    let iconFolder = base.appendingPathComponent("Icon project")
    try fm.createDirectory(at: iconFolder, withIntermediateDirectories: true)
    try rejects("fixed icon capture rejects a generic uncustomised folder") { _ = try IconService.captureFolderIcon(iconFolder) }
    let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in NSColor.systemRed.setFill(); rect.fill(); return true }
    try IconService.apply(image.tiffRepresentation!, to: iconFolder)
    let captured = try IconService.captureFolderIcon(iconFolder)
    try check(NSImage(data: captured) != nil, "existing custom Finder icon captured as standalone image")
    let formatTemplate = base.appendingPathComponent("Format template")
    try put(Data("unchanged document contents".utf8), at: formatTemplate.appendingPathComponent("Template/Template.prproj"))
    let formatDestination = base.appendingPathComponent("Format output")
    try fm.createDirectory(at: formatDestination, withIntermediateDirectories: true)
    for format in ["Long", "Short", "Podcast", "Livestream"] {
        let fields = ProjectFields(number: "003", format: format, campaign: "Series", title: "Episode")
        let name = try fields.finalName()
        let plan = try TemplateReader.scan(formatTemplate, fields: fields)
        let output = try CreationEngine.create(plan: plan, destination: formatDestination, name: name, icon: captured)
        try check(name == "003 — \(format) — Series — Episode", "\(format) matches Post Haste field order")
        try check(Data(contentsOf: output.appendingPathComponent("\(name)/\(name).prproj")) == Data("unchanged document contents".utf8), "\(format) renames template folder and file, preserves contents")
        try check(((IconService.attribute("com.apple.FinderInfo", at: output)?[8] ?? 0) & 0x04) != 0, "\(format) applies saved outer folder icon")
    }
}

private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw AppFailure(message) }
        return value
    }
}
