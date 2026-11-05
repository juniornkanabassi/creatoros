import Foundation
import TemplateCore

/// Blocking filesystem work uses captured values; AppModel publishes results and owns all mutations.
enum BackgroundFileOperations {
    static func trashIfPresent(_ payload: URL, runtime: AppRuntime) async throws -> URL? {
        try await Task.detached(priority: .userInitiated) {
            try runtime.requireWritable(payload)
            guard FileManager.default.fileExists(atPath: payload.path) else { return nil }
            var trashed: NSURL?
            try FileManager.default.trashItem(at: payload, resultingItemURL: &trashed)
            return trashed as URL?
        }.value
    }

    static func restore(_ trashed: URL, to payload: URL, runtime: AppRuntime) async throws {
        try await Task.detached(priority: .userInitiated) {
            try runtime.requireWritable(payload)
            // moveItem refuses an occupied destination, retaining the recoverable file in the Bin.
            try FileManager.default.moveItem(at: trashed, to: payload)
        }.value
    }

    static func relinkRoots(library: Library, hiddenLocations: Set<String>, mountedLocations: Set<String>, locationKey: String?) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            func allowed(_ path: String) -> Bool {
                Relinker.allowsRoot(path: path, hiddenLocations: hiddenLocations, locationKey: locationKey)
            }
            var roots: [URL] = []
            for location in library.locations ?? [] where allowed(location.path) {
                if let url = try? location.resolve(), allowed(url.path), fm.fileExists(atPath: url.path) { roots.append(url) }
                else if fm.fileExists(atPath: location.path) { roots.append(URL(fileURLWithPath: location.path)) }
            }
            for preset in library.presets where allowed(preset.destination) {
                let url = URL(fileURLWithPath: preset.destination)
                if fm.fileExists(atPath: url.path) { roots.append(url) }
            }
            var parents = Set<String>()
            for record in library.projects where !record.isPlanned {
                for path in [record.path] + (record.previousPaths ?? []) {
                    let parent = (path as NSString).deletingLastPathComponent
                    let location = ProjectLocation(path: parent)
                    guard allowed(parent), mountedLocations.contains(location.key) else { continue }
                    parents.insert(parent)
                }
            }
            for parent in parents.sorted() where fm.fileExists(atPath: parent) { roots.append(URL(fileURLWithPath: parent)) }
            var seen = Set<String>()
            return roots.filter { seen.insert($0.path).inserted }
        }.value
    }
}
