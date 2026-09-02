import Foundation
import Darwin

public struct ExportRecord: Codable, Identifiable, Sendable, Hashable {
    public var id: String { relativePath }
    public var relativePath: String
    public var bytes: Int64
    public var modified: Date?
    public init(relativePath: String, bytes: Int64, modified: Date?) {
        self.relativePath = relativePath; self.bytes = bytes; self.modified = modified
    }
}

public struct CatalogueLocation: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var path: String
    public var bookmark: Data
    public var lastScanned: Date?
    public init(url: URL) throws {
        name = url.lastPathComponent; path = url.path
        bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    public func resolve() throws -> URL {
        var stale = false
        let result = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw AppFailure("Choose this library location again to refresh its bookmark.") }
        return result
    }
}

public struct DiscoveryResult: Sendable {
    public var location: CatalogueLocation
    public var projects: [ProjectRecord]
    public var notes: [String]
}

public struct ProjectInspection: Sendable {
    public var record: ProjectRecord
    public var available: Bool
    public var status: String
    public var root: URL?
}

public enum Catalogue {
    static func canonicalURL(_ url: URL) throws -> URL {
        // Foundation may abbreviate /private/var while directory enumeration returns
        // /private/var. POSIX realpath keeps relative-path arithmetic consistent.
        guard let resolved = realpath(url.path, nil) else { throw AppFailure("Cannot resolve \(url.path): \(String(cString: strerror(errno)))") }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
    public static let movieExtensions: Set<String> = ["mp4", "mov", "m4v", "mxf", "avi", "mkv", "webm", "mts", "m2ts"]
    static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
    public static func plainFolderName(_ name: String) -> String {
        name.replacingOccurrences(of: #"^\d+[\s._-]*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces).lowercased()
    }
    public static func isExportFolder(_ name: String) -> Bool {
        ["exports", "export", "final exports", "final videos", "deliverables", "renders", "output", "outputs"].contains(plainFolderName(name))
    }
    public static func inferredFormat(_ url: URL) -> String {
        let text = url.path.lowercased()
        if text.contains("podcast") { return "Podcast" }
        if text.contains("livestream") || text.contains("live stream") { return "Livestream" }
        if text.contains("short") { return "Short" }
        if text.contains("long") { return "Long" }
        return "Existing"
    }
    static func children(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    static func ordinaryDirectory(_ url: URL) throws -> Bool {
        let v = try url.resourceValues(forKeys: keys)
        return v.isDirectory == true && v.isSymbolicLink != true && v.isPackage != true && !TemplateReader.packages.contains(url.pathExtension.lowercased())
    }
    public static func discover(root: URL, cancellation: Cancellation = Cancellation(),
                                progress: CreationEngine.Progress = { _, _ in }) throws -> DiscoveryResult {
        guard try ordinaryDirectory(root) else { throw AppFailure("Choose a project collection folder, not a package or symbolic link.") }
        let root = try canonicalURL(root)
        var location = try CatalogueLocation(url: root)
        var projects: [ProjectRecord] = []; var notes: [String] = []; var visited = 0
        func walk(_ folder: URL, depth: Int) throws {
            try cancellation.check(); visited += 1
            guard visited <= 20_000 else { throw AppFailure("This location contains too many folders. Choose a smaller collection.") }
            if visited % 20 == 0 { progress(0, "Inspecting \(visited) folders") }
            let items: [URL]
            do { items = try children(folder) } catch {
                if depth == 0 { throw error }
                notes.append("Could not inspect \(folder.path): \(error.localizedDescription)"); return
            }
            var dirs: [URL] = []
            for item in items {
                do { if try ordinaryDirectory(item) { dirs.append(item) } }
                catch { notes.append("Could not inspect \(item.path): \(error.localizedDescription)") }
            }
            let labels = Set(dirs.map { plainFolderName($0.lastPathComponent) })
            let hasExports = dirs.contains { isExportFolder($0.lastPathComponent) }
            let markers = labels.intersection(["documents", "project files", "media", "footage", "exports", "other", "assets", "edit", "edits"]).count
            let hasProjectFile = items.contains { ["prproj", "aep", "drp", "sesx"].contains($0.pathExtension.lowercased()) }
            let numbered = folder.lastPathComponent.range(of: #"^\d+\s*[—–-]"#, options: .regularExpression) != nil
            if markers >= 2 || hasProjectFile || (numbered && hasExports) {
                var record = try ProjectRecord(url: folder, format: inferredFormat(folder))
                record = try indexExports(record, root: folder, cancellation: cancellation)
                projects.append(record)
                return // Do not inspect source media or nested project package internals.
            }
            guard depth < 8 else { if !dirs.isEmpty { notes.append("Depth limit reached at \(folder.path). Add this folder separately if needed.") }; return }
            for child in dirs {
                if ["raw footage", "footage", "media", "node_modules", "cache", "caches"].contains(plainFolderName(child.lastPathComponent)) { continue }
                try walk(child, depth: depth + 1)
            }
        }
        try walk(root, depth: 0)
        location.lastScanned = Date()
        return DiscoveryResult(location: location, projects: projects, notes: notes)
    }
    public static func safeChild(_ relative: String, under root: URL) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
            throw AppFailure("Invalid relative export path.")
        }
        let canonical = try canonicalURL(root)
        let child = canonical.appendingPathComponent(relative)
        guard child.path.hasPrefix(canonical.path + "/"), try canonicalURL(child).path == child.path else {
            throw AppFailure("Export path leaves the project or uses a symbolic link.")
        }
        return child
    }
    public static func indexExports(_ project: ProjectRecord, root: URL, cancellation: Cancellation = Cancellation()) throws -> ProjectRecord {
        let root = try canonicalURL(root)
        var updated = project
        var roots = project.exportFolders ?? []
        let direct = try children(root)
        roots += direct.filter { isExportFolder($0.lastPathComponent) }.map(\.lastPathComponent)
        // A manually registered project may store finished movies directly at its root.
        var exports: [ExportRecord] = []; var notes: [String] = []; var visited = 0
        func collect(_ url: URL, depth: Int) throws {
            try cancellation.check(); visited += 1
            guard visited <= 50_000 else { throw AppFailure("Export index limit reached. Choose a smaller export folder.") }
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { notes.append("Skipped symbolic link \(url.lastPathComponent)"); return }
            if values.isDirectory == true {
                if values.isPackage == true || TemplateReader.packages.contains(url.pathExtension.lowercased()) { return }
                guard depth < 12 else { notes.append("Export depth limit at \(url.lastPathComponent)"); return }
                for child in try children(url) { try collect(child, depth: depth + 1) }
            } else if values.isRegularFile == true && movieExtensions.contains(url.pathExtension.lowercased()) {
                let relative = String(url.path.dropFirst(root.path.count + 1))
                _ = try safeChild(relative, under: root)
                exports.append(ExportRecord(relativePath: relative, bytes: Int64(values.fileSize ?? 0), modified: values.contentModificationDate))
            }
        }
        for relative in Set(roots).sorted() {
            do { try collect(safeChild(relative, under: root), depth: 0) }
            catch is CancellationError { throw CancellationError() }
            catch { notes.append("\(relative): \(error.localizedDescription)") }
        }
        for item in direct where movieExtensions.contains(item.pathExtension.lowercased()) {
            try collect(item, depth: 0)
        }
        if !notes.isEmpty {
            // A partial scan is not evidence that previously indexed exports were deleted.
            exports += project.exports ?? []
            notes.append("Scan incomplete. Previously indexed exports are retained and may be unavailable.")
        }
        var seen = Set<String>()
        updated.exports = exports.filter { seen.insert($0.relativePath).inserted }.sorted {
            if $0.modified != $1.modified { return ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        updated.lastIndexed = Date(); updated.scanNotes = notes
        // Keep the pinned final even if currently absent, so it can be recovered later.
        return updated
    }
    /// Availability only. Resolves the bookmark and checks the folder and drive identity without indexing or saving.
    public static func availability(_ record: ProjectRecord) -> ProjectInspection {
        do {
            let url = try record.resolve()
            let v = try url.resourceValues(forKeys: [.isDirectoryKey, .volumeUUIDStringKey])
            guard v.isDirectory == true else { throw AppFailure("Stored location is no longer a folder.") }
            if let expected = record.volumeID, let actual = v.volumeUUIDString, expected != actual {
                return ProjectInspection(record: record, available: false, status: "A different drive is mounted here. Use Locate Folder.", root: nil)
            }
            return ProjectInspection(record: record, available: true, status: "Available", root: url)
        } catch {
            let drive = record.volumePath ?? ""
            let offline = drive.hasPrefix("/Volumes/") && !FileManager.default.fileExists(atPath: drive)
            return ProjectInspection(record: record, available: false,
                status: offline ? "Drive unavailable · \(record.volumeName ?? drive). Reconnect it to browse this project." : "Folder unavailable or access needs attention. Use Locate Folder. \(error.localizedDescription)", root: nil)
        }
    }
    public static func inspect(_ record: ProjectRecord, cancellation: Cancellation = Cancellation()) -> ProjectInspection {
        do {
            try cancellation.check()
            let url = try record.resolve()
            let v = try url.resourceValues(forKeys: [.isDirectoryKey, .volumeUUIDStringKey])
            guard v.isDirectory == true else { throw AppFailure("Stored location is no longer a folder.") }
            if let expected = record.volumeID, let actual = v.volumeUUIDString, expected != actual {
                return ProjectInspection(record: record, available: false, status: "A different drive is mounted here. Use Locate Folder.", root: nil)
            }
            let result = try indexExports(record, root: url.resolvingSymlinksInPath(), cancellation: cancellation)
            return ProjectInspection(record: result, available: true, status: "Available · index refreshed", root: url)
        } catch {
            let drive = record.volumePath ?? ""
            let offline = drive.hasPrefix("/Volumes/") && !FileManager.default.fileExists(atPath: drive)
            return ProjectInspection(record: record, available: false,
                status: offline ? "Drive unavailable · \(record.volumeName ?? drive). Reconnect it to play these exports." : "Folder unavailable or access needs attention. Use Locate Folder. \(error.localizedDescription)", root: nil)
        }
    }
    public static func merge(_ found: [ProjectRecord], into existing: [ProjectRecord]) -> [ProjectRecord] {
        var result = existing
        for new in found {
            if let i = result.firstIndex(where: { $0.path == new.path }) {
                // Collection discovery does not know this record's custom export folders.
                // Retain those cached entries until a full per-project refresh checks them.
                let custom = result[i].exportFolders ?? []
                let retained = (result[i].exports ?? []).filter { export in custom.contains { export.relativePath.hasPrefix($0 + "/") } }
                var seen = Set<String>()
                result[i].exports = ((new.exports ?? []) + retained).filter { seen.insert($0.relativePath).inserted }
                result[i].lastIndexed = new.lastIndexed; result[i].scanNotes = new.scanNotes
            } else { result.append(new) }
        }
        return result // Never remove unobserved projects when a drive is offline.
    }
}
