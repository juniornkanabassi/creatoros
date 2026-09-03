// ContentTool: the app's own engine from the command line, for controlled tests and audits.
//
//   ContentTool audit <folder>
//       Windows-compatibility audit of every name under the folder. Nothing is changed.
//   ContentTool create --set <name> --format <Short|Long|Podcast|Livestream> --number <n> --title <t> --destination <folder> [--fix-names] [--no-icons] [--library <root>]
//       --no-icons leaves out the Icon\r files, FinderInfo, resource forks and the preset icon (for LucidLink).
//       Creates one project exactly as the app does (same scan, substitution, rename, copy engine and icon), then audits it.
//       Refuses when the destination is not a mounted directory or the final folder already exists. Registers nothing in the library.
//   ContentTool restore-icons --project <folder> --set <name> [--format <f>] [--library <root>]
//       Puts the template's folder icons back onto an existing project (after it has left LucidLink), matched by path. Files untouched.
//   ContentTool probe <folder>
//       Tries the metadata operations a project needs (FinderInfo, ResourceFork, an Icon\r file, hidden flag) in a temporary folder, reports each errno, and removes the folder.
import Foundation
import AppKit
import TemplateCore
import Darwin

struct Finding: Codable { let path: String; let problem: String; let corrected: String? }

enum Audit {
    static let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
    static let reserved = Set(["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] })
    static let windowsLimit = 260
    /// Problems with one component. Icon\r files are reported separately as expected icon support files.
    static func problems(_ name: String) -> [String] {
        if name == "Icon\r" { return [] }
        var out: [String] = []
        if name.hasSuffix(" ") { out.append("trailing space") }
        if name.hasSuffix(".") { out.append("trailing period") }
        if let r = name.rangeOfCharacter(from: invalid) { out.append("Windows-invalid character \(name[r])") }
        if name.rangeOfCharacter(from: .controlCharacters) != nil { out.append("control character") }
        let stem = name.split(separator: ".", omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces).uppercased()
        if reserved.contains(stem) { out.append("reserved Windows name \(stem)") }
        if name.utf8.count > 255 { out.append("longer than 255 bytes") }
        return out
    }
    static func corrected(_ name: String) -> String {
        var clean = String(name.unicodeScalars.map { invalid.contains($0) || CharacterSet.controlCharacters.contains($0) ? "-" : Character($0) })
        while clean.hasSuffix(" ") || clean.hasSuffix(".") { clean.removeLast() }
        let stem = clean.split(separator: ".", omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces).uppercased()
        if reserved.contains(stem) { clean = "_" + clean }
        return clean.isEmpty ? "_" : clean
    }
    /// Walks everything, hidden files included. Returns findings, icon files, long paths and the count of entries.
    static func run(_ root: URL, base: String = "C:\\Projects\\") -> (findings: [Finding], iconFiles: [String], longPaths: [String], entries: Int) {
        var findings: [Finding] = [], icons: [String] = [], long: [String] = [], count = 0
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [])!
        for case let url as URL in enumerator {
            count += 1
            let relative = String(url.path.dropFirst(root.deletingLastPathComponent().path.count + 1))
            let name = url.lastPathComponent
            if name == "Icon\r" { icons.append(relative.replacingOccurrences(of: "\r", with: "\\r")); continue }
            for problem in problems(name) { findings.append(Finding(path: relative, problem: problem, corrected: nil)) }
            if (base + relative.replacingOccurrences(of: "/", with: "\\")).utf16.count > windowsLimit { long.append(relative) }
        }
        return (findings, icons, long, count)
    }
    /// Renames offending ordinary entries in place, deepest first, never an Icon\r file. Returns what changed.
    static func fix(_ root: URL) throws -> [Finding] {
        var urls: [URL] = []
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [])! { urls.append(url) }
        var changed: [Finding] = []
        for url in urls.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            let name = url.lastPathComponent
            guard name != "Icon\r", !problems(name).isEmpty else { continue }
            let target = url.deletingLastPathComponent().appendingPathComponent(corrected(name))
            guard !FileManager.default.fileExists(atPath: target.path) else { changed.append(Finding(path: url.path, problem: problems(name).joined(separator: ", "), corrected: "not renamed: \(target.lastPathComponent) already exists")); continue }
            try FileManager.default.moveItem(at: url, to: target)
            changed.append(Finding(path: String(url.path.dropFirst(root.deletingLastPathComponent().path.count + 1)), problem: problems(name).joined(separator: ", "), corrected: target.lastPathComponent))
        }
        return changed
    }
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

func probe(_ folder: URL) {
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
guard let command = args.first else { print("usage: ContentTool audit|create|probe …"); exit(2) }

switch command {
case "audit":
    guard let path = args.dropFirst().first else { print("audit needs a folder"); exit(2) }
    let result = Audit.run(URL(fileURLWithPath: path))
    print("# Audit of \(path)\n\(result.entries) entries checked.\n")
    report("Name problems", result.findings.map { "\($0.path): \($0.problem)" })
    report("Expected icon support files (Icon\\r, kept)", result.iconFiles)
    report("Paths over \(Audit.windowsLimit) characters under C:\\Projects\\", result.longPaths)
case "probe":
    guard let path = args.dropFirst().first else { print("probe needs a folder"); exit(2) }
    probe(URL(fileURLWithPath: path))
case "create":
    guard let setName = option("--set"), let format = option("--format"), let number = option("--number"), let title = option("--title"), let destinationPath = option("--destination") else {
        print("create needs --set --format --number --title --destination"); exit(2)
    }
    let store = LibraryStore(root: option("--library").map { URL(fileURLWithPath: $0) })
    let library = try store.load()
    guard let set = library.sets.first(where: { $0.name == setName }) else { print("No set called \(setName). Sets: \(library.sets.map(\.name))"); exit(1) }
    guard let record = library.resolve(setID: set.id, format: format) else { print("\(format) is not set up in \(setName)."); exit(1) }
    let payload = store.payload(record)
    let fields = ProjectFields(number: number, format: format, title: title)
    let name = try fields.finalName()
    let destination = URL(fileURLWithPath: destinationPath)
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
    let before = Audit.run(payload)
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
        })
    } catch {
        print("## Creation failed\n- \(error.localizedDescription)\n- \(errnoText())")
        let stages = (try? FileManager.default.contentsOfDirectory(atPath: destination.path))?.filter { $0.hasPrefix(".project-templates-") } ?? []
        print("- partial folder left behind: \(FileManager.default.fileExists(atPath: final.path) ? "yes, \(final.path)" : stages.isEmpty ? "no" : "staging remains: \(stages)")\n")
        probe(destination)
        exit(1)
    }
    print("## Created\n- \(created.path)\n")
    let after = Audit.run(created)
    var corrections: [Finding] = []
    if args.contains("--fix-names"), !after.findings.isEmpty { corrections = try Audit.fix(created) }
    let final2 = Audit.run(created)
    report("Generated project audit (\(final2.entries) entries)", final2.findings.map { "\($0.path): \($0.problem)" })
    report("Names corrected in the generated project only", corrections.map { "\($0.path) → \($0.corrected ?? "")  (\($0.problem))" })
    report("Expected icon support files (kept)", final2.iconFiles)
    report("Paths over \(Audit.windowsLimit) characters under C:\\Projects\\", final2.longPaths)
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
        for case let url as URL in FileManager.default.enumerator(at: created, includingPropertiesForKeys: nil, options: [])! {
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
    print(sizeProblems.isEmpty && final2.findings.isEmpty ? "Test project generated completely." : "Test project generated with the notes above.")
case "restore-icons":
    guard let projectPath = option("--project"), let setName = option("--set") else { print("restore-icons needs --project and --set"); exit(2) }
    let project = URL(fileURLWithPath: projectPath)
    let store = LibraryStore(root: option("--library").map { URL(fileURLWithPath: $0) })
    let library = try store.load()
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
default:
    print("unknown command \(command)"); exit(2)
}
