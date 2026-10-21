import Foundation

/// Searches the text documents inside project folders, for the cases where a name is not remembered but a line
/// of a script or note is. Bounded on purpose: only `.md`, `.txt` and `.markdown` files, only under the project's
/// first three levels, at most 40 files and 256 KB per file per project, and every file's text is cached by
/// modification date so a repeated search reads nothing again. Hidden and disconnected drives never reach here.
actor DeepSearch {
    static let shared = DeepSearch()
    struct Candidate: Sendable { let id: UUID; let path: String }
    private struct Cached { let modified: Date?; let text: String }
    private var cache: [String: Cached] = [:]
    private static let extensions: Set<String> = ["md", "txt", "markdown"]
#if DEEP_SEARCH_CHECKS
    func checkedDocumentCount(_ path: String) -> Int { text(of: path).count }
#endif

    /// ponytail: the cache holds at most 32 MB of text and is cleared when full; a smarter policy if searches get slow.
    private static let cacheLimit = 32 * 1024 * 1024
    private var cachedBytes = 0
    func matches(for query: String, in candidates: [Candidate]) -> Set<UUID> {
        // Forget text from folders that are no longer candidates (removed, hidden or moved projects).
        let prefixes = candidates.map { $0.path + "/" }
        for path in cache.keys where !prefixes.contains(where: { path.hasPrefix($0) }) { cachedBytes -= cache[path]?.text.utf8.count ?? 0; cache[path] = nil }
        var found = Set<UUID>()
        for candidate in candidates {
            if Task.isCancelled { break }
            if text(of: candidate.path).contains(where: { $0.localizedCaseInsensitiveContains(query) }) { found.insert(candidate.id) }
        }
        return found
    }

    private func text(of projectPath: String) -> [String] {
        let root = URL(fileURLWithPath: projectPath)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var texts: [String] = []
        while let url = enumerator.nextObject() as? URL {
            if texts.count >= 40 || Task.isCancelled { break }
            if enumerator.level > 3 { enumerator.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, Self.extensions.contains(url.pathExtension.lowercased()), (values.fileSize ?? 0) <= 262_144 else { continue }
            let path = url.path
            if let cached = cache[path], cached.modified == values.contentModificationDate { texts.append(cached.text); continue }
            guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { continue }
            if cachedBytes + text.utf8.count > Self.cacheLimit { cache.removeAll(); cachedBytes = 0 }
            cachedBytes += text.utf8.count - (cache[path]?.text.utf8.count ?? 0)
            cache[path] = Cached(modified: values.contentModificationDate, text: text)
            texts.append(text)
        }
        return texts
    }
}

#if DEEP_SEARCH_CHECKS
// Run: swiftc -parse-as-library -D DEEP_SEARCH_CHECKS Sources/ProjectTemplates/DeepSearch.swift -o /private/tmp/creatoros-deep-check && /private/tmp/creatoros-deep-check
@main enum DeepSearchCheck {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CreatorOS-search-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<41 { try Data("document \(index)".utf8).write(to: root.appendingPathComponent("\(index).txt")) }
        let search = DeepSearch()
        let cold = await search.checkedDocumentCount(root.path)
        let warm = await search.checkedDocumentCount(root.path)
        assert(cold == 40 && warm == 40, "Cached searches must obey the same document bound")
        print("DeepSearch cold/warm bound passed")
    }
}
#endif
