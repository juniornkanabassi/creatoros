import Foundation
import AppKit
import Darwin
import CryptoKit

public enum ImportMode: String, Codable, CaseIterable, Sendable {
    case full, structure
    public var title: String { self == .full ? "Files and folders" : "Folder structure only" }
}

public final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

public struct Entry: Identifiable, Sendable {
    public var id: String { output }
    public let source: String
    public let output: String
    public let directory: Bool
    /// Finder icon support file. Copied as metadata, never renamed, hidden in browsers.
    public let metadata: Bool
    /// Inside a document package. Copied byte for byte, never renamed.
    public let opaque: Bool
    public let bytes: Int64
    public let modified: Date?
    public init(source: String, output: String, directory: Bool, metadata: Bool, opaque: Bool = false, bytes: Int64, modified: Date?) {
        self.source = source; self.output = output; self.directory = directory; self.metadata = metadata
        self.opaque = opaque; self.bytes = bytes; self.modified = modified
    }
}

public struct CopyPlan: Sendable {
    public let root: URL
    public let entries: [Entry]
    public let excluded: [String]
    public var bytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    public var visible: [Entry] { entries.filter { !$0.metadata } }
    /// The same plan without Finder icon support files, for destinations that cannot hold them.
    public var withoutIconFiles: CopyPlan { CopyPlan(root: root, entries: visible, excluded: excluded + entries.filter(\.metadata).map(\.output)) }
    /// Compare a reviewed plan with a fresh scan before copying, including added or removed entries and renamed outputs.
    public func sameInventory(as other: CopyPlan) -> Bool {
        root == other.root && entries.count == other.entries.count && zip(entries, other.entries).allSatisfy {
            $0.source == $1.source && $0.output == $1.output && $0.directory == $1.directory &&
            $0.bytes == $1.bytes && $0.modified == $1.modified && $0.metadata == $1.metadata && $0.opaque == $1.opaque
        }
    }
}

public enum TemplateReader {
    public static let packages: Set<String> = ["app", "rtfd", "fcpbundle", "bundle", "framework", "photoslibrary", "logicx", "band", "playground"]
    public static func payload(_ selected: URL) throws -> URL {
        let root = selected.pathExtension.lowercased() == "pht" ? selected.appendingPathComponent("Files") : selected
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw AppFailure("Choose an ordinary folder or a .pht containing a Files folder.") }
        return root.resolvingSymlinksInPath()
    }

    public static func scan(_ root: URL, mode: ImportMode = .full, fields: ProjectFields? = nil,
                            excluding: Set<String> = [], cancellation: Cancellation = Cancellation()) throws -> CopyPlan {
        var entries: [Entry] = []; var excluded: [String] = []; var names = Set<String>()
        let canonical = try payload(root)
        func walk(_ folder: URL, relative: String, output: String, opaque: Bool) throws {
            try cancellation.check()
            let children = try FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for child in children {
                try cancellation.check()
                let name = child.lastPathComponent
                let rel = relative.isEmpty ? name : relative + "/" + name
                if excluding.contains(rel) { excluded.append(rel + " (omitted)"); continue }
                if name == ".DS_Store" { continue }
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey])
                guard values.isSymbolicLink != true else {
                    if mode == .structure { excluded.append(rel + " (symbolic link)"); continue }
                    throw AppFailure("Symbolic link is unsupported: \(rel). Remove it from a separate template copy before importing.")
                }
                let directory = values.isDirectory == true
                let package = directory && (values.isPackage == true || packages.contains(child.pathExtension.lowercased()))
                let icon = name == "Icon\r"
                if mode == .structure && (package || (!directory && !icon)) {
                    excluded.append(rel + (package ? " (package)" : " (file)")); continue
                }
                guard directory || values.isRegularFile == true else { throw AppFailure("Unsupported special file: \(rel)") }
                let renamed = try rename(name, metadata: icon, opaque: opaque, fields: fields)
                let out = output.isEmpty ? renamed : output + "/" + renamed
                guard names.insert(Naming.key(out)).inserted else { throw AppFailure("Case or Unicode name collision: \(out)") }
                entries.append(Entry(source: rel, output: out, directory: directory, metadata: icon, opaque: opaque,
                                     bytes: directory ? 0 : Int64(values.fileSize ?? 0), modified: values.contentModificationDate))
                if directory { try walk(child, relative: rel, output: out, opaque: opaque || package) }
            }
        }
        try walk(canonical, relative: "", output: "", opaque: false)
        return CopyPlan(root: canonical, entries: entries, excluded: excluded)
    }

    /// The single rename step. Metadata and package internals keep their names; everything else follows Naming.render.
    public static func rename(_ name: String, metadata: Bool, opaque: Bool, fields: ProjectFields?) throws -> String {
        guard let fields, !metadata, !opaque else { return name }
        return try Naming.render(name, fields: fields)
    }

    /// Derives the executable plan from a structural scan (fields nil) without touching the disk again.
    /// Produces exactly what scan(root, fields:) would, entry for entry, so a cached structure can be reused per keystroke.
    public static func plan(from structure: CopyPlan, fields: ProjectFields, renamingPaths: Set<String>? = nil) throws -> CopyPlan {
        var entries: [Entry] = []; var names = Set<String>(); var outputs: [String: String] = [:]
        for entry in structure.entries {
            let name = (entry.source as NSString).lastPathComponent
            let parent = (entry.source as NSString).deletingLastPathComponent
            let parentOutput = parent.isEmpty ? "" : (outputs[parent] ?? parent)
            let renamed = try rename(name, metadata: entry.metadata, opaque: entry.opaque,
                                     fields: renamingPaths.map { $0.contains(entry.source) } ?? true ? fields : nil)
            let out = parentOutput.isEmpty ? renamed : parentOutput + "/" + renamed
            guard names.insert(Naming.key(out)).inserted else { throw AppFailure("Case or Unicode name collision: \(out)") }
            if entry.directory { outputs[entry.source] = out }
            entries.append(Entry(source: entry.source, output: out, directory: entry.directory, metadata: entry.metadata,
                                 opaque: entry.opaque, bytes: entry.bytes, modified: entry.modified))
        }
        return CopyPlan(root: structure.root, entries: entries, excluded: structure.excluded)
    }
}

public enum IconService {
    public static let attributes = ["com.apple.FinderInfo", "com.apple.ResourceFork"]
    public static func captureFolderIcon(_ folder: URL) throws -> Data {
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true, let finder = try attribute("com.apple.FinderInfo", at: folder),
              finder.count >= 10, finder[8] & 0x04 != 0 else { throw AppFailure("This folder does not have a custom Finder icon.") }
        let image = NSWorkspace.shared.icon(forFile: folder.path)
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw AppFailure("Cannot capture this folder icon.") }
        return png
    }
    public static func attribute(_ name: String, at url: URL) throws -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0 {
            if errno == ENOATTR { return nil }
            throw AppFailure("Cannot read metadata at \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read == size else { throw AppFailure("Metadata changed while reading \(url.lastPathComponent). Retry the operation.") }
        return data
    }
    public static func copyMetadata(from source: URL, to target: URL) throws {
        for name in attributes {
            if let data = try attribute(name, at: source) {
                let result = data.withUnsafeBytes { setxattr(target.path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
                guard result == 0 else { throw AppFailure("Unable to preserve Finder icon metadata for \(target.lastPathComponent).") }
            }
        }
        if target.lastPathComponent == "Icon\r" {
            var flags = stat()
            guard lstat(target.path, &flags) == 0, chflags(target.path, flags.st_flags | UInt32(UF_HIDDEN)) == 0 else {
                throw AppFailure("Cannot hide the copied Finder icon support file.")
            }
        }
    }
    public static func apply(_ data: Data, to folder: URL) throws {
        guard let image = NSImage(data: data), NSWorkspace.shared.setIcon(image, forFile: folder.path, options: []) else {
            throw AppFailure("Finder could not apply the selected project icon. No project was committed. Check the destination and retry.")
        }
    }
}

/// Result of putting a template's folder icons back onto a project that lost them, for example one that lived in LucidLink.
public struct IconRestoreReport: Sendable {
    public var restored: [String] = []
    /// Project folders the template does not have, such as `06 Media Revised`, that took the icon of the template folder
    /// their name extends (`03 Media`).
    public var inherited: [String] = []
    /// Folders that extend two equally long template names; they are skipped rather than guessed.
    public var ambiguous: [String] = []
    public var unmatched: [String] = []
    public var failed: [String] = []
    public var outerIconApplied = false
    /// Stopped part way: what is listed was done, and a second restore finishes the rest.
    public var cancelled = false
    public var summary: String {
        var parts = [(cancelled ? "Cancelled part way. " : "") + "Restored \(restored.count) folder icons."]
        if !inherited.isEmpty { parts.append("\(inherited.count) more folders inherited the icon of the template folder their name extends.") }
        if !ambiguous.isEmpty { parts.append("\(ambiguous.count) folders match more than one template folder and were skipped.") }
        if outerIconApplied { parts.append("Project icon applied.") }
        if !unmatched.isEmpty { parts.append("\(unmatched.count) template folders were not found in the project and were skipped.") }
        if !failed.isEmpty { parts.append("\(failed.count) could not be written.") }
        return parts.joined(separator: " ")
    }
}

public extension IconService {
    /// Checks the complete destination folder layout before restore writes any metadata.
    static func preflight(template payload: URL, fields: ProjectFields, onto project: URL,
                          cancellation: Cancellation = Cancellation()) throws {
        let plan = try TemplateReader.scan(payload, fields: fields, cancellation: cancellation)
        try preflight(plan: plan, onto: project)
    }
    private static func preflight(plan: CopyPlan, onto project: URL) throws {
        guard (try project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw AppFailure("The project folder is unavailable.")
        }
        let fm = FileManager.default
        func directory(_ path: String) -> Bool {
            guard let values = try? URL(fileURLWithPath: path, isDirectory: true).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        func numberedPrefix(_ name: String) -> String? {
            let digits = name.prefix(while: \.isNumber)
            return digits.isEmpty ? nil : String(digits)
        }
        var childrenCache: [String: [URL]] = [:]
        func children(of folder: URL) throws -> [URL] {
            if let cached = childrenCache[folder.path] { return cached }
            do {
                let found = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
                childrenCache[folder.path] = found
                return found
            } catch {
                throw AppFailure("Cannot inspect project folder layout at \(folder.path): \(error.localizedDescription)")
            }
        }
        var conflicts: [String: Set<String>] = [:]
        for entry in plan.entries where entry.directory {
            var parent = project
            let components = entry.output.split(separator: "/").map(String.init)
            for (index, component) in components.enumerated() {
                let siblings = try children(of: parent)
                if let exact = siblings.first(where: { Naming.key($0.lastPathComponent) == Naming.key(component) }) {
                    if directory(exact.path) {
                        parent = exact
                        continue
                    }
                    let ancestor = components.prefix(index + 1).joined(separator: "/")
                    conflicts[ancestor, default: []].insert(exact.path)
                    break
                }
                if let expectedPrefix = numberedPrefix(component) {
                    for sibling in siblings where directory(sibling.path) {
                        guard numberedPrefix(sibling.lastPathComponent) == expectedPrefix,
                              Naming.key(sibling.lastPathComponent) != Naming.key(component) else { continue }
                        let ancestor = components.prefix(index + 1).joined(separator: "/")
                        conflicts[ancestor, default: []].insert(sibling.path)
                    }
                }
                break
            }
        }
        let oldPremiere = project.appendingPathComponent("02 Project Files/01 Video", isDirectory: true)
        let newPremiere = project.appendingPathComponent("02 Project Files/01 Premiere Pro", isDirectory: true)
        if directory(oldPremiere.path), directory(newPremiere.path) {
            conflicts["Premiere folder anchors", default: []].formUnion([oldPremiere.path, newPremiere.path])
        }
        guard conflicts.isEmpty else {
            let evidence = conflicts.keys.sorted().flatMap { ancestor in
                conflicts[ancestor, default: []].sorted().map { "\(ancestor) conflicts with \($0)" }
            }
            let shown = evidence.prefix(4).joined(separator: "; ")
            let omitted = evidence.count - min(evidence.count, 4)
            let more = omitted > 0 ? " +\(omitted) more conflicts." : "."
            throw AppFailure("The selected template does not match this project's folder layout. No icons were changed. Showing \(min(evidence.count, 4)) of \(evidence.count) conflicts: \(shown)\(more)")
        }
    }

    /// One folder that will receive an icon: the template's `Icon\r` and folder, and where they go in the project.
    private struct RestoreStep {
        let icon: URL, templateFolder: URL, target: URL, folder: URL, label: String, inherited: Bool
    }
    /// The folders a restore would write to, found without writing anything. Exact matches come first, in template order;
    /// then project folders that are not in the template but extend the name of one that has an icon.
    private static func restoreSteps(plan: CopyPlan, payload: URL, project: URL) throws -> (steps: [RestoreStep], unmatched: [String], ambiguous: [String]) {
        let fm = FileManager.default
        func isFolder(_ url: URL) -> Bool {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        func hasCustomIcon(_ url: URL) -> Bool {
            guard let info = try? attribute("com.apple.FinderInfo", at: url), info.count > 8 else { return false }
            return info[8] & 0x04 != 0
        }
        // The name after the numeric prefix: "03 Media" gives "media". "06 Media Revised" extends it.
        func plainName(_ name: String) -> String? {
            guard name.first?.isNumber == true else { return nil }
            let rest = name.drop(while: \.isNumber).drop(while: { " -._".contains($0) })
            return rest.isEmpty ? nil : Naming.key(String(rest))
        }
        var steps: [RestoreStep] = [], unmatched: [String] = []
        for entry in plan.entries where entry.metadata {
            let target = project.appendingPathComponent(entry.output), folder = target.deletingLastPathComponent()
            let parent = (entry.output as NSString).deletingLastPathComponent
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { unmatched.append(parent); continue }
            let source = payload.appendingPathComponent(entry.source)
            steps.append(RestoreStep(icon: source, templateFolder: source.deletingLastPathComponent(), target: target, folder: folder,
                                     label: parent.isEmpty ? "." : parent, inherited: false))
        }
        var candidates: [String: [(length: Int, step: RestoreStep)]] = [:]
        for entry in plan.entries where entry.metadata {
            let templateFolder = (entry.output as NSString).deletingLastPathComponent
            guard let base = plainName((templateFolder as NSString).lastPathComponent) else { continue }
            let parent = (templateFolder as NSString).deletingLastPathComponent
            let projectParent = parent.isEmpty ? project : project.appendingPathComponent(parent)
            guard isFolder(projectParent),
                  let siblings = try? fm.contentsOfDirectory(at: projectParent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
            let known = Set(plan.entries.filter { $0.directory && ($0.output as NSString).deletingLastPathComponent == parent }
                .map { Naming.key(($0.output as NSString).lastPathComponent) })
            for sibling in siblings where isFolder(sibling) && !known.contains(Naming.key(sibling.lastPathComponent)) {
                guard let extended = plainName(sibling.lastPathComponent), extended.hasPrefix(base + " "), !hasCustomIcon(sibling) else { continue }
                let source = payload.appendingPathComponent(entry.source)
                let step = RestoreStep(icon: source, templateFolder: source.deletingLastPathComponent(), target: sibling.appendingPathComponent("Icon\r"), folder: sibling,
                                       label: (parent.isEmpty ? "" : parent + "/") + sibling.lastPathComponent, inherited: true)
                candidates[sibling.path, default: []].append((base.count, step))
            }
        }
        // The longest template name wins when a folder extends more than one; an exact tie is skipped and reported.
        var ambiguous: [String] = [], inherited: [RestoreStep] = []
        for options in candidates.values {
            let longest = options.map(\.length).max() ?? 0, top = options.filter { $0.length == longest }
            if top.count == 1 { inherited.append(top[0].step) } else { ambiguous.append(top[0].step.label) }
        }
        steps += inherited.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        return (steps, unmatched, ambiguous.sorted())
    }

    /// Which folders `restore` would write to, found without writing anything. Runs the same layout check first.
    static func restorePreview(template payload: URL, fields: ProjectFields, onto project: URL,
                               cancellation: Cancellation = Cancellation()) throws -> IconRestoreReport {
        let plan = try TemplateReader.scan(payload, fields: fields, cancellation: cancellation)
        try preflight(plan: plan, onto: project)
        let found = try restoreSteps(plan: plan, payload: payload, project: project)
        var report = IconRestoreReport()
        report.restored = found.steps.filter { !$0.inherited }.map(\.label)
        report.inherited = found.steps.filter(\.inherited).map(\.label)
        report.unmatched = found.unmatched; report.ambiguous = found.ambiguous
        return report
    }

    /// Reattaches every custom folder icon the template carries onto the matching folders of an existing project,
    /// matched by the same substituted paths creation would have produced. Files are never touched, folders are never
    /// created, renamed or removed; a folder the project no longer has is reported, not made. A project folder the template
    /// does not have but whose name extends a template folder's (`06 Media Revised` beside `03 Media`) takes that icon too.
    /// The outer folder gets the preset icon when one is given. Works only on a filesystem that accepts the `Icon\r` support file.
    static func restore(template payload: URL, fields: ProjectFields, onto project: URL, presetIcon: Data? = nil,
                        cancellation: Cancellation = Cancellation()) throws -> IconRestoreReport {
        let plan = try TemplateReader.scan(payload, fields: fields, cancellation: cancellation)
        try preflight(plan: plan, onto: project)
        var report = IconRestoreReport()
        let fm = FileManager.default
        let found = try restoreSteps(plan: plan, payload: payload, project: project)
        report.unmatched = found.unmatched; report.ambiguous = found.ambiguous
        // Icon\r files first, then their folders, so the custom-icon flag never points at a missing file.
        for step in found.steps {
            if cancellation.isCancelled { report.cancelled = true; return report }
            var createdIcon = false
            do {
                if !fm.fileExists(atPath: step.target.path) { try Data(contentsOf: step.icon).write(to: step.target, options: .withoutOverwriting); createdIcon = true }
                let values = try step.target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw AppFailure("Icon support must be an ordinary file.") }
                try copyMetadata(from: step.icon, to: step.target)
                try copyMetadata(from: step.templateFolder, to: step.folder)
                if step.inherited { report.inherited.append(step.label) } else { report.restored.append(step.label) }
            } catch {
                if createdIcon { try? fm.removeItem(at: step.target) }
                report.failed.append("\(step.label): \(error.localizedDescription)")
            }
        }
        if let presetIcon {
            do { try apply(presetIcon, to: project); report.outerIconApplied = true }
            catch { report.failed.append("project folder icon: \(error.localizedDescription)") }
        }
        return report
    }
}

public struct IconStripReport: Sendable {
    public var iconFilesRemoved: [String] = []
    public var foldersCleared: [String] = []
    public var failed: [String] = []
    /// Stopped part way: what is listed was done.
    public var cancelled = false
    public var summary: String {
        var parts = [(cancelled ? "Cancelled part way. " : "") + "Removed \(iconFilesRemoved.count) icon files and cleared \(foldersCleared.count) folders."]
        if !failed.isEmpty { parts.append("\(failed.count) could not be changed.") }
        return parts.joined(separator: " ")
    }
}

public extension IconService {
    /// Removes custom folder icons from a project so it can be copied to a drive that cannot hold them:
    /// every `Icon\r` file goes, and every folder loses its FinderInfo and resource fork. Ordinary files are never touched.
    /// The template keeps the icons, so `restore` can put them back later.
    /// With `dryRun` nothing is removed or cleared; the report lists what would be.
    static func strip(project: URL, dryRun: Bool = false, cancellation: Cancellation = Cancellation()) throws -> IconStripReport {
        guard (try project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw AppFailure("The project folder is unavailable.") }
        var report = IconStripReport()
        let fm = FileManager.default
        var folders: [URL] = [project]
        guard let enumerator = fm.enumerator(at: project, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isRegularFileKey], options: []) else { throw AppFailure("Cannot read the project folder.") }
        for case let url as URL in enumerator {
            // A stop returns what was already done, so a partial removal is never reported as "nothing happened".
            if cancellation.isCancelled { report.cancelled = true; return report }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isRegularFileKey])
            if values.isSymbolicLink == true { continue }
            if values.isPackage == true { enumerator.skipDescendants(); continue }
            if url.lastPathComponent == "Icon\r" {
                guard values.isRegularFile == true else { enumerator.skipDescendants(); report.failed.append(relative(url, to: project) + ": not an ordinary icon file"); continue }
                do { if !dryRun { try fm.removeItem(at: url) }; report.iconFilesRemoved.append(relative(url, to: project)) }
                catch { report.failed.append("\(relative(url, to: project)): \(error.localizedDescription)") }
            } else if values.isDirectory == true { folders.append(url) }
        }
        for folder in folders {
            if cancellation.isCancelled { report.cancelled = true; return report }
            var changed = false, problem: String?
            for name in attributes where (try? attribute(name, at: folder)) ?? nil != nil {
                if dryRun || removexattr(folder.path, name, XATTR_NOFOLLOW) == 0 { changed = true } else { problem = String(cString: strerror(errno)) }
            }
            if let problem { report.failed.append("\(relative(folder, to: project)): \(problem)") }
            else if changed { report.foldersCleared.append(relative(folder, to: project)) }
        }
        return report
    }
    private static func relative(_ url: URL, to root: URL) -> String {
        // Enumerated paths may carry the /private prefix that Foundation strips from /tmp and /var, and a name
        // with a carriage return does not resolve, so compare both sides without that prefix.
        func canonical(_ path: String) -> String { path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path }
        let base = canonical(root.path), path = canonical(url.path)
        let clean = (path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return clean.isEmpty ? "." : clean.replacingOccurrences(of: "\r", with: "")
    }
}

public enum CreationEngine {
    public typealias Progress = @Sendable (Double, String) -> Void

    /// Both corrected copies and idea promotion verify staged bytes before their exclusive commit.
    public static func verifyCopiedBytes(plan: CopyPlan, at stage: URL, cancellation: Cancellation = Cancellation(),
                                         allowingExtraPaths: Set<String> = []) throws {
        var expected: [String: Bool] = [:]
        for entry in plan.entries {
            guard expected.updateValue(entry.directory, forKey: entry.output) == nil else { throw AppFailure("Duplicate output in verification plan.") }
        }
        var seen = Set<String>(), enumerationError: Error?
        func components(_ url: URL) -> [String] {
            var path = url.standardizedFileURL.path
            if path == "/var" || path.hasPrefix("/var/") || path == "/tmp" || path.hasPrefix("/tmp/") { path = "/private" + path }
            return (path as NSString).pathComponents
        }
        let stageComponents = components(stage)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let stageValues = try stage.resourceValues(forKeys: keys)
        guard stageValues.isDirectory == true, stageValues.isSymbolicLink != true,
              stageComponents == components(stage.resolvingSymlinksInPath()) else { throw AppFailure("The staging folder changed during verification.") }
        guard let walker = FileManager.default.enumerator(at: stage, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, error in
            enumerationError = error; return false
        }) else { throw AppFailure("Cannot enumerate the staged copy for verification.") }
        for case let url as URL in walker {
            try cancellation.check()
            let pathComponents = components(url)
            guard pathComponents.starts(with: stageComponents) else { throw AppFailure("A staged path escaped during verification.") }
            let relative = pathComponents.dropFirst(stageComponents.count).joined(separator: "/")
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { throw AppFailure("Unsupported staged entry: \(relative)") }
            if let directory = expected[relative] {
                guard directory == (values.isDirectory == true) else { throw AppFailure("Staged entry type changed: \(relative)") }
                seen.insert(relative)
            } else {
                guard allowingExtraPaths.contains(relative), values.isRegularFile == true else { throw AppFailure("Unexpected staged entry: \(relative)") }
            }
        }
        if let enumerationError { throw enumerationError }
        guard seen == Set(expected.keys) else { throw AppFailure("Files or empty folders are missing from the staged copy.") }
        func digest(_ url: URL) throws -> SHA256.Digest {
            try cancellation.check()
            guard components(url) == components(url.resolvingSymlinksInPath()) else { throw AppFailure("A file path changed during copy verification.") }
            let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw AppFailure("Cannot verify \(url.lastPathComponent).") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw AppFailure("Expected an ordinary file during verification.") }
            var hash = SHA256()
            while true {
                try cancellation.check()
                guard let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty else { break }
                hash.update(data: bytes)
            }
            return hash.finalize()
        }
        for entry in plan.entries where !entry.directory {
            let source = plan.root.appendingPathComponent(entry.source), target = stage.appendingPathComponent(entry.output)
            guard source.standardizedFileURL.path.hasPrefix(plan.root.path + "/"), target.standardizedFileURL.path.hasPrefix(stage.path + "/"),
                  try digest(source) == digest(target) else { throw AppFailure("Copied bytes could not be verified: \(entry.source). Nothing was committed.") }
        }
    }

    /// Makes an independent, allowlisted-metadata copy into a new destination. Never merges.
    /// `finderMetadata: false` copies plain files and folders only: no FinderInfo, resource forks or preset icon,
    /// for filesystems such as LucidLink that reject the `Icon\r` support file. Default behaviour is unchanged.
    public static func create(plan: CopyPlan, destination: URL, name: String, icon: Data? = nil, finderMetadata: Bool = true,
                              cancellation: Cancellation = Cancellation(), progress: Progress = { _, _ in },
                              strictExclusiveCommit: Bool = false, prepareCommit: ((URL) throws -> Void)? = nil) throws -> URL {
        try Naming.validate(name)
        try cancellation.check()
        let fm = FileManager.default
        let destination = destination.resolvingSymlinksInPath()
        let values = try destination.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw AppFailure("Destination folder is unavailable. Choose a mounted, writable folder.") }
        guard destination != plan.root, !destination.path.hasPrefix(plan.root.path + "/") else {
            throw AppFailure("Destination must be outside the template being copied.")
        }
        let final = destination.appendingPathComponent(name)
        guard !fm.fileExists(atPath: final.path) else { throw AppFailure("A project named ‘\(name)’ already exists. Nothing has been overwritten.") }
        let stage = destination.appendingPathComponent(".project-templates-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? fm.removeItem(at: stage) } }
        var completed: Int64 = 0
        var lastProgress = Date.distantPast
        for entry in plan.entries {
            try cancellation.check()
            let source = plan.root.appendingPathComponent(entry.source)
            let target = stage.appendingPathComponent(entry.output)
            // Plans are internal, but enforce containment again at the writing boundary.
            guard source.standardizedFileURL.path.hasPrefix(plan.root.path + "/"),
                  source.resolvingSymlinksInPath().path == source.standardizedFileURL.path,
                  target.standardizedFileURL.path.hasPrefix(stage.path + "/") else {
                throw AppFailure("Template path changed or escaped its root. Nothing was committed.")
            }
            let current = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            guard current.isSymbolicLink != true, (current.isDirectory == true) == entry.directory,
                  entry.directory || (Int64(current.fileSize ?? 0) == entry.bytes && current.contentModificationDate == entry.modified) else {
                throw AppFailure("Template changed since preview: \(entry.source). Refresh the preview and retry.")
            }
            if entry.directory {
                try fm.createDirectory(at: target, withIntermediateDirectories: false)
            } else {
                let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
                guard descriptor >= 0 else { throw AppFailure("Cannot read \(entry.source). Check access and download any cloud-only files first.") }
                let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? input.close() }
                let outputDescriptor = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
                guard outputDescriptor >= 0 else { throw AppFailure("Cannot create \(entry.output) without overwriting. Check free space and permissions.") }
                let output = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
                defer { try? output.close() }
                while true {
                    try cancellation.check()
                    guard let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
                    try output.write(contentsOf: chunk)
                    completed += Int64(chunk.count)
                    if Date().timeIntervalSince(lastProgress) > 0.08 {
                        progress(Double(completed) / Double(max(plan.bytes, 1)), entry.output)
                        lastProgress = Date()
                    }
                }
                try output.synchronize()
                let copied = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard Int64(copied) == entry.bytes, after.contentModificationDate == entry.modified else {
                    throw AppFailure("File changed during copying: \(entry.source). Nothing was committed.")
                }
                if finderMetadata { try IconService.copyMetadata(from: source, to: target) }
            }
        }
        if finderMetadata {
            // Directory metadata follows children, so the custom-icon flag and Icon\r arrive together.
            for entry in plan.entries.reversed() where entry.directory {
                try cancellation.check()
                try IconService.copyMetadata(from: plan.root.appendingPathComponent(entry.source), to: stage.appendingPathComponent(entry.output))
            }
            try IconService.copyMetadata(from: plan.root, to: stage)
            if let icon { try IconService.apply(icon, to: stage) }
        }
        try cancellation.check()
        progress(1, "Finalising")
        try prepareCommit?(stage)
        try cancellation.check()
        // RENAME_EXCL prevents a late destination race from replacing another project's folder.
        if renamex_np(stage.path, final.path, UInt32(RENAME_EXCL)) != 0 {
            // SMB mounts such as LucidLink do not support the exclusive rename (ENOTSUP). Re-check the destination
            // and use a plain rename; the check-then-rename window is the best that filesystem allows.
            guard !strictExclusiveCommit, errno == ENOTSUP, !fm.fileExists(atPath: final.path), rename(stage.path, final.path) == 0 else {
                throw AppFailure("Could not finalise without replacing an existing path: \(String(cString: strerror(errno))). Nothing was overwritten.")
            }
        }
        committed = true
        progress(1, "Complete")
        return final
    }
}
