import Foundation

/// Finds a moved project folder the way an editor relinks media: same name, likely places first, then a bounded search.
public enum Relinker {
    /// Check before resolving bookmarks or touching a root, including quiet searches scoped to one drive.
    public static func allowsRoot(path: String, hiddenLocations: Set<String>, locationKey: String? = nil) -> Bool {
        let key = ProjectLocation(path: path).key
        return !path.isEmpty && !hiddenLocations.contains(key) && (locationKey == nil || key == locationKey)
    }

    public static func canAutomaticallyRelink(candidateCount: Int, originalMounted: Bool, originalMissing: Bool, candidateAlreadyRegistered: Bool) -> Bool {
        candidateCount == 1 && originalMounted && originalMissing && !candidateAlreadyRegistered
    }

    /// Folders that exist right now and carry the record's name. Never scans whole drives; depth and visits are capped.
    public static func candidates(for record: ProjectRecord, roots: [URL], cancellation: Cancellation = Cancellation()) -> [URL] {
        guard !record.isPlanned else { return [] }
        guard !roots.isEmpty, (try? cancellation.check()) != nil else { return [] }
        let fm = FileManager.default
        let name = record.name
        var found: [String] = []; var seen = Set<String>()
        func consider(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard (try? cancellation.check()) != nil else { return }
            guard path != record.path, !seen.contains(path) else { return }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return }
            seen.insert(path); found.append(path)
        }
        // Search only caller-approved collection roots, never every mounted drive.
        // 2. Saved locations and known roots with the last one to three path components.
        let components = (record.path as NSString).pathComponents
        for root in roots {
            guard (try? cancellation.check()) != nil else { return [] }
            guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            for keep in 1...min(3, components.count) {
                let tail = components.suffix(keep).joined(separator: "/")
                consider(root.appendingPathComponent(tail))
            }
        }
        // 3. A bounded walk under each root looking for the exact folder name.
        var visited = 0
        for root in roots {
            guard (try? cancellation.check()) != nil else { break }
            guard visited < 8_000 else { break }
            guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                guard (try? cancellation.check()) != nil else { return [] }
                visited += 1
                if visited > 8_000 { break }
                // Enumerator URLs may canonicalise /var to /private/var. Its
                // level remains relative to the requested root in either case.
                let depth = enumerator.level
                if depth > 4 { enumerator.skipDescendants(); continue }
                if depth == 4 { enumerator.skipDescendants() }
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true else { continue }
                if url.lastPathComponent == name { consider(url); enumerator.skipDescendants() }
                if ["raw footage", "footage", "media", "cache", "caches"].contains(Catalogue.plainFolderName(url.lastPathComponent)) { enumerator.skipDescendants() }
            }
        }
        return found.map { URL(fileURLWithPath: $0) }
    }
}
