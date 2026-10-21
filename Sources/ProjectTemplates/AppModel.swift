import SwiftUI
import AppKit
import TemplateCore

/// The three places in the app. New Project is a sheet over any of them, opened with Command-N.
enum Page: String, CaseIterable, Identifiable {
    case projects = "Projects", pipeline = "Pipeline", templates = "Templates"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .pipeline: "rectangle.3.group"
        case .projects: "externaldrive"
        case .templates: "square.stack.3d.up"
        }
    }
    var hint: String {
        switch self {
        case .pipeline: "Move recordings and streams through their stages"
        case .projects: "Browse every project, wherever it lives"
        case .templates: "Template sets and the folders each format copies"
        }
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

/// What happened to a Finder tag write, returned to control callers; the GUI ignores it.
enum TagOutcome: String { case applied, skipped, failed }

struct PendingAssignment: Equatable { let setID: UUID; let format: String }
struct IconRestoreCandidate: Identifiable {
    let id: UUID
    let name: String
    let available: Bool
    let reason: String?
}
struct NewSetPrompt: Identifiable { let id = UUID(); let mappingTemplateID: UUID?; var name: String }
struct CachedStructure { let plan: CopyPlan; let rootModified: Date?; let renamingPaths: Set<String>? }

/// What Find Moved Folders concluded about one project whose folder was missing.
struct RelinkOutcome: Identifiable {
    enum Kind: Hashable { case relinked(URL), candidates([URL]), notFound, stillThere }
    let id: UUID
    let name: String
    let previousPath: String
    var kind: Kind
}
struct RelinkReport: Identifiable {
    let id = UUID()
    let checked: Int
    var outcomes: [RelinkOutcome]
    /// Turns a row green once the project has been linked, by the pass itself or by hand while the report is open.
    mutating func markLinked(_ id: UUID, at url: URL) {
        if let index = outcomes.firstIndex(where: { $0.id == id }) { outcomes[index].kind = .relinked(url) }
    }
    var relinked: [RelinkOutcome] { outcomes.filter { if case .relinked = $0.kind { return true }; return false } }
    var unresolved: [RelinkOutcome] { outcomes.filter { switch $0.kind { case .candidates, .notFound: true; default: false } } }
}

enum AppInfo {
    static var name: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "CreatorOS" }
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development" }
    static var channel: String { Bundle.main.object(forInfoDictionaryKey: "CreatorOSChannel") as? String ?? "" }
    static var channelName: String {
        switch channel { case "α": "Alpha"; case "β": "Beta"; case "RC": "Release candidate"; default: channel }
    }
    static var label: String { [name, version, channel].filter { !$0.isEmpty }.joined(separator: " ") }
}

/// Keep the ordinary Greek characters, but give their release marks a distinct handwritten tail.
struct ReleaseVersionLabel: View {
    var includeName = false
    var size: CGFloat = 13

    var body: some View {
        let prefix = "\(includeName ? AppInfo.name + " " : "")\(AppInfo.version)"
        let spacer = AppInfo.channel.isEmpty ? "" : " "
        let greek = AppInfo.channel == "α" || AppInfo.channel == "β"
        let mark = Text(AppInfo.channel).font(greek ? .custom("TimesNewRomanPS-ItalicMT", fixedSize: size + 3) : nil)
        Text("\(prefix)\(spacer)\(mark)")
            .accessibilityLabel([prefix, AppInfo.channelName].filter { !$0.isEmpty }.joined(separator: " "))
    }
}

/// Named colours the user can pick for a location badge.
enum BadgeColour: String, CaseIterable, Identifiable {
    case gray, orange, green, blue, purple, teal, pink, indigo, red, yellow, brown, mint
    var id: String { rawValue }
    var colour: Color {
        switch self {
        case .gray: .gray; case .orange: .orange; case .green: .green; case .blue: .blue; case .purple: .purple; case .teal: .teal
        case .pink: .pink; case .indigo: .indigo; case .red: .red; case .yellow: .yellow; case .brown: .brown; case .mint: .mint
        }
    }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

@MainActor final class AppModel: ObservableObject {
    @Published var library = Library()
    @Published var page: Page { didSet { defaults.set(page.rawValue, forKey: "page") } }
    @Published var selection: TemplateSelection? { didSet { defaults.set(selection?.stored, forKey: "selection") } }
    @Published var format: String { didSet { defaults.set(format, forKey: "format") } }
    @Published var number = ""
    @Published var numberIsAutomatic = true
    @Published var campaign = ""
    @Published var title = ""
    @Published var extraValues: [UUID: String] = [:]
    @Published var destination = "" { didSet { updatePlainFolders() } }
    @Published var preview: PreviewRendering?
    @Published var plan: CopyPlan?
    @Published var validation = ""
    @Published var busy = false
    @Published var fraction = 0.0
    @Published var status = ""
    @Published var error: String?
    @Published var created: URL?
    @Published var startingFrom: UUID?
    @Published var importSource: URL?
    @Published var importName = ""
    @Published var importMode: ImportMode = .full
    @Published var importPlan: CopyPlan?
    @Published var importPresented = false
    @Published var pendingAssignment: PendingAssignment?
    @Published var search = "" { didSet { scheduleDeepSearch() } }
    @Published var storeUsable = true
    @Published var selectedProject: UUID?
    @Published var inspections: [UUID: ProjectInspection] = [:]
    @Published var discovery: DiscoveryResult?
    @Published var discoveryPresented = false
    @Published var discoverySelection = Set<UUID>()
    @Published var formatFilter = "All formats"
    /// Stages unticked in the Stages filter. Empty means every stage shows.
    @Published var excludedStages: Set<String> { didSet { defaults.set(Array(excludedStages).sorted(), forKey: "excludedStages") } }
    /// New Project is a sheet; this opens it.
    @Published var newProjectPresented = false
    /// Bumped by Refresh Project (⌘R) and the filters' Refresh; every open file browser reads its folders again.
    @Published var browserRefresh = 0
    /// Projects whose documents matched the search text, found by the deep search off the main thread.
    @Published var deepMatches: Set<UUID> = []
    @Published var mountedLocations: Set<String> = []
    @Published var locationColours: [String: String] = [:]
    @Published var editingIcon = false
    @Published var templateToBrowse: TemplateRecord?
    @Published var templatesSelection: TemplateSelection?
    @Published var newSetPrompt: NewSetPrompt?
    @Published var viewModes: [BrowserSurface: BrowserViewMode] = [:]
    @Published var activeSurfaces: [BrowserSurface] = []
    @Published var zoomLevel: Int { didSet { defaults.set(zoomLevel, forKey: "zoomLevel") } }
    @Published var pipelineSelection: UUID?
    @Published var pipelineKind: PipelineKind { didSet { defaults.set(pipelineKind.rawValue, forKey: "pipelineKind"); if !pipelineKind.includes(format: formatFilter) { formatFilter = "All formats" } } }
    @Published var tagging = false
    /// New Project: copy without folder icons, for a destination such as LucidLink that cannot hold them.
    @Published var plainFolders = false
    @Published var newIdeaPresented = false
    @Published var compatibilityReport: CompatibilityReport?
    @Published var compatibilityPresented = false
    @Published var compatibilityOutput: URL?
    @Published var workspacePrompt: ProjectRecord?
    @Published var workspaceToBrowse: ProjectRecord?
    @Published var workspaceCleanup: ProjectRecord?
    @Published var renamePrompt: ProjectRecord?
    var controlServer: ControlServer?
    var controlResults: [String: (parameters: Data, result: [String: Any])] = [:]
    var controlPending = Set<String>()
    var controlMutating = false
    /// The request id of the control mutation that is running now, so app.cancel only stops the operation its caller started.
    var controlOwner: String?
    var tagTasks: [UUID: Task<TagOutcome, Never>] = [:]
    var tagGeneration: [UUID: Int] = [:]
    @Published var restoreIconsPrompt: ProjectRecord?
    @Published var binIdea: ProjectRecord?
    @Published var confirmedWorkspaceURL: URL?
    @Published var groupByDate: Bool { didSet { defaults.set(groupByDate, forKey: "groupByDate") } }
    @Published var relinkCandidates: [UUID: [URL]] = [:]
    @Published var relinking: Set<UUID> = []
    @Published var relinkBatchRunning = false
    /// The result of the last Find Moved Folders pass, shown as a sheet.
    @Published var relinkReport: RelinkReport?
    @Published var duplicatesPresented = false
    /// Drives unticked in the Locations filter: their projects stay registered but are kept out of every list, and the drive is never read.
    @Published var hiddenLocations: Set<String> { didSet { defaults.set(Array(hiddenLocations).sorted(), forKey: "hiddenLocations") } }
    var mountTimer: Timer?
    private var checkingMounts = false
    private var attemptedDates = Set<UUID>()
    let store: LibraryStore
    let runtime: AppRuntime
    let defaults: UserDefaults
    var cancellation = Cancellation()
    var scanCancellation = Cancellation()
    var revision = 0
    var refreshTask: Task<Void, Never>?
    var structureCache: [UUID: CachedStructure] = [:]
    var inspectionRevision = 0

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        var startupError: String?
        var chosenRoot: URL?
        if let i = arguments.firstIndex(of: "--data-directory") {
            if arguments.indices.contains(i + 1), !arguments[i + 1].hasPrefix("--") { chosenRoot = URL(fileURLWithPath: arguments[i + 1]) }
            else { startupError = "--data-directory requires a separate disposable folder." }
        }
        do { runtime = try AppRuntime.forLaunch(bundleIdentifier: Bundle.main.bundleIdentifier, channel: AppInfo.channel, dataRoot: chosenRoot) }
        catch { startupError = error.localizedDescription; runtime = try! AppRuntime.isolated() }
        store = LibraryStore(root: runtime.root)
        defaults = runtime.isIsolated ? UserDefaults(suiteName: runtime.defaultsSuite)! : .standard
        page = Page(rawValue: defaults.string(forKey: "page") ?? "") ?? .projects
        format = defaults.string(forKey: "format") ?? "Short"
        selection = defaults.string(forKey: "selection").flatMap(TemplateSelection.init(stored:))
        hiddenLocations = Set(defaults.stringArray(forKey: "hiddenLocations") ?? [])
        excludedStages = Set(defaults.stringArray(forKey: "excludedStages") ?? [])
        zoomLevel = defaults.object(forKey: "zoomLevel") as? Int ?? 0
        groupByDate = defaults.object(forKey: "groupByDate") as? Bool ?? true
        pipelineKind = PipelineKind(rawValue: defaults.string(forKey: "pipelineKind") ?? "") ?? .recordings
        for surface in BrowserSurface.allCases {
            viewModes[surface] = BrowserViewMode(rawValue: defaults.string(forKey: "viewMode." + surface.rawValue) ?? "") ?? .list
        }
        do {
            if let startupError { throw AppFailure(startupError) }
            try runtime.requireWritable(store.file)
            let storedSchema = store.storedSchema()
            let loaded = try store.load()
            try runtime.validate(loaded)
            if !runtime.isIsolated, let storedSchema, storedSchema < Library.currentSchema { try store.save(loaded) }
            library = loaded
            if !FileManager.default.fileExists(atPath: store.file.path) {
                for index in library.presets.indices { library.presets[index].destination = runtime.projects.appendingPathComponent(library.presets[index].format).path }
            }
            try FileManager.default.createDirectory(at: runtime.ideas, withIntermediateDirectories: true)
        }
        catch { storeUsable = false; self.error = "Library could not be read. It has not been changed. \(error.localizedDescription)" }
        if !Library.formats.contains(format) { format = "Short" }
        if !selectionIsValid { selection = defaultSelection }
        destination = preset.destination
        updatePlainFolders()
        number = suggestedNumber
    }

    // MARK: Selection and resolution

    var fields: ProjectFields {
        .init(number: number, format: format, campaign: campaign, title: title,
              extras: library.fieldList.map { ExtraValue(name: $0.name, value: extraValues[$0.id] ?? "", includeInName: $0.includeInName) })
    }
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

    // MARK: Numbering

    var suggestedNumber: String { Numbering.next(for: format, in: library.projects) }
    func numberEdited() {
        if number.isEmpty { number = suggestedNumber }
        numberIsAutomatic = number == suggestedNumber
        fieldChanged()
    }
    private func applySuggestedNumber() { if numberIsAutomatic || number.isEmpty { number = suggestedNumber; numberIsAutomatic = true } }

    // MARK: Persistence

    /// Applies a change at once and writes the library shortly after, off the main thread, so a click never waits for the disk.
    /// Changes made while a write is in flight are coalesced into the next write; a failed write stops further changes.
    func mutate(_ change: (inout Library) throws -> Void) throws {
        guard storeUsable else { throw AppFailure("Library is read-only after a load error.") }
        var next = library; try change(&next)
        try runtime.validate(next)
        library = next
        if numberIsAutomatic && created == nil { number = suggestedNumber }
        scheduleSave()
    }
    private var pendingSave: Library?
    private var saveTask: Task<Void, Never>?
    func saveTaskForWorkspace() async { await saveTask?.value }
    /// Transactional operations wait for older snapshots, then save before publishing or offering cleanup.
    func commitDurably(_ change: (inout Library) throws -> Void) async throws {
        await saveTask?.value
        guard storeUsable else { throw AppFailure("The library is unavailable. The existing records have been retained.") }
        var next = library
        try change(&next)
        do { try runtime.requireWritable(store.file) }
        catch { storeUsable = false; throw error }
        try runtime.validate(next)
        do {
            try runtime.requireWritable(store.file)
            try store.save(next)
        } catch {
            storeUsable = false
            throw error
        }
        library = next
        if numberIsAutomatic && created == nil { number = suggestedNumber }
    }
    private func scheduleSave() {
        pendingSave = library
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else { return }
            while let snapshot = self.pendingSave, self.storeUsable {
                self.pendingSave = nil
                let store = self.store
                let runtime = self.runtime
                do { try await Task.detached(priority: .userInitiated) { try runtime.requireWritable(store.file); try store.save(snapshot) }.value }
                catch { self.storeUsable = false; self.error = "The library could not be saved, so further changes are stopped. \(error.localizedDescription)" }
            }
            self.saveTask = nil
        }
    }
    func attempt(_ work: () throws -> Void) { do { try work() } catch { self.error = error.localizedDescription } }

    // MARK: Destinations and formats

    /// An Open panel saves its size and last folder in the standard defaults domain, which an isolated launch of the stable
    /// app shares with production. There is no way to point AppKit elsewhere, so such a launch does not open panels.
    func runPanel(_ panel: NSOpenPanel) -> NSApplication.ModalResponse {
        guard !runtime.sharesProductionPreferences(bundleIdentifier: Bundle.main.bundleIdentifier) else {
            error = "Open panels are off in a --data-directory run of CreatorOS, because they would write the everyday app's preferences. Use the alpha build to test them."
            return .cancel
        }
        return panel.runModal()
    }
    func folderPanel(title: String) -> URL? {
        let panel = NSOpenPanel(); panel.title = title; panel.canChooseFiles = false
        panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = runtime.root
        return runPanel(panel) == .OK ? panel.url : nil
    }
    func chooseDestination() {
        guard let url = folderPanel(title: "Choose where \(formatLabel) projects go") else { return }
        attempt { try setDestination(url, for: format) }
    }
    /// Saves where a format's projects go. The New Project form follows only when it is showing that format.
    func setDestination(_ url: URL, for target: String) throws {
        try runtime.requireWritable(url)
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        try mutate { lib in
            if let index = lib.presets.firstIndex(where: { $0.format == target }) {
                lib.presets[index].destination = url.path; lib.presets[index].destinationBookmark = bookmark
            }
        }
        if target == format { destination = url.path }
    }
    func updatePlainFolders() { plainFolders = ProjectLocation(path: destination).label == "LucidLink" }
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
        updatePlainFolders()
        // Each format starts with its own sequence; a manual override applies to that form only.
        numberIsAutomatic = true
        applySuggestedNumber()
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
        let workspaceRecord = startingFrom.flatMap { id in library.projects.first { $0.id == id && $0.ideaWorkspace != nil } }
        guard payload != nil || workspaceRecord != nil else {
            preview = nil; plan = nil
            switch variantState {
            case .missing(let setName): validation = "\(formatLabel) is not set up in \(setName) yet. Import template files or reuse another format's to see the preview."
            default: validation = library.templates.isEmpty ? "Import a template to see the preview." : "Choose a template to see the preview."
            }
            return
        }
        let sourceID = workspaceRecord?.id ?? payload!.id
        if workspaceRecord != nil, let cached = structureCache[sourceID] {
            render(cached.plan, renamingPaths: cached.renamingPaths); return
        }
        let root: URL
        do { root = try workspaceRecord.map { try IdeaWorkspaceEngine.resolve(for: $0) } ?? store.payload(payload!) ; try runtime.requireWritable(root) }
        catch { preview = nil; plan = nil; validation = error.localizedDescription; return }
        if let cached = structureCache[sourceID], cached.rootModified == rootModified(root) { render(cached.plan, renamingPaths: cached.renamingPaths); return }
        preview = nil; plan = nil; validation = "Reading template…"
        scanCancellation = Cancellation(); let token = scanCancellation; let id = sourceID
        refreshTask = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { () throws -> (structure: CopyPlan, renamingPaths: Set<String>?) in
                    if let workspaceRecord {
                        let scanned = try IdeaWorkspaceEngine.scan(for: workspaceRecord, cancellation: token)
                        return (scanned.structure, scanned.renamingPaths)
                    }
                    return (try TemplateReader.scan(root, cancellation: token), nil)
                }.value
                guard revision == version else { return }
                structureCache[id] = CachedStructure(plan: result.structure, rootModified: rootModified(root), renamingPaths: result.renamingPaths)
                render(result.structure, renamingPaths: result.renamingPaths)
            } catch is CancellationError {
            } catch { if revision == version { validation = error.localizedDescription } }
        }
    }
    private func render(_ structure: CopyPlan, renamingPaths: Set<String>? = nil) {
        let rendering = PreviewRenderer.render(structure: structure, fields: fields, renamingPaths: renamingPaths)
        preview = rendering; validation = ""
        guard rendering.isExecutable else { plan = nil; return }
        do { plan = try TemplateReader.plan(from: structure, fields: fields, renamingPaths: renamingPaths) }
        catch { plan = nil; validation = error.localizedDescription }
    }

    // MARK: Import

    func beginImport(assigning: PendingAssignment? = nil) {
        let panel = NSOpenPanel(); panel.title = "Choose a template folder or Post Haste package"
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        guard runPanel(panel) == .OK, let source = panel.url else { return }
        pendingAssignment = assigning
        importSource = source
        importName = source.pathExtension.lowercased() == "pht" ? source.deletingPathExtension().lastPathComponent : source.lastPathComponent
        importPresented = true; scanImport()
    }
    func scanImport() {
        guard let source = importSource, !busy else { return }
        importPlan = nil
        let mode = importMode
        scanTemplate(source, mode: mode) { if case .success(let result) = $0 { self.importPlan = result } }
    }
    /// Reads a template folder or .pht into a plan without copying it. The sheet and control share this.
    func scanTemplate(_ source: URL, mode: ImportMode, onFinish: @escaping (Result<CopyPlan, Error>) -> Void) {
        run("Inspecting template", cancelNote: "Nothing was imported.") { token, _ in
            try TemplateReader.scan(source, mode: mode, cancellation: token)
        } completion: { onFinish(.success($0)) } failure: { onFinish(.failure(AppFailure($0))) }
    }
    func commitImport() {
        guard let importPlan else { return }
        let pending = pendingAssignment
        registerImport(plan: importPlan, name: importName, mode: importMode, assigning: pending) { result in
            guard case .success(let record) = result else { return }
            self.importPresented = false; self.pendingAssignment = nil
            if let pending { self.selection = .set(pending.setID); self.format = pending.format; self.changeFormat() }
            else if self.selection == nil || self.selectedSet == nil { self.selection = .legacy(record.id); self.changeSelection() }
            if self.page == .templates { self.templatesSelection = pending.map { .set($0.setID) } ?? .legacy(record.id) }
        }
    }
    /// Copies the scanned template into the library and registers it, optionally assigning it to a format of a set.
    func registerImport(plan importPlan: CopyPlan, name: String, mode: ImportMode, assigning pending: PendingAssignment?,
                        onFinish: @escaping (Result<TemplateRecord, Error>) -> Void) {
        let store = store, runtime = runtime
        run("Importing independent template", cancelNote: "Nothing was registered.") { token, progress in
            try runtime.requireWritable(store.templates)
            return try store.importTemplate(plan: importPlan, name: name, mode: mode, cancellation: token, progress: progress)
        } completion: { record in
            do {
                try self.mutate { lib in
                    lib.templates.append(record)
                    if let pending { try lib.assign(format: pending.format, templateID: record.id, in: pending.setID) }
                }
                onFinish(.success(record))
            } catch {
                let failure = AppFailure("Template copied to \(store.payload(record).path), but registration failed. Original is untouched. \(error.localizedDescription)")
                self.error = failure.localizedDescription
                onFinish(.failure(failure))
            }
        } failure: { onFinish(.failure(AppFailure($0))) }
    }

    // MARK: Sets

    func promptNewSet(mapping templateID: UUID? = nil) {
        newSetPrompt = NewSetPrompt(mappingTemplateID: templateID, name: templateID.flatMap { library.template($0)?.name } ?? "")
    }
    func confirmNewSet() {
        guard let prompt = newSetPrompt else { return }
        attempt { _ = try createSet(named: prompt.name, mapping: prompt.mappingTemplateID); newSetPrompt = nil }
    }
    /// Creates a content template set and selects it the way the New Set sheet does.
    @discardableResult
    func createSet(named name: String, mapping templateID: UUID?) throws -> TemplateSet {
        var made: TemplateSet?
        try mutate { made = try $0.createSet(named: name, mappingAll: templateID) }
        guard let made else { throw AppFailure("The set could not be created.") }
        templatesSelection = .set(made.id)
        if selection == nil || selectedSet == nil || templateID != nil { selection = .set(made.id); changeSelection() }
        return made
    }
    func renameSet(_ id: UUID, to name: String) { attempt { try applySetName(id, to: name) } }
    func applySetName(_ id: UUID, to name: String) throws { try mutate { try $0.renameSet(id, to: name) } }
    func assign(format: String, templateID: UUID, in setID: UUID) { attempt { try assignTemplate(format: format, templateID: templateID, in: setID) } }
    func assignTemplate(format: String, templateID: UUID, in setID: UUID) throws {
        try mutate { try $0.assign(format: format, templateID: templateID, in: setID) }; refresh()
    }
    func unassign(format: String, in setID: UUID) { attempt { try unassignTemplate(format: format, in: setID) } }
    func unassignTemplate(format: String, in setID: UUID) throws { try mutate { $0.unassign(format: format, in: setID) }; refresh() }
    func removeSet(_ id: UUID) { attempt { try deleteSet(id) } }
    func deleteSet(_ id: UUID) throws {
        try mutate { $0.removeSet(id) }
        if templatesSelection == .set(id) { templatesSelection = nil }
        if selection == .set(id) { selection = defaultSelection; changeSelection() }
    }
    /// Moves the managed payload to the Trash and drops every assignment that used it.
    func removeTemplate(_ record: TemplateRecord) {
        Task { do { try await deleteTemplate(record) } catch { self.error = error.localizedDescription } }
    }
    /// The payload goes to the Bin first, then the library is saved before this returns. If the save fails the payload is
    /// put back, or the error names its exact place in the Bin, so the library never points at a payload that is gone.
    @discardableResult
    func deleteTemplate(_ record: TemplateRecord) async throws -> URL? {
        let payload = store.payload(record)
        try runtime.requireWritable(payload)
        var trashed: NSURL?
        if FileManager.default.fileExists(atPath: payload.path) { try FileManager.default.trashItem(at: payload, resultingItemURL: &trashed) }
        do {
            try await commitDurably { lib in
                lib.templates.removeAll { $0.id == record.id }
                lib.templateSets = lib.sets.map { set in var s = set; s.variants.removeAll { $0.templateID == record.id }; return s }
            }
        } catch {
            if let bin = trashed as URL? {
                do { try FileManager.default.moveItem(at: bin, to: payload) }
                catch { throw AppFailure("The library could not be saved and the template files could not be put back. They are in the Bin at \(bin.path). \(error.localizedDescription)") }
            }
            throw error
        }
        invalidateStructure(record.id)
        if templatesSelection == .legacy(record.id) { templatesSelection = nil }
        if !selectionIsValid { selection = defaultSelection }
        refresh()
        return trashed as URL?
    }
    func useForNewProject(_ choice: TemplateSelection) { selection = choice; changeSelection(); newProjectPresented = true }
    func browseTemplate(_ record: TemplateRecord) { templateToBrowse = record }
    func finishedBrowsingTemplate() {
        if let record = templateToBrowse { invalidateStructure(record.id) }
        templateToBrowse = nil; refresh()
    }

    // MARK: Creation

    func create(onFinish: ((Result<ProjectRecord, Error>) -> Void)? = nil) {
        guard canCreate, let plan, let preview else { onFinish?(.failure(AppFailure("Project cannot be created from the current form."))); return }
        let destination = URL(fileURLWithPath: destination); let name = preview.outerFolderName
        let icon = preset.icon; let format = format; let payloadID = payload?.id
        let campaignAtCreation = campaign
        let fromSheet = newProjectPresented
        let origin = startingFrom.flatMap { id in library.projects.first { $0.id == id } }
        let fields = fields; let runtime = runtime
        let plain = plainFolders
        created = nil
        run(plain ? "Creating project with plain folders" : "Creating project", cancelNote: "Nothing was created or registered.") { token, progress in
            try runtime.requireWritable(destination)
            if let origin, origin.ideaWorkspace != nil {
                try runtime.requireWritable(IdeaWorkspaceEngine.resolve(for: origin))
                return try IdeaWorkspaceEngine.promote(for: origin, fields: fields, destination: destination, expectedPlan: plan, icon: plain ? nil : icon,
                                                       finderMetadata: !plain, cancellation: token, progress: progress)
            }
            let fresh = try TemplateReader.scan(plan.root, fields: fields, cancellation: token)
            guard plan.sameInventory(as: fresh) else {
                throw AppFailure("The template changed since its preview. Review the refreshed preview before creating the project.")
            }
            return try CreationEngine.create(plan: plain ? plan.withoutIconFiles : plan, destination: destination, name: name, icon: plain ? nil : icon,
                                      finderMetadata: !plain, cancellation: token, progress: progress)
        } completion: { url in
            self.created = url
            self.busy = true
            Task {
            defer { self.busy = false }
            do {
                var savedID: UUID?
                try await self.commitDurably { lib in
                let currentOrigin = origin.flatMap { previous in lib.projects.first { $0.id == previous.id } }
                if origin != nil && currentOrigin == nil { throw AppFailure("The original idea is no longer in the library.") }
                var record = try currentOrigin?.promoted(to: url) ?? ProjectRecord(url: url, format: format)
                // A recording starts in its second stage because the first holds ideas; a live stream starts as Scheduled.
                let kind = PipelineKind.of(format: format)
                let stages = lib.stages(for: kind)
                let starting = kind == .live ? stages.first : (stages.count > 1 ? stages[1] : stages.first)
                if let currentOrigin { record.stage = currentOrigin.stage == stages.first && kind == .recordings ? (starting ?? currentOrigin.stage) : currentOrigin.stage }
                else { record.stage = starting }
                record.campaign = campaignAtCreation.isEmpty ? nil : campaignAtCreation
                    if let origin { lib.projects.removeAll { $0.id == origin.id } }
                    lib.projects.insert(record, at: 0)
                    savedID = record.id
                }
                guard let record = self.library.projects.first(where: { $0.id == savedID }) else { return }
                self.tagFolder(record)
                self.refreshMounts()
                // Keep an ordinary UI creation's completion visible. CLI creation clears its temporary form;
                // workspace promotion still closes the sheet before offering the old-workspace review.
                self.search = ""
                self.selectedProject = record.id; self.page = .projects; self.selectProject()
                // The idea is now this project, so a kept-open sheet must not still claim to start from it.
                if self.startingFrom == origin?.id { self.startingFrom = nil }
                if !fromSheet || !self.newProjectPresented || record.ideaWorkspace != nil {
                    self.newProjectPresented = false
                    self.nextProject()
                }
                if record.ideaWorkspace != nil { self.workspaceCleanup = record }
                onFinish?(.success(record))
            } catch { onFinish?(.failure(error)); self.error = "The project exists at \(url.path), but history could not be saved. Do not create it again. Resolve the storage issue, restart the app, then use Add Existing Project to recover. \(error.localizedDescription)" }
            }
        } failure: { message in
            onFinish?(.failure(ControlFailure(code: "create_failed", message: message)))
            if message.contains("changed") {
                if let origin, origin.ideaWorkspace != nil { self.invalidateStructure(origin.id) }
                else if let payloadID { self.invalidateStructure(payloadID) }
                self.refresh()
            }
        }
    }
    /// Clears the form for the next project, moving the number on.
    func nextProject() {
        created = nil; title = ""; campaign = ""; extraValues = [:]; startingFrom = nil
        numberIsAutomatic = true; number = suggestedNumber
        refresh()
    }
    /// Runs one long operation with visible progress. `failure` always hears about a refusal or a stop, so callers outside the
    /// GUI never wait for ever; `cancelNote` says what a stop leaves behind.
    func run<T: Sendable>(_ label: String, cancelNote: String = "Work that finished before the stop is still in place.",
                          operation: @escaping @Sendable (Cancellation, @escaping CreationEngine.Progress) async throws -> T,
                          completion: @escaping (T) -> Void, failure: @escaping (String) -> Void = { _ in }) {
        guard !busy, storeUsable else { failure(storeUsable ? "Another operation is running. Wait for it to finish." : "The library is unavailable."); return }
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
            } catch is CancellationError { busy = false; status = "\(label) cancelled. \(cancelNote)"; failure(status) }
            catch { busy = false; status = "Stopped"; self.error = error.localizedDescription; failure(error.localizedDescription) }
        }
    }

    // MARK: Icons

    func chooseIcon(fromFolder: Bool) {
        let panel = NSOpenPanel(); panel.title = fromFolder ? "Choose a folder whose icon you want" : "Choose an icon image"
        panel.canChooseDirectories = fromFolder; panel.canChooseFiles = !fromFolder
        guard runPanel(panel) == .OK, let url = panel.url else { return }
        attempt { try setFormatIcon(from: url, fromFolder: fromFolder, for: format) }
    }
    /// Saves an image, or another folder's icon, as a format's icon for new projects.
    func setFormatIcon(from url: URL, fromFolder: Bool, for target: String) throws {
        let image = fromFolder ? NSWorkspace.shared.icon(forFile: url.path) : NSImage(contentsOf: url)
        guard let data = image?.tiffRepresentation else { throw AppFailure("That file could not be read as an image.") }
        try mutate { lib in if let i = lib.presets.firstIndex(where: { $0.format == target }) {
            lib.presets[i].icon = data; lib.presets[i].iconSource = url.path; lib.presets[i].iconLocked = true
        } }
        editingIcon = false
    }

    // MARK: Locations

    var distinctLocations: [ProjectLocation] {
        var seen = Set<String>(); var result: [ProjectLocation] = []
        for record in library.projects where !record.isPlanned {
            let location = record.location
            if seen.insert(location.key).inserted { result.append(location) }
        }
        return result.sorted { a, b in
            if a.kind != b.kind { return a.kind == .local }
            return a.label.localizedStandardCompare(b.label) == .orderedAscending
        }
    }
    /// One stat per distinct location, never per project, so it is safe to call on every appearance.
    func refreshMounts() {
        guard storeUsable, !checkingMounts else { return }
        checkingMounts = true
        let locations = distinctLocations.filter { !hiddenLocations.contains($0.key) }
        Task.detached(priority: .utility) {
            let mounted = Set(locations.filter(\.isMounted).map(\.key))
            await MainActor.run {
                self.checkingMounts = false
                let changed = self.mountedLocations != mounted
                if changed { self.attemptedDates.removeAll() }
                self.mountedLocations = mounted
                if changed, let selected = self.selectedRecord { self.inspectProject(selected, findMoved: true) }
                self.backfillFolderDates()
            }
        }
    }
    private var backfilling = false
    /// Records registered before folder dates were kept get their creation date read once from disk, when the drive is there.
    func backfillFolderDates() {
        guard !backfilling, storeUsable else { return }
        let pending = library.projects.filter { !$0.isPlanned && $0.folderCreated == nil && !attemptedDates.contains($0.id) && mountedLocations.contains($0.location.key) && $0.location.kind != .cloud }
        guard !pending.isEmpty else { return }
        backfilling = true
        attemptedDates.formUnion(pending.map(\.id))
        Task.detached(priority: .utility) {
            var dates: [UUID: Date] = [:]
            for record in pending {
                if let date = try? URL(fileURLWithPath: record.path).resourceValues(forKeys: [.creationDateKey]).creationDate { dates[record.id] = date }
            }
            let found = dates
            await MainActor.run {
                self.backfilling = false
                guard !found.isEmpty else { return }
                self.attempt { try self.mutate { lib in for i in lib.projects.indices { if let date = found[lib.projects[i].id] { lib.projects[i].folderCreated = date } } } }
            }
        }
    }
    func setHidden(_ hidden: Bool, for location: ProjectLocation) {
        if hidden { hiddenLocations.insert(location.key) } else { hiddenLocations.remove(location.key) }
        refreshMounts()
        scheduleDeepSearch()
    }
    func setExcluded(_ excluded: Bool, stage: String) {
        if excluded { excludedStages.insert(stage) } else { excludedStages.remove(stage) }
    }

    // MARK: Deep search

    private var deepSearchTask: Task<Void, Never>?
    /// Looks inside the documents of visible, connected projects for the search text, a moment after typing stops.
    /// Hidden drives are never read. Results only add to the name matches, never remove them.
    func scheduleDeepSearch() {
        deepSearchTask?.cancel()
        let query = search.trimmingCharacters(in: .whitespaces)
        guard query.count >= 3 else { deepMatches = []; return }
        let candidates = library.projects.filter { !$0.isPlanned && !hiddenLocations.contains($0.location.key) && mountedLocations.contains($0.location.key) }
            .map { DeepSearch.Candidate(id: $0.id, path: $0.path) }
        deepSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            let found = await DeepSearch.shared.matches(for: query, in: candidates)
            guard !Task.isCancelled, let self, self.search.trimmingCharacters(in: .whitespaces) == query else { return }
            self.deepMatches = found
        }
    }
    func badgeColour(_ location: ProjectLocation) -> BadgeColour {
        BadgeColour(rawValue: locationColours[location.key] ?? defaults.string(forKey: "locationColour." + location.key) ?? location.defaultColour) ?? .gray
    }
    func setBadgeColour(_ colour: BadgeColour, for location: ProjectLocation) {
        locationColours[location.key] = colour.rawValue
        defaults.set(colour.rawValue, forKey: "locationColour." + location.key)
    }

    // MARK: Pinning, dates and relinking

    func togglePin(_ id: UUID) { if let record = library.projects.first(where: { $0.id == id }) { attempt { try setPinned(!record.isPinned, for: id) } } }
    func setPinned(_ pinned: Bool, for id: UUID) throws { try modifyProject(id) { $0.pinned = pinned ? true : nil } }
    /// Section title for a date: Today, Yesterday, Last 7 days, This month, then month and year.
    func dateGroup(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let week = calendar.date(byAdding: .day, value: -7, to: Date()), date > week { return "Last 7 days" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .month) { return "This month" }
        return date.formatted(.dateTime.month(.wide).year())
    }
    var groupedProjects: [(title: String, records: [ProjectRecord])] {
        let unpinned = filteredProjects.filter { !$0.isPinned }
        guard groupByDate else { return [("All projects", unpinned)] }
        let sorted = unpinned.sorted { $0.effectiveDate > $1.effectiveDate }
        var groups: [(String, [ProjectRecord])] = []
        for record in sorted {
            let title = dateGroup(record.effectiveDate)
            if let last = groups.indices.last, groups[last].0 == title { groups[last].1.append(record) } else { groups.append((title, [record])) }
        }
        return groups.map { (title: $0.0, records: $0.1) }
    }
    var pinnedProjects: [ProjectRecord] { filteredProjects.filter(\.isPinned) }
    /// Roots worth searching when a folder has moved: every saved location (by bookmark, or by path when the bookmark
    /// cannot be resolved, as happens on a network filespace), each format's destination, and every folder that already
    /// holds a registered project or once did. Those are the places Junior keeps things; unticked drives are left out.
    func relinkRoots(locationKey: String? = nil) -> [URL] {
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
    }
    /// Registered projects that share a name, usually a copy made for an editor or a move that was really a copy.
    /// The likely live one sits under a configured destination; failing that, the newest folder.
    var duplicateGroups: [[ProjectRecord]] {
        var groups: [String: [ProjectRecord]] = [:]
        for record in library.projects where !record.isPlanned && !hiddenLocations.contains(record.location.key) {
            groups[record.name.trimmingCharacters(in: .whitespaces).lowercased(), default: []].append(record)
        }
        return groups.values.filter { $0.count > 1 }.map { $0.sorted { $0.effectiveDate > $1.effectiveDate } }
            .sorted { $0[0].name.localizedStandardCompare($1[0].name) == .orderedAscending }
    }
    func likelyLive(_ record: ProjectRecord, among group: [ProjectRecord]) -> Bool {
        let destinations = library.presets.map(\.destination).filter { !$0.isEmpty }
        let onDestination = group.filter { candidate in destinations.contains { candidate.path.hasPrefix($0 + "/") } }
        if !onDestination.isEmpty { return onDestination.contains { $0.id == record.id } }
        return group.first?.id == record.id
    }
    /// The refresh button: drives, the selected project, and the search, all checked again.
    func refreshEverything() {
        refreshMounts(); refreshProject()
    }
    /// Command-R: reads the selected project's folder again so files added since it was last shown appear, checks the
    /// folder is still there, and reruns the search. On purpose not automatic: the folders live on drives that should
    /// not be woken for every glance.
    func refreshProject() {
        browserRefresh += 1
        if let record = selectedRecord { inspectProject(record, findMoved: true) }
        if let record = library.projects.first(where: { $0.id == pipelineSelection }) { inspectProject(record) }
        scheduleDeepSearch()
        // Junior's request (23 Sep): one press also finds moved folders. The report only appears when something is missing.
        relinkAll(reportWhenNothingMissing: false)
    }
    /// Command-F: puts the cursor in the search field of the front window, the way every Mac app does.
    static func focusSearchField() {
        guard let window = NSApp.keyWindow else { return }
        func find(in view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            for child in view.subviews { if let field = find(in: child) { return field } }
            return nil
        }
        var field = window.contentView.flatMap(find(in:))
        if field == nil { for item in window.toolbar?.items ?? [] { if let view = item.view, let found = find(in: view) { field = found; break } } }
        if let field { window.makeFirstResponder(field) }
    }
    /// Offline originals may be copies, so offer candidates instead of silently redirecting them.
    func relink(_ record: ProjectRecord, quietly: Bool = false) {
        Task { await searchForMoved(record, quietly: quietly) }
    }
    /// One project's result from a relink pass. With `apply` false nothing is changed, in the library or in the GUI: a result
    /// of `.relinked` then means "this is the one folder it would be linked to". `alert` false keeps the "not found" dialog quiet.
    @discardableResult
    func searchForMoved(_ record: ProjectRecord, quietly: Bool = false, searchAllLocations: Bool = false, apply: Bool = true, alert: Bool = true) async -> RelinkOutcome.Kind {
        guard !relinking.contains(record.id), !record.isPlanned, !hiddenLocations.contains(record.location.key) else { return .stillThere }
        relinking.insert(record.id)
        defer { relinking.remove(record.id) }
        // A quiet search, the one that runs when a project is merely selected, stays on the project's own drive.
        // Searching every root would wake the archive drive on each click.
        let roots = relinkRoots(locationKey: quietly && !searchAllLocations ? record.location.key : nil)
        let candidates = await Task.detached(priority: .userInitiated) { Relinker.candidates(for: record, roots: roots) }.value
        guard let current = library.projects.first(where: { $0.id == record.id }), current.path == record.path,
              !hiddenLocations.contains(current.location.key) else { return .stillThere }
        let found = candidates.filter { !hiddenLocations.contains(ProjectLocation(path: $0.path).key) }
        // A proposed automatic relink needs a fresh mount-only stat: the polling cache may predate a disconnect.
        let originalMounted = found.count == 1 ? current.location.isMounted : mountedLocations.contains(current.location.key)
        let originalMissing = !originalMounted || !FileManager.default.fileExists(atPath: current.path)
        let candidateAlreadyRegistered = found.first.map { candidate in library.projects.contains { $0.id != current.id && $0.name == current.name && !hiddenLocations.contains($0.location.key) && URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == candidate.resolvingSymlinksInPath() } } ?? false
        if Relinker.canAutomaticallyRelink(candidateCount: found.count, originalMounted: originalMounted, originalMissing: originalMissing, candidateAlreadyRegistered: candidateAlreadyRegistered) {
            if !apply { return .relinked(found[0]) }
            var relinked: URL?
            attempt {
                if try relocate(current, to: found[0]) != nil { relinked = found[0] }
            }
            if let relinked { return .relinked(relinked) }
        }
        if apply { relinkCandidates[record.id] = found }
        if apply && alert && found.isEmpty && !quietly { error = "No folder called ‘\(record.name)’ was found on the ticked drives. Use Locate Folder when you know where it went." }
        if !originalMissing { return .stillThere }
        return found.isEmpty ? .notFound : .candidates(found)
    }
    func relink(_ record: ProjectRecord, to url: URL) { attempt { _ = try relocate(record, to: url) } }
    /// Points a record at a folder, keeping the old path in its history. Locate Folder, a chosen candidate and control share it.
    @discardableResult
    func relocate(_ record: ProjectRecord, to url: URL) throws -> ProjectRecord? {
        guard var updated = library.projects.first(where: { $0.id == record.id }) else { return nil }
        try updated.relocate(to: url)
        let final = updated
        try mutate { lib in if let i = lib.projects.firstIndex(where: { $0.id == record.id }) { lib.projects[i] = final } }
        relinkCandidates[record.id] = nil
        if selectedProject == record.id { inspectProject(final) }
        relinkReport?.markLinked(record.id, at: url)
        return final
    }
    /// Checks every project on the ticked drives whose folder is missing, relinks the certain ones, and reports the rest,
    /// the way an editor reports offline media. Roots from unticked drives are never searched. With `apply` false it only reports.
    func relinkAll(reportWhenNothingMissing: Bool = true, apply: Bool = true, onFinish: ((Result<(checked: Int, outcomes: [RelinkOutcome]), Error>) -> Void)? = nil) {
        guard !relinkBatchRunning else { onFinish?(.failure(AppFailure("Find Missing Projects is already running."))); return }
        relinkBatchRunning = true
        let records = library.projects.filter { !$0.isPlanned && !hiddenLocations.contains($0.location.key) }
        Task {
            defer { relinkBatchRunning = false }
            let missing = await Task.detached { records.filter { !FileManager.default.fileExists(atPath: $0.path) } }.value
            var outcomes: [RelinkOutcome] = []
            for (index, record) in missing.enumerated() {
                if apply { status = "Looking for moved folders \(index + 1) of \(missing.count)…" }
                let kind = await searchForMoved(record, quietly: true, searchAllLocations: true, apply: apply)
                outcomes.append(RelinkOutcome(id: record.id, name: record.name, previousPath: record.path, kind: kind))
            }
            if apply {
                status = ""
                if reportWhenNothingMissing || !outcomes.isEmpty { relinkReport = RelinkReport(checked: records.count, outcomes: outcomes) }
            }
            onFinish?(.success((records.count, outcomes)))
        }
    }

    // MARK: Pipeline

    func updateProject(_ id: UUID, _ change: (inout ProjectRecord) -> Void) { attempt { try modifyProject(id, change) } }
    func modifyProject(_ id: UUID, _ change: (inout ProjectRecord) -> Void) throws {
        try mutate { lib in if let i = lib.projects.firstIndex(where: { $0.id == id }) { change(&lib.projects[i]) } }
    }
    /// Saves pipeline details. nil leaves a field alone, an empty value clears it, and text is trimmed.
    func saveDetails(_ id: UUID, campaign: String? = nil, editor: String? = nil, notes: String? = nil, series: [String]? = nil) throws {
        func text(_ value: String) -> String? { let t = value.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
        try modifyProject(id) { r in
            if let campaign { r.campaign = text(campaign) }
            if let editor { r.editor = text(editor) }
            if let notes { r.notes = text(notes) }
            if let series { let list = series.compactMap(text); r.series = list.isEmpty ? nil : list }
        }
    }
    static func splitSeries(_ text: String) -> [String] { text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    func setStage(_ stage: String, for id: UUID) { attempt { _ = try moveToStage(stage, for: id) } }
    /// Moves one record to a stage on its own board and starts its Finder tag write. Unknown records and stages from the other
    /// board are refused here, so a stray drop or a control call can never put a stream on the recordings board.
    @discardableResult
    func moveToStage(_ stage: String, for id: UUID) throws -> Task<TagOutcome, Never> {
        guard let record = library.projects.first(where: { $0.id == id }) else { throw AppFailure("That project is no longer in the library.") }
        guard moveTargets(for: record).contains(stage) else {
            throw AppFailure("‘\(stage)’ is not a stage on the \(PipelineKind.of(format: record.format).title) board. Use one of: \(moveTargets(for: record).joined(separator: ", ")).")
        }
        try modifyProject(id) { $0.stage = stage }
        return tagFolder(library.projects.first { $0.id == id } ?? record)
    }
    /// Moves every card in one column at once; a deliberate action from the column's own menu.
    func moveAll(from stage: String, to target: String) {
        let ids = projects(in: stage).map(\.id)
        guard !ids.isEmpty else { return }
        attempt { _ = try moveAll(ids: ids, to: target) }
    }
    /// Moves exactly these records. Every one must be able to take the stage on its own board.
    @discardableResult
    func moveAll(ids: [UUID], to target: String) throws -> [Task<TagOutcome, Never>] {
        let wanted = Set(ids)
        guard library.projects.filter({ wanted.contains($0.id) }).allSatisfy({ moveTargets(for: $0).contains(target) }) else {
            throw AppFailure("‘\(target)’ is not a stage on the board these records are on.")
        }
        try mutate { lib in for i in lib.projects.indices where wanted.contains(lib.projects[i].id) { lib.projects[i].stage = target } }
        return library.projects.filter { wanted.contains($0.id) }.map(tagFolder)
    }
    func addIdea(title: String, format: String, campaign: String, notes: String) {
        do { pipelineSelection = try addIdeaRecord(title: title, format: format, campaign: campaign, notes: notes).id }
        catch { self.error = error.localizedDescription }
    }
    @discardableResult
    func addIdeaRecord(title: String, format: String, campaign: String, notes: String) throws -> ProjectRecord {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw AppFailure("Give the idea a title.") }
        guard Library.formats.contains(format) else { throw AppFailure("Use Long, Short, Podcast or Livestream.") }
        guard PipelineKind.of(format: format) == .recordings else { throw AppFailure("Live streams are scheduled, not collected as ideas. Create the stream from New Project.") }
        var record = ProjectRecord(planned: clean, format: format, stage: library.stageList.first ?? "Idea", campaign: campaign.isEmpty ? nil : campaign)
        record.notes = notes.isEmpty ? nil : notes
        let added = record
        try mutate { $0.projects.insert(added, at: 0) }
        return added
    }
    func removeProject(_ id: UUID) {
        if let record = library.projects.first(where: { $0.id == id }), record.ideaWorkspace != nil {
            if record.isPlanned { requestBinIdea(record) }
            else { error = "Review the old idea workspace before removing this project from the list. Its recovery reference is still retained." }
            return
        }
        attempt { try removeRecord(id) }
    }
    /// Forgets a record. Its folder is never touched.
    func removeRecord(_ id: UUID) throws {
        try mutate { $0.projects.removeAll { $0.id == id } }
        if selectedProject == id { selectedProject = nil }
        if pipelineSelection == id { pipelineSelection = nil }
    }
    /// Prefills New Project from a planned idea. The idea is replaced by the real record on creation.
    func startPlanned(_ record: ProjectRecord) {
        invalidateStructure(record.id)
        format = record.format
        title = record.isPlanned ? record.name : record.title
        campaign = record.campaign ?? ""
        startingFrom = record.id
        created = nil
        newProjectPresented = true
        changeFormat()
    }
    func forgetStartingIdea() {
        if let id = startingFrom { invalidateStructure(id) }
        startingFrom = nil
        preview = nil; plan = nil
        refresh()
    }
    func setStages(_ stages: [String], for kind: PipelineKind = .recordings) { attempt { try applyStages(stages, for: kind) } }
    func applyStages(_ stages: [String], for kind: PipelineKind = .recordings) throws {
        let checked = try Configuration.stages(stages)
        try mutate { if kind == .live { $0.liveStages = checked } else { $0.stages = checked } }
    }
    func setStageColour(_ colour: StageColour, for stage: String) { attempt { _ = try applyStageColour(colour, for: stage) } }
    @discardableResult
    func applyStageColour(_ colour: StageColour, for stage: String) throws -> [Task<TagOutcome, Never>] {
        try mutate { lib in var colours = lib.stageColours ?? [:]; colours[stage] = colour.rawValue; lib.stageColours = colours }
        return library.projects.filter { $0.stage == stage }.map(tagFolder)
    }
    func setFinderTags(_ enabled: Bool) { attempt { try applyFinderTags(enabled) } }
    func applyFinderTags(_ enabled: Bool) throws { try mutate { $0.finderTags = enabled } }
    func stageColour(_ stage: String) -> Color {
        BadgeColour(rawValue: library.colour(of: stage).rawValue)?.colour ?? .secondary
    }

    // MARK: Icons

    /// Removes a project's folder icons so it can be copied to LucidLink. The template keeps them; Restore puts them back.
    func removeFolderIcons(_ record: ProjectRecord) { stripFolderIcons(record) }
    /// The same action with a result for callers outside the GUI. Progress, status and alerts stay visible in the app.
    func stripFolderIcons(_ record: ProjectRecord, onFinish: ((Result<IconStripReport, Error>) -> Void)? = nil) {
        guard !record.isPlanned else { onFinish?(.failure(AppFailure("An idea has no folder yet."))); return }
        let runtime = runtime
        run("Removing folder icons from \(record.name)", cancelNote: "Icons already removed stay removed; Restore Folder Icons puts them back.") { token, _ in
            let project = try record.resolve(); try runtime.requireWritable(project)
            return try IconService.strip(project: project, cancellation: token)
        } completion: { report in
            self.status = report.summary
            if !report.failed.isEmpty { self.error = "Some icons could not be removed. " + report.failed.prefix(3).joined(separator: " ") }
            if self.selectedProject == record.id { self.inspectProject(record) }
            onFinish?(.success(report))
        } failure: { onFinish?(.failure(AppFailure($0))) }
    }
    /// Opens a one-operation set and format chooser without changing New Project preferences.
    func restoreIcons(_ record: ProjectRecord) {
        guard !record.isPlanned else { return }
        restoreIconsPrompt = record
    }
    func iconRestoreCandidates(for record: ProjectRecord, format: String) -> [IconRestoreCandidate] {
        guard Library.formats.contains(format) else { return [] }
        do {
            let project = try record.resolve()
            try runtime.requireWritable(project)
            let fields = iconRestoreFields(record, format: format)
            return library.sets.compactMap { set in
                guard let payload = library.resolve(setID: set.id, format: format) else { return nil }
                do {
                    let root = store.payload(payload)
                    try runtime.requireWritable(root)
                    try IconService.preflight(template: root, fields: fields, onto: project)
                    return IconRestoreCandidate(id: set.id, name: set.name, available: true, reason: nil)
                } catch {
                    return IconRestoreCandidate(id: set.id, name: set.name, available: false, reason: error.localizedDescription)
                }
            }
        } catch {
            return [IconRestoreCandidate(id: UUID(), name: "Unable to check sets", available: false, reason: error.localizedDescription)]
        }
    }
    func restoreIcons(_ record: ProjectRecord, format: String, setID: UUID, onFinish: ((Result<IconRestoreReport, Error>) -> Void)? = nil) {
        guard !record.isPlanned, Library.formats.contains(format),
              let set = library.set(setID), let payload = library.resolve(setID: setID, format: format) else {
            onFinish?(.failure(AppFailure("Choose a template set that has files for this format."))); return
        }
        let fields = iconRestoreFields(record, format: format)
        let root = store.payload(payload), icon = library.presets.first { $0.format == format }?.icon
        let runtime = runtime
        run("Restoring folder icons from \(set.name)", cancelNote: "Icons already restored stay in place; run Restore again to finish.") { token, _ in
            let project = try record.resolve()
            try runtime.requireWritable(project); try runtime.requireWritable(root)
            return try IconService.restore(template: root, fields: fields, onto: project, presetIcon: icon, cancellation: token)
        } completion: { report in
            self.status = report.summary
            if !report.failed.isEmpty { self.error = "Some icons could not be written. " + report.failed.prefix(3).joined(separator: " ") + (report.failed.count > 3 ? " …" : "") + " A drive such as LucidLink cannot hold folder icons; move the project to a Mac drive first." }
            if self.selectedProject == record.id { self.inspectProject(record) }
            onFinish?(.success(report))
        } failure: { onFinish?(.failure(AppFailure($0))) }
    }
    func iconRestoreFields(_ record: ProjectRecord, format: String) -> ProjectFields {
        let parts = record.name.components(separatedBy: " — ")
        return ProjectFields(number: record.number ?? "", format: format, campaign: parts.count >= 4 ? parts[2] : "",
                             title: parts.count >= 4 ? parts.dropFirst(3).joined(separator: " — ") : record.title)
    }

    // MARK: Finder tags

    /// Writes the record's stage onto its folder as a Finder tag, so Finder shows the same colour. One-way, app to Finder,
    /// and only when the drive is connected and ticked; nothing is hydrated or searched. Writes for one folder run one after
    /// another and a newer stage change replaces an older one still waiting, so rapid changes cannot finish out of order.
    /// Failures are silent in the GUI because the record is already saved; control callers read the outcome.
    @discardableResult
    func tagFolder(_ record: ProjectRecord) -> Task<TagOutcome, Never> {
        guard library.finderTagsEnabled, !record.isPlanned, let stage = record.stage, library.allStages.contains(stage),
              !hiddenLocations.contains(record.location.key), record.location.isMounted else { return Task { .skipped } }
        guard (try? runtime.requireWritable(URL(fileURLWithPath: record.path))) != nil else { return Task { .failed } }
        let colour = library.colour(of: stage), known = library.allStages, url = URL(fileURLWithPath: record.path), id = record.id
        let generation = (tagGeneration[id] ?? 0) + 1
        tagGeneration[id] = generation
        let previous = tagTasks[id]
        let task = Task { @MainActor () -> TagOutcome in
            _ = await previous?.value
            guard self.tagGeneration[id] == generation else { return .skipped }
            return await Task.detached(priority: .utility) {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return TagOutcome.skipped }
                do { _ = try FinderTags.apply(stage: stage, colour: colour, knownStages: known, to: url); return .applied } catch { return .failed }
            }.value
        }
        tagTasks[id] = task
        return task
    }
    struct TagReport { var candidates = 0, tagged = 0, missing = 0, failed = 0, offline = 0, hidden = 0 }
    /// Tags every staged folder on a connected, ticked drive, one after another, and reports the count. Unstaged folders are
    /// left alone, and a folder whose drive was unticked or whose stage changed since the pass began is checked again first.
    func tagAllFolders(dryRun: Bool = false, onFinish: ((Result<TagReport, Error>) -> Void)? = nil) {
        guard !tagging else { onFinish?(.failure(AppFailure("Tagging is already running."))); return }
        let known = library.allStages
        let staged = library.projects.filter { !$0.isPlanned && $0.stage != nil && known.contains($0.stage!) }
        let visible = staged.filter { !hiddenLocations.contains($0.location.key) }
        let records = visible.filter { mountedLocations.contains($0.location.key) }
        var report = TagReport(candidates: records.count, offline: visible.count - records.count, hidden: staged.count - visible.count)
        guard !records.isEmpty, !dryRun else {
            if records.isEmpty && !dryRun { status = "No staged folders are on a connected drive." }
            onFinish?(.success(report)); return
        }
        tagging = true
        Task {
            defer { tagging = false }
            for (index, original) in records.enumerated() {
                status = "Tagging folder \(index + 1) of \(records.count)…"
                guard let record = library.projects.first(where: { $0.id == original.id }), !hiddenLocations.contains(record.location.key) else { report.hidden += 1; continue }
                switch await tagFolder(record).value { case .applied: report.tagged += 1; case .skipped: report.missing += 1; case .failed: report.failed += 1 }
            }
            var parts = ["Tagged \(report.tagged) folders in Finder."]
            if report.missing > 0 { parts.append("\(report.missing) folders were not found.") }
            if report.failed > 0 { parts.append("\(report.failed) could not be written.") }
            if report.offline > 0 { parts.append("\(report.offline) are on drives that are not connected.") }
            status = parts.joined(separator: " ")
            onFinish?(.success(report))
        }
    }
    func addCustomField(_ name: String) { attempt { _ = try addField(name) } }
    @discardableResult
    func addField(_ name: String, includeInName: Bool = true) throws -> CustomField {
        let field = CustomField(name: try Configuration.fieldName(name, others: library.fieldList.map(\.name)), includeInName: includeInName)
        try mutate { $0.customFields = $0.fieldList + [field] }; refresh()
        return field
    }
    func updateCustomField(_ field: CustomField) { attempt { try replaceField(field) } }
    func replaceField(_ field: CustomField) throws {
        var checked = field
        checked.name = try Configuration.fieldName(field.name, others: library.fieldList.filter { $0.id != field.id }.map(\.name))
        try mutate { lib in lib.customFields = lib.fieldList.map { $0.id == checked.id ? checked : $0 } }; refresh()
    }
    func removeCustomField(_ id: UUID) { attempt { try deleteField(id) } }
    func deleteField(_ id: UUID) throws {
        try mutate { lib in lib.customFields = lib.fieldList.filter { $0.id != id } }; extraValues[id] = nil; refresh()
    }

    // MARK: Zoom

    var uiScale: CGFloat { 1 + CGFloat(min(max(zoomLevel, -2), 5)) * 0.1 }
    func zoom(_ delta: Int) { zoomLevel = min(max(zoomLevel + delta, -2), 5) }

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
