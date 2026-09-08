import Foundation
import Darwin

public struct IdeaWorkspace: Codable, Sendable {
    public var path: String
    public var bookmark: Data?
    public var rootPath: String
    public var rootBookmark: Data?
    public var owner: UUID
}

public enum IdeaWorkspaceEngine {
    public static let markerName = ".creatoros-idea.json"
    private static let markerByteLimit = 8 * 1_048_576
    private struct Marker: Codable {
        let record: UUID
        let owner: UUID
        /// Only original template paths expand bracket tokens. Later attachments keep literal names.
        // ponytail: provenance follows paths, not moved files; use explicit template designation if moving token files must retain substitution.
        let templatePaths: [String]?
    }

    /// The caller persists the returned reference before presenting the workspace as registered.
    public static func create(for record: ProjectRecord, root: URL, payload: URL? = nil,
                              cancellation: Cancellation = Cancellation(),
                              progress: CreationEngine.Progress = { _, _ in }) throws -> IdeaWorkspace {
        guard record.isPlanned, record.ideaWorkspace == nil else { throw AppFailure("This idea already has a workspace or has been started.") }
        let root = try localDirectory(root)
        let fm = FileManager.default
        let empty = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("CreatorOS-empty-" + UUID().uuidString)
        if payload == nil { try fm.createDirectory(at: empty, withIntermediateDirectories: false) }
        defer { if payload == nil { try? fm.removeItem(at: empty) } }
        let plan = try TemplateReader.scan(payload ?? empty, cancellation: cancellation)
        guard !plan.entries.contains(where: { Naming.key($0.source) == Naming.key(markerName) }) else {
            throw AppFailure("The template contains the reserved idea ownership marker.")
        }
        let owner = UUID()
        let markerData = try JSONEncoder().encode(Marker(record: record.id, owner: owner, templatePaths: plan.entries.map(\.source)))
        guard markerData.count <= markerByteLimit else { throw AppFailure("The template has too many paths for an idea workspace ownership marker.") }
        let url = try CreationEngine.create(plan: plan, destination: root, name: "Idea " + record.id.uuidString,
            cancellation: cancellation, progress: progress, strictExclusiveCommit: true, prepareCommit: { stage in
                _ = try localDirectory(root)
                try cancellation.check()
                try markerData.write(to: stage.appendingPathComponent(markerName), options: .withoutOverwriting)
            })
        do {
            return IdeaWorkspace(path: url.path,
                bookmark: try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil),
                rootPath: root.path,
                rootBookmark: try root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil), owner: owner)
        } catch {
            throw AppFailure("The workspace exists at \(url.path), but its reference could not be created. Keep that folder for recovery. \(error.localizedDescription)")
        }
    }

    public static func resolve(for record: ProjectRecord) throws -> URL {
        try owned(for: record).0
    }

    private static func owned(for record: ProjectRecord) throws -> (URL, Marker) {
        guard let reference = record.ideaWorkspace else { throw AppFailure("This idea has no workspace.") }
        let root = try localDirectory(resolve(reference.rootBookmark, path: reference.rootPath))
        let workspace = try localDirectory(resolve(reference.bookmark, path: reference.path))
        guard workspace.deletingLastPathComponent() == root else {
            throw AppFailure("The workspace is outside its configured Ideas root. Nothing was changed.")
        }
        let marker = workspace.appendingPathComponent(markerName)
        let info = try marker.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard info.isSymbolicLink != true, info.isRegularFile == true, (info.fileSize ?? Int.max) <= markerByteLimit else {
            throw AppFailure("This folder does not carry a readable idea ownership marker. Nothing was changed.")
        }
        let decoded = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: marker))
        guard decoded.record == record.id, decoded.owner == reference.owner else {
            throw AppFailure("This folder does not carry the matching idea ownership marker. Nothing was changed.")
        }
        return (workspace, decoded)
    }

    public static func promotionPlan(for record: ProjectRecord, fields: ProjectFields,
                                     cancellation: Cancellation = Cancellation()) throws -> CopyPlan {
        let source = try scan(for: record, cancellation: cancellation)
        return try TemplateReader.plan(from: source.structure, fields: fields, renamingPaths: source.renamingPaths)
    }

    /// Cache both values together. Rendering and planning then share provenance without reading files on each keystroke.
    public static func scan(for record: ProjectRecord, cancellation: Cancellation = Cancellation()) throws -> (structure: CopyPlan, renamingPaths: Set<String>) {
        guard record.isPlanned else { throw AppFailure("This idea has already been started.") }
        let (workspace, marker) = try owned(for: record)
        let structure = try TemplateReader.scan(workspace, excluding: [markerName], cancellation: cancellation)
        let templatePaths = Set(marker.templatePaths ?? [])
        var renamingPaths = templatePaths
        for entry in structure.entries {
            try cancellation.check()
            let name = (entry.source as NSString).lastPathComponent
            let lower = name.lowercased()
            let templatePrefix = lower == "template" || lower.hasPrefix("template.") || lower.hasPrefix("template ")
            if templatePrefix { renamingPaths.insert(entry.source) }
        }
        return (structure, renamingPaths)
    }

    /// Copies the workspace alone. Template files already in it are substituted once; attachments never merge with another payload.
    /// A successful return is a recoverable output, not evidence that the caller has durably registered it.
    public static func promote(for record: ProjectRecord, fields: ProjectFields, destination: URL,
                               expectedPlan: CopyPlan? = nil,
                               icon: Data? = nil, finderMetadata: Bool = true,
                               cancellation: Cancellation = Cancellation(),
                               progress: CreationEngine.Progress = { _, _ in }) throws -> URL {
        let original = try promotionPlan(for: record, fields: fields, cancellation: cancellation)
        if let expectedPlan, !expectedPlan.sameInventory(as: original) {
            throw AppFailure("The idea workspace changed since its preview. Refresh Workspace and review it again before starting.")
        }
        if !finderMetadata { try requirePlainCopySafe(original, cancellation: cancellation) }
        let plan = finderMetadata ? original : original.withoutIconFiles
        return try CreationEngine.create(plan: plan, destination: destination, name: fields.finalName(),
            icon: icon, finderMetadata: finderMetadata, cancellation: cancellation, progress: progress,
            strictExclusiveCommit: true, prepareCommit: { stage in
                let fresh = try promotionPlan(for: record, fields: fields, cancellation: cancellation)
                guard original.sameInventory(as: fresh) else { throw AppFailure("The idea workspace changed during copying. The original remains intact; retry after editing has stopped.") }
                try CreationEngine.verifyCopiedBytes(plan: plan, at: stage, cancellation: cancellation,
                    allowingExtraPaths: finderMetadata && icon != nil ? ["Icon\r"] : [])
                if !finderMetadata { try requirePlainCopySafe(original, cancellation: cancellation) }
                guard original.sameInventory(as: try promotionPlan(for: record, fields: fields, cancellation: cancellation)) else {
                    throw AppFailure("The idea workspace changed during verification. Nothing was committed.")
                }
            })
    }

    /// Call only after explicit confirmation of this exact path. Post-promotion cleanup additionally requires a durable library save.
    @discardableResult
    public static func trash(for record: ProjectRecord, confirmedURL: URL) throws -> URL? {
        let workspace = try resolve(for: record)
        guard confirmedURL.path == workspace.path else { throw AppFailure("The workspace path changed since confirmation. Nothing was put in the Bin.") }
        // Refuse unsupported descendants before handing the owned directory to Finder's recoverable Trash operation.
        _ = try TemplateReader.scan(workspace)
        guard try resolve(for: record) == workspace else { throw AppFailure("Workspace ownership changed. Nothing was put in the Bin.") }
        var trashed: NSURL?
        try FileManager.default.trashItem(at: workspace, resultingItemURL: &trashed)
        return trashed as URL?
    }

    private static func resolve(_ bookmark: Data?, path: String) throws -> URL {
        let saved = URL(fileURLWithPath: path)
        guard let bookmark else { return saved }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, systemPath(url.path) == systemPath(saved.path) else { throw AppFailure("The saved workspace location changed or is unavailable. Nothing was changed.") }
        return url
    }

    private static func localDirectory(_ url: URL) throws -> URL {
        // Compare the original spelling before Foundation standardises it, so user-created symlinks cannot disappear from validation.
        let clean = URL(fileURLWithPath: systemPath(url.path))
        guard url.isFileURL, clean.path != "/", clean.path == systemPath(clean.resolvingSymlinksInPath().path),
              ProjectLocation(path: clean.path).kind == .local,
              !clean.path.contains("/Library/Mobile Documents/") else {
            throw AppFailure("Choose an ordinary local Ideas folder without symbolic links, outside cloud and external drives.")
        }
        let info = try clean.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .volumeIsLocalKey, .isUbiquitousItemKey])
        guard info.isDirectory == true, info.isSymbolicLink != true, info.volumeIsLocal == true, info.isUbiquitousItem != true else {
            throw AppFailure("The local Ideas folder is unavailable. Nothing was changed.")
        }
        return clean
    }

    /// Foundation bookmarks and standardisation disagree on macOS's built-in /private aliases.
    /// Only these system prefixes are equivalent; moved targets and user-created symlinks remain distinct.
    private static func systemPath(_ path: String) -> String {
        for prefix in ["/var", "/tmp", "/etc"] where path == prefix || path.hasPrefix(prefix + "/") {
            return "/private" + path
        }
        return path
    }

    private static func requirePlainCopySafe(_ plan: CopyPlan, cancellation: Cancellation) throws {
        for entry in plan.entries where !entry.directory && !entry.metadata {
            try cancellation.check()
            let path = plan.root.appendingPathComponent(entry.source).path
            let length = getxattr(path, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW)
            if length > 0 { throw AppFailure("The attachment \(entry.source) contains resource-fork data. Turn off Plain folders to preserve it; the idea workspace has not been changed.") }
            if length < 0 && errno != ENOATTR && errno != ENOTSUP { throw AppFailure("Cannot inspect resource-fork metadata: \(entry.source). Nothing was committed.") }
        }
    }

}
