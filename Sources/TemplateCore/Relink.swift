import Foundation

/// Finds a moved project folder the way an editor relinks media: same name, likely places first, then a bounded search.
public enum Relinker {
    /// Folders that exist right now and carry the record's name. Never scans whole drives; depth and visits are capped.
    public static func candidates(for record: ProjectRecord, roots: [URL], cancellation: Cancellation = Cancellation()) -> [URL] {
        guard !record.isPlanned else { return [] }
        let fm = FileManager.default
        let name = record.name
        var found: [String] = []; var seen = Set<String>()
        func consider(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard path != record.path, !seen.contains(path) else { return }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return }
            seen.insert(path); found.append(path)
        }
        // 1. The same relative position on every mounted volume and on the boot drive.
        let location = record.location
        if !location.mountPath.isEmpty, record.path.hasPrefix(location.mountPath) {
            let suffix = String(record.path.dropFirst(location.mountPath.count))
            var mounts = ["/"]
            if let volumes = try? fm.contentsOfDirectory(atPath: "/Volumes") { mounts += volumes.map { "/Volumes/" + $0 } }
            for mount in mounts where mount != location.mountPath {
                consider(URL(fileURLWithPath: (mount == "/" ? "" : mount) + suffix))
            }
        }
        // 2. Saved locations and known roots with the last one to three path components.
        let components = (record.path as NSString).pathComponents
        for root in roots {
            for keep in 1...min(3, components.count) {
                let tail = components.suffix(keep).joined(separator: "/")
                consider(root.appendingPathComponent(tail))
            }
        }
        // 3. A bounded walk under each root looking for the exact folder name.
        var visited = 0
        for root in roots {
            guard (try? cancellation.check()) != nil else { break }
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                visited += 1
                if visited > 8_000 { break }
                let depth = url.pathComponents.count - root.pathComponents.count
                if depth >= 4 { enumerator.skipDescendants(); continue }
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true else { continue }
                if url.lastPathComponent == name { consider(url); enumerator.skipDescendants() }
                if ["raw footage", "footage", "media", "cache", "caches"].contains(Catalogue.plainFolderName(url.lastPathComponent)) { enumerator.skipDescendants() }
            }
        }
        return found.map { URL(fileURLWithPath: $0) }
    }
}
