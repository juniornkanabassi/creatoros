import SwiftUI
import AppKit
import TemplateCore
import AVKit

@MainActor final class AppModel: ObservableObject {
    @Published var library = Library()
    @Published var page = "New Project"
    @Published var selected: UUID?
    @Published var format = "Short"
    @Published var number = ""
    @Published var campaign = ""
    @Published var title = ""
    @Published var destination = ""
    @Published var plan: CopyPlan?
    @Published var validation = "Import and select a template to begin."
    @Published var busy = false
    @Published var fraction = 0.0
    @Published var status = ""
    @Published var error: String?
    @Published var created: URL?
    @Published var importSource: URL?
    @Published var importName = ""
    @Published var importMode: ImportMode = .full
    @Published var importPlan: CopyPlan?
    @Published var importPresented = false
    @Published var search = ""
    @Published var storeUsable = true
    @Published var selectedProject: UUID?
    @Published var inspections: [UUID: ProjectInspection] = [:]
    @Published var discovery: DiscoveryResult?
    @Published var discoveryPresented = false
    @Published var discoverySelection = Set<UUID>()
    @Published var player: AVPlayer?
    @Published var selectedExport: ExportRecord?
    @Published var formatFilter = "All formats"
    @Published var onlyFinals = false
    @Published var editingIcon = false
    @Published var inspectorTab = "Files"
    @Published var templateToBrowse: ProjectRecord?
    var inspectionRevision = 0
    var inspectionCancellation = Cancellation()
    let store: LibraryStore
    var cancellation = Cancellation()
    var revision = 0
    var scanCancellation = Cancellation()
    var cachedRoot: URL?
    // Index construction stays off the main actor; scans are debounced and cancellable.
    var refreshTask: Task<Void, Never>?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "--data-directory"), arguments.indices.contains(i + 1) {
            store = LibraryStore(root: URL(fileURLWithPath: arguments[i + 1]))
        } else { store = LibraryStore() }
        do { library = try store.load(); selected = library.templates.first?.id }
        catch { storeUsable = false; self.error = "Library could not be read. It has not been changed. \(error.localizedDescription)" }
        destination = preset.destination
    }
    var fields: ProjectFields { .init(number: number, format: format, campaign: campaign, title: title) }
    var preset: Preset { library.presets.first { $0.format == format } ?? Preset(format) }
    var template: TemplateRecord? { library.templates.first { $0.id == selected } }
    var finalName: String { (try? fields.finalName()) ?? "Enter project details" }
    var canCreate: Bool { !busy && storeUsable && plan != nil && validation.isEmpty && !destination.isEmpty }
    func save() throws { guard storeUsable else { throw AppFailure("Library is read-only after a load error.") }; try store.save(library) }
    func mutate(_ change: (inout Library) -> Void) throws {
        guard storeUsable else { throw AppFailure("Library is read-only after a load error.") }
        var next = library; change(&next)
        try store.save(next); library = next
    }
    func folderPanel(title: String) -> URL? {
        let panel = NSOpenPanel(); panel.title = title; panel.canChooseFiles = false
        panel.canChooseDirectories = true; panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
    func chooseDestination() {
        guard let url = folderPanel(title: "Choose project destination") else { return }
        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            try mutate { lib in
                if let index = lib.presets.firstIndex(where: { $0.format == format }) {
                    lib.presets[index].destination = url.path; lib.presets[index].destinationBookmark = bookmark
                }
            }
            destination = url.path; refresh()
        } catch { self.error = error.localizedDescription }
    }
    func changeFormat() {
        created = nil
        editingIcon = false
        destination = preset.destination
        if let bookmark = preset.destinationBookmark {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale else { throw AppFailure("Choose the destination again to refresh its bookmark.") }
                destination = url.path
            } catch { destination = ""; self.error = "Destination is unavailable. Choose it again. \(error.localizedDescription)" }
        }
        refresh()
    }
    func refresh() {
        revision += 1; let version = revision
        refreshTask?.cancel(); scanCancellation.cancel(); scanCancellation = Cancellation()
        let token = scanCancellation
        plan = nil; validation = "Preparing preview…"
        guard let template else { validation = "Import and select a template to begin."; return }
        let root = store.payload(template); let fields = fields
        refreshTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
                _ = try fields.finalName()
                let result = try await Task.detached(priority: .userInitiated) {
                    try TemplateReader.scan(root, fields: fields, cancellation: token)
                }.value
                guard revision == version else { return }
                plan = result; validation = ""
            } catch is CancellationError { }
            catch { if revision == version { validation = error.localizedDescription } }
        }
    }
    func beginImport() {
        let panel = NSOpenPanel(); panel.title = "Choose template folder or Post Haste package"
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let source = panel.url else { return }
        importSource = source; importName = source.pathExtension.lowercased() == "pht" ? source.deletingPathExtension().lastPathComponent : source.lastPathComponent
        importPresented = true; scanImport()
    }
    func scanImport() {
        guard let source = importSource, !busy else { return }
        importPlan = nil
        run("Inspecting template") { token, progress in
            try TemplateReader.scan(source, mode: await self.importMode, cancellation: token)
        } completion: { result in self.importPlan = result }
    }
    func commitImport() {
        guard let importPlan else { return }
        let name = importName; let mode = importMode; let store = store
        run("Importing independent template") { token, progress in
            try store.importTemplate(plan: importPlan, name: name, mode: mode, cancellation: token, progress: progress)
        } completion: { record in
            do {
                try self.mutate { $0.templates.append(record) }
                self.selected = record.id; self.importPresented = false; self.page = "New Project"; self.refresh()
            } catch {
                self.error = "Template copied to \(store.payload(record).path), but registration failed. Original is untouched. \(error.localizedDescription)"
            }
        }
    }
    func create() {
        guard canCreate, let plan else { return }
        let destination = URL(fileURLWithPath: destination); let name = finalName
        let icon = preset.icon; let format = format
        created = nil
        run("Creating project") { token, progress in
            try CreationEngine.create(plan: plan, destination: destination, name: name, icon: icon, cancellation: token, progress: progress)
        } completion: { url in
            self.created = url
            do {
                let record = try ProjectRecord(url: url, format: format)
                try self.mutate { $0.projects.insert(record, at: 0) }
            } catch { self.error = "The project exists at \(url.path), but history could not be saved. Do not create it again. Use Add Existing Project to recover. \(error.localizedDescription)" }
        }
    }
    func run<T: Sendable>(_ label: String,
                          operation: @escaping @Sendable (Cancellation, @escaping CreationEngine.Progress) async throws -> T,
                          completion: @escaping (T) -> Void) {
        guard !busy, storeUsable else { return }
        busy = true; status = label; fraction = 0; cancellation = Cancellation()
        let token = cancellation
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await operation(token) { value, text in
                        Task { @MainActor in self.fraction = value; self.status = text }
                    }
                }.value
                busy = false; status = "Complete"; completion(result)
            } catch is CancellationError { busy = false; status = "Cancelled. No new project or template was registered." }
            catch { busy = false; status = "Stopped"; self.error = error.localizedDescription }
        }
    }
    func addExisting() {
        guard let url = folderPanel(title: "Add existing project to history") else { return }
        run("Indexing existing project") { token, _ in
            let record = try ProjectRecord(url: url, format: Catalogue.inferredFormat(url))
            return try Catalogue.indexExports(record, root: url.resolvingSymlinksInPath(), cancellation: token)
        } completion: { record in
            do { try self.mutate { $0.projects = Catalogue.merge([record], into: $0.projects) } }
            catch { self.error = error.localizedDescription }
        }
    }
    func locate(_ record: ProjectRecord) {
        guard let url = folderPanel(title: "Locate \(record.name)") else { return }
        stopPreview()
        do {
            var updated = record; try updated.relocate(to: url)
            try mutate { lib in if let i = lib.projects.firstIndex(where: { $0.id == record.id }) { lib.projects[i] = updated } }
            inspectProject(updated)
        } catch { self.error = error.localizedDescription }
    }
    func open(_ record: ProjectRecord) {
        do {
            let url = try record.resolve()
            guard FileManager.default.fileExists(atPath: url.path) else { throw AppFailure("Folder is unavailable. Its drive may be disconnected, access may be denied, or the folder may have moved. Use Locate Folder.") }
            if !NSWorkspace.shared.open(url) { throw AppFailure("Finder could not open this folder.") }
        } catch { self.error = error.localizedDescription }
    }
    func removeRecord(_ record: ProjectRecord) {
        do { try mutate { $0.projects.removeAll { $0.id == record.id } } }
        catch { self.error = error.localizedDescription }
        if selectedProject == record.id { selectedProject = nil; stopPreview() }
    }
    func chooseIcon(fromFolder: Bool) {
        let panel = NSOpenPanel(); panel.title = fromFolder ? "Choose a folder whose icon you want" : "Choose an icon image"
        panel.canChooseDirectories = fromFolder; panel.canChooseFiles = !fromFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let image = fromFolder ? NSWorkspace.shared.icon(forFile: url.path) : NSImage(contentsOf: url)
        guard let data = image?.tiffRepresentation else { error = "That file could not be read as an image."; return }
        do { try mutate { lib in if let i = lib.presets.firstIndex(where: { $0.format == format }) {
            lib.presets[i].icon = data; lib.presets[i].iconSource = url.path; lib.presets[i].iconLocked = true
        } }; editingIcon = false }
        catch { self.error = error.localizedDescription }
    }
}
