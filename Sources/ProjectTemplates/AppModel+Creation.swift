import SwiftUI
import AppKit
import TemplateCore

/// New Project selection, preview and creation use the same draft for the app and its command line.
extension AppModel {
    // MARK: Selection and resolution

    var fields: ProjectFields { draft.fields(format: format, fieldList: library.fieldList) }
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
    var canCreate: Bool { !busy && storeUsable && created == nil && plan != nil && preview?.isExecutable == true && !draft.destination.isEmpty }

    // MARK: Numbering

    var suggestedNumber: String { Numbering.next(for: format, in: library.projects) }
    func numberEdited() { draft.numberEdited(suggested: suggestedNumber); fieldChanged() }

    // MARK: Destinations and formats

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
        if target == format { draft.destination = url.path }
    }
    func changeFormat() {
        created = nil; editingIcon = false
        draft.destination = preset.destination
        if let bookmark = preset.destinationBookmark {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale else { throw AppFailure("Choose the destination again to refresh its bookmark.") }
                draft.destination = url.path
            } catch {
                draft.destination = ""
                fail("Destination is unavailable. Choose it again. \(error.localizedDescription)", action: ("Choose…", { [weak self] in
                    self?.chooseDestination()
                    if self?.draft.destination.isEmpty == false { self?.error = nil }
                }))
            }
        }
        draft.restartNumbering(suggested: suggestedNumber)
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
        let workspaceRecord = draft.startingFrom.flatMap { id in library.projects.first { $0.id == id && $0.ideaWorkspace != nil } }
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

    // MARK: Creation

    func create(onFinish: ((Result<ProjectRecord, Error>) -> Void)? = nil) {
        guard canCreate, let plan, let preview else { onFinish?(.failure(AppFailure("Project cannot be created from the current form."))); return }
        let destination = URL(fileURLWithPath: draft.destination); let name = preview.outerFolderName
        let icon = preset.icon; let format = format; let payloadID = payload?.id
        let campaignAtCreation = draft.campaign
        let fromSheet = newProjectPresented
        let origin = draft.startingFrom.flatMap { id in library.projects.first { $0.id == id } }
        let fields = fields; let runtime = runtime
        let plain = draft.plainFolders
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
            self.continueHolding {
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
                if self.draft.startingFrom == origin?.id { self.draft.startingFrom = nil }
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
        created = nil; draft.clearForNext(suggested: suggestedNumber)
        refresh()
    }
}
