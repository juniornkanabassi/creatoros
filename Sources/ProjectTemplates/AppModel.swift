import SwiftUI
import AppKit
import TemplateCore

enum Page: String, CaseIterable, Identifiable {
    case newProject = "New Project", pipeline = "Pipeline", projects = "Projects", templates = "Templates"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .newProject: "folder.badge.plus"
        case .pipeline: "rectangle.3.group"
        case .projects: "externaldrive"
        case .templates: "square.stack.3d.up"
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

struct PendingAssignment: Equatable { let setID: UUID; let format: String }
struct NewSetPrompt: Identifiable { let id = UUID(); let mappingTemplateID: UUID?; var name: String }
struct CachedStructure { let plan: CopyPlan; let rootModified: Date? }

enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development" }
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
    @Published var destination = ""
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
    @Published var search = ""
    @Published var storeUsable = true
    @Published var selectedProject: UUID?
    @Published var inspections: [UUID: ProjectInspection] = [:]
    @Published var discovery: DiscoveryResult?
    @Published var discoveryPresented = false
    @Published var discoverySelection = Set<UUID>()
    @Published var formatFilter = "All formats"
    @Published var locationFilter: String? { didSet { defaults.set(locationFilter, forKey: "locationFilter") } }
    @Published var stageFilter: String?
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
    @Published var newIdeaPresented = false
    @Published var groupByDate: Bool { didSet { defaults.set(groupByDate, forKey: "groupByDate") } }
    @Published var relinkCandidates: [UUID: [URL]] = [:]
    @Published var relinking: Set<UUID> = []
    @Published var relinkBatchRunning = false
    var mountTimer: Timer?
    private var checkingMounts = false
    private var attemptedDates = Set<UUID>()
    let store: LibraryStore
    let defaults: UserDefaults
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
            defaults = UserDefaults(suiteName: "local.projecttemplates.test." + Data(arguments[i + 1].utf8).base64EncodedString())!
        } else { store = LibraryStore(); defaults = .standard }
        page = Page(rawValue: defaults.string(forKey: "page") ?? "") ?? .newProject
        format = defaults.string(forKey: "format") ?? "Short"
        selection = defaults.string(forKey: "selection").flatMap(TemplateSelection.init(stored:))
        locationFilter = defaults.string(forKey: "locationFilter")
        zoomLevel = defaults.object(forKey: "zoomLevel") as? Int ?? 0
        groupByDate = defaults.object(forKey: "groupByDate") as? Bool ?? true
        for surface in BrowserSurface.allCases {
            viewModes[surface] = BrowserViewMode(rawValue: defaults.string(forKey: "viewMode." + surface.rawValue) ?? "") ?? .list
        }
        do { library = try store.load() }
        catch { storeUsable = false; self.error = "Library could not be read. It has not been changed. \(error.localizedDescription)" }
        if !Library.formats.contains(format) { format = "Short" }
        if !selectionIsValid { selection = defaultSelection }
        destination = preset.destination
        number = suggestedNumber
        refreshMounts()
        mountTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshMounts() } }
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

    func save() throws { guard storeUsable else { throw AppFailure("Library is read-only after a load error.") }; try store.save(library) }
    func mutate(_ change: (inout Library) throws -> Void) throws {
        guard storeUsable else { throw AppFailure("Library is read-only after a load error.") }
        var next = library; try change(&next)
        try store.save(next); library = next
        if numberIsAutomatic && created == nil { number = suggestedNumber }
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
        let campaignAtCreation = campaign
        let origin = startingFrom.flatMap { id in library.projects.first { $0.id == id } }
        created = nil
        run("Creating project") { token, progress in
            try CreationEngine.create(plan: plan, destination: destination, name: name, icon: icon, cancellation: token, progress: progress)
        } completion: { url in
            self.created = url
            do {
                var record = try ProjectRecord(url: url, format: format)
                let stages = self.library.stageList
                if let origin {
                    record.stage = origin.stage == stages.first ? (stages.dropFirst().first ?? origin.stage) : origin.stage
                    record.campaign = origin.campaign; record.series = origin.series; record.editor = origin.editor
                    record.notes = origin.notes; record.notionURL = origin.notionURL
                } else {
                    record.stage = stages.count > 1 ? stages[1] : stages.first
                    if !campaignAtCreation.isEmpty { record.campaign = campaignAtCreation }
                }
                try self.mutate { lib in
                    if let origin { lib.projects.removeAll { $0.id == origin.id } }
                    lib.projects.insert(record, at: 0)
                }
                self.startingFrom = nil
                self.numberIsAutomatic = true
                self.refreshMounts()
            } catch { self.error = "The project exists at \(url.path), but history could not be saved. Do not create it again. Use Add Existing Project to recover. \(error.localizedDescription)" }
        } failure: { message in
            if message.contains("changed"), let payloadID { self.invalidateStructure(payloadID); self.refresh() }
        }
    }
    /// Clears the form for the next project, moving the number on.
    func nextProject() {
        created = nil; title = ""; campaign = ""; extraValues = [:]; startingFrom = nil
        numberIsAutomatic = true; number = suggestedNumber
        refresh()
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
        guard !checkingMounts else { return }
        checkingMounts = true
        let locations = distinctLocations
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
    func badgeColour(_ location: ProjectLocation) -> BadgeColour {
        BadgeColour(rawValue: locationColours[location.key] ?? defaults.string(forKey: "locationColour." + location.key) ?? location.defaultColour) ?? .gray
    }
    func setBadgeColour(_ colour: BadgeColour, for location: ProjectLocation) {
        locationColours[location.key] = colour.rawValue
        defaults.set(colour.rawValue, forKey: "locationColour." + location.key)
    }

    // MARK: Pinning, dates and relinking

    func togglePin(_ id: UUID) { updateProject(id) { $0.pinned = $0.isPinned ? nil : true } }
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
    var unavailableProjects: [ProjectRecord] {
        library.projects.filter { !$0.isPlanned && (!mountedLocations.contains($0.location.key) || !FileManager.default.fileExists(atPath: $0.path)) }
    }
    /// Roots worth searching when a folder has moved: every saved location plus each known drive's archive root.
    var relinkRoots: [URL] {
        var roots: [URL] = []
        for location in library.locations ?? [] { if let url = try? location.resolve(), FileManager.default.fileExists(atPath: url.path) { roots.append(url) } }
        for preset in library.presets where !preset.destination.isEmpty {
            let url = URL(fileURLWithPath: preset.destination)
            if FileManager.default.fileExists(atPath: url.path) { roots.append(url) }
        }
        var seen = Set<String>()
        return roots.filter { seen.insert($0.path).inserted }
    }
    /// Offline originals may be copies, so offer candidates instead of silently redirecting them.
    func relink(_ record: ProjectRecord, quietly: Bool = false) {
        Task { await searchForMoved(record, quietly: quietly) }
    }
    func searchForMoved(_ record: ProjectRecord, quietly: Bool = false) async {
        guard !relinking.contains(record.id), !record.isPlanned else { return }
        relinking.insert(record.id)
        defer { relinking.remove(record.id) }
        let roots = relinkRoots
            let found = await Task.detached(priority: .userInitiated) { Relinker.candidates(for: record, roots: roots) }.value
            guard let current = library.projects.first(where: { $0.id == record.id }), current.path == record.path else { return }
            let originalMissing = !FileManager.default.fileExists(atPath: current.path)
            let candidateAlreadyRegistered = found.first.map { candidate in library.projects.contains { $0.id != current.id && $0.name == current.name && URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == candidate.resolvingSymlinksInPath() } } ?? false
            if found.count == 1 && current.location.isMounted && originalMissing && !candidateAlreadyRegistered {
                attempt {
                    var updated = current; try updated.relocate(to: found[0])
                    try mutate { lib in if let i = lib.projects.firstIndex(where: { $0.id == record.id }) { lib.projects[i] = updated } }
                    relinkCandidates[record.id] = nil
                    if selectedProject == record.id { inspectProject(updated) }
                }
            } else {
                relinkCandidates[record.id] = found
                if found.isEmpty && !quietly { error = "No folder called ‘\(record.name)’ was found on the connected drives. Use Locate Folder when you know where it went." }
            }
    }
    func relink(_ record: ProjectRecord, to url: URL) {
        attempt {
            guard var updated = library.projects.first(where: { $0.id == record.id }) else { return }
            try updated.relocate(to: url)
            try mutate { lib in if let i = lib.projects.firstIndex(where: { $0.id == record.id }) { lib.projects[i] = updated } }
            relinkCandidates[record.id] = nil
            if selectedProject == record.id { inspectProject(updated) }
        }
    }
    /// Tries every project whose folder is missing while its drive, or another drive, is connected.
    func relinkAll() {
        guard !relinkBatchRunning else { return }
        relinkBatchRunning = true
        let records = library.projects.filter { !$0.isPlanned }
        Task {
            defer { relinkBatchRunning = false }
            let missing = await Task.detached { records.filter { !FileManager.default.fileExists(atPath: $0.path) } }.value
            for (index, record) in missing.enumerated() {
                status = "Looking for moved folders \(index + 1) of \(missing.count)…"
                await searchForMoved(record, quietly: true)
            }
            status = missing.isEmpty ? "Every project folder is where the list says it is." : "Finished checking \(missing.count) missing folders. Review suggested matches in Projects."
        }
    }

    // MARK: Pipeline

    func updateProject(_ id: UUID, _ change: (inout ProjectRecord) -> Void) {
        attempt { try mutate { lib in if let i = lib.projects.firstIndex(where: { $0.id == id }) { change(&lib.projects[i]) } } }
    }
    func setStage(_ stage: String, for id: UUID) { updateProject(id) { $0.stage = stage } }
    func addIdea(title: String, format: String, campaign: String, notes: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { error = "Give the idea a title."; return }
        var record = ProjectRecord(planned: clean, format: format, stage: library.stageList.first ?? "Idea", campaign: campaign.isEmpty ? nil : campaign)
        record.notes = notes.isEmpty ? nil : notes
        attempt { try mutate { $0.projects.insert(record, at: 0) } }
        pipelineSelection = record.id
    }
    func removeProject(_ id: UUID) {
        attempt { try mutate { $0.projects.removeAll { $0.id == id } } }
        if selectedProject == id { selectedProject = nil }
        if pipelineSelection == id { pipelineSelection = nil }
    }
    /// Prefills New Project from a planned idea. The idea is replaced by the real record on creation.
    func startPlanned(_ record: ProjectRecord) {
        format = record.format
        title = record.title
        campaign = record.campaign ?? ""
        startingFrom = record.id
        created = nil
        page = .newProject
        changeFormat()
    }
    func setStages(_ stages: [String]) { attempt { let checked = try Configuration.stages(stages); try mutate { $0.stages = checked } } }
    func addCustomField(_ name: String) {
        attempt {
            let clean = try Configuration.fieldName(name, others: library.fieldList.map(\.name))
            try mutate { $0.customFields = $0.fieldList + [CustomField(name: clean)] }; refresh()
        }
    }
    func updateCustomField(_ field: CustomField) {
        attempt {
            var checked = field
            checked.name = try Configuration.fieldName(field.name, others: library.fieldList.filter { $0.id != field.id }.map(\.name))
            try mutate { lib in lib.customFields = lib.fieldList.map { $0.id == checked.id ? checked : $0 } }; refresh()
        }
    }
    func removeCustomField(_ id: UUID) {
        attempt { try mutate { lib in lib.customFields = lib.fieldList.filter { $0.id != id } }; extraValues[id] = nil; refresh() }
    }

    // MARK: Zoom

    var uiScale: CGFloat { 1 + CGFloat(min(max(zoomLevel, -2), 3)) * 0.1 }
    func zoom(_ delta: Int) { zoomLevel = min(max(zoomLevel + delta, -2), 3) }

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
