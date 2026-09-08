import Foundation
import Darwin

/// Alpha writes stay within its own library or an explicitly chosen disposable data root.
public struct AppRuntime: Sendable {
    public let root: URL
    public static let alphaIdentifier = "local.creatoros.alpha"
    public static var stableRoot: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Project Templates") }
    public static var alphaRoot: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CreatorOS Alpha") }
    public var defaultsSuite: String { Self.alphaIdentifier + "." + Data(root.path.utf8).base64EncodedString() }
    public var projects: URL { root.appendingPathComponent("Projects") }
    public var ideas: URL { root.appendingPathComponent("Ideas") }

    public init(root: URL = AppRuntime.alphaRoot, stableRoot: URL = AppRuntime.stableRoot) throws {
        let resolved = URL(fileURLWithPath: Self.systemPath(root.standardizedFileURL.resolvingSymlinksInPath().path))
        let stable = URL(fileURLWithPath: Self.systemPath(stableRoot.standardizedFileURL.resolvingSymlinksInPath().path))
        let lexical = Self.systemPath(root.standardizedFileURL.path)
        // macOS's system aliases are canonicalised; user-created symlink roots are refused.
        let temporaryRoots = [URL(fileURLWithPath: "/private/tmp"), URL(fileURLWithPath: Self.systemPath(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path))]
        let isTemporaryChild = temporaryRoots.contains { $0 != resolved && Self.contains($0, resolved) }
        let isAlphaChild = Self.contains(Self.alphaRoot.standardizedFileURL.resolvingSymlinksInPath(), resolved)
        guard root.isFileURL, lexical == resolved.path, isTemporaryChild || isAlphaChild,
              resolved.path != "/", resolved.path != FileManager.default.homeDirectoryForCurrentUser.path,
              !Self.contains(resolved, stable), !Self.contains(stable, resolved) else {
            throw AppFailure("Use CreatorOS Alpha's own data folder or a dedicated child of the system temporary folder. Production folders, symlink roots and the stable library cannot be alpha data roots.")
        }
        try Self.rejectSymlinkAncestors(lexical)
        self.root = resolved
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
        guard url.isFileURL, Self.contains(root, lexical), Self.contains(root, resolved) else { throw AppFailure("This alpha only writes inside \(root.path). Choose a folder there; production files stay outside this test workspace.") }
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
            try requireWritable(URL(fileURLWithPath: preset.destination))
            if let bookmark = preset.destinationBookmark { try validateBookmark(bookmark) }
        }
        for location in library.locations ?? [] {
            try requireWritable(URL(fileURLWithPath: location.path))
            try requireWritable(location.resolve())
        }
        for record in library.projects {
            if !record.isPlanned {
                try requireWritable(URL(fileURLWithPath: record.path))
                try requireWritable(record.resolve())
            }
            for path in record.previousPaths ?? [] { try requireWritable(URL(fileURLWithPath: path)) }
            if let workspace = record.ideaWorkspace {
                try requireWritable(URL(fileURLWithPath: workspace.path))
                try requireWritable(URL(fileURLWithPath: workspace.rootPath))
                if let bookmark = workspace.bookmark { try validateBookmark(bookmark) }
                if let bookmark = workspace.rootBookmark { try validateBookmark(bookmark) }
            }
        }
    }
    private func validateBookmark(_ bookmark: Data) throws {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        try requireWritable(url)
    }
}
