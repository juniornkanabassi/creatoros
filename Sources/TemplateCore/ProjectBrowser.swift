import Foundation

public struct BrowserItem: Identifiable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let name: String
    public let directory: Bool
    public let package: Bool
    public let bytes: Int64
    public let modified: Date?
    public init(relativePath: String, name: String, directory: Bool, package: Bool, bytes: Int64, modified: Date?) {
        self.relativePath = relativePath; self.name = name; self.directory = directory
        self.package = package; self.bytes = bytes; self.modified = modified
    }
}

/// Read-only navigation. No metadata files, symlinks, package internals or executable launch.
public enum ProjectBrowser {
    public static let projectExtensions: Set<String> = ["prproj", "aep", "aepx", "sesx", "psd", "psb", "drp", "fcpbundle", "logicx", "band"]
    public static let unsafeExtensions: Set<String> = ["app", "command", "sh", "bash", "zsh", "py", "js", "scpt", "applescript", "workflow", "exe", "bat", "cmd", "ps1", "pkg", "dmg"]
    public static func root(_ record: ProjectRecord) throws -> URL {
        let root = try Catalogue.canonicalURL(record.resolve())
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .volumeUUIDStringKey])
        guard values.isDirectory == true else { throw AppFailure("This project folder is unavailable. Use Locate Folder.") }
        if let expected = record.volumeID, let actual = values.volumeUUIDString, expected != actual { throw AppFailure("A different drive is mounted here. Use Locate Folder.") }
        return root
    }
    public static func list(root: URL, relative: String = "", cancellation: Cancellation = Cancellation()) throws -> [BrowserItem] {
        try cancellation.check()
        let root = try Catalogue.canonicalURL(root)
        let folder = relative.isEmpty ? root : try Catalogue.safeChild(relative, under: root)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isRegularFileKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey]
        let folderValues = try folder.resourceValues(forKeys: keys)
        guard folderValues.isDirectory == true, folderValues.isPackage != true,
              !TemplateReader.packages.contains(folder.pathExtension.lowercased()) else { throw AppFailure("Packages open as documents; their internal files are not browsed.") }
        let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        guard children.count <= 20_000 else { throw AppFailure("This folder is too large to display. Choose a smaller folder.") }
        var items: [BrowserItem] = []
        for child in children {
            try cancellation.check()
            guard child.lastPathComponent != "Icon\r", !child.lastPathComponent.hasPrefix("._"), child.lastPathComponent != ".DS_Store" else { continue }
            let values = try child.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isHidden != true, values.isDirectory == true || values.isRegularFile == true else { continue }
            let path = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
            _ = try Catalogue.safeChild(path, under: root)
            items.append(BrowserItem(relativePath: path, name: child.lastPathComponent,
                directory: values.isDirectory == true,
                package: values.isPackage == true || TemplateReader.packages.contains(child.pathExtension.lowercased()),
                bytes: Int64(values.fileSize ?? 0), modified: values.contentModificationDate))
        }
        return items.sorted {
            if $0.directory != $1.directory { return $0.directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    public static func projectFiles(root: URL, cancellation: Cancellation = Cancellation()) throws -> [BrowserItem] {
        var found: [BrowserItem] = []; var visited = 0
        func walk(_ relative: String, depth: Int) throws {
            guard depth <= 8 else { throw AppFailure("Project-file search reached its depth limit. Browse the folder manually.") }
            for item in try list(root: root, relative: relative, cancellation: cancellation) {
                visited += 1
                guard visited <= 20_000 else { throw AppFailure("Project-file search is too large. Browse the folder manually.") }
                if projectExtensions.contains((item.name as NSString).pathExtension.lowercased()) { found.append(item) }
                if item.directory && !item.package && !["media", "footage", "raw footage", "exports", "export", "cache", "caches", "node_modules"].contains(Catalogue.plainFolderName(item.name)) {
                    try walk(item.relativePath, depth: depth + 1)
                }
            }
        }
        try walk("", depth: 0)
        return found.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }
    public static func openable(_ item: BrowserItem, root: URL) throws -> URL {
        let url = try Catalogue.safeChild(item.relativePath, under: root)
        let ext = url.pathExtension.lowercased()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isExecutableKey, .isRegularFileKey])
        guard !unsafeExtensions.contains(ext), !ext.isEmpty,
              values.isDirectory != true || projectExtensions.contains(ext) else { throw AppFailure("Use this browser for project documents and media. Applications, installers and scripts are not launched here.") }
        // A regular media/document file may have an executable bit on an external drive.
        // Known project/media types are allowed; otherwise reject executable payloads.
        if values.isExecutable == true && !projectExtensions.contains(ext) && !Catalogue.movieExtensions.contains(ext) { throw AppFailure("Executable files cannot be opened from this browser.") }
        return url
    }
}
