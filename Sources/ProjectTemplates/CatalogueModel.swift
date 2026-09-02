import SwiftUI
import AppKit
import AVKit
import TemplateCore

extension AppModel {
    func browseTemplate(_ template: TemplateRecord) {
        do { var record = try ProjectRecord(url: store.payload(template), format: "Template"); record.name = template.name; templateToBrowse = record }
        catch { self.error = error.localizedDescription }
    }
    func matchingExports(_ record: ProjectRecord) -> [ExportRecord] {
        (record.exports ?? []).filter { export in
            (!onlyFinals || record.markedFinals.contains(export.relativePath)) &&
            (search.isEmpty || ([record.name, record.path] + (record.previousPaths ?? [])).joined(separator: " ").localizedCaseInsensitiveContains(search) || export.relativePath.localizedCaseInsensitiveContains(search))
        }
    }
    var selectedRecord: ProjectRecord? { library.projects.first { $0.id == selectedProject } }
    var filteredProjects: [ProjectRecord] {
        library.projects.filter {
            (formatFilter == "All formats" || $0.format == formatFilter) &&
            (search.isEmpty || $0.searchableText.localizedCaseInsensitiveContains(search))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
    }
    func stopPreview() { player?.pause(); player = nil; selectedExport = nil }
    func inspectProject(_ record: ProjectRecord) {
        inspectionCancellation.cancel(); inspectionCancellation = Cancellation()
        let token = inspectionCancellation
        inspectionRevision += 1; let revision = inspectionRevision
        let id = record.id
        Task {
            let result = await Task.detached(priority: .userInitiated) { Catalogue.inspect(record, cancellation: token) }.value
            guard inspectionRevision == revision, library.projects.contains(where: { $0.id == id }) else { return }
            inspections[id] = result
            if result.available {
                do { try mutate { lib in
                    if let index = lib.projects.firstIndex(where: { $0.id == id }) {
                        // Update index fields only; preserve any user edits made during the scan.
                        lib.projects[index].exports = result.record.exports
                        lib.projects[index].lastIndexed = result.record.lastIndexed
                        lib.projects[index].scanNotes = result.record.scanNotes
                    }
                } } catch { self.error = "Index refreshed but could not be saved. \(error.localizedDescription)" }
            }
        }
    }
    func selectProject() {
        stopPreview()
        if let record = selectedRecord { inspectProject(record) }
    }
    func scanLocation(_ url: URL? = nil) {
        guard let url = url ?? folderPanel(title: "Choose a folder containing projects") else { return }
        run("Looking for projects without moving files") { token, progress in
            try Catalogue.discover(root: url, cancellation: token, progress: progress)
        } completion: { result in
            self.discovery = result; self.discoverySelection = Set(result.projects.map(\.id)); self.discoveryPresented = true
        }
    }
    func rescanLocation(_ location: CatalogueLocation) {
        // Bookmark resolution is worker work too; withoutMounting avoids waking offline drives.
        run("Checking saved location") { token, progress in
            try Catalogue.discover(root: location.resolve(), cancellation: token, progress: progress)
        } completion: { result in
            self.discovery = result; self.discoverySelection = Set(result.projects.map(\.id)); self.discoveryPresented = true
        }
    }
    func registerDiscovery() {
        guard let discovery else { return }
        do {
            try mutate { lib in
                lib.projects = Catalogue.merge(discovery.projects.filter { discoverySelection.contains($0.id) }, into: lib.projects)
                var locations = lib.locations ?? []
                if let index = locations.firstIndex(where: { $0.path == discovery.location.path }) { locations[index] = discovery.location }
                else { locations.append(discovery.location) }
                lib.locations = locations
            }
            discoveryPresented = false
        } catch { self.error = error.localizedDescription }
    }
    func addExportFolder(_ record: ProjectRecord) {
        guard let folder = folderPanel(title: "Choose an exports subfolder inside this project") else { return }
        do {
            let root = try record.resolve().resolvingSymlinksInPath()
            guard folder.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
                throw AppFailure("Choose a subfolder inside this project. Register a different project separately.")
            }
            let relative = String(folder.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
            _ = try Catalogue.safeChild(relative, under: root)
            var changed = record; changed.exportFolders = Array(Set((record.exportFolders ?? []) + [relative])).sorted()
            try mutate { lib in if let index = lib.projects.firstIndex(where: { $0.id == record.id }) { lib.projects[index] = changed } }
            inspectProject(changed)
        } catch { self.error = error.localizedDescription }
    }
    func markFinal(_ export: ExportRecord, in record: ProjectRecord) {
        do { try mutate { lib in
            if let index = lib.projects.firstIndex(where: { $0.id == record.id }) {
                var finals = lib.projects[index].markedFinals
                if finals.contains(export.relativePath) { finals.remove(export.relativePath) } else { finals.insert(export.relativePath) }
                lib.projects[index].finalExportPaths = finals.sorted()
                lib.projects[index].finalExportPath = nil
            }
        } } catch { self.error = error.localizedDescription }
    }
    func preview(_ export: ExportRecord, in record: ProjectRecord, external: Bool = false) {
        stopPreview()
        run("Checking export location") { token, _ in
            try token.check()
            let root = try record.resolve()
            let url = try Catalogue.safeChild(export.relativePath, under: root)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .volumeUUIDStringKey])
            guard values.isRegularFile == true else { throw AppFailure("Export is unavailable. Reconnect its drive or refresh the project index.") }
            if let expected = record.volumeID, let actual = values.volumeUUIDString, expected != actual { throw AppFailure("The mounted drive does not match this project.") }
            return url
        } completion: { url in
            if external { if !NSWorkspace.shared.open(url) { self.error = "No application could open this video." } }
            else {
                self.selectedExport = export
                let player = AVPlayer(url: url); player.isMuted = true
                self.player = player // Never auto-play or produce unexpected sound.
            }
        }
    }
    func reveal(_ record: ProjectRecord) {
        do { NSWorkspace.shared.activateFileViewerSelecting([try record.resolve()]) }
        catch { self.error = error.localizedDescription }
    }
}
