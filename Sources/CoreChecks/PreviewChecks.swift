import Foundation
import TemplateCore

func previewChecks(base: URL) throws {
    let root = base.appendingPathComponent("Preview payload")
    try put(Data("a".utf8), at: root.appendingPathComponent("02 Project Files/Template.prproj"))
    try put(Data("b".utf8), at: root.appendingPathComponent("02 Project Files/Template – Video Thumbnail.psd"))
    try put(Data("c".utf8), at: root.appendingPathComponent("04 Exports/Template Description.rtf"))
    try put(Data("d".utf8), at: root.appendingPathComponent("01 Documents/[Conent Form] brief [Campaign].txt"))
    try put(Data("e".utf8), at: root.appendingPathComponent("01 Documents/My Template notes.txt"))
    try put(Data("f".utf8), at: root.appendingPathComponent("Library.rtfd/Template.txt"))
    try put(Data(), at: root.appendingPathComponent("Icon\r"))
    try put(Data(), at: root.appendingPathComponent("03 Media/Icon\r"))
    let structure = try TemplateReader.scan(root)
    try check(structure.entries.allSatisfy { $0.source == $0.output }, "structural scan keeps names untouched")
    try check(structure.entries.first { $0.source == "Library.rtfd/Template.txt" }?.opaque == true && structure.entries.first { $0.source == "02 Project Files/Template.prproj" }?.opaque == false, "package internals are flagged opaque")

    let empty = ProjectFields(number: "", format: "Short", title: "")
    let blank = PreviewRenderer.render(structure: structure, fields: empty)
    try check(blank.outerFolderName == "[Project Number] — Short — [Project Name]", "empty fields render placeholders in field order")
    try check(blank.missingFields == ["Project Number", "Project Name"] && !blank.isExecutable, "missing fields listed and preview not executable")
    let prproj = blank.entries.first { $0.source == "02 Project Files/Template.prproj" }!
    try check(prproj.output == "02 Project Files/[Project Number] — Short — [Project Name].prproj" && prproj.placeholder && prproj.renamed, "legacy file shows the placeholder name")
    try check(blank.entries.first { $0.source == "Library.rtfd/Template.txt" }?.output == "Library.rtfd/Template.txt", "package internals are never renamed in the preview")
    try check(blank.entries.first { $0.source == "01 Documents/My Template notes.txt" }?.renamed == false, "unrelated prose is untouched in the preview")
    try check(blank.entries.first { $0.source == "01 Documents/[Conent Form] brief [Campaign].txt" }?.output == "01 Documents/Short brief .txt", "campaign token disappears when blank")
    try check(blank.issues.isEmpty, "placeholders produce no false validation issues")
    try check(blank.children(of: "").map(\.name) == ["01 Documents", "02 Project Files", "03 Media", "04 Exports", "Library.rtfd"], "preview children hide metadata and keep folders first")
    try check(blank.children(of: "").first { $0.name == "Library.rtfd" }?.package == true, "preview marks packages")
    try check(blank.visible.count == structure.visible.count, "preview lists every visible entry")

    let partial = PreviewRenderer.render(structure: structure, fields: ProjectFields(number: "007", format: "Short", title: ""))
    try check(partial.outerFolderName == "007 — Short — [Project Name]" && partial.missingFields == ["Project Name"], "typing the number updates the preview and narrows what is missing")

    let invalid = PreviewRenderer.render(structure: structure, fields: ProjectFields(number: "007", format: "Short", title: "Doué/PSG"))
    try check(invalid.issues.contains { $0.hasPrefix("Project Name:") } && !invalid.isExecutable && invalid.entries.count == structure.entries.count, "invalid title is an inline issue, not a crash, and the tree stays visible")

    let fields = ProjectFields(number: "007", format: "Short", campaign: "Series", title: "Doué & PSG")
    let ready = PreviewRenderer.render(structure: structure, fields: fields)
    try check(ready.isExecutable && ready.outerFolderName == "007 — Short — Series — Doué & PSG", "complete fields make the preview executable")
    let derived = try TemplateReader.plan(from: structure, fields: fields)
    let direct = try TemplateReader.scan(root, fields: fields)
    try check(derived.entries.map(\.output) == direct.entries.map(\.output), "plan derived from the cached structure equals a fresh scan")
    try check(ready.entries.map(\.output) == direct.entries.map(\.output), "preview names equal the executable plan names")
    try check(derived.entries.map(\.source) == direct.entries.map(\.source) && derived.entries.map(\.bytes) == direct.entries.map(\.bytes), "derived plan keeps sources and sizes")
    let destination = base.appendingPathComponent("Preview output")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let output = try CreationEngine.create(plan: derived, destination: destination, name: ready.outerFolderName)
    for entry in ready.visible where !entry.directory {
        try check(FileManager.default.fileExists(atPath: output.appendingPathComponent(entry.output).path), "created file matches preview \(entry.output.debugDescription)")
    }
    try check(FileManager.default.fileExists(atPath: output.appendingPathComponent("03 Media/Icon\r").path), "created project keeps nested icon metadata")

    let collision = base.appendingPathComponent("Preview collision")
    try put(Data(), at: collision.appendingPathComponent("Template.txt"))
    try put(Data(), at: collision.appendingPathComponent("[template].txt"))
    let collisionStructure = try TemplateReader.scan(collision)
    let clash = PreviewRenderer.render(structure: collisionStructure, fields: fields)
    try check(clash.issues.contains { $0.contains("collision") } && !clash.isExecutable, "collision is surfaced as a preview issue")
    try rejects("collision still blocks the executable plan") { _ = try TemplateReader.plan(from: collisionStructure, fields: fields) }

    let offline = try ProjectRecord(url: root, format: "Short")
    var missing = offline; missing.bookmark = nil; missing.path = "/Volumes/ContentTemplate-Missing/project"; missing.volumePath = "/Volumes/ContentTemplate-Missing"
    missing.exports = [ExportRecord(relativePath: "x.mp4", bytes: 1, modified: nil)]
    let state = Catalogue.availability(missing)
    try check(!state.available && state.status.contains("Drive unavailable") && state.record.exports?.count == 1 && state.record.lastIndexed == nil, "availability check reports offline drive without indexing")
    try check(Catalogue.availability(offline).available, "availability check confirms a present folder")
}
