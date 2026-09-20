import Foundation
import Darwin

/// Production uses the preserved Project Templates library. Tests and explicit
/// `--data-directory` launches remain confined to a disposable root.
public struct AppRuntime: Sendable {
    public enum Scope: Sendable { case production, isolated }
    public let root: URL
    public let scope: Scope
    public static let alphaIdentifier = "local.creatoros.alpha"
    public static var stableRoot: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Project Templates") }
    public static var alphaRoot: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CreatorOS Alpha") }
    public var defaultsSuite: String { Self.alphaIdentifier + "." + Data(root.path.utf8).base64EncodedString() }
    public var isIsolated: Bool { scope == .isolated }
    public var projects: URL { root.appendingPathComponent("Projects") }
    public var ideas: URL { root.appendingPathComponent("Ideas") }

    public static func production(stableRoot: URL = AppRuntime.stableRoot) throws -> AppRuntime {
        try AppRuntime(root: stableRoot, stableRoot: stableRoot, scope: .production)
    }

    public static func isolated(root: URL = AppRuntime.alphaRoot, stableRoot: URL = AppRuntime.stableRoot) throws -> AppRuntime {
        try AppRuntime(root: root, stableRoot: stableRoot, scope: .isolated)
    }

    public static func forLaunch(bundleIdentifier: String?, channel: String, dataRoot: URL? = nil) throws -> AppRuntime {
        if let dataRoot { return try isolated(root: dataRoot) }
        if bundleIdentifier == alphaIdentifier || channel == "α" { return try isolated() }
        guard bundleIdentifier == nil || bundleIdentifier == "local.projecttemplates.mac" else {
            throw AppFailure("This CreatorOS bundle identity is not allowed to open the production library.")
        }
        return try production()
    }

    /// Retained for test/tool callers: an explicit root always means isolation.
    public init(root: URL = AppRuntime.alphaRoot, stableRoot: URL = AppRuntime.stableRoot) throws {
        try self.init(root: root, stableRoot: stableRoot, scope: .isolated)
    }

    private init(root: URL, stableRoot: URL, scope: Scope) throws {
        let resolved = URL(fileURLWithPath: Self.systemPath(root.standardizedFileURL.resolvingSymlinksInPath().path))
        let stable = URL(fileURLWithPath: Self.systemPath(stableRoot.standardizedFileURL.resolvingSymlinksInPath().path))
        let lexical = Self.systemPath(root.standardizedFileURL.path)
        guard root.isFileURL, lexical == resolved.path else { throw AppFailure("CreatorOS data folders must be local paths without symbolic links.") }
        if scope == .isolated {
            // macOS's system aliases are canonicalised; user-created symlink roots are refused.
            let temporaryRoots = [URL(fileURLWithPath: "/private/tmp"), URL(fileURLWithPath: Self.systemPath(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path))]
            let isTemporaryChild = temporaryRoots.contains { $0 != resolved && Self.contains($0, resolved) }
            let isAlphaChild = Self.contains(Self.alphaRoot.standardizedFileURL.resolvingSymlinksInPath(), resolved)
            guard isTemporaryChild || isAlphaChild,
                  resolved.path != "/", resolved.path != FileManager.default.homeDirectoryForCurrentUser.path,
                  !Self.contains(resolved, stable), !Self.contains(stable, resolved) else {
                throw AppFailure("Use CreatorOS's isolated data folder or a dedicated child of the system temporary folder. Production folders, symlink roots and the live library cannot be test data roots.")
            }
        } else {
            guard resolved == stable else { throw AppFailure("Production CreatorOS must use its preserved Project Templates library.") }
        }
        try Self.rejectSymlinkAncestors(lexical)
        self.root = resolved
        self.scope = scope
    }
    public static func contains(_ parent: URL, _ child: URL) -> Bool {
        let parentPath = systemPath(parent.path), childPath = systemPath(child.path)
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }
    private static func systemPath(_ path: String) -> String {
        if path == "/tmp" || path.hasPrefix("/tmp/") || path == "/var" || path.hasPrefix("/var/") { return "/private" + path }
        return path
    }
    public func requireWritable(_ url: URL) throws {
        let lexical = URL(fileURLWithPath: Self.systemPath(url.standardizedFileURL.path))
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard url.isFileURL else { throw AppFailure("CreatorOS can only write to local file URLs.") }
        if scope == .isolated {
            guard Self.contains(root, lexical), Self.contains(root, resolved) else { throw AppFailure("This isolated launch only writes inside \(root.path). Choose a folder there; production files stay outside this test workspace.") }
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            let forbidden = [URL(fileURLWithPath: "/"), home, Self.alphaRoot.standardizedFileURL]
            guard !forbidden.contains(where: { lexical == $0 || Self.contains($0, lexical) && $0 == Self.alphaRoot.standardizedFileURL }) else {
                throw AppFailure("CreatorOS will not use this broad or isolated path as a write destination: \(lexical.path)")
            }
        }
        guard lexical.path == Self.systemPath(resolved.path) else { throw AppFailure("CreatorOS write paths cannot pass through symbolic links: \(lexical.path)") }
        try Self.rejectSymlinkAncestors(lexical.path)
    }
    /// Foundation may leave symlink ancestors unresolved when the final output does not exist yet.
    private static func rejectSymlinkAncestors(_ path: String) throws {
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += "/" + String(component)
            var info = stat()
            if lstat(prefix, &info) != 0 {
                if errno == ENOENT { return }
                throw AppFailure("Cannot verify the alpha path \(prefix): \(String(cString: strerror(errno)))")
            }
            guard (info.st_mode & mode_t(S_IFMT)) != mode_t(S_IFLNK) else {
                throw AppFailure("Alpha paths cannot pass through symbolic links: \(prefix)")
            }
        }
    }
    public func validate(_ library: Library) throws {
        try requireWritable(root.appendingPathComponent("library.json"))
        try requireWritable(root.appendingPathComponent("Templates"))
        for template in library.templates { try requireWritable(root.appendingPathComponent("Templates").appendingPathComponent(template.id.uuidString)) }
        for preset in library.presets where !preset.destination.isEmpty {
            try validateStoredReference(preset.destination)
            if scope == .isolated, let bookmark = preset.destinationBookmark { try validateBookmark(bookmark) }
        }
        for location in library.locations ?? [] {
            try validateStoredReference(location.path)
            if scope == .isolated { try requireWritable(location.resolve()) }
        }
        for record in library.projects {
            if !record.isPlanned {
                try validateStoredReference(record.path)
                if scope == .isolated { try requireWritable(record.resolve()) }
            }
            for path in record.previousPaths ?? [] { try validateStoredReference(path) }
            if let workspace = record.ideaWorkspace {
                try validateStoredReference(workspace.path)
                try validateStoredReference(workspace.rootPath)
                if scope == .isolated, let bookmark = workspace.bookmark { try validateBookmark(bookmark) }
                if scope == .isolated, let bookmark = workspace.rootBookmark { try validateBookmark(bookmark) }
            }
        }
    }
    private func validateStoredReference(_ path: String) throws {
        guard path.hasPrefix("/") else { throw AppFailure("CreatorOS found an invalid stored file path.") }
        let url = URL(fileURLWithPath: path)
        guard url.isFileURL else { throw AppFailure("CreatorOS found an invalid stored file path.") }
        if scope == .isolated { try requireWritable(url) }
    }
    private func validateBookmark(_ bookmark: Data) throws {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        try requireWritable(url)
    }
}
