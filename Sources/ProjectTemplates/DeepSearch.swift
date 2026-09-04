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

    func matches(for query: String, in candidates: [Candidate]) -> Set<UUID> {
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
            if enumerator.level > 3 { enumerator.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, Self.extensions.contains(url.pathExtension.lowercased()), (values.fileSize ?? 0) <= 262_144 else { continue }
            let path = url.path
            if let cached = cache[path], cached.modified == values.contentModificationDate { texts.append(cached.text); continue }
            guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { continue }
            cache[path] = Cached(modified: values.contentModificationDate, text: text)
            texts.append(text)
            if texts.count >= 40 { break }
        }
        return texts
    }
}
