import Foundation
import AppKit
import TemplateCore
import Darwin
import CryptoKit

var checks = 0
func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
    guard try condition() else { throw AppFailure("FAILED: \(name)") }
    checks += 1; print("PASS \(name)")
}
func rejects(_ name: String, _ action: () throws -> Void) throws {
    do { try action() } catch { checks += 1; print("PASS \(name)"); return }
    throw AppFailure("FAILED, expected rejection: \(name)")
}
func put(_ data: Data, at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}
func children(_ root: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() }
func digestTree(_ root: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { throw AppFailure("Cannot enumerate fixture") }
    for case let url as URL in enumerator {
        let key = String(url.path.dropFirst(root.path.count))
        if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[key] = SHA256.hash(data: try Data(contentsOf: url)).description
        }
        for attribute in IconService.attributes {
            if let data = try IconService.attribute(attribute, at: url) { result[key + "::" + attribute] = SHA256.hash(data: data).description }
        }
    }
    for attribute in IconService.attributes {
        if let data = try IconService.attribute(attribute, at: root) { result["ROOT::" + attribute] = SHA256.hash(data: data).description }
    }
    return result
}

do {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("ContentTemplate-checks-" + UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: false)
    // Keep this run's disposable fixtures for inspection; no user folder is ever removed.
    print("FIXTURES \(base.path)")
    let source = base.appendingPathComponent("Original")
    let destination = base.appendingPathComponent("Projects")
    try fm.createDirectory(at: destination, withIntermediateDirectories: false)
    let document = Data("opaque Adobe bytes\u{0}123".utf8)
    try put(document, at: source.appendingPathComponent("02 Project Files/Template.prproj"))
    try put(Data("thumbnail".utf8), at: source.appendingPathComponent("02 Project Files/Template – Video Thumbnail.psd"))
    try put(Data("rich text".utf8), at: source.appendingPathComponent("01 Documents/Template Description.rtf"))
    try put(Data("package content".utf8), at: source.appendingPathComponent("Library.rtfd/Template.txt"))
    try fm.createDirectory(at: source.appendingPathComponent("03 Media/Empty"), withIntermediateDirectories: true)
    let fields = ProjectFields(number: "007", format: "Short", title: "Doué & PSG")
    let name = try fields.finalName()
    try check(name == "007 — Short — Doué & PSG", "blank campaign and leading zeroes")
    try check(Naming.render("Template.prproj", fields: fields) == name + ".prproj", "legacy project filename")
    try check(Naming.render("Template – Video Thumbnail.psd", fields: fields) == name + " – Video Thumbnail.psd", "legacy descriptive suffix")
    try check(Naming.render("Template Description.rtf", fields: fields) == name + " Description.rtf", "legacy space prefix")
    try check(Naming.render("My Template notes.txt", fields: fields) == "My Template notes.txt", "unrelated word retained")
    try check(Naming.render("[Project Number] [Conent Form].txt", fields: fields) == "007 Short.txt", "legacy typo explicitly mapped")
    try check(Naming.render("[template].aep", fields: fields) == name + ".aep", "explicit template token")
    for invalid in ["../escape", "/absolute", "a\\b", "bad|name", "trailing ", "trailing.", "CON.txt", "LPT1", "COM¹.txt", "\n", ""] {
        try rejects("invalid name \(invalid.debugDescription)") { try Naming.validate(invalid) }
    }
    try rejects("missing title") { _ = try ProjectFields(number: "1", format: "Short", title: "").finalName() }
    try rejects("unknown token") { _ = try Naming.render("[unknown].txt", fields: fields) }
    let plan = try TemplateReader.scan(source, fields: fields)
    let output = try CreationEngine.create(plan: plan, destination: destination, name: name)
    try check(Data(contentsOf: output.appendingPathComponent("02 Project Files/" + name + ".prproj")) == document, "opaque file byte equality")
    try check(fm.fileExists(atPath: output.appendingPathComponent("03 Media/Empty").path), "empty folders retained")
    try check(fm.fileExists(atPath: output.appendingPathComponent("Library.rtfd/Template.txt").path), "package internal filenames unchanged")
    try check(Data(contentsOf: source.appendingPathComponent("02 Project Files/Template.prproj")) == document, "template source unchanged")
    let oldInode = try fm.attributesOfItem(atPath: source.appendingPathComponent("02 Project Files/Template.prproj").path)[.systemFileNumber] as? NSNumber
    let newInode = try fm.attributesOfItem(atPath: output.appendingPathComponent("02 Project Files/" + name + ".prproj").path)[.systemFileNumber] as? NSNumber
    try check(oldInode != newInode, "independent files, no hard links")
    try rejects("existing project cannot be overwritten") { _ = try CreationEngine.create(plan: plan, destination: destination, name: name) }
    let cancellation = Cancellation(); cancellation.cancel()
    try rejects("pre-cancelled operation") { _ = try CreationEngine.create(plan: plan, destination: destination, name: "Cancelled", cancellation: cancellation) }
    try check(!fm.fileExists(atPath: destination.appendingPathComponent("Cancelled").path), "cancelled output absent")

    let raceName = "Race"
    try rejects("late destination race") {
        _ = try CreationEngine.create(plan: plan, destination: destination, name: raceName, progress: { _, stage in
            if stage == "Finalising" { try? FileManager.default.createDirectory(at: destination.appendingPathComponent(raceName), withIntermediateDirectories: false) }
        })
    }
    try check(children(destination.appendingPathComponent(raceName)).isEmpty, "late competing destination untouched")
    try check(!children(destination).contains(where: { $0.hasPrefix(".project-templates-") }), "owned staging cleaned after failures")

    let iconImage = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
        NSColor.systemPurple.setFill(); NSBezierPath(roundedRect: rect.insetBy(dx: 8, dy: 8), xRadius: 24, yRadius: 24).fill(); return true
    }
    guard let iconData = iconImage.tiffRepresentation else { throw AppFailure("Could not create test icon") }
    try IconService.apply(iconData, to: source)
    try IconService.apply(iconData, to: source.appendingPathComponent("03 Media/Empty"))
    let iconPlan = try TemplateReader.scan(source, fields: fields)
    let iconOutput = try CreationEngine.create(plan: iconPlan, destination: destination, name: "Icon project")
    for relative in ["", "03 Media/Empty"] {
        let a = source.appendingPathComponent(relative); let b = iconOutput.appendingPathComponent(relative)
        try check(IconService.attribute("com.apple.FinderInfo", at: a) == IconService.attribute("com.apple.FinderInfo", at: b), "FinderInfo preserved \(relative)")
        try check(IconService.attribute("com.apple.ResourceFork", at: a.appendingPathComponent("Icon\r")) == IconService.attribute("com.apple.ResourceFork", at: b.appendingPathComponent("Icon\r")), "icon resource fork preserved \(relative)")
    }
    let overrideOutput = try CreationEngine.create(plan: iconPlan, destination: destination, name: "Override", icon: iconData)
    try check(fm.fileExists(atPath: overrideOutput.appendingPathComponent("Icon\r").path), "explicit outer icon applied")
    try rejects("invalid explicit icon prevents commit") { _ = try CreationEngine.create(plan: iconPlan, destination: destination, name: "Bad icon", icon: Data([0, 1, 2])) }
    try check(!fm.fileExists(atPath: destination.appendingPathComponent("Bad icon").path), "icon failure leaves no final project")

    let structure = try TemplateReader.scan(source, mode: .structure)
    let structureOutput = try CreationEngine.create(plan: structure, destination: destination, name: "Structure only")
    try check(!fm.fileExists(atPath: structureOutput.appendingPathComponent("Library.rtfd").path), "structure excludes document packages")
    try check(!fm.fileExists(atPath: structureOutput.appendingPathComponent("02 Project Files/Template.prproj").path), "structure excludes regular payloads")
    try check(fm.fileExists(atPath: structureOutput.appendingPathComponent("03 Media/Empty").path), "structure preserves empty hierarchy")
    try check(IconService.attribute("com.apple.ResourceFork", at: source.appendingPathComponent("Icon\r")) == IconService.attribute("com.apple.ResourceFork", at: structureOutput.appendingPathComponent("Icon\r")), "structure preserves root icon data")

    let store = LibraryStore(root: base.appendingPathComponent("Isolated app data"))
    let record = try store.importTemplate(plan: TemplateReader.scan(source), name: "Independent", mode: .full, cancellation: Cancellation())
    var library = Library(); library.templates.append(record); library.projects.append(try ProjectRecord(url: output, format: "Short"))
    library.presets[0].icon = iconData
    try store.save(library)
    let restored = try store.load()
    try check(restored.templates.count == 1 && restored.projects.count == 1 && restored.presets[0].icon == iconData, "restart JSON persistence")
    try fm.moveItem(at: source, to: base.appendingPathComponent("Original moved away"))
    let independent = try CreationEngine.create(plan: TemplateReader.scan(store.payload(record), fields: fields), destination: destination, name: "Source unavailable")
    try check(fm.fileExists(atPath: independent.appendingPathComponent("02 Project Files/" + name + ".prproj").path), "managed template works after original moved")
    let empty = try LibraryStore(root: base.appendingPathComponent("Friend data")).load()
    try check(empty.templates.isEmpty && empty.projects.isEmpty && empty.presets.allSatisfy { $0.destination.isEmpty }, "clean first run without personal paths")
    try put(Data("bad json".utf8), at: store.file)
    try rejects("corrupt store not silently reset") { _ = try store.load() }

    let links = base.appendingPathComponent("Links")
    try fm.createDirectory(at: links, withIntermediateDirectories: false)
    try fm.createSymbolicLink(at: links.appendingPathComponent("outside"), withDestinationURL: destination)
    try rejects("full import rejects symlink") { _ = try TemplateReader.scan(links) }
    let onlyLinks = try TemplateReader.scan(links, mode: .structure)
    try check(onlyLinks.entries.isEmpty && onlyLinks.excluded.count == 1, "structure reports and excludes symlink")

    let collision = base.appendingPathComponent("Collision")
    try put(Data(), at: collision.appendingPathComponent("Template.txt"))
    try put(Data(), at: collision.appendingPathComponent("[template].txt"))
    try rejects("renaming collision before copy") { _ = try TemplateReader.scan(collision, fields: fields) }
    try check(Naming.key("CAFÉ") == Naming.key("cafe\u{301}"), "case and Unicode normalisation")

    let pht = base.appendingPathComponent("Imported.pht")
    try put(document, at: pht.appendingPathComponent("Files/Template.prproj"))
    try check(TemplateReader.scan(pht).entries[0].source == "Template.prproj", "pht Files level unwrapped")

    let large = base.appendingPathComponent("Large")
    try put(Data(repeating: 91, count: 64 * 1_048_576), at: large.appendingPathComponent("large.bin"))
    let largePlan = try TemplateReader.scan(large)
    let start = Date()
    let midCancel = Cancellation()
    try rejects("mid-file cancellation") {
        _ = try CreationEngine.create(plan: largePlan, destination: destination, name: "Mid cancel", cancellation: midCancel,
                                      progress: { value, _ in if value > 0 { midCancel.cancel() } })
    }
    print("MEASURE cancellation test elapsed \(Date().timeIntervalSince(start)) seconds")
    try check(!fm.fileExists(atPath: destination.appendingPathComponent("Mid cancel").path), "mid-file cancelled output absent")
    let copyStart = Date()
    _ = try CreationEngine.create(plan: largePlan, destination: destination, name: "64 MiB copy")
    print("MEASURE 64 MiB creation \(Date().timeIntervalSince(copyStart)) seconds")
    try put(Data("changed".utf8), at: large.appendingPathComponent("large.bin"))
    try rejects("source mutation invalidates preview") { _ = try CreationEngine.create(plan: largePlan, destination: destination, name: "Stale plan") }
    try catalogueChecks(base: base)
    try browserChecks(base: base)
    try setChecks(base: base)
    try previewChecks(base: base)
    try pipelineChecks(base: base)
    try boardChecks(base: base)
    try plainCopyChecks(base: base)
    try relinkChecks(base: base)
    let args = ProcessInfo.processInfo.arguments
    if let index = args.firstIndex(of: "--master"), args.indices.contains(index + 1) {
        let master = URL(fileURLWithPath: args[index + 1]).resolvingSymlinksInPath()
        let before = try digestTree(master)
        let realStore = LibraryStore(root: base.appendingPathComponent("Master test library"))
        let importStart = Date()
        let importPlan = try TemplateReader.scan(master)
        let realRecord = try realStore.importTemplate(plan: importPlan, name: "Master fixture", mode: .full, cancellation: Cancellation())
        print("MEASURE master import \(Date().timeIntervalSince(importStart)) seconds, \(importPlan.bytes) bytes, \(importPlan.entries.count) entries")
        let realStart = Date()
        let realFields = ProjectFields(number: "000", format: "Short", title: "Disposable app validation")
        let realPlan = try TemplateReader.scan(realStore.payload(realRecord), fields: realFields)
        let realOutput = try CreationEngine.create(plan: realPlan, destination: destination, name: realFields.finalName())
        print("MEASURE master creation \(Date().timeIntervalSince(realStart)) seconds")
        for entry in realPlan.entries where !entry.directory {
            try check(Data(contentsOf: realPlan.root.appendingPathComponent(entry.source)) == Data(contentsOf: realOutput.appendingPathComponent(entry.output)), "master payload bytes \(entry.source.debugDescription)")
        }
        var iconCount = 0
        for entry in realPlan.entries where entry.metadata {
            let original = try IconService.attribute("com.apple.ResourceFork", at: realPlan.root.appendingPathComponent(entry.source))
            let copied = try IconService.attribute("com.apple.ResourceFork", at: realOutput.appendingPathComponent(entry.output))
            try check(original != nil && original == copied, "master icon resource fork \(entry.source.debugDescription)")
            iconCount += 1
        }
        try check(iconCount == 26, "26 current master icons retained")
        try check(digestTree(master) == before, "real master files and icon metadata unchanged")
        print("REAL_OUTPUT \(realOutput.path)")
    }
    print("RESULT \(checks) checks passed")
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
