import SwiftUI
import AppKit
import TemplateCore

extension AppModel {
    var selectedRecord: ProjectRecord? { library.projects.first { $0.id == selectedProject } }
    var filteredProjects: [ProjectRecord] {
        library.projects.filter {
            (formatFilter == "All formats" || $0.format == formatFilter) &&
            (search.isEmpty || $0.searchableText.localizedCaseInsensitiveContains(search))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
    }
    /// Availability only. Nothing is indexed and the library is not saved.
    func inspectProject(_ record: ProjectRecord) {
        inspectionRevision += 1; let revision = inspectionRevision
        let id = record.id
        Task {
            let result = await Task.detached(priority: .userInitiated) { Catalogue.availability(record) }.value
            guard inspectionRevision == revision else { return }
            inspections[id] = result
        }
    }
    func selectProject() { if let record = selectedRecord { inspectProject(record) } }
    func scanLocation(_ url: URL? = nil) {
        guard let url = url ?? folderPanel(title: "Choose a folder containing projects") else { return }
        run("Looking for projects without moving files") { token, progress in
            try Catalogue.discover(root: url, cancellation: token, progress: progress)
        } completion: { result in
            self.discovery = result; self.discoverySelection = Set(result.projects.map(\.id)); self.discoveryPresented = true
        }
    }
    func rescanLocation(_ location: CatalogueLocation) {
        run("Checking saved location") { token, progress in
            try Catalogue.discover(root: location.resolve(), cancellation: token, progress: progress)
        } completion: { result in
            self.discovery = result; self.discoverySelection = Set(result.projects.map(\.id)); self.discoveryPresented = true
        }
    }
    func registerDiscovery() {
        guard let discovery else { return }
        attempt {
            try mutate { lib in
                lib.projects = Catalogue.merge(discovery.projects.filter { discoverySelection.contains($0.id) }, into: lib.projects)
                var locations = lib.locations ?? []
                if let index = locations.firstIndex(where: { $0.path == discovery.location.path }) { locations[index] = discovery.location }
                else { locations.append(discovery.location) }
                lib.locations = locations
            }
            discoveryPresented = false
        }
    }
    func addExisting() {
        guard let url = folderPanel(title: "Add an existing project") else { return }
        run("Registering existing project") { token, _ in
            let record = try ProjectRecord(url: url, format: Catalogue.inferredFormat(url))
            return try Catalogue.indexExports(record, root: url.resolvingSymlinksInPath(), cancellation: token)
        } completion: { record in
            self.attempt { try self.mutate { $0.projects = Catalogue.merge([record], into: $0.projects) } }
        }
    }
    func locate(_ record: ProjectRecord) {
        guard let url = folderPanel(title: "Locate \(record.name)") else { return }
        attempt {
            var updated = record; try updated.relocate(to: url)
            try mutate { lib in if let i = lib.projects.firstIndex(where: { $0.id == record.id }) { lib.projects[i] = updated } }
            inspectProject(updated)
        }
    }
    func open(_ record: ProjectRecord) {
        attempt {
            let url = try record.resolve()
            guard FileManager.default.fileExists(atPath: url.path) else { throw AppFailure("Folder is unavailable. Its drive may be disconnected, access may be denied, or the folder may have moved. Use Locate Folder.") }
            if !NSWorkspace.shared.open(url) { throw AppFailure("Finder could not open this folder.") }
        }
    }
    func reveal(_ record: ProjectRecord) { attempt { NSWorkspace.shared.activateFileViewerSelecting([try record.resolve()]) } }
    func removeRecord(_ record: ProjectRecord) {
        attempt { try mutate { $0.projects.removeAll { $0.id == record.id } } }
        if selectedProject == record.id { selectedProject = nil }
    }
    func removeLocation(_ location: CatalogueLocation) {
        attempt { try mutate { $0.locations = ($0.locations ?? []).filter { $0.id != location.id } } }
    }
}
