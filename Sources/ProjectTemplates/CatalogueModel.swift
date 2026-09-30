import SwiftUI
import AppKit
import TemplateCore

extension AppModel {
    var selectedRecord: ProjectRecord? { library.projects.first { $0.id == selectedProject } }
    var filteredProjects: [ProjectRecord] {
        library.projects.filter {
            !$0.isPlanned && !hiddenLocations.contains($0.location.key) &&
            (formatFilter == "All formats" || $0.format == formatFilter) &&
            !excludedStages.contains(effectiveStage($0)) &&
            (search.isEmpty || $0.searchableText.localizedCaseInsensitiveContains(search) || deepMatches.contains($0.id))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
    }
    /// Projects for the current board, planned ideas included, with the same format, location and search filters.
    var pipelineProjects: [ProjectRecord] {
        library.projects.filter {
            pipelineKind.includes(format: $0.format) && ($0.isPlanned || !hiddenLocations.contains($0.location.key)) &&
            (formatFilter == "All formats" || $0.format == formatFilter) &&
            (search.isEmpty || $0.searchableText.localizedCaseInsensitiveContains(search) || deepMatches.contains($0.id))
        }
    }
    /// A folder's existence is not evidence that its content was published.
    func effectiveStage(_ record: ProjectRecord) -> String {
        record.stage ?? (record.isPlanned ? library.stageList.first : "Unclassified") ?? "Unclassified"
    }
    /// Every stage across both boards, plus any stage a record still carries that is no longer configured.
    var visibleStages: [String] {
        let configured = library.allStages
        return configured + Set(library.projects.map(effectiveStage).filter { !configured.contains($0) }).sorted()
    }
    /// Columns of the current board: its configured stages, then any orphaned stage its records still use.
    var boardStages: [String] {
        let configured = library.stages(for: pipelineKind)
        let orphans = Set(library.projects.filter { pipelineKind.includes(format: $0.format) }.map(effectiveStage).filter { !configured.contains($0) })
        return configured + orphans.sorted()
    }
    /// Where one record can be moved: its own board's stages, keeping its current stage in the list if that is no longer configured.
    func moveTargets(for record: ProjectRecord) -> [String] {
        let configured = library.stages(for: PipelineKind.of(format: record.format))
        let current = effectiveStage(record)
        return configured.contains(current) ? configured : configured + [current]
    }
    func projects(in stage: String) -> [ProjectRecord] {
        let list = pipelineProjects.filter { effectiveStage($0) == stage }
        return list.sorted { a, b in
            if a.isPlanned != b.isPlanned { return a.isPlanned }
            return (a.numberValue ?? -1) > (b.numberValue ?? -1)
        }
    }
    /// Availability only. Nothing is indexed and the library is not saved.
    func inspectProject(_ record: ProjectRecord, findMoved: Bool = false) {
        inspectionRevision += 1; let revision = inspectionRevision
        let id = record.id
        Task {
            let result = await Task.detached(priority: .userInitiated) { Catalogue.availability(record) }.value
            guard inspectionRevision == revision else { return }
            inspections[id] = result
            if findMoved && !result.available && !record.isPlanned { relink(record, quietly: true) }
        }
    }
    func selectProject() {
        guard let record = selectedRecord else { return }
        inspectProject(record, findMoved: true)
    }
    func scanLocation(_ url: URL? = nil) {
        guard let url = url ?? folderPanel(title: "Choose a folder containing projects") else { return }
        do { try runtime.requireWritable(url) } catch { self.error = error.localizedDescription; return }
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
        do { try runtime.requireWritable(url) } catch { self.error = error.localizedDescription; return }
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
            relinkCandidates[record.id] = nil
            relinkReport?.markLinked(record.id, at: url)
        }
    }
    func projectFolderForAction(_ record: ProjectRecord) throws -> URL {
        guard !record.isPlanned, !hiddenLocations.contains(record.location.key) else { throw ControlFailure(code: "location_hidden", message: "Choose a project on a ticked location.") }
        guard mountedLocations.contains(record.location.key) else { throw ControlFailure(code: "unavailable", message: "Connect the project's drive first.") }
        let url = try record.resolve()
        try runtime.requireWritable(url)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ControlFailure(code: "unavailable", message: "Folder is unavailable. Use Locate Folder.") }
        return url
    }
    func open(_ record: ProjectRecord) {
        attempt {
            let url = try projectFolderForAction(record)
            if !NSWorkspace.shared.open(url) { throw AppFailure("Finder could not open this folder.") }
        }
    }
    func removeLocation(_ location: CatalogueLocation) {
        attempt { try mutate { $0.locations = ($0.locations ?? []).filter { $0.id != location.id } } }
    }
}
