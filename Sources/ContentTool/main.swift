// ContentTool: the app's own engine from the command line, for controlled tests and audits.
// Command-line operations stay inside an isolated data root. The GUI uses the
// production library only when it is launched without --data-directory.
//
//   ContentTool audit <folder>
//       Windows-compatibility audit of every name under the folder. Nothing is changed.
//   ContentTool create --set <name> --format <Short|Long|Podcast|Livestream> --number <n> --title <t> --destination <folder> [--fix-names] [--no-icons] [--library <root>]
//       --no-icons leaves out the Icon\r files, FinderInfo, resource forks and the preset icon (for LucidLink).
//       Creates one project exactly as the app does (same scan, substitution, rename, copy engine and icon), then audits it.
//       Refuses when the destination is not a mounted directory or the final folder already exists. Registers nothing in the library.
//   ContentTool restore-icons --project <folder> --set <name> [--format <f>] [--library <root>]
//       Puts the template's folder icons back onto an existing project (after it has left LucidLink), matched by path. Files untouched.
//   ContentTool strip-icons --project <folder>
//       Removes the Icon\r files and folder icon metadata from a project before it goes to LucidLink. Files untouched.
//   ContentTool probe <folder>
//       Tries the metadata operations a project needs (FinderInfo, ResourceFork, an Icon\r file, hidden flag) in a temporary folder, reports each errno, and removes the folder.
import Foundation
import AppKit
import TemplateCore
import Darwin

/// Legacy --fix-names is deliberately confined to the project just created by this process.
/// Existing projects use corrected-copy, which retains the original and writes a rename manifest.
func fixGeneratedCopy(_ created: URL) throws -> [CompatibilityFinding] {
    let audit = try Compatibility.scan(created)
    guard audit.isComplete, audit.collisions.isEmpty else { throw AppFailure("Generated copy needs manual attention: incomplete audit or corrected-name collision.") }
    var changed: [CompatibilityFinding] = []
    for finding in audit.findings.sorted(by: { $0.path.components(separatedBy: "/").count > $1.path.components(separatedBy: "/").count }) {
        guard let corrected = finding.corrected else { throw AppFailure("Package-internal correction is unsupported.") }
        let parts = finding.path.components(separatedBy: "/")
        guard parts.first == created.lastPathComponent, parts.count > 1 else { throw AppFailure("Unexpected generated root correction.") }
        let source = parts.dropFirst().reduce(created) { $0.appendingPathComponent($1) }
        let target = source.deletingLastPathComponent().appendingPathComponent(corrected)
        // Exclusive rename refuses a late collision even on a case-sensitive volume.
        guard renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 else { throw AppFailure("Cannot safely correct \(finding.path): \(errnoText())") }
        changed.append(finding)
    }
    return changed
}

func reportAudit(_ result: CompatibilityReport) {
    report("Name problems", result.findings.map { "\($0.path): \($0.problem)" })
    report("Finder icon support (omitted by corrected-copy)", result.iconFiles)
    report(result.pathLengthAssumption, result.longPaths)
    report("Document packages", result.packages)
    report("Collisions after correction", result.collisions)
    report("Skipped entries — audit incomplete", result.skipped)
    report("Read errors or unsafe content", result.errors)
}

func errnoText() -> String { "errno \(errno) (\(String(cString: strerror(errno))))" }
func report(_ title: String, _ lines: [String]) { print("## \(title)"); print(lines.isEmpty ? "- none" : lines.map { "- " + $0 }.joined(separator: "\n")); print("") }
func mounted(_ url: URL) -> Bool {
    var info = statfs(); guard statfs(url.path, &info) == 0 else { return false }
    let mountPoint = withUnsafePointer(to: &info.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
    return url.path.hasPrefix("/Volumes/") ? mountPoint.hasPrefix("/Volumes/") : true
}
func fsType(_ url: URL) -> String {
    var info = statfs(); guard statfs(url.path, &info) == 0 else { return "unknown" }
    let type = withUnsafePointer(to: &info.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
    let from = withUnsafePointer(to: &info.f_mntfromname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
    return "\(type) from \(from)"
}

func probe(_ folder: URL, runtime: AppRuntime) throws {
    try runtime.requireWritable(folder)
    let temp = folder.appendingPathComponent(".content-template-probe-" + UUID().uuidString)
    var lines: [String] = []
    guard (try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)) != nil else { report("Probe", ["cannot create a temporary folder: \(errnoText())"]); return }
    defer { try? FileManager.default.removeItem(at: temp) }
    var finder = Data(count: 32); finder[8] = 0x04  // kHasCustomIcon
    let info = finder.withUnsafeBytes { setxattr(temp.path, "com.apple.FinderInfo", $0.baseAddress, 32, 0, XATTR_NOFOLLOW) }
    lines.append("FinderInfo on folder: " + (info == 0 ? "ok" : "failed, \(errnoText())"))
    let icon = temp.appendingPathComponent("Icon\r")
    lines.append("Icon\\r file: " + (FileManager.default.createFile(atPath: icon.path, contents: Data()) ? "ok" : "failed, \(errnoText())"))
    let fork = Data(repeating: 0, count: 286)
    let rf = fork.withUnsafeBytes { setxattr(icon.path, "com.apple.ResourceFork", $0.baseAddress, fork.count, 0, XATTR_NOFOLLOW) }
    lines.append("ResourceFork on Icon\\r: " + (rf == 0 ? "ok" : "failed, \(errnoText())"))
    var st = stat()
    lines.append("hidden flag on Icon\\r: " + (lstat(icon.path, &st) == 0 && chflags(icon.path, st.st_flags | UInt32(UF_HIDDEN)) == 0 ? "ok" : "failed, \(errnoText())"))
    let back = try? IconService.attribute("com.apple.FinderInfo", at: temp)
    lines.append("FinderInfo reads back: " + (back?.count == 32 && back?[8] == 0x04 ? "ok" : "no"))
    lines.append("filesystem: " + fsType(folder))
    report("Probe of \(folder.path)", lines)
}

let args = CommandLine.arguments.dropFirst()
func option(_ name: String) -> String? { guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }; return args[i + 1] }
func alphaRuntime() throws -> AppRuntime {
    if let library = option("--library"), let data = option("--data-directory"), library != data {
        throw AppFailure("Use one alpha data root; --library and --data-directory disagree.")
    }
    return try AppRuntime.isolated(root: (option("--library") ?? option("--data-directory")).map { URL(fileURLWithPath: $0) } ?? AppRuntime.alphaRoot)
}
guard let command = args.first else { print("usage: ContentTool audit|corrected-copy|create|probe|restore-icons|strip-icons|register-location …"); exit(2) }

do {
switch command {
case "audit":
    guard let path = args.dropFirst().first else { print("audit needs a folder"); exit(2) }
    let result = try Compatibility.scan(URL(fileURLWithPath: path))
    print("# Audit of \(path)\n\(result.entries) entries checked.\n")
    reportAudit(result)
    if !result.isComplete || !result.collisions.isEmpty { exit(1) }
case "corrected-copy":
    guard let path = args.dropFirst().first, let destination = option("--destination") else {
        print("corrected-copy <source> --destination <existing parent folder> [--name <new folder>] [--confirm]"); exit(2)
    }
    let audit = try Compatibility.scan(URL(fileURLWithPath: path))
    reportAudit(audit)
    let proposal = try Compatibility.proposal(audit)
    report("Repair preview", proposal.renames.map { "\($0.from) → \($0.to)" })
    print("Original preserved; Finder icons omitted. Renamed media may require manual relinking in Premiere, OBS or Watchtower.")
    guard args.contains("--confirm") else { print("Preview only. Repeat with --confirm to create this corrected copy."); exit(0) }
    let runtime = try alphaRuntime()
    let destinationURL = URL(fileURLWithPath: destination)
    try runtime.requireWritable(destinationURL)
    let output = try Compatibility.copy(proposal, destination: destinationURL, name: option("--name"))
    print("Created \(output.path); rename manifest saved inside.")
case "probe":
    guard let path = args.dropFirst().first else { print("probe needs a folder"); exit(2) }
    try probe(URL(fileURLWithPath: path), runtime: alphaRuntime())
case "create":
    guard let setName = option("--set"), let format = option("--format"), let number = option("--number"), let title = option("--title"), let destinationPath = option("--destination") else {
        print("create needs --set --format --number --title --destination"); exit(2)
    }
    let runtime = try alphaRuntime()
    let store = LibraryStore(root: runtime.root)
    let library = try store.load()
    try runtime.validate(library)
    guard let set = library.sets.first(where: { $0.name == setName }) else { print("No set called \(setName). Sets: \(library.sets.map(\.name))"); exit(1) }
    guard let record = library.resolve(setID: set.id, format: format) else { print("\(format) is not set up in \(setName)."); exit(1) }
    let payload = store.payload(record)
    let fields = ProjectFields(number: number, format: format, title: title)
    let name = try fields.finalName()
    let destination = URL(fileURLWithPath: destinationPath)
    try runtime.requireWritable(destination)
    try runtime.requireWritable(payload)
    let final = destination.appendingPathComponent(name)
    print("# Create \(name)\n")
    var pre: [String] = []
    let isDir = (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    pre.append("destination \(destination.path): " + (isDir ? "directory present" : "MISSING"))
    pre.append("mounted: " + (isDir && mounted(destination) ? "yes (\(fsType(destination)))" : "NO"))
    pre.append("final folder \(final.path): " + (FileManager.default.fileExists(atPath: final.path) ? "ALREADY EXISTS" : "free"))
    pre.append("template payload: \(record.name) (\(record.mode.title)) at \(payload.path)")
    report("Preflight", pre)
    guard isDir, mounted(destination), !FileManager.default.fileExists(atPath: final.path) else { print("Stopped before creating anything."); exit(1) }
    let before = try Compatibility.scan(payload)
    report("Template audit before (\(before.entries) entries, not modified)", before.findings.map { "\($0.path): \($0.problem)" } + before.longPaths.map { "long path: " + $0 })
    print("Template icon support files: \(before.iconFiles.count)\n")
    let noIcons = args.contains("--no-icons")
    let plan = noIcons ? try TemplateReader.scan(payload, fields: fields).withoutIconFiles : try TemplateReader.scan(payload, fields: fields)
    if noIcons { print("Icons: excluded on request (\(plan.excluded.count) icon support files left out, no Finder metadata will be written)\n") }
    print("Plan: \(plan.visible.count) visible items, \(plan.entries.filter(\.metadata).count) icon files, \(ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file)); excluded \(plan.excluded.count)\n")
    let icon = library.presets.first { $0.format == format }?.icon
    let created: URL
    do {
        created = try CreationEngine.create(plan: plan, destination: destination, name: name, icon: noIcons ? nil : icon, finderMetadata: !noIcons, progress: { fraction, item in
            if fraction >= 1 { print("  \(item)") }
        }, strictExclusiveCommit: true)
    } catch {
        print("## Creation failed\n- \(error.localizedDescription)\n- \(errnoText())")
        let stages = (try? FileManager.default.contentsOfDirectory(atPath: destination.path))?.filter { $0.hasPrefix(".project-templates-") } ?? []
        print("- partial folder left behind: \(FileManager.default.fileExists(atPath: final.path) ? "yes, \(final.path)" : stages.isEmpty ? "no" : "staging remains: \(stages)")\n")
        try probe(destination, runtime: runtime)
        exit(1)
    }
    print("## Created\n- \(created.path)\n")
    let after = try Compatibility.scan(created)
    var corrections: [CompatibilityFinding] = []
    if args.contains("--fix-names"), !after.findings.isEmpty { corrections = try fixGeneratedCopy(created) }
    let final2 = try Compatibility.scan(created)
    report("Generated project audit (\(final2.entries) entries)", final2.findings.map { "\($0.path): \($0.problem)" })
    report("Names corrected in the generated project only", corrections.map { "\($0.path) → \($0.corrected ?? "")  (\($0.problem))" })
    report("Expected icon support files (kept)", final2.iconFiles)
    report(final2.pathLengthAssumption, final2.longPaths)
    report("Incomplete audit", final2.errors + final2.skipped + final2.collisions)
    // Icon verification: every folder that had a custom icon in the template must have one now, plus the outer folder.
    var iconLines: [String] = []
    for entry in plan.entries where entry.directory && !noIcons {
        let src = payload.appendingPathComponent(entry.source), dst = created.appendingPathComponent(entry.output)
        let srcFlag = ((try? IconService.attribute("com.apple.FinderInfo", at: src)) ?? nil).map { $0.count >= 10 && $0[8] & 0x04 != 0 } ?? false
        guard srcFlag else { continue }
        let dstInfo = (try? IconService.attribute("com.apple.FinderInfo", at: dst)) ?? nil
        let dstFlag = dstInfo.map { $0.count >= 10 && $0[8] & 0x04 != 0 } ?? false
        let iconFile = dst.appendingPathComponent("Icon\r")
        let fork = ((try? IconService.attribute("com.apple.ResourceFork", at: iconFile)) ?? nil)?.count ?? 0
        iconLines.append("\(entry.output): custom-icon flag \(dstFlag ? "set" : "MISSING"), Icon\\r \(FileManager.default.fileExists(atPath: iconFile.path) ? "present" : "MISSING"), resource fork \(fork) bytes")
    }
    let outer = (try? IconService.attribute("com.apple.FinderInfo", at: created)) ?? nil
    let outerFork = ((try? IconService.attribute("com.apple.ResourceFork", at: created.appendingPathComponent("Icon\r"))) ?? nil)?.count ?? 0
    if noIcons {
        var leftovers: [String] = []
        guard let iconWalker = FileManager.default.enumerator(at: created, includingPropertiesForKeys: nil, options: [], errorHandler: { url, error in
            leftovers.append("Cannot inspect \(url.path): \(error.localizedDescription)"); return false
        }) else { throw AppFailure("Cannot verify the generated copy's metadata.") }
        for case let url as URL in iconWalker {
            if url.lastPathComponent == "Icon\r" { leftovers.append("Icon file at \(url.deletingLastPathComponent().lastPathComponent)") }
            if let info = (try? IconService.attribute("com.apple.FinderInfo", at: url)) ?? nil, info.count >= 10, info[8] & 0x04 != 0 { leftovers.append("custom-icon flag on \(url.lastPathComponent)") }
        }
        iconLines.append(leftovers.isEmpty ? "no Icon files and no custom-icon flags anywhere in the project, as requested" : "LEFTOVERS: " + leftovers.joined(separator: "; "))
    } else {
        iconLines.append("outer folder: custom-icon flag \(outer.map { $0.count >= 10 && $0[8] & 0x04 != 0 } == true ? "set" : "MISSING"), Icon\\r resource fork \(outerFork) bytes")
    }
    report("Icons after copying", iconLines)
    // Byte check: every file in the plan has the planned size at its output path.
    var sizeProblems: [String] = []
    for entry in plan.entries where !entry.directory {
        let size = (try? created.appendingPathComponent(entry.output).resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? -1
        if Int64(size) != entry.bytes { sizeProblems.append("\(entry.output): \(size) bytes, expected \(entry.bytes)") }
    }
    report("Files whose size differs from the template", sizeProblems)
    print(sizeProblems.isEmpty && final2.findings.isEmpty && final2.isComplete && final2.collisions.isEmpty ? "Test project generated completely." : "Test project generated with the notes above.")
case "register-location":
    // register-location <root> --library <data directory>: discover the projects under root and add them to the library,
    // recording the root as a saved location. Run only while the app is closed; it never moves or renames anything.
    let rest = Array(args.dropFirst())
    guard let rootPath = rest.first, !rootPath.hasPrefix("--") else { print("usage: ContentTool register-location <root> --library <data directory>"); exit(2) }
    let root = URL(fileURLWithPath: rootPath)
    guard let libraryIndex = args.firstIndex(of: "--library"), args.indices.contains(libraryIndex + 1) else { print("--library <data directory> is required"); exit(2) }
    let runtime = try alphaRuntime()
    try runtime.requireWritable(root)
    let store = LibraryStore(root: runtime.root)
    do {
        var library = try store.load()
        try runtime.validate(library)
        let result = try Catalogue.discover(root: root)
        let before = library.projects.count
        library.projects = Catalogue.merge(result.projects, into: library.projects)
        var locations = library.locations ?? []
        if let index = locations.firstIndex(where: { $0.path == result.location.path }) { locations[index] = result.location } else { locations.append(result.location) }
        library.locations = locations
        try runtime.validate(library)
        try store.save(library)
        print("Found \(result.projects.count) projects under \(root.path); library went from \(before) to \(library.projects.count) records.")
        for record in result.projects { print("  \(record.format)  \(record.name)") }
        for note in result.notes { print("  note: \(note)") }
    } catch { print("Failed: \(error.localizedDescription)"); exit(1) }
case "restore-icons":
    guard let projectPath = option("--project"), let setName = option("--set") else { print("restore-icons needs --project and --set"); exit(2) }
    let project = URL(fileURLWithPath: projectPath)
    let runtime = try alphaRuntime()
    try runtime.requireWritable(project)
    _ = try TemplateReader.scan(project) // Refuse linked descendants before restoring metadata.
    let store = LibraryStore(root: runtime.root)
    let library = try store.load()
    try runtime.validate(library)
    guard let set = library.sets.first(where: { $0.name == setName }) else { print("No set called \(setName)."); exit(1) }
    let name = project.lastPathComponent
    let parts = name.components(separatedBy: " — ")
    let format = option("--format") ?? (parts.count >= 2 ? parts[1] : "")
    guard let record = library.resolve(setID: set.id, format: format) else { print("\(format) is not set up in \(setName)."); exit(1) }
    let number = String(name.prefix { $0.isNumber })
    let title = parts.count >= 3 ? parts.dropFirst(2).joined(separator: " — ") : name
    let campaign = parts.count >= 4 ? parts[2] : ""
    let fields = ProjectFields(number: number, format: format, campaign: campaign, title: parts.count >= 4 ? parts.dropFirst(3).joined(separator: " — ") : title)
    print("# Restore icons onto \(name)\n- template: \(record.name)\n- fields: number \(number), format \(format), campaign \(campaign.isEmpty ? "none" : campaign), title \(fields.title)\n- filesystem: \(fsType(project))\n")
    let icon = library.presets.first { $0.format == format }?.icon
    let result = try IconService.restore(template: store.payload(record), fields: fields, onto: project, presetIcon: icon)
    report("Folders with icons restored", result.restored)
    report("Template folders not found in the project (skipped)", result.unmatched)
    report("Failed", result.failed)
    print(result.summary)
case "strip-icons":
    guard let projectPath = option("--project") else { print("strip-icons needs --project"); exit(2) }
    let runtime = try alphaRuntime()
    let project = URL(fileURLWithPath: projectPath)
    try runtime.requireWritable(project)
    let result = try IconService.strip(project: project)
    print("# Strip icons from \(URL(fileURLWithPath: projectPath).lastPathComponent)\n")
    report("Icon files removed", result.iconFilesRemoved)
    report("Folders cleared of icon metadata", result.foldersCleared)
    report("Failed", result.failed)
    print(result.summary)
default:
    print("unknown command \(command)"); exit(2)
}
} catch {
    fputs("ContentTool: \(error.localizedDescription)\n", stderr)
    exit(1)
}
