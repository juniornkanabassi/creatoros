import Foundation

public struct TemplateRecord: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var imported: Date
    public var source: String
    public var mode: ImportMode
    public init(id: UUID, name: String, source: String, mode: ImportMode) {
        self.id = id; self.name = name; self.source = source; self.mode = mode; imported = Date()
    }
}
public struct ProjectRecord: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var format: String
    public var path: String
    public var bookmark: Data?
    public var created = Date()
    public var previousPaths: [String]?
    public var exports: [ExportRecord]?
    public var exportFolders: [String]?
    public var finalExportPath: String?
    public var finalExportPaths: [String]?
    public var markedFinals: Set<String> { Set(finalExportPaths ?? finalExportPath.map { [$0] } ?? []) }
    public var lastIndexed: Date?
    public var volumeName: String?
    public var volumeID: String?
    public var volumePath: String?
    public var scanNotes: [String]?
    public init(url: URL, format: String) throws {
        name = url.lastPathComponent; path = url.path; self.format = format
        bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        captureVolume(url)
    }
    public mutating func captureVolume(_ url: URL) {
        if let info = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeUUIDStringKey, .volumeURLKey]) {
            volumeName = info.volumeName; volumeID = info.volumeUUIDString; volumePath = info.volume?.path
        }
    }
    public mutating func relocate(to url: URL) throws {
        let replacement = try ProjectRecord(url: url, format: format)
        if path != url.path { previousPaths = Array(Set((previousPaths ?? []) + [path])).sorted() }
        path = replacement.path; bookmark = replacement.bookmark; name = replacement.name
        volumeName = replacement.volumeName; volumeID = replacement.volumeID; volumePath = replacement.volumePath
        // Export paths are relative to the project root, so moving a project does not break them.
    }
    public var searchableText: String {
        ([name, format, path, volumeName ?? ""] + (previousPaths ?? []) + (exports ?? []).map(\.relativePath)).joined(separator: " ")
    }
    public func resolve() throws -> URL {
        guard let bookmark else { return URL(fileURLWithPath: path) }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw AppFailure("Folder bookmark needs refreshing. Use Locate Folder.") }
        return url
    }
}
public struct Preset: Codable, Identifiable, Sendable {
    public var id: String { format }
    public var format: String
    public var destination: String = ""
    public var destinationBookmark: Data?
    public var icon: Data?
    public var iconSource: String?
    public var iconLocked: Bool?
    public init(_ format: String) { self.format = format }
}
public struct Library: Codable, Sendable {
    public var schema = 2
    public var templates: [TemplateRecord] = []
    public var projects: [ProjectRecord] = []
    public var presets = ["Long", "Short", "Podcast", "Livestream"].map(Preset.init)
    public var locations: [CatalogueLocation]?
    public init() {}
}
public struct LibraryStore: Sendable {
    public let root: URL
    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Project Templates")
    }
    public var file: URL { root.appendingPathComponent("library.json") }
    public var templates: URL { root.appendingPathComponent("Templates") }
    public func payload(_ record: TemplateRecord) -> URL { templates.appendingPathComponent(record.id.uuidString) }
    public func load() throws -> Library {
        guard FileManager.default.fileExists(atPath: file.path) else { return Library() }
        var library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: file))
        guard (1...2).contains(library.schema) else { throw AppFailure("This library uses a newer schema. It has not been modified.") }
        library.schema = 2
        return library
    }
    public func save(_ library: Library) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Keep a single recoverable schema-one snapshot before the first upgraded write.
        let migrationBackup = root.appendingPathComponent("library-before-schema-2.json")
        if FileManager.default.fileExists(atPath: file.path), !FileManager.default.fileExists(atPath: migrationBackup.path),
           let old = try? Data(contentsOf: file),
           let json = try? JSONSerialization.jsonObject(with: old) as? [String: Any], json["schema"] as? Int == 1 {
            try old.write(to: migrationBackup, options: .withoutOverwriting)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: file, options: .atomic)
    }
    public func importTemplate(plan: CopyPlan, name: String, mode: ImportMode, cancellation: Cancellation,
                               progress: CreationEngine.Progress = { _, _ in }) throws -> TemplateRecord {
        try Naming.validate(name)
        try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
        let record = TemplateRecord(id: UUID(), name: name, source: plan.root.path, mode: mode)
        _ = try CreationEngine.create(plan: plan, destination: templates, name: record.id.uuidString, cancellation: cancellation, progress: progress)
        return record
    }
}
