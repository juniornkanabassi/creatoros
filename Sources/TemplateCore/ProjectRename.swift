import Foundation
import Darwin

public struct ProjectRenameChange: Codable, Sendable, Hashable {
    public let path: String
    public let from: String
    public let to: String
    public let heading: Bool
}
public struct ProjectRenamePlan: Sendable {
    public let root: URL
    public let oldName: String, newName: String
    public let changes: [ProjectRenameChange]
    public let warnings: [String]
    fileprivate let record: ProjectRecord
    fileprivate let fields: ProjectFields
    fileprivate let updateHeadings: Bool
    public var newRoot: URL { root.deletingLastPathComponent().appendingPathComponent(newName) }
}
public struct ProjectRenameResult: Sendable {
    public let oldRoot: URL, newRoot: URL, manifest: URL
    public let changes: [ProjectRenameChange]
}

public enum ProjectRename {
    public static func requireExclusiveRenaming(_ supported: Bool?) throws {
        guard supported == true else { throw AppFailure("This drive cannot rename safely. Rename in Finder, then use Locate Folder in CreatorOS.") }
    }
    public static func fields(of record: ProjectRecord) -> ProjectFields? {
        let parts = record.name.components(separatedBy: " — ")
        guard !record.isPlanned, parts.count == 3 || parts.count == 4,
              parts[0].range(of: #"^\d+$"#, options: .regularExpression) != nil,
              parts[1] == record.format else { return nil }
        return ProjectFields(number: parts[0], format: parts[1], campaign: parts.count == 4 ? parts[2] : "", title: parts.last!)
    }
    public static func plan(record: ProjectRecord, number: String, campaign: String, title: String,
                            updateHeadings: Bool = false, runtime: AppRuntime,
                            cancellation: Cancellation = Cancellation()) throws -> ProjectRenamePlan {
        guard let old = fields(of: record) else { throw AppFailure("Rename needs a folder named Number — Format — [Campaign — ]Title. Planned ideas cannot be renamed here.") }
        let fields = ProjectFields(number: number, format: record.format, campaign: campaign, title: title)
        let newName = try fields.finalName()
        guard number.range(of: #"^\d+$"#, options: .regularExpression) != nil else { throw AppFailure("Use digits for the project number.") }
        guard Naming.key(newName) != Naming.key(record.name) else { throw AppFailure("Choose a different name; case-only and unchanged renames are refused.") }
        let unresolved = try record.resolve()
        try runtime.requireWritable(unresolved)
        let root = unresolved.standardizedFileURL.resolvingSymlinksInPath()
        let libraries = [runtime.root, AppRuntime.stableRoot, AppRuntime.alphaRoot]
        guard !libraries.contains(where: { AppRuntime.contains(root, $0) || AppRuntime.contains($0.appendingPathComponent("Templates"), root) || root.deletingLastPathComponent() == $0 }) else { throw AppFailure("Library folders and managed templates cannot be renamed.") }
        try runtime.requireWritable(root)
        guard root.lastPathComponent == record.name,
              try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true else { throw AppFailure("The project moved or is unavailable. Locate Folder before renaming.") }
        try requireExclusiveRenaming(root.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey]).volumeSupportsExclusiveRenaming)
        // Reuse the browser's ancestor/symlink/package validation without reading media.
        _ = try BrowserTransfer.dragURL(root: root.deletingLastPathComponent(), relative: root.lastPathComponent)
        let fm = FileManager.default
        guard !(try fm.contentsOfDirectory(atPath: root.deletingLastPathComponent().path)).contains(where: { Naming.key($0) == Naming.key(newName) }) else { throw AppFailure("The new project name already exists, including a case or Unicode variant.") }
        func relative(_ child: URL) -> String {
            func canonical(_ path: String) -> String { path.hasPrefix("/private/") ? String(path.dropFirst(8)) : path }
            return String(canonical(child.path).dropFirst(canonical(root.path).count + 1))
        }
        var headings: [ProjectRenameChange] = [], renames: [ProjectRenameChange] = []
        func replacement(_ name: String) -> String {
            name.components(separatedBy: record.name).map { $0.replacingOccurrences(of: old.title, with: title) }.joined(separator: newName)
        }
        func walk(_ directory: URL) throws {
            try cancellation.check()
            let children = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey, .isRegularFileKey]).sorted { $0.path < $1.path }
            var names = Set<String>()
            for child in children {
                try cancellation.check()
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey, .isRegularFileKey])
                let name = child.lastPathComponent
                let excluded = name.hasPrefix(".") || name == "Icon\r" || values.isHidden == true || values.isSymbolicLink == true || (values.isDirectory != true && values.isRegularFile != true) || (directory.standardizedFileURL.resolvingSymlinksInPath() == root && name == "03 Media")
                let next = excluded ? name : replacement(name)
                guard names.insert(Naming.key(next)).inserted else { throw AppFailure("Rename would collide at \(child.path), including case or Unicode variants.") }
                if excluded { continue }
                if next != name { guard Naming.key(next) != Naming.key(name) else { throw AppFailure("Case-only rename is refused at " + child.path) }; try Naming.validate(next); renames.append(ProjectRenameChange(path: relative(child), from: name, to: next, heading: false)) }
                if values.isPackage == true || TemplateReader.packages.contains(child.pathExtension.lowercased()) { continue }
                if values.isDirectory == true { try walk(child) }
                else if updateHeadings && values.isRegularFile == true && child.pathExtension.lowercased() == "md" {
                    // ponytail: headings in Markdown files up to 8 MiB; leave larger documents unchanged.
                    guard (try child.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8 * 1024 * 1024 else { continue }
                    let bytes = try Data(contentsOf: child)
                    guard String(data: bytes, encoding: .utf8) != nil else { continue }
                    let line = firstLine(bytes)
                    if line.hasPrefix("#"), line.contains(record.name) { headings.append(ProjectRenameChange(path: relative(child), from: line, to: line.replacingOccurrences(of: record.name, with: newName), heading: true)) }
                }
            }
        }
        try walk(root)
        renames.sort { let a = $0.path.split(separator: "/").count, b = $1.path.split(separator: "/").count; return a == b ? $0.path < $1.path : a > b }
        renames.append(ProjectRenameChange(path: "", from: record.name, to: newName, heading: false))
        return ProjectRenamePlan(root: root, oldName: record.name, newName: newName, changes: headings + renames,
                                 warnings: ["Absolute media paths change. Relink Premiere media and update Watchtower paths separately."], record: record, fields: fields, updateHeadings: updateHeadings)
    }
    private static func move(_ from: URL, _ to: URL) throws {
        guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else { throw AppFailure("Cannot rename without overwriting \(to.path): \(String(cString: strerror(errno)))") }
    }
    private static func firstLine(_ data: Data) -> String {
        let start = data.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        let end = data.firstIndex(of: 10) ?? data.endIndex
        return String(decoding: data[start..<end], as: UTF8.self)
    }
    private static func heading(_ url: URL, from: String, to: String) throws {
        let data = try Data(contentsOf: url)
        guard String(data: data, encoding: .utf8) != nil else { throw AppFailure("Markdown changed since review: \(url.path)") }
        guard firstLine(data) == from else { throw AppFailure("Markdown changed since review: \(url.path)") }
        // Write in place: retain inode, Finder metadata and permissions.
        let fd = Darwin.open(url.path, O_WRONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw AppFailure("Cannot update heading at \(url.path)") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        let bom = data.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        var replacement = Data(data.prefix(bom))
        replacement.append(contentsOf: to.utf8)
        replacement.append(data.dropFirst(bom + from.utf8.count))
        do { try file.write(contentsOf: replacement); try file.truncate(atOffset: UInt64(replacement.count)); try file.synchronize() }
        catch {
            do { try file.seek(toOffset: 0); try file.write(contentsOf: data); try file.truncate(atOffset: UInt64(data.count)); try file.synchronize() }
            catch { throw AppFailure("Heading update and restoration failed at \(url.path): \(error.localizedDescription)") }
            throw error
        }
    }
    private static func undo(_ changes: [ProjectRenameChange], root: URL, newRoot: URL) throws {
        var current = newRoot
        for change in changes.reversed() {
            if change.path.isEmpty { try move(current, root); current = root }
            else {
                let old = current.appendingPathComponent(change.path)
                if change.heading { try heading(old, from: change.to, to: change.from) }
                else { try move(old.deletingLastPathComponent().appendingPathComponent(change.to), old) }
            }
        }
    }
    public static func apply(_ plan: ProjectRenamePlan, runtime: AppRuntime) throws -> ProjectRenameResult {
        let fresh = try self.plan(record: plan.record, number: plan.fields.number, campaign: plan.fields.campaign, title: plan.fields.title, updateHeadings: plan.updateHeadings, runtime: runtime)
        guard fresh.changes == plan.changes, fresh.root == plan.root else { throw AppFailure("The rename list changed. Review a fresh plan.") }
        var done: [ProjectRenameChange] = []
        var current = plan.root
        let manifestParent = plan.root.appendingPathComponent("05 Other")
        // Validate the future manifest's parent before moving anything, including symlinks.
        if FileManager.default.fileExists(atPath: manifestParent.path) { try runtime.requireWritable(manifestParent) }
        var manifest: URL?
        do {
            for change in plan.changes {
                let old = change.path.isEmpty ? current : current.appendingPathComponent(change.path)
                try runtime.requireWritable(old)
                if change.heading { try heading(old, from: change.from, to: change.to) }
                else { try move(old, old.deletingLastPathComponent().appendingPathComponent(change.to)) }
                done.append(change)
                if change.path.isEmpty { current = plan.newRoot }
            }
            let other = current.appendingPathComponent("05 Other")
            let parent = (try? other.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? other : current
            try runtime.requireWritable(parent)
            let url = parent.appendingPathComponent("Rename-" + UUID().uuidString + ".json")
            let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw AppFailure("Cannot create rename manifest without overwriting.") }
            manifest = url
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? file.close() }
            try file.write(contentsOf: JSONEncoder().encode(plan.changes)); try file.synchronize()
            return ProjectRenameResult(oldRoot: plan.root, newRoot: current, manifest: url, changes: done)
        } catch {
            if let manifest { try? FileManager.default.removeItem(at: manifest) }
            do { try undo(done, root: plan.root, newRoot: current) }
            catch let rollback { throw AppFailure("Rename failed and rollback needs attention at \(current.path): \(rollback.localizedDescription).") }
            throw error
        }
    }
    public static func revert(_ result: ProjectRenameResult) throws {
        try undo(result.changes, root: result.oldRoot, newRoot: result.newRoot)
        let relativeManifest = result.manifest.path.dropFirst(result.newRoot.path.count)
        try? FileManager.default.removeItem(atPath: result.oldRoot.path + relativeManifest)
    }
}
