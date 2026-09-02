// Local, explicit migration helper. Not included in the application bundle.
import Foundation
import TemplateCore
import Darwin

func backup(_ store: LibraryStore) throws {
    if FileManager.default.fileExists(atPath: store.file.path) {
        let folder = store.root.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: store.file, to: folder.appendingPathComponent("library-\(UUID().uuidString).json"))
    }
}
do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let action = args.first else { throw AppFailure("Use inspect collection-folder, catalogue library-folder collection-folder, or icons library-folder long-folder short-folder podcast-folder livestream-folder. Quit the app before commands that write.") }
    switch action {
    case "inspect":
        guard args.count == 2 else { throw AppFailure("inspect needs one collection folder") }
        let result = try Catalogue.discover(root: URL(fileURLWithPath: args[1]))
        for project in result.projects {
            print("\(project.format) | \((project.exports ?? []).count) exports | \(project.path)")
            for export in project.exports ?? [] { print("  \(export.relativePath)") }
        }
        for note in result.notes { print("NOTE \(note)") }
        print("PROJECTS \(result.projects.count), EXPORTS \(result.projects.reduce(0) { $0 + ($1.exports ?? []).count })")
    case "catalogue":
        guard args.count == 3 else { throw AppFailure("catalogue needs the library folder and collection folder") }
        let store = LibraryStore(root: URL(fileURLWithPath: args[1])); var library = try store.load()
        let result = try Catalogue.discover(root: URL(fileURLWithPath: args[2]))
        try backup(store)
        library.projects = Catalogue.merge(result.projects, into: library.projects)
        var locations = library.locations ?? []
        if let i = locations.firstIndex(where: { $0.path == result.location.path }) { locations[i] = result.location }
        else { locations.append(result.location) }
        library.locations = locations
        try store.save(library)
        print("Registered \(result.projects.count) projects; \(library.projects.count) total. No media was moved or changed.")
    case "icons":
        guard args.count == 6 else { throw AppFailure("icons needs library folder and Long, Short, Podcast, Livestream folders, in that order") }
        let store = LibraryStore(root: URL(fileURLWithPath: args[1])); var library = try store.load()
        for (format, path) in zip(["Long", "Short", "Podcast", "Livestream"], args.dropFirst(2)) {
            guard let i = library.presets.firstIndex(where: { $0.format == format }) else { throw AppFailure("Missing preset \(format)") }
            library.presets[i].icon = try IconService.captureFolderIcon(URL(fileURLWithPath: path))
            library.presets[i].iconSource = path; library.presets[i].iconLocked = true
        }
        try backup(store); try store.save(library)
        print("Saved four fixed format icons. Source folders are untouched.")
    default: throw AppFailure("Unknown command \(action)")
    }
} catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
