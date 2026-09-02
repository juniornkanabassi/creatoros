import SwiftUI
import AppKit
import TemplateCore

enum Page: String, CaseIterable, Identifiable {
    case newProject = "New Project", projects = "Projects", templates = "Templates"
    var id: String { rawValue }
    var systemImage: String {
        switch self { case .newProject: "folder.badge.plus"; case .projects: "externaldrive"; case .templates: "square.stack.3d.up" }
    }
}

/// What the New Project screen creates from: a set resolved by format, or a legacy template used directly.
enum TemplateSelection: Hashable {
    case set(UUID), legacy(UUID)
    var stored: String { switch self { case .set(let id): "set:\(id.uuidString)"; case .legacy(let id): "legacy:\(id.uuidString)" } }
    init?(stored: String) {
        let parts = stored.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] { case "set": self = .set(id); case "legacy": self = .legacy(id); default: return nil }
    }
}

enum VariantState {
    case none
    case missing(setName: String)
    case ready(TemplateRecord, sharedWith: [String])
    case legacy(TemplateRecord)
    var record: TemplateRecord? { switch self { case .ready(let r, _), .legacy(let r): r; default: nil } }
}

/// Which browser receives the View menu shortcuts. Sheets push over pages.
enum BrowserSurface: String, CaseIterable { case projectFiles, managedTemplate, creationPreview }

struct PendingAssignment: Equatable { let setID: UUID; let format: String }
struct NewSetPrompt: Identifiable { let id = UUID(); let mappingTemplateID: UUID?; var name: String }
struct CachedStructure { let plan: CopyPlan; let rootModified: Date? }

enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development" }
}

@MainActor final class AppModel: ObservableObject {
    @Published var library = Library()
    @Published var page: Page { didSet { defaults.set(page.rawValue, forKey: "page") } }
    @Published var selection: TemplateSelection? { didSet { defaults.set(selection?.stored, forKey: "selection") } }
    @Published var format: String { didSet { defaults.set(format, forKey: "format") } }
    @Published var number = ""
    @Published var campaign = ""
    @Published var title = ""
    @Published var destination = ""
    @Published var preview: PreviewRendering?
    @Published var plan: CopyPlan?
    @Published var validation = ""
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
    @Published var pendingAssignment: PendingAssignment?
    @Published var search = ""
    @Published var storeUsable = true
    @Published var selectedProject: UUID?
    @Published var inspections: [UUID: ProjectInspection] = [:]
    @Published var discovery: DiscoveryResult?
    @Published var discoveryPresented = false
    @Published var discoverySelection = Set<UUID>()
    @Published var formatFilter = "All formats"
    @Published var editingIcon = false
    @Published var templateToBrowse: TemplateRecord?
    @Published var templatesSelection: TemplateSelection?
    @Published var newSetPrompt: NewSetPrompt?
    @Published var viewModes: [BrowserSurface: BrowserViewMode] = [:]
    @Published var activeSurfaces: [BrowserSurface] = []
    let store: LibraryStore
    let defaults = UserDefaults.standard
    var cancellation = Cancellation()
    var scanCancellation = Cancellation()
    var revision = 0
    var refreshTask: Task<Void, Never>?
    var structureCache: [UUID: CachedStructure] = [:]
    var inspectionRevision = 0

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "--data-directory"), arguments.indices.contains(i + 1) {
            store = LibraryStore(root: URL(fileURLWithPath: arguments[i + 1]))
        } else { store = LibraryStore() }
        page = Page(rawValue: defaults.string(forKey: "page") ?? "") ?? .newProject
        format = defaults.string(forKey: "format") ?? "Short"
        selection = defaults.string(forKey: "selection").flatMap(TemplateSelection.init(stored:))
        for surface in BrowserSurface.allCases {
            viewModes[surface] = BrowserViewMode(rawValue: defaults.string(forKey: "viewMode." + surface.rawValue) ?? "") ?? .list
        }
        do { library = try store.load() }
        catch { storeUsable = false; self.error = "Library could not be read. It has not been changed. \(error.localizedDescription)" }
        if !Library.formats.contains(format) { format = "Short" }
        if !selectionIsValid { selection = defaultSelection }
        destination = preset.destination
    }

    // MARK: Selection and resolution

    var fields: ProjectFields { .init(number: number, format: format, campaign: campaign, title: title) }
    var preset: Preset { library.presets.first { $0.format == format } ?? Preset(format) }
    var formatLabel: String { preset.label }
    func label(for format: String) -> String { library.presets.first { $0.format == format }?.label ?? format }
    var selectionIsValid: Bool {
        switch selection {
        case .set(let id): library.set(id) != nil
        case .legacy(let id): library.template(id) != nil
        case nil: false
        }
    }
    var defaultSelection: TemplateSelection? {
        if let set = library.sets.first { return .set(set.id) }
        if let legacy = library.unassignedTemplates.first { return .legacy(legacy.id) }
        return nil
    }
    var selectedSet: TemplateSet? { if case .set(let id) = selection { return library.set(id) }; return nil }
    var variantState: VariantState {
        switch selection {
        case .set(let id):
            guard let set = library.set(id) else { return .none }
            guard let variant = set.variant(for: format), let record = library.template(variant.templateID) else { return .missing(setName: set.name) }
            return .ready(record, sharedWith: set.formatsSharing(record.id, excluding: format).map(label(for:)))
        case .legacy(let id):
            guard let record = library.template(id) else { return .none }
            return .legacy(record)
        case nil: return .none
        }
    }
    var payload: TemplateRecord? { variantState.record }
    func isReady(format: String) -> Bool {
        switch selection {
        case .set(let id): library.resolve(setID: id, format: format) != nil
        case .legacy: true
        case nil: false
        }
    }
    var canCreate: Bool { !busy && storeUsable && created == nil && plan != nil && preview?.isExecutable == true && !destination.isEmpty }

    // MARK: Persistence

    func save() throws { guard storeUsable else { throw AppFailure("Library is read-only after a load error.") }; try store.save(library) }
    func mutate(_ change: (inout Library) throws -> Void) throws {
        guard storeUsable else { throw AppFailure("Library is read-only after a load error.") }
        var next = library; try change(&next)
        try store.save(next); library = next
    }
    func attempt(_ work: () throws -> Void) { do { try work() } catch { self.error = error.localizedDescription } }

    // MARK: Destinations and formats

    func folderPanel(title: String) -> URL? {
        let panel = NSOpenPanel(); panel.title = title; panel.canChooseFiles = false
        panel.canChooseDirectories = true; panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
    func chooseDestination() {
        guard let url = folderPanel(title: "Choose where \(formatLabel) projects go") else { return }
        attempt {
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            try mutate { lib in
                if let index = lib.presets.firstIndex(where: { $0.format == format }) {
                    lib.presets[index].destination = url.path; lib.presets[index].destinationBookmark = bookmark
                }
            }
            destination = url.path
        }
    }
    func changeFormat() {
        created = nil; editingIcon = false
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
    func changeSelection() { created = nil; refresh() }
    func fieldChanged() { created = nil; refresh() }

    // MARK: Preview

    private func rootModified(_ root: URL) -> Date? { try? root.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
    func invalidateStructure(_ id: UUID? = nil) {
        if let id { structureCache[id] = nil } else { structureCache.removeAll() }
    }
    /// Renders synchronously from the cached structure; scans in the background only when the payload is new or changed.
    func refresh() {
        revision += 1; let version = revision
        refreshTask?.cancel(); scanCancellation.cancel()
        guard let payload else {
            preview = nil; plan = nil
            switch variantState {
            case .missing(let setName): validation = "\(formatLabel) is not set up in \(setName) yet. Import a payload or reuse another format's payload to see the preview."
            default: validation = library.templates.isEmpty ? "Import a template to see the preview." : "Choose a content template to see the preview."
            }
            return
        }
        let root = store.payload(payload)
        if let cached = structureCache[payload.id], cached.rootModified == rootModified(root) { render(cached.plan); return }
        preview = nil; plan = nil; validation = "Reading template…"
        scanCancellation = Cancellation(); let token = scanCancellation; let id = payload.id
        refreshTask = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try TemplateReader.scan(root, cancellation: token) }.value
                guard revision == version else { return }
                structureCache[id] = CachedStructure(plan: result, rootModified: rootModified(root))
                render(result)
            } catch is CancellationError {
            } catch { if revision == version { validation = error.localizedDescription } }
        }
    }
    private func render(_ structure: CopyPlan) {
        let rendering = PreviewRenderer.render(structure: structure, fields: fields)
        preview = rendering; validation = ""
        guard rendering.isExecutable else { plan = nil; return }
        do { plan = try TemplateReader.plan(from: structure, fields: fields) }
        catch { plan = nil; validation = error.localizedDescription }
    }

    // MARK: Import

    func beginImport(assigning: PendingAssignment? = nil) {
        let panel = NSOpenPanel(); panel.title = "Choose a template folder or Post Haste package"
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let source = panel.url else { return }
        pendingAssignment = assigning
        importSource = source
        importName = source.pathExtension.lowercased() == "pht" ? source.deletingPathExtension().lastPathComponent : source.lastPathComponent
        importPresented = true; scanImport()
    }
    func scanImport() {
        guard let source = importSource, !busy else { return }
        importPlan = nil
        run("Inspecting template") { token, _ in
            try TemplateReader.scan(source, mode: await self.importMode, cancellation: token)
        } completion: { result in self.importPlan = result }
    }
    func commitImport() {
        guard let importPlan else { return }
        let name = importName; let mode = importMode; let store = store; let pending = pendingAssignment
        run("Importing independent template") { token, progress in
            try store.importTemplate(plan: importPlan, name: name, mode: mode, cancellation: token, progress: progress)
        } completion: { record in
            do {
                try self.mutate { lib in
                    lib.templates.append(record)
                    if let pending { try lib.assign(format: pending.format, templateID: record.id, in: pending.setID) }
                }
                self.importPresented = false; self.pendingAssignment = nil
                if let pending { self.selection = .set(pending.setID); self.format = pending.format; self.changeFormat() }
                else if self.selection == nil || self.selectedSet == nil { self.selection = .legacy(record.id); self.changeSelection() }
                if self.page == .templates { self.templatesSelection = pending.map { .set($0.setID) } ?? .legacy(record.id) }
            } catch {
                self.error = "Template copied to \(store.payload(record).path), but registration failed. Original is untouched. \(error.localizedDescription)"
            }
        }
    }

    // MARK: Sets

    func promptNewSet(mapping templateID: UUID? = nil) {
        newSetPrompt = NewSetPrompt(mappingTemplateID: templateID, name: templateID.flatMap { library.template($0)?.name } ?? "")
    }
    func confirmNewSet() {
        guard let prompt = newSetPrompt else { return }
        attempt {
            var made: TemplateSet?
            try mutate { made = try $0.createSet(named: prompt.name, mappingAll: prompt.mappingTemplateID) }
            newSetPrompt = nil
            if let made {
                templatesSelection = .set(made.id)
                if selection == nil || selectedSet == nil || prompt.mappingTemplateID != nil { selection = .set(made.id); changeSelection() }
            }
        }
    }
    func renameSet(_ id: UUID, to name: String) { attempt { try mutate { try $0.renameSet(id, to: name) } } }
    func assign(format: String, templateID: UUID, in setID: UUID) {
        attempt { try mutate { try $0.assign(format: format, templateID: templateID, in: setID) }; refresh() }
    }
    func unassign(format: String, in setID: UUID) { attempt { try mutate { $0.unassign(format: format, in: setID) }; refresh() } }
    func removeSet(_ id: UUID) {
        attempt {
            try mutate { $0.removeSet(id) }
            if templatesSelection == .set(id) { templatesSelection = nil }
            if selection == .set(id) { selection = defaultSelection; changeSelection() }
        }
    }
    /// Moves the managed payload to the Trash and drops every assignment that used it.
    func removeTemplate(_ record: TemplateRecord) {
        attempt {
            let payload = store.payload(record)
            if FileManager.default.fileExists(atPath: payload.path) { try FileManager.default.trashItem(at: payload, resultingItemURL: nil) }
            try mutate { lib in
                lib.templates.removeAll { $0.id == record.id }
                lib.templateSets = lib.sets.map { set in var s = set; s.variants.removeAll { $0.templateID == record.id }; return s }
            }
            invalidateStructure(record.id)
            if templatesSelection == .legacy(record.id) { templatesSelection = nil }
            if !selectionIsValid { selection = defaultSelection }
            refresh()
        }
    }
    func useForNewProject(_ choice: TemplateSelection) { selection = choice; page = .newProject; changeSelection() }
    func browseTemplate(_ record: TemplateRecord) { templateToBrowse = record }
    func finishedBrowsingTemplate() {
        if let record = templateToBrowse { invalidateStructure(record.id) }
        templateToBrowse = nil; refresh()
    }

    // MARK: Creation

    func create() {
        guard canCreate, let plan, let preview else { return }
        let destination = URL(fileURLWithPath: destination); let name = preview.outerFolderName
        let icon = preset.icon; let format = format; let payloadID = payload?.id
        created = nil
        run("Creating project") { token, progress in
            try CreationEngine.create(plan: plan, destination: destination, name: name, icon: icon, cancellation: token, progress: progress)
        } completion: { url in
            self.created = url
            do {
                let record = try ProjectRecord(url: url, format: format)
                try self.mutate { $0.projects.insert(record, at: 0) }
            } catch { self.error = "The project exists at \(url.path), but history could not be saved. Do not create it again. Use Add Existing Project to recover. \(error.localizedDescription)" }
        } failure: { message in
            if message.contains("changed"), let payloadID { self.invalidateStructure(payloadID); self.refresh() }
        }
    }
    func run<T: Sendable>(_ label: String,
                          operation: @escaping @Sendable (Cancellation, @escaping CreationEngine.Progress) async throws -> T,
                          completion: @escaping (T) -> Void, failure: @escaping (String) -> Void = { _ in }) {
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
            } catch is CancellationError { busy = false; status = "Cancelled. Nothing was created or registered." }
            catch { busy = false; status = "Stopped"; self.error = error.localizedDescription; failure(error.localizedDescription) }
        }
    }

    // MARK: Icons

    func chooseIcon(fromFolder: Bool) {
        let panel = NSOpenPanel(); panel.title = fromFolder ? "Choose a folder whose icon you want" : "Choose an icon image"
        panel.canChooseDirectories = fromFolder; panel.canChooseFiles = !fromFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let image = fromFolder ? NSWorkspace.shared.icon(forFile: url.path) : NSImage(contentsOf: url)
        guard let data = image?.tiffRepresentation else { error = "That file could not be read as an image."; return }
        attempt {
            try mutate { lib in if let i = lib.presets.firstIndex(where: { $0.format == format }) {
                lib.presets[i].icon = data; lib.presets[i].iconSource = url.path; lib.presets[i].iconLocked = true
            } }
            editingIcon = false
        }
    }

    // MARK: Browser view modes

    var activeSurface: BrowserSurface? { activeSurfaces.last }
    var activeViewMode: BrowserViewMode? { activeSurface.flatMap { viewModes[$0] } }
    func viewMode(_ surface: BrowserSurface) -> BrowserViewMode { viewModes[surface] ?? .list }
    func setViewMode(_ mode: BrowserViewMode, for surface: BrowserSurface) {
        viewModes[surface] = mode; defaults.set(mode.rawValue, forKey: "viewMode." + surface.rawValue)
    }
    func setActiveViewMode(_ mode: BrowserViewMode) { if let surface = activeSurface { setViewMode(mode, for: surface) } }
    func activate(_ surface: BrowserSurface) { activeSurfaces.removeAll { $0 == surface }; activeSurfaces.append(surface) }
    func deactivate(_ surface: BrowserSurface) { activeSurfaces.removeAll { $0 == surface } }
}
