import Foundation
import Darwin

public struct CompatibilityFinding: Sendable {
    public let path: String
    public let problem: String
    public let corrected: String?
}

public struct CompatibilityRename: Codable, Sendable {
    public let from: String
    public let to: String
}

public struct CompatibilityReport: Sendable {
    public let root: URL
    public let rootName: String
    public var suggestedRootName: String { Naming.corrected(rootName) }
    public var findings: [CompatibilityFinding] = []
    public var iconFiles: [String] = []
    public var longPaths: [String] = []
    public var packages: [String] = []
    public var skipped: [String] = []
    public var errors: [String] = []
    public var collisions: [String] = []
    public var entries = 0
    public var isComplete: Bool { skipped.isEmpty && errors.isEmpty }
    public var canCopy: Bool { isComplete && collisions.isEmpty && structure != nil }
    public let pathLengthAssumption = "Advisory only: paths at least 260 UTF-16 units with an assumed C:\\Projects\\ prefix. Windows application and long-path support vary."
    fileprivate var structure: CopyPlan?
    fileprivate var inventory: [String: CompatibilityStamp] = [:]
    fileprivate var maxEntries = 100_000
    fileprivate var maxDepth = 128
}

public struct CompatibilityProposal: Sendable {
    public let outputName: String
    public let renames: [CompatibilityRename]
    public let plan: CopyPlan
    public let omittedIcons: [String]
    fileprivate let report: CompatibilityReport
}

/// File identity and mutation times also catch replacement with a same-size, same-mtime file.
fileprivate struct CompatibilityStamp: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let mode: UInt16
    let bytes: Int64
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    init(_ url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw AppFailure("Cannot inspect \(url.path): \(String(cString: strerror(errno)))") }
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode; bytes = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
    }
}

public enum Compatibility {
    public static let manifestName = "CreatorOS Rename Manifest.json"

    /// Audits actual names, including hidden entries. It never expands template tokens or reads document contents.
    public static func scan(_ selected: URL, cancellation: Cancellation = Cancellation(), maxEntries: Int = 100_000,
                            maxDepth: Int = 128) throws -> CompatibilityReport {
        try cancellation.check()
        let root = selected.standardizedFileURL.resolvingSymlinksInPath()
        var report = CompatibilityReport(root: root, rootName: selected.lastPathComponent)
        report.maxEntries = maxEntries; report.maxDepth = maxDepth
        var entries: [Entry] = []
        do {
            // Permit the system /tmp and /var aliases, but reject user-selected symlink roots and ancestors.
            guard selected.isFileURL, systemPath(selected.standardizedFileURL.path) == systemPath(root.path), root.pathComponents.count > 2,
                  root.path != URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path else {
                throw AppFailure("Choose a specific ordinary project folder, without symbolic-link ancestors.")
            }
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  values.isPackage != true, !TemplateReader.packages.contains(root.pathExtension.lowercased()) else {
                throw AppFailure("The source must be an available ordinary project folder, not a package or link.")
            }
            report.inventory[""] = try CompatibilityStamp(root)
            if try hasFinderIcon(root) { report.iconFiles.append(report.rootName + " (custom Finder icon metadata)") }
            guard maxEntries > 0, maxDepth > 0 else { throw AppFailure("The scan limits must be positive.") }
        } catch { report.errors.append(error.localizedDescription); return report }
        var packagePaths = Set<String>()
        var visited = 1
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { url, error in
            report.errors.append("\(url.path): \(error.localizedDescription)"); return false
        }) else { report.errors.append("Cannot enumerate the source folder."); return report }
        while let value = walker.nextObject() {
            try cancellation.check()
            guard visited < maxEntries else { report.skipped.append("Enumeration limit of \(maxEntries) entries reached."); break }
            visited += 1
            guard let child = value as? URL else { report.errors.append("Unexpected directory entry."); break }
            let components = (systemPath(child.standardizedFileURL.path) as NSString).pathComponents
            let rootComponents = (systemPath(root.path) as NSString).pathComponents
            guard components.starts(with: rootComponents) else { report.errors.append("An entry escaped the source root."); break }
            let parts = Array(components.dropFirst(rootComponents.count))
            guard !parts.isEmpty else { report.errors.append("Unexpected root entry."); break }
            let relative = parts.joined(separator: "/")
            guard parts.count <= maxDepth else { walker.skipDescendants(); report.skipped.append("Depth limit: \(relative)"); continue }
            do {
                let values = try child.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { walker.skipDescendants(); report.skipped.append("Symbolic link: \(relative)"); continue }
                guard values.isDirectory == true || values.isRegularFile == true else {
                    walker.skipDescendants(); report.skipped.append("Unsupported special file: \(relative)"); continue
                }
                let opaque = (1..<parts.count).contains { packagePaths.contains(parts.prefix($0).joined(separator: "/")) }
                let package = values.isDirectory == true && (values.isPackage == true || TemplateReader.packages.contains(child.pathExtension.lowercased()))
                if package { packagePaths.insert(relative); report.packages.append(relative + " (contents audited; names and bytes remain opaque)") }
                let icon = child.lastPathComponent == "Icon\r"
                if icon && values.isDirectory == true {
                    report.errors.append("Icon support name is a directory and cannot be omitted safely: \(relative)")
                }
                if values.isDirectory == true, try hasFinderIcon(child) {
                    report.iconFiles.append(report.rootName + "/" + relative + " (custom Finder icon metadata)")
                }
                // A plain copy would lose an ordinary file's resource-fork data, so refuse instead of discarding it.
                if values.isRegularFile == true && !icon {
                    let length = getxattr(child.path, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW)
                    if length > 0 { report.errors.append("Resource-fork content requires a metadata-preserving copy: \(relative)") }
                    else if length < 0 && errno != ENOATTR && errno != ENOTSUP { throw AppFailure("Cannot inspect resource-fork metadata: \(relative)") }
                }
                report.inventory[relative] = try CompatibilityStamp(child)
                entries.append(Entry(source: relative, output: relative, directory: values.isDirectory == true, metadata: icon,
                                     opaque: opaque, bytes: values.isDirectory == true ? 0 : Int64(values.fileSize ?? 0), modified: values.contentModificationDate))
            } catch { walker.skipDescendants(); report.errors.append("\(relative): \(error.localizedDescription)") }
        }
        report.structure = CopyPlan(root: root, entries: entries, excluded: [])
        addNames(entries: entries, to: &report)
        return report
    }

    /// Prospective-output audit uses the existing plan's output names and performs no filesystem reads.
    public static func scan(plan: CopyPlan, outerName: String) -> CompatibilityReport {
        var report = CompatibilityReport(root: plan.root, rootName: outerName)
        report.skipped = plan.excluded
        addNames(entries: plan.entries, to: &report)
        return report
    }

    private static func hasFinderIcon(_ url: URL) throws -> Bool {
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = getxattr(url.path, "com.apple.FinderInfo", &bytes, bytes.count, 0, XATTR_NOFOLLOW)
        if count < 0 {
            guard errno == ENOATTR || errno == ENOTSUP else { throw AppFailure("Cannot inspect Finder metadata: \(url.path)") }
            return false
        }
        return count >= 10 && bytes[8] & 0x04 != 0
    }

    private static func systemPath(_ path: String) -> String {
        if path == "/var" || path.hasPrefix("/var/") || path == "/tmp" || path.hasPrefix("/tmp/") { return "/private" + path }
        return path
    }

    private static func addNames(entries: [Entry], to report: inout CompatibilityReport) {
        report.entries = entries.count + 1
        func inspect(_ path: String, name: String, opaque: Bool = false) {
            let problems = Naming.problems(name)
            if !problems.isEmpty {
                report.findings.append(CompatibilityFinding(path: path, problem: problems.joined(separator: "; "), corrected: opaque ? nil : Naming.corrected(name)))
            }
            if ("C:\\Projects\\" + path.replacingOccurrences(of: "/", with: "\\")).utf16.count >= 260 { report.longPaths.append(path) }
        }
        inspect(report.rootName, name: report.rootName)
        var outputs: [String: [String]] = [:]
        for entry in entries {
            let path = report.rootName + "/" + entry.output
            if entry.opaque && !Naming.problems((entry.output as NSString).lastPathComponent).isEmpty {
                report.errors.append("Package-internal name cannot be repaired: \(entry.output)")
            }
            if entry.metadata { report.iconFiles.append(path.replacingOccurrences(of: "\r", with: "\\r")); continue }
            inspect(path, name: (entry.output as NSString).lastPathComponent, opaque: entry.opaque)
            let corrected = entry.output.split(separator: "/").map { Naming.corrected(String($0)) }.joined(separator: "/")
            outputs[Naming.key(corrected), default: []].append(entry.output)
        }
        report.collisions = outputs.values.filter { $0.count > 1 }.map { $0.sorted().joined(separator: " ↔ ") }.sorted()
    }

    public static func proposal(_ report: CompatibilityReport) throws -> CompatibilityProposal {
        guard report.canCopy, let structure = report.structure else {
            throw AppFailure("Repair requires a complete scan with no collisions, unsupported entries or package-internal problems.")
        }
        var entries: [Entry] = [], renames: [CompatibilityRename] = [], icons: [String] = []
        var directories: [String: String] = ["": ""]
        if report.rootName != report.suggestedRootName { renames.append(CompatibilityRename(from: report.rootName, to: report.suggestedRootName)) }
        for entry in structure.entries {
            if entry.metadata { icons.append(entry.source); continue }
            let parent = (entry.source as NSString).deletingLastPathComponent
            guard let parentOutput = directories[parent] else { throw AppFailure("Incomplete parent directory in copy plan.") }
            let oldName = (entry.source as NSString).lastPathComponent
            let name = entry.opaque ? oldName : Naming.corrected(oldName)
            let output = parentOutput.isEmpty ? name : parentOutput + "/" + name
            if entry.directory { directories[entry.source] = output }
            if entry.source != output { renames.append(CompatibilityRename(from: report.rootName + "/" + entry.source, to: report.suggestedRootName + "/" + output)) }
            entries.append(Entry(source: entry.source, output: output, directory: entry.directory, metadata: false, opaque: entry.opaque, bytes: entry.bytes, modified: entry.modified))
        }
        guard !entries.contains(where: { Naming.key($0.output) == Naming.key(manifestName) }) else {
            throw AppFailure("The source already contains \(manifestName). Choose a source without a conflicting manifest.")
        }
        return CompatibilityProposal(outputName: report.suggestedRootName, renames: renames,
                                     plan: CopyPlan(root: structure.root, entries: entries, excluded: icons), omittedIcons: icons, report: report)
    }

    public static func copy(_ proposal: CompatibilityProposal, destination: URL, name: String? = nil,
                            cancellation: Cancellation = Cancellation(), progress: CreationEngine.Progress = { _, _ in }) throws -> URL {
        let outputName = name ?? proposal.outputName
        try Naming.validate(outputName)
        let root = proposal.plan.root
        func verifySource() throws {
            let fresh = try scan(root, cancellation: cancellation, maxEntries: proposal.report.maxEntries, maxDepth: proposal.report.maxDepth)
            guard fresh.isComplete, fresh.inventory == proposal.report.inventory else {
                throw AppFailure("The source changed or could not be completely read since preview. Scan it again.")
            }
        }
        try verifySource()
        return try CreationEngine.create(plan: proposal.plan, destination: destination, name: outputName, finderMetadata: false,
                                         cancellation: cancellation, progress: progress, strictExclusiveCommit: true, prepareCommit: { stage in
            try verifySource()
            try CreationEngine.verifyCopiedBytes(plan: proposal.plan, at: stage, cancellation: cancellation)
            try verifySource()
            struct Manifest: Encodable {
                let source: String
                let destinationName: String
                let renames: [CompatibilityRename]
                let omittedIconFiles: [String]
                let note: String
            }
            var renames = proposal.renames.map { rename in
                CompatibilityRename(from: rename.from, to: outputName + String(rename.to.dropFirst(proposal.outputName.count)))
            }
            if proposal.report.rootName == proposal.outputName && outputName != proposal.outputName {
                renames.insert(CompatibilityRename(from: proposal.report.rootName, to: outputName), at: 0)
            }
            let manifest = Manifest(source: root.path, destinationName: outputName, renames: renames, omittedIconFiles: proposal.omittedIcons,
                                    note: "Original preserved. Document contents were not rewritten. Renamed media may require manual relinking in Premiere, OBS or Watchtower. Finder icon metadata is omitted.")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: stage.appendingPathComponent(manifestName), options: .withoutOverwriting)
        })
    }
}
