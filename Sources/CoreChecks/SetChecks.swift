import Foundation
import TemplateCore

func setChecks(base: URL) throws {
    let fm = FileManager.default
    let store = LibraryStore(root: base.appendingPathComponent("Sets library"))
    // A schema-2 document exactly as 0.3.0 wrote it: no templateSets key at all.
    var legacy = Library(); legacy.schema = 2; legacy.templateSets = nil
    let payload = base.appendingPathComponent("Set payload")
    try put(Data("doc".utf8), at: payload.appendingPathComponent("Template.prproj"))
    let record = try store.importTemplate(plan: TemplateReader.scan(payload), name: "Legacy master", mode: .full, cancellation: Cancellation())
    legacy.templates = [record]
    legacy.projects = [try ProjectRecord(url: payload, format: "Long")]
    legacy.projects[0].exports = [ExportRecord(relativePath: "04 Exports/final.mp4", bytes: 12, modified: nil)]
    legacy.projects[0].finalExportPaths = ["04 Exports/final.mp4"]
    legacy.presets[1].icon = Data([1, 2, 3])
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let original = try encoder.encode(legacy)
    try put(original, at: store.file)
    var loaded = try store.load()
    try check(loaded.schema == Library.currentSchema && loaded.sets.isEmpty, "schema-two library loads as the current schema with no sets")
    try check(loaded.projects[0].exports?.count == 1 && loaded.projects[0].markedFinals == ["04 Exports/final.mp4"] && loaded.presets[1].icon == Data([1, 2, 3]),
              "export records, finals and icons survive the upgrade untouched")
    try check(loaded.unassignedTemplates.map(\.id) == [record.id], "template with no set is reported as unassigned")
    try store.save(loaded)
    try check(Data(contentsOf: store.root.appendingPathComponent("library-before-schema-\(Library.currentSchema).json")) == original, "first save over an older schema keeps a byte-exact backup")
    try check(!fm.fileExists(atPath: store.root.appendingPathComponent("library-before-schema-2.json").path), "schema-two origin does not fabricate a schema-one backup")
    loaded.projects[0].name = "Edited later"
    try store.save(loaded)
    try check(Data(contentsOf: store.root.appendingPathComponent("library-before-schema-\(Library.currentSchema).json")) == original, "later saves never overwrite the upgrade backup")
    let reread = try store.load()
    try check(reread.projects[0].exports?.first?.relativePath == "04 Exports/final.mp4", "unused export fields round-trip through save and load")

    var library = try store.load()
    try rejects("blank set name rejected") { _ = try library.createSet(named: "   ") }
    let shared = try library.createSet(named: "Junior Nkana Bassi", mappingAll: record.id)
    try check(shared.variants.count == 4 && Set(shared.variants.map(\.templateID)) == [record.id], "mapping a legacy template creates four variants on one payload")
    try check(library.unassignedTemplates.isEmpty, "mapped template is no longer unassigned")
    try check(library.resolve(setID: shared.id, format: "Livestream")?.id == record.id, "set and format resolve to the shared payload")
    try check(shared.formatsSharing(record.id, excluding: "Short") == ["Long", "Podcast", "Livestream"], "shared payload lists the other formats")
    try rejects("duplicate set name rejected case-insensitively") { _ = try library.createSet(named: "junior nkana bassi") }

    let livePayload = base.appendingPathComponent("Live payload")
    try put(Data("live".utf8), at: livePayload.appendingPathComponent("Template – Livestream Thumbnail.psd"))
    let live = try store.importTemplate(plan: TemplateReader.scan(livePayload), name: "Live only", mode: .full, cancellation: Cancellation())
    library.templates.append(live)
    let client = try library.createSet(named: "Client")
    try library.assign(format: "Livestream", templateID: live.id, in: client.id)
    try check(library.resolve(setID: client.id, format: "Livestream")?.id == live.id, "second set resolves its own Live payload")
    try check(library.resolve(setID: client.id, format: "Short") == nil, "missing format resolves to nothing, never another format")
    try check(library.resolve(setID: shared.id, format: "Livestream")?.id == record.id, "sets are isolated from each other")
    try library.assign(format: "Livestream", templateID: record.id, in: client.id)
    try check(library.set(client.id)?.variants.count == 1 && library.resolve(setID: client.id, format: "Livestream")?.id == record.id, "reassigning replaces rather than duplicates the variant")
    try check(library.usages(of: record.id).count == 5, "usages count every set and format on a payload")
    library.unassign(format: "Livestream", in: client.id)
    try check(library.resolve(setID: client.id, format: "Livestream") == nil, "unassign clears the format")
    try rejects("assigning an unknown format is rejected") { try library.assign(format: "Reel", templateID: live.id, in: client.id) }
    try rejects("assigning a missing template is rejected") { try library.assign(format: "Short", templateID: UUID(), in: client.id) }
    try library.renameSet(client.id, to: "DAZN48")
    try check(library.set(client.id)?.name == "DAZN48", "set renamed")
    library.templates.removeAll { $0.id == live.id }
    try library.assign(format: "Long", templateID: record.id, in: client.id)
    var dangling = library; dangling.templateSets![0].variants[0].templateID = UUID()
    try check(dangling.referenceProblems().count == 1 && dangling.resolve(setID: shared.id, format: "Long") == nil, "dangling variant is reported and resolves to nothing")
    library.removeSet(client.id)
    try check(library.sets.count == 1 && library.templates.count == 1 && fm.fileExists(atPath: store.payload(record).path), "removing a set keeps templates and payload folders")
    try store.save(library)
    let persisted = try store.load()
    try check(persisted.sets.first?.variants.count == 4, "sets persist across restart")
}
