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
        Task { await inspect(record, findMoved: findMoved) }
    }
    /// The same check, awaitable. A newer inspection supersedes an older one's stored result, not its returned one.
    @discardableResult
    func inspect(_ record: ProjectRecord, findMoved: Bool = false, quietRelink: Bool = true) async -> ProjectInspection {
        inspectionRevision += 1; let revision = inspectionRevision
        let id = record.id
        let result = await Task.detached(priority: .userInitiated) { Catalogue.availability(record) }.value
        if inspectionRevision == revision { inspections[id] = result }
        if findMoved && !result.available && !record.isPlanned && inspectionRevision == revision { await searchForMoved(record, quietly: quietRelink) }
        return result
    }
    func selectProject() {
        guard let record = selectedRecord else { return }
        inspectProject(record, findMoved: true)
    }
    func scanLocation(_ url: URL? = nil) {
        guard let url = url ?? folderPanel(title: "Choose a folder containing projects") else { return }
        do { try runtime.requireWritable(url) } catch { self.error = error.localizedDescription; return }
        discoverProjects(root: url) { if case .success(let result) = $0 { self.showDiscovery(result) } }
    }
    func rescanLocation(_ location: CatalogueLocation) {
        discoverProjects(root: nil, saved: location, label: "Checking saved location") { if case .success(let result) = $0 { self.showDiscovery(result) } }
    }
    private func showDiscovery(_ result: DiscoveryResult) {
        discovery = result; discoverySelection = Set(result.projects.map(\.id)); discoveryPresented = true
    }
    /// Looks through a folder, or a saved location, for projects without moving anything. The sheet and control share it.
    func discoverProjects(root: URL?, saved: CatalogueLocation? = nil, label: String = "Looking for projects without moving files",
                          onFinish: @escaping (Result<DiscoveryResult, Error>) -> Void) {
        run(label, cancelNote: "Nothing was registered.") { token, progress in
            try Catalogue.discover(root: root ?? saved!.resolve(), cancellation: token, progress: progress)
        } completion: { onFinish(.success($0)) } failure: { onFinish(.failure(AppFailure($0))) }
    }
    func registerDiscovery() {
        guard let discovery else { return }
        attempt { try registerDiscovered(discovery, selecting: discoverySelection); discoveryPresented = false }
    }
    /// Registers the chosen discovered projects (all by default) and remembers the scanned location. Nothing on disk changes.
    func registerDiscovered(_ discovery: DiscoveryResult, selecting chosen: Set<UUID>? = nil) throws {
        try mutate { lib in
            lib.projects = Catalogue.merge(discovery.projects.filter { chosen?.contains($0.id) ?? true }, into: lib.projects)
            var locations = lib.locations ?? []
            if let index = locations.firstIndex(where: { $0.path == discovery.location.path }) { locations[index] = discovery.location }
            else { locations.append(discovery.location) }
            lib.locations = locations
        }
    }
    func addExisting() {
        guard let url = folderPanel(title: "Add an existing project") else { return }
        do { try runtime.requireWritable(url) } catch { self.error = error.localizedDescription; return }
        registerExisting(url)
    }
    /// Registers one project folder made outside the app. Returns the library's record for it, new or already there.
    func registerExisting(_ url: URL, format: String? = nil, onFinish: ((Result<ProjectRecord, Error>) -> Void)? = nil) {
        run("Registering existing project", cancelNote: "Nothing was registered.") { token, _ in
            try token.check()
            return try ProjectRecord(url: url, format: format ?? Catalogue.inferredFormat(url))
        } completion: { record in
            do {
                try self.mutate { $0.projects = Catalogue.merge([record], into: $0.projects) }
                if let saved = self.library.projects.first(where: { $0.path == record.path }) { onFinish?(.success(saved)) }
                else { onFinish?(.failure(AppFailure("The project was not registered."))) }
            } catch { self.error = error.localizedDescription; onFinish?(.failure(error)) }
        } failure: { onFinish?(.failure(AppFailure($0))) }
    }
    func locate(_ record: ProjectRecord) {
        guard let url = folderPanel(title: "Locate \(record.name)") else { return }
        attempt { if let updated = try relocate(record, to: url) { inspectProject(updated) } }
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
    func removeLocation(_ location: CatalogueLocation) { attempt { try forgetLocation(location) } }
    func forgetLocation(_ location: CatalogueLocation) throws { try mutate { $0.locations = ($0.locations ?? []).filter { $0.id != location.id } } }
}
