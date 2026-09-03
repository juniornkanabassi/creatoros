import Foundation

public struct TemplateRecord: Codable, Identifiable, Sendable, Hashable {
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
    // Export fields are retained for compatibility with 0.2.0 and 0.3.0 libraries.
    // The 0.1.0 interface does not use them; see Deferred features.md.
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
    // Schema 4: content pipeline. All optional so older files decode unchanged.
    public var stage: String?
    public var campaign: String?
    public var series: [String]?
    public var editor: String?
    public var notes: String?
    public var notionURL: String?
    /// True for an idea that has no folder yet. `path` is empty and `resolve()` fails until it is started.
    public var planned: Bool?
    public var publishedDate: Date?
    public var pinned: Bool?
    /// The folder's own creation date on disk, captured when registered or relinked. `created` is the registration date.
    public var folderCreated: Date?
    public init(url: URL, format: String) throws {
        name = url.lastPathComponent; path = url.path; self.format = format
        bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        captureVolume(url)
        folderCreated = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }
    public var isPinned: Bool { pinned == true }
    /// Best date for "how old is this": the folder's creation date when known, else when it was registered.
    public var effectiveDate: Date { folderCreated ?? created }
    /// An idea or planned project with no folder yet.
    public init(planned title: String, format: String, stage: String, campaign: String? = nil) {
        name = title; path = ""; self.format = format; self.stage = stage; self.campaign = campaign; planned = true
    }
    public var isPlanned: Bool { planned == true || path.isEmpty }
    /// Leading digits of the folder name, for example "168" in "168 — Short — Title".
    public var number: String? {
        guard let match = name.range(of: #"^\d+"#, options: .regularExpression) else { return nil }
        return String(name[match])
    }
    public var numberValue: Int? { number.flatMap(Int.init) }
    /// The title after the number, format and optional campaign segments.
    public var title: String {
        let parts = name.components(separatedBy: " — ")
        if parts.count >= 3 { return parts.dropFirst(2).joined(separator: " — ") }
        if parts.count == 2 { return parts[1] }
        return name.replacingOccurrences(of: #"^\d+\s*"#, with: "", options: .regularExpression)
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
        if folderCreated == nil { folderCreated = replacement.folderCreated }
    }
    public var searchableText: String {
        ([name, format, path, volumeName ?? "", stage ?? "", campaign ?? "", editor ?? "", notes ?? ""] + (series ?? []) + (previousPaths ?? [])).joined(separator: " ")
    }
    public func resolve() throws -> URL {
        guard !isPlanned else { throw AppFailure("This is a planned project without a folder yet. Start it from New Project.") }
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
    /// The visible label. The stored key stays Livestream because saved records and icons use it.
    public var label: String { format == "Livestream" ? "Live" : format }
}
/// An extra naming parameter, for example Sponsor or Client, defined by the user in Settings.
public struct CustomField: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var includeInName: Bool
    public init(name: String, includeInName: Bool = true) { id = UUID(); self.name = name; self.includeInName = includeInName }
}
public struct Library: Codable, Sendable {
    public static let currentSchema = 4
    public static let formats = ["Long", "Short", "Podcast", "Livestream"]
    public static let defaultStages = ["Idea", "Writing", "Filming", "Editing", "Published"]
    public var schema = Library.currentSchema
    public var templates: [TemplateRecord] = []
    public var projects: [ProjectRecord] = []
    public var presets = Library.formats.map(Preset.init)
    public var locations: [CatalogueLocation]?
    public var templateSets: [TemplateSet]?
    public var stages: [String]?
    public var customFields: [CustomField]?
    public init() {}
    public var stageList: [String] { (stages ?? []).isEmpty ? Library.defaultStages : stages! }
    public var fieldList: [CustomField] { customFields ?? [] }
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
        guard (1...Library.currentSchema).contains(library.schema) else { throw AppFailure("This library uses a newer schema. It has not been modified.") }
        library.schema = Library.currentSchema
        if library.templateSets == nil { library.templateSets = [] }
        return library
    }
    /// Reads the schema number stored on disk without decoding the whole document.
    func storedSchema() -> Int? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["schema"] as? Int
    }
    public func save(_ library: Library) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Keep one recoverable snapshot per schema upgrade, written once, never overwritten.
        if let stored = storedSchema(), stored < Library.currentSchema {
            let backup = root.appendingPathComponent("library-before-schema-\(Library.currentSchema).json")
            if !FileManager.default.fileExists(atPath: backup.path), let old = try? Data(contentsOf: file) {
                try old.write(to: backup, options: .withoutOverwriting)
            }
            if stored == 1 {
                let legacyBackup = root.appendingPathComponent("library-before-schema-2.json")
                if !FileManager.default.fileExists(atPath: legacyBackup.path), let old = try? Data(contentsOf: file) {
                    try old.write(to: legacyBackup, options: .withoutOverwriting)
                }
            }
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
