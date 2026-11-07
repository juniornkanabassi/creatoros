import SwiftUI
import TemplateCore

/// Pipeline mutations share AppModel's writer slot and durable library save.
extension AppModel {
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
    func setStage(_ stage: String, for id: UUID) {
        let before = library.projects.first(where: { $0.id == id })
        attempt {
            reportTagFailures([try moveToStage(stage, for: id)], name: before?.name ?? stage)
            guard let before, before.stage != stage, let after = library.projects.first(where: { $0.id == id }) else { return }
            registerStageUndo(before: [before], after: [after], manager: undoManager)
        }
    }
    /// The record is already saved when its Finder tag fails, so say that Finder is out of step instead of staying silent.
    func reportTagFailures(_ tasks: [Task<TagOutcome, Never>], name: String) {
        Task {
            var failed = 0
            for task in tasks where await task.value == .failed { failed += 1 }
            guard failed > 0 else { return }
            status = tasks.count == 1 ? "Could not tag ‘\(name)’ in Finder. Tag All Folders Now will retry."
                : "Could not tag \(failed) of \(tasks.count) folders in Finder. Tag All Folders Now will retry."
        }
    }
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
        let before = projects(in: stage)
        let ids = before.map(\.id)
        guard !ids.isEmpty else { return }
        attempt {
            reportTagFailures(try moveAll(ids: ids, to: target), name: before.count == 1 ? before[0].name : target)
            let changed = before.filter { $0.stage != target }
            let wanted = Set(changed.map(\.id))
            if !changed.isEmpty { registerStageUndo(before: changed, after: library.projects.filter { wanted.contains($0.id) }, manager: undoManager) }
        }
    }
    /// Moves exactly these records. Every one must be able to take the stage on its own board.
    @discardableResult
    func moveAll(ids: [UUID], to target: String) throws -> [Task<TagOutcome, Never>] {
        let wanted = Set(ids)
        guard library.projects.filter({ wanted.contains($0.id) }).allSatisfy({ moveTargets(for: $0).contains(target) }) else {
            throw AppFailure("‘\(target)’ is not a stage on the board these records are on.")
        }
        try mutate { lib in for i in lib.projects.indices where wanted.contains(lib.projects[i].id) { lib.projects[i].stage = target } }
        return library.projects.filter { wanted.contains($0.id) }.map { tagFolder($0) }
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
            else { fail("This project still links to its old idea folder. Decide what to do with that folder first.", action: ("Review…", { [weak self] in self?.workspaceCleanup = record })) }
            return
        }
        guard let index = library.projects.firstIndex(where: { $0.id == id }) else { return }
        let record = library.projects[index]
        attempt {
            try removeRecord(id)
            registerProjectUndo(record, index: index, restoring: true, manager: undoManager)
        }
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
        draft.title = record.isPlanned ? record.name : record.title
        draft.campaign = record.campaign ?? ""
        draft.startingFrom = record.id
        created = nil
        newProjectPresented = true
        changeFormat()
    }
    func forgetStartingIdea() {
        if let id = draft.startingFrom { invalidateStructure(id) }
        draft.startingFrom = nil
        preview = nil; plan = nil
        refresh()
    }
    func setStages(_ stages: [String], for kind: PipelineKind = .recordings) {
        let before = library.stages(for: kind)
        attempt {
            try applyStages(stages, for: kind)
            let after = library.stages(for: kind)
            if before != after { registerStageListUndo(before: before, after: after, kind: kind, manager: undoManager) }
        }
    }
    func applyStages(_ stages: [String], for kind: PipelineKind = .recordings) throws {
        let checked = try Configuration.stages(stages)
        try mutate { if kind == .live { $0.liveStages = checked } else { $0.stages = checked } }
    }
    struct StageRenameReport { var projects = 0, tagsToRewrite = 0, tags: [TagOutcome] = [], newName = "" }
    /// The rename field in Settings: a rename the user can undo.
    @discardableResult
    func renameStage(_ old: String, to new: String, on kind: PipelineKind) async throws -> StageRenameReport {
        let manager = undoManager
        let report = try await renameStageCore(old, to: new, on: kind)
        registerStageRenameUndo(old: old, new: report.newName, kind: kind, manager: manager)
        return report
    }
    /// Renames a stage on one board and takes everything that used the old name with it: the records on that stage, its colour,
    /// the saved stage filter, and the Finder tag on every staged folder that is on a connected, ticked drive (the old tag is
    /// replaced, other tags stay). Saved before the tags are written. With `dryRun` it only counts.
    @discardableResult
    func renameStageCore(_ old: String, to new: String, on kind: PipelineKind, dryRun: Bool = false) async throws -> StageRenameReport {
        if dryRun { return try await renameStageHoldingSlot(old, to: new, on: kind, dryRun: true) }
        return try await withWriter { try await renameStageHoldingSlot(old, to: new, on: kind, dryRun: false) }
    }
    private func renameStageHoldingSlot(_ old: String, to new: String, on kind: PipelineKind, dryRun: Bool) async throws -> StageRenameReport {
        let stages = library.stages(for: kind)
        guard let index = stages.firstIndex(of: old) else { throw AppFailure("‘\(old)’ is not a stage on the \(kind.title) board.") }
        var renamed = stages; renamed[index] = new
        let checked = try Configuration.stages(renamed)
        guard checked[index] != old else { throw AppFailure("The new name is the same as the old one.") }
        let name = checked[index]
        func affected(_ lib: Library) -> [ProjectRecord] { lib.projects.filter { kind.includes(format: $0.format) && $0.stage == old } }
        var report = StageRenameReport(projects: affected(library).count, newName: name)
        let taggable = { (r: ProjectRecord) in self.library.finderTagsEnabled && !r.isPlanned && !self.hiddenLocations.contains(r.location.key) && r.location.isMounted }
        report.tagsToRewrite = affected(library).filter(taggable).count
        if dryRun { return report }
        await writePauseForTests?()
        let ids = Set(affected(library).map(\.id))
        try await commitDurably { applyRename(&$0, from: old, to: name, checked: checked, on: kind) }
        for task in startedRename(from: old, to: name, on: kind, ids: ids) { report.tags.append(await task.value) }
        return report
    }
    /// The library half of a rename: the list, the records on the stage and its colour.
    func applyRename(_ lib: inout Library, from old: String, to name: String, checked: [String], on kind: PipelineKind) {
        let otherBoardUsesOld = lib.stages(for: kind == .live ? .recordings : .live).contains(old)
        let colour = lib.colour(of: old)
        if kind == .live { lib.liveStages = checked } else { lib.stages = checked }
        for i in lib.projects.indices where kind.includes(format: lib.projects[i].format) && lib.projects[i].stage == old { lib.projects[i].stage = name }
        var colours = lib.stageColours ?? [:]
        if colour != .none, colours[name] == nil { colours[name] = colour.rawValue }
        if !otherBoardUsesOld { colours[old] = nil }
        lib.stageColours = colours
    }
    /// The rest of a saved rename: the saved stage filter follows, and each record's Finder tag is rewritten.
    @discardableResult
    func startedRename(from old: String, to name: String, on kind: PipelineKind, ids: Set<UUID>) -> [Task<TagOutcome, Never>] {
        let otherBoardUsesOld = library.stages(for: kind == .live ? .recordings : .live).contains(old)
        if excludedStages.contains(old) && !otherBoardUsesOld { excludedStages.remove(old); excludedStages.insert(name) }
        return library.projects.filter { ids.contains($0.id) }.map { tagFolder($0, replacing: old) }
    }
    func setStageColour(_ colour: StageColour, for stage: String) { attempt { _ = try applyStageColour(colour, for: stage) } }
    @discardableResult
    func applyStageColour(_ colour: StageColour, for stage: String) throws -> [Task<TagOutcome, Never>] {
        try mutate { lib in var colours = lib.stageColours ?? [:]; colours[stage] = colour.rawValue; lib.stageColours = colours }
        return library.projects.filter { $0.stage == stage }.map { tagFolder($0) }
    }
    func setFinderTags(_ enabled: Bool) { attempt { try applyFinderTags(enabled) } }
    func applyFinderTags(_ enabled: Bool) throws { try mutate { $0.finderTags = enabled } }
    func stageColour(_ stage: String) -> Color {
        BadgeColour(rawValue: library.colour(of: stage).rawValue)?.colour ?? .secondary
    }

    // MARK: Finder tags

    /// Writes the record's stage onto its folder as a Finder tag, so Finder shows the same colour. One-way, app to Finder,
    /// and only when the drive is connected and ticked; nothing is hydrated or searched. Writes for one folder run one after
    /// another and a newer stage change replaces an older one still waiting, so rapid changes cannot finish out of order.
    /// Failures are silent in the GUI because the record is already saved; control callers read the outcome.
    /// What a tag write would do for this record right now, or nil when it should be skipped (tags off, an idea, an unknown
    /// stage, an unticked or disconnected location).
    private func tagPlan(_ record: ProjectRecord, replacing old: String? = nil) -> (stage: String, colour: StageColour, known: [String], url: URL)? {
        guard library.finderTagsEnabled, !record.isPlanned, let stage = record.stage, library.allStages.contains(stage),
              !hiddenLocations.contains(record.location.key), record.location.isMounted else { return nil }
        // After a stage rename the old name is no longer configured, but its tag must still be the one that is replaced.
        return (stage, library.colour(of: stage), library.allStages + (old.map { [$0] } ?? []), URL(fileURLWithPath: record.path))
    }
    @discardableResult
    func tagFolder(_ record: ProjectRecord, replacing old: String? = nil) -> Task<TagOutcome, Never> {
        guard let first = tagPlan(record, replacing: old) else { return Task { .skipped } }
        guard (try? runtime.requireWritable(first.url)) != nil else { return Task { .failed } }
        let id = record.id
        let generation = (tagGeneration[id] ?? 0) + 1
        tagGeneration[id] = generation
        let previous = tagTasks[id]
        let task = Task { @MainActor () -> TagOutcome in
            _ = await previous?.value
            guard self.tagGeneration[id] == generation else { return .skipped }
            // A tag write is a write: it waits (briefly) while somebody else holds the writer slot, and gives up if they keep it.
            var waits = 0
            while self.writeLocked && waits < 30 { try? await Task.sleep(for: .milliseconds(100)); waits += 1 }
            guard !self.writeLocked else { return .skipped }
            // The wait may have been long: look at the record, its location and the settings again just before writing.
            guard let current = self.library.projects.first(where: { $0.id == id }), let plan = self.tagPlan(current, replacing: old) else { return .skipped }
            guard (try? self.runtime.requireWritable(plan.url)) != nil else { return .failed }
            // From this last check until the write is done the slot is held (joined, inside a command's own tag write), so a hide
            // or a rename cannot slip in between the check and the write.
            guard let owner = try? self.acquireWriter() else { return .skipped }
            defer { self.releaseWriter(owner) }
            await self.writePauseForTests?()
            let (stage, colour, known, url) = plan
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
        // Tagging many folders is one multi-step write: it holds the slot, or is refused when somebody else does.
        guard let owner = try? acquireWriter() else { error = Self.writeLockedMessage; onFinish?(.failure(AppFailure(Self.writeLockedMessage))); return }
        tagging = true
        Task {
          await Self.$me.withValue(owner) {
            defer { tagging = false }
            for (index, original) in records.enumerated() {
                status = "Tagging folder \(index + 1) of \(records.count)…"
                guard let record = library.projects.first(where: { $0.id == original.id }), !hiddenLocations.contains(record.location.key) else { report.hidden += 1; continue }
                switch await tagFolder(record).value { case .applied: report.tagged += 1; case .skipped: report.missing += 1; case .failed: report.failed += 1 }
            }
            func folders(_ n: Int) -> String { "\(n) folder\(n == 1 ? "" : "s")" }
            var parts = ["Tagged \(folders(report.tagged)) in Finder."]
            if report.missing > 0 { parts.append("\(folders(report.missing)) \(report.missing == 1 ? "was" : "were") not found.") }
            if report.failed > 0 { parts.append("\(report.failed) could not be written.") }
            if report.offline > 0 { parts.append("\(report.offline) are on drives that are not connected.") }
            status = parts.joined(separator: " ")
            onFinish?(.success(report))
          }
          releaseWriter(owner)
        }
    }
}
