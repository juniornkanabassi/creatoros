import Foundation
import AppKit
import TemplateCore

/// Control handlers for project, idea and creation commands. Each one calls the AppModel action the GUI uses, then waits for
/// the library to be on disk and returns the record read back from it, so a caller never has to read library.json.
extension AppModel {
    // MARK: Shared helpers

    /// Runs an AppModel core whose AppFailure means "the caller asked for something invalid".
    func asInvalid<T>(_ work: () throws -> T) throws -> T {
        do { return try work() } catch let failure as AppFailure { throw ControlFailure(code: "invalid_params", message: failure.localizedDescription) }
    }
    /// Starts one of the callback-style actions (the ones that show progress in the app) and waits for its result.
    func awaiting<T>(_ start: (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        do { return try await withCheckedThrowingContinuation { done in start { done.resume(with: $0) } } }
        catch let failure as AppFailure {
            let text = failure.localizedDescription
            if text.hasPrefix("Another operation is running") { throw ControlFailure(code: "busy", message: text) }
            if text.contains(" cancelled. ") { throw ControlFailure(code: "cancelled", message: text) }
            throw failure
        }
    }
    /// The library change made by the action just taken is on disk when this returns, or it throws.
    func durable() async throws {
        await saveTaskForWorkspace()
        guard storeUsable else { throw ControlFailure(code: "store_unavailable", message: "The library could not be saved, so the change may not have reached disk. Resolve the error in the app.") }
    }
    func requireIdle() throws {
        guard !busy else { throw ControlFailure(code: "busy", message: "Wait for the current operation.") }
    }
    func requireNoSheet(_ open: Bool, _ what: String) throws {
        if open { throw ControlFailure(code: "form_in_use", message: "Close the app's \(what) first.") }
    }
    /// An absolute path the caller names, never read when it is on an unticked location.
    func controlURL(_ path: String, directory: Bool? = nil, writable: Bool = false) throws -> URL {
        guard path.hasPrefix("/") else { throw ControlFailure(code: "invalid_params", message: "Use an absolute path.") }
        // Kept as written (Foundation's standardizing turns /private/tmp into /tmp, which would not match stored paths).
        guard !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { throw ControlFailure(code: "invalid_params", message: "Use a path without . or .. parts.") }
        let url = URL(fileURLWithPath: path)
        guard !hiddenLocations.contains(ProjectLocation(path: url.path).key) else { throw ControlFailure(code: "location_hidden", message: "Tick this path's location in the GUI first.") }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { throw ControlFailure(code: "not_found", message: "Nothing exists at \(url.path).") }
        if let directory, isFolder.boolValue != directory { throw ControlFailure(code: "invalid_params", message: "\(url.path) must be a \(directory ? "folder" : "file").") }
        if writable {
            do { try runtime.requireWritable(url) } catch { throw ControlFailure(code: "not_allowed", message: error.localizedDescription) }
        }
        return url
    }
    /// Whether a cached answer may still be shown: the record it names and every path it was asked about must be on ticked locations.
    func cachedAccessRefusal(_ params: [String: Any], _ result: [String: Any]) -> ControlFailure? {
        let refusal = ControlFailure(code: "location_hidden", message: "Tick this project's location in the GUI first.")
        if let text = result["id"] as? String, let id = UUID(uuidString: text),
           let record = library.projects.first(where: { $0.id == id }), !record.isPlanned, hiddenLocations.contains(record.location.key) { return refusal }
        for key in ["path", "destination", "copyTo", "root"] {
            if let path = params[key] as? String, path.hasPrefix("/"), hiddenLocations.contains(ProjectLocation(path: path).key) { return refusal }
        }
        return nil
    }
    /// The folder to show or browse for a record: the project folder, or an idea's owned workspace.
    func folderToShow(_ record: ProjectRecord) async throws -> URL {
        if record.isPlanned {
            guard record.ideaWorkspace != nil else { throw ControlFailure(code: "invalid_params", message: "This idea has no workspace folder yet. Use idea create-workspace.") }
            return try await asInvalidAsync { try await Task.detached { try IdeaWorkspaceEngine.resolve(for: record) }.value }
        }
        return try projectFolderForAction(record)
    }
    func controlOutcome(_ kind: RelinkOutcome.Kind) -> [String: Any] {
        switch kind {
        case .relinked(let url): ["result": "relinked", "path": url.path]
        case .candidates(let urls): ["result": "candidates", "candidates": urls.map(\.path)]
        case .notFound: ["result": "notFound"]
        case .stillThere: ["result": "stillThere"]
        }
    }
    func deepMatchIDs(_ query: String) async -> Set<UUID> {
        let candidates = library.projects.filter { !$0.isPlanned && !hiddenLocations.contains($0.location.key) && mountedLocations.contains($0.location.key) }
            .map { DeepSearch.Candidate(id: $0.id, path: $0.path) }
        return await DeepSearch.shared.matches(for: query, in: candidates)
    }
    func compatibilitySummary(_ report: CompatibilityReport) -> [String: Any] {
        ["root": report.rootName, "suggestedName": report.suggestedRootName, "complete": report.isComplete, "canCopy": report.canCopy, "entries": report.entries,
         "findings": report.findings.count, "items": report.findings.prefix(50).map { ["path": $0.path, "problem": $0.problem, "corrected": $0.corrected as Any? ?? NSNull()] },
         "iconFiles": report.iconFiles.count, "longPaths": report.longPaths.count, "packages": report.packages, "collisions": report.collisions,
         "skipped": report.skipped, "errors": report.errors]
    }

    /// The record as it is in the library now, with everything an editor shows, so a caller can verify any change without
    /// reading library.json. The record is fetched again after the disk checks, in case something changed meanwhile.
    func controlReadBack(_ id: UUID, availability supplied: ProjectInspection? = nil) async throws -> [String: Any] {
        guard let first = library.projects.first(where: { $0.id == id }) else { throw ControlFailure(code: "not_found", message: "The record is no longer in the library.") }
        let checks = await Task.detached { () -> (ProjectInspection?, [String: Any]?) in
            let inspection = first.isPlanned ? nil : (supplied?.record.id == first.id ? supplied : Catalogue.availability(first))
            guard let workspace = first.ideaWorkspace else { return (inspection, nil) }
            do { _ = try IdeaWorkspaceEngine.resolve(for: first); return (inspection, ["path": workspace.path, "state": "ok"]) }
            catch { return (inspection, ["path": workspace.path, "state": "unavailable", "message": error.localizedDescription]) }
        }.value
        guard let record = library.projects.first(where: { $0.id == id }) else { throw ControlFailure(code: "not_found", message: "The record is no longer in the library.") }
        // The wait above may have let someone untick the record's location; nothing about it is reported then.
        guard record.isPlanned || !hiddenLocations.contains(record.location.key) else { throw ControlFailure(code: "location_hidden", message: "Tick this project's location in the GUI first.") }
        var result = controlSummary(record)
        result["title"] = ProjectRename.fields(of: record)?.title ?? record.title
        result["campaign"] = record.campaign as Any? ?? NSNull(); result["editor"] = record.editor as Any? ?? NSNull()
        result["series"] = record.series ?? []; result["notes"] = record.notes as Any? ?? NSNull(); result["notionURL"] = record.notionURL as Any? ?? NSNull()
        result["workspace"] = checks.1 as Any? ?? NSNull()
        result["available"] = checks.0?.available ?? false
        result["availability"] = checks.0?.status ?? "Planned idea"
        result["folderCreated"] = record.folderCreated.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()
        result["previousPaths"] = record.previousPaths ?? []
        return result
    }

    // MARK: Create

    func controlCreate(_ params: [String: Any]) async throws -> [String: Any] {
        try requireIdle()
        guard !newProjectPresented, renamePrompt == nil, !importPresented, startingFrom == nil else { throw ControlFailure(code: "form_in_use", message: "Close the app's project form first.") }
        let dryRun = params["dryRun"] as? Bool == true
        var origin: ProjectRecord?
        if let reference = params["fromIdea"] as? String {
            let idea = try controlRecord(["project": reference])
            guard idea.isPlanned else { throw ControlFailure(code: "invalid_params", message: "\(idea.name) is already a project; only an idea can be started.") }
            if let requested = params["format"] as? String, requested != idea.format { throw ControlFailure(code: "invalid_params", message: "The idea is a \(idea.format); --format \(requested) does not match.") }
            origin = idea
        }
        guard let requestedFormat = origin?.format ?? params["format"] as? String, Library.formats.contains(requestedFormat) else { throw ControlFailure(code: "invalid_params", message: "Use Long, Short, Podcast or Livestream.") }
        let saved = (format, selection, number, numberIsAutomatic, title, campaign, extraValues, destination, plainFolders)
        defer {
            format = saved.0; selection = saved.1; number = saved.2; numberIsAutomatic = saved.3
            if numberIsAutomatic { number = suggestedNumber }
            title = saved.4; campaign = saved.5; extraValues = saved.6; destination = saved.7; plainFolders = saved.8
            startingFrom = nil
            refresh()
        }
        format = requestedFormat; changeFormat(); extraValues = [:]
        if let origin { invalidateStructure(origin.id); startingFrom = origin.id; created = nil }
        if let template = params["template"] as? String {
            let sets = library.sets.filter { $0.id.uuidString.lowercased() == template.lowercased() || $0.name == template }
            let templates = library.templates.filter { $0.id.uuidString.lowercased() == template.lowercased() || $0.name == template }
            guard sets.count + templates.count == 1 else { throw ControlFailure(code: "template_not_ready", message: "Choose a unique template set or payload UUID/name.") }
            selection = sets.first.map { .set($0.id) } ?? .legacy(templates[0].id)
        }
        guard payload != nil || origin?.ideaWorkspace != nil else { throw ControlFailure(code: "template_not_ready", message: "Set up a template for this format in the GUI.") }
        title = params["title"] as? String ?? origin.map { $0.name } ?? ""
        campaign = params["campaign"] as? String ?? origin?.campaign ?? ""
        numberIsAutomatic = params["number"] == nil; number = params["number"] as? String ?? suggestedNumber
        for (name, value) in params["extra"] as? [String: String] ?? [:] {
            guard let field = library.fieldList.first(where: { Naming.key($0.name) == Naming.key(name) }) else {
                throw ControlFailure(code: "invalid_params", message: "There is no custom field called ‘\(name)’. Fields: " + library.fieldList.map(\.name).joined(separator: ", "))
            }
            extraValues[field.id] = value
        }
        // A one-off destination for this project only; the format's saved destination is not touched, so another caller's
        // create cannot see it.
        if let override = params["destination"] as? String { destination = try controlURL(override, directory: true, writable: true).path }
        if let plain = params["plainFolders"] as? Bool { plainFolders = plain }
        do { _ = try fields.finalName() } catch { throw ControlFailure(code: "invalid_params", message: error.localizedDescription) }
        guard !destination.isEmpty else { throw ControlFailure(code: "no_destination", message: "Choose a destination for this format in the GUI, or pass --destination.") }
        guard !hiddenLocations.contains(ProjectLocation(path: destination).key) else { throw ControlFailure(code: "location_hidden", message: "Tick the destination's location in the GUI first.") }
        busy = true
        refresh(); await refreshTask?.value
        busy = false
        guard !newProjectPresented, renamePrompt == nil, !importPresented else { throw ControlFailure(code: "form_in_use", message: "Close the app's project form first.") }
        if dryRun {
            let name = preview?.outerFolderName ?? ""
            var reply: [String: Any] = ["dryRun": true, "ready": canCreate, "folderName": name, "destination": destination, "path": destination + "/" + name,
                                        "plainFolders": plainFolders, "validation": validation, "fromIdea": origin?.id.uuidString as Any? ?? NSNull(),
                                        "template": payload?.id.uuidString as Any? ?? NSNull()]
            if let preview {
                reply["missingFields"] = preview.missingFields; reply["issues"] = preview.issues
                reply["items"] = preview.visible.count; reply["bytes"] = preview.bytes
                reply["renamed"] = preview.renamedEntries.prefix(50).map { ["from": $0.source, "to": $0.output] }
                reply["renamedCount"] = preview.renamedEntries.count
            }
            reply["compatibility"] = prospectiveCompatibility().map(compatibilitySummary) as Any? ?? NSNull()
            return reply
        }
        guard canCreate else { throw ControlFailure(code: "template_not_ready", message: validation.isEmpty ? "Template cannot create this project." : validation) }
        let templateID = payload?.id.uuidString
        let record: ProjectRecord = try await awaiting { done in create { done($0) } }
        try await durable()
        // create() starts the tag write itself; asking again chains behind it and replaces it, so the folder is tagged
        // once and the reply can say how it went.
        let tag = await tagFolder(library.projects.first { $0.id == record.id } ?? record).value
        var result = try await controlReadBack(record.id)
        result["finderTag"] = tag.rawValue
        result["template"] = templateID as Any? ?? NSNull()
        if record.ideaWorkspace != nil { result["workspaceReview"] = "The idea's old workspace is still linked. Use project workspace-detach or project workspace-bin." }
        return result
    }

    // MARK: Project and idea commands (one record)

    func controlProject(_ action: String, _ record: ProjectRecord, _ params: [String: Any]) async throws -> [String: Any] {
        let dryRun = params["dryRun"] as? Bool == true
        switch action {
        case "project.open":
            let page = params["page"] as? String ?? "projects"
            guard ["projects", "pipeline"].contains(page) else { throw ControlFailure(code: "invalid_params", message: "Use --page projects or --page pipeline.") }
            if formatFilter != "All formats" && formatFilter != record.format { formatFilter = "All formats" }
            if page == "pipeline" {
                pipelineKind = PipelineKind.of(format: record.format)
                pipelineSelection = record.id; self.page = .pipeline
            } else {
                if !search.isEmpty && !record.searchableText.localizedCaseInsensitiveContains(search) && !deepMatches.contains(record.id) { search = "" }
                excludedStages.remove(effectiveStage(record))
                selectedProject = record.id; self.page = .projects
                // Selecting checks the folder and may relink it, as it does for a click; wait for that so the reply is final.
                await inspect(record, findMoved: true)
            }
            var reply = try await controlReadBack(record.id)
            reply["selected"] = true; reply["page"] = self.page.rawValue
            return reply
        case "project.refresh":
            browserRefresh += 1
            let inspection = await inspect(record, findMoved: false)
            var reply: [String: Any] = [:]
            if !inspection.available && !record.isPlanned { reply["relink"] = controlOutcome(await searchForMoved(record, quietly: true, alert: false)) }
            try await durable()
            for (key, value) in try await controlReadBack(record.id) { reply[key] = value }
            return reply
        case "project.pin", "project.unpin":
            try setPinned(action == "project.pin", for: record.id)
            try await durable()
            return try await controlReadBack(record.id)
        case "project.set-stage":
            let stage = params["stage"] as! String
            let targets = moveTargets(for: record)
            guard targets.contains(stage) else { throw ControlFailure(code: "invalid_stage", message: "‘\(stage)’ is not a stage for a \(record.format). Use one of: \(targets.joined(separator: ", ")).") }
            var tag = TagOutcome.skipped
            // An unstaged record already reads as Unclassified; saying so again changes nothing.
            if !(record.stage == nil && stage == effectiveStage(record)) {
                let task = try moveToStage(stage, for: record.id)
                try await durable()
                tag = await task.value
            }
            var reply = try await controlReadBack(record.id)
            reply["finderTag"] = tag.rawValue
            return reply
        case "project.update":
            let names = ["campaign", "editor", "notes", "series"]
            guard names.contains(where: { params[$0] != nil }) else { throw ControlFailure(code: "invalid_params", message: "Give at least one of --campaign, --editor, --notes, --series (an empty value clears it).") }
            try saveDetails(record.id, campaign: params["campaign"] as? String, editor: params["editor"] as? String, notes: params["notes"] as? String,
                            series: (params["series"] as? String).map(AppModel.splitSeries))
            try await durable()
            return try await controlReadBack(record.id)
        case "project.relocate":
            guard !record.isPlanned else { throw ControlFailure(code: "invalid_params", message: "An idea has no folder to relocate.") }
            let url = try controlURL(params["path"] as! String, directory: true, writable: true)
            var warnings: [String] = []
            if url.lastPathComponent != record.name { warnings.append("The record will be renamed to ‘\(url.lastPathComponent)’, the folder's name. The folder itself is not renamed.") }
            if library.projects.contains(where: { $0.id != record.id && $0.path == url.path }) { warnings.append("Another record already points at this folder.") }
            if dryRun {
                return ["dryRun": true, "id": record.id.uuidString, "from": record.path, "to": url.path, "newName": url.lastPathComponent,
                        "previousPaths": Array(Set((record.previousPaths ?? []) + [record.path])).sorted(), "warnings": warnings]
            }
            try requireIdle()
            guard try relocate(record, to: url) != nil else { throw ControlFailure(code: "not_found", message: "The record is no longer in the library.") }
            try await durable()
            var reply = try await controlReadBack(record.id)
            reply["from"] = record.path; reply["to"] = url.path; reply["warnings"] = warnings
            return reply
        case "project.find-moved":
            guard !record.isPlanned else { throw ControlFailure(code: "invalid_params", message: "An idea has no folder to find.") }
            let kind = await searchForMoved(record, quietly: false, apply: !dryRun, alert: false)
            if !dryRun { try await durable() }
            var reply = try await controlReadBack(record.id)
            for (key, value) in controlOutcome(kind) { reply[key] = value }
            if dryRun {
                reply["dryRun"] = true
                if case .relinked(let url) = kind { reply["result"] = "wouldRelink"; reply["path"] = url.path }
            }
            return reply
        case "project.icons-strip":
            guard !record.isPlanned else { throw ControlFailure(code: "invalid_params", message: "An idea has no folder icons.") }
            try requireNoSheet(restoreIconsPrompt != nil, "icon restore window")
            let project = try projectFolderForAction(record)
            if dryRun {
                let report = try await Task.detached { try IconService.strip(project: project, dryRun: true) }.value
                return ["dryRun": true, "iconFiles": report.iconFilesRemoved.count, "folders": report.foldersCleared.count,
                        "items": report.iconFilesRemoved.prefix(50).map { $0 }, "failed": report.failed]
            }
            try requireIdle()
            let report: IconStripReport = try await awaiting { done in stripFolderIcons(record, onFinish: done) }
            var reply = try await controlReadBack(record.id)
            reply["iconFilesRemoved"] = report.iconFilesRemoved.count; reply["foldersCleared"] = report.foldersCleared.count
            reply["failed"] = report.failed; reply["cancelled"] = report.cancelled; reply["summary"] = report.summary
            if report.cancelled { throw ControlFailure(code: "cancelled", message: report.summary + " The folders cleared so far stay cleared.") }
            return reply
        case "project.icons-restore":
            return try await controlRestoreIcons(record, params)
        case "project.remove":
            if record.ideaWorkspace != nil {
                throw ControlFailure(code: "workspace_review", message: record.isPlanned
                    ? "This idea owns a workspace folder. Use idea remove --trash-workspace to Bin it with the idea."
                    : "Review the old idea workspace first: project workspace-detach keeps the folder, project workspace-bin moves it to the Bin.")
            }
            let summary = controlSummary(record)
            if dryRun { return ["dryRun": true, "wouldRemove": summary, "folderUntouched": true] }
            try requireIdle()
            try removeRecord(record.id)
            try await durable()
            return ["removed": summary, "folderUntouched": true]
        case "project.workspace-detach":
            guard !record.isPlanned, record.ideaWorkspace != nil else { throw ControlFailure(code: "invalid_params", message: "This project has no old idea workspace linked.") }
            try requireIdle()
            let kept = record.ideaWorkspace?.path ?? ""
            try await detachWorkspace(record)
            var reply = try await controlReadBack(record.id)
            reply["keptWorkspace"] = kept
            return reply
        case "project.workspace-bin":
            guard params["confirm"] as? Bool == true else { throw ControlFailure(code: "confirmation_required", message: "This moves the old workspace folder to the Bin. Repeat with --confirm to do it.") }
            guard !record.isPlanned, record.ideaWorkspace != nil else { throw ControlFailure(code: "invalid_params", message: "This project has no old idea workspace linked.") }
            try requireNoSheet(binIdea != nil, "Bin confirmation")
            let url = try asInvalid { try confirmedWorkspace(for: record) }
            if dryRun { return ["dryRun": true, "workspace": url.path, "wouldMoveToBin": true] }
            try requireIdle()
            let bin = try await trashWorkspace(record, at: url, removingRecord: false)
            var reply = try await controlReadBack(record.id)
            reply["binned"] = url.path; reply["binPath"] = bin?.path as Any? ?? NSNull()
            return reply
        case "project.files":
            let root = try await projectRoot(record)
            return try await listFolder(root: root, relative: params["path"] as? String ?? "", params: params)
        case "project.open-file":
            let root = try await projectRoot(record)
            let relative = params["path"] as! String
            let url = try await asInvalidAsync { try await Self.openDocument(root: root, relative: relative, activates: params["show"] as? Bool == true) }
            return ["id": record.id.uuidString, "opened": url.path]
        case "project.open-premiere":
            let root = try await projectRoot(record)
            if let file = params["file"] as? String {
                let url = try await asInvalidAsync { try await Self.openDocument(root: root, relative: file, expecting: "prproj") }
                return ["id": record.id.uuidString, "opened": url.path]
            }
            let files = try await Task.detached { try ProjectBrowser.premiereFiles(root: root) }.value
            return ["id": record.id.uuidString, "candidates": files.map(\.relativePath), "hint": files.count == 1 ? "Repeat with --file to open it." : "Choose one and repeat with --file."]
        case "project.add-files":
            return try await controlAddFiles(record, params)
        case "idea.remove":
            guard record.isPlanned else { throw ControlFailure(code: "invalid_params", message: "\(record.name) is a project, not an idea. Use project remove.") }
            let summary = controlSummary(record)
            if record.ideaWorkspace == nil {
                if dryRun { return ["dryRun": true, "wouldRemove": summary, "workspace": NSNull()] }
                try requireIdle(); try removeRecord(record.id); try await durable()
                return ["removed": summary, "workspace": NSNull()]
            }
            guard params["trashWorkspace"] as? Bool == true else {
                throw ControlFailure(code: "workspace_review", message: "This idea owns a workspace folder. Repeat with --trash-workspace to move it to the Bin with the idea.")
            }
            try requireNoSheet(binIdea != nil, "Bin confirmation")
            let url = try asInvalid { try confirmedWorkspace(for: record) }
            if dryRun { return ["dryRun": true, "wouldRemove": summary, "workspace": url.path, "wouldMoveToBin": true] }
            try requireIdle()
            let bin = try await trashWorkspace(record, at: url, removingRecord: true)
            return ["removed": summary, "binned": url.path, "binPath": bin?.path as Any? ?? NSNull()]
        case "idea.create-workspace":
            guard record.isPlanned, record.ideaWorkspace == nil else { throw ControlFailure(code: "invalid_params", message: "Only an idea without a workspace can get one.") }
            try requireNoSheet(workspacePrompt != nil, "workspace window")
            try requireIdle()
            var templateID: UUID?
            if let reference = params["template"] as? String { templateID = try lookupTemplate(reference).id }
            let root = try (params["root"] as? String).map { try controlURL($0, directory: true, writable: true) } ?? runtime.ideas
            let saved: ProjectRecord = try await awaiting { done in createWorkspace(for: record, root: root, templateID: templateID, onFinish: done) }
            try await durable()
            return try await controlReadBack(saved.id)
        case "idea.merge":
            return try await controlMergeIdea(record, params)
        default:
            throw ControlFailure(code: "unknown_action", message: action)
        }
    }

    func asInvalidAsync<T>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() } catch let failure as AppFailure { throw ControlFailure(code: "invalid_params", message: failure.localizedDescription) }
    }
    /// The project's folder for browsing: connected, ticked and still where the record says.
    func projectRoot(_ record: ProjectRecord) async throws -> URL {
        // An idea browses its owned workspace through the same validated resolver the GUI's Browse Workspace uses.
        if record.isPlanned { return try await folderToShow(record) }
        guard mountedLocations.contains(record.location.key) else { throw ControlFailure(code: "unavailable", message: "Connect the project's drive first.") }
        do { return try await Task.detached { try ProjectBrowser.root(record) }.value }
        catch { throw ControlFailure(code: "unavailable", message: error.localizedDescription) }
    }
    /// One bounded folder listing, the same engine the file browser uses.
    func listFolder(root: URL, relative: String, params: [String: Any]) async throws -> [String: Any] {
        let items: [BrowserItem]
        do { items = try await Task.detached { try ProjectBrowser.list(root: root, relative: relative) }.value }
        catch { throw ControlFailure(code: "invalid_params", message: error.localizedDescription) }
        let offset = params["offset"] as? Int ?? 0, limit = params["limit"] as? Int ?? 100
        let batch = items.dropFirst(min(offset, items.count)).prefix(limit)
        let formatter = ISO8601DateFormatter()
        return ["path": relative, "total": items.count, "offset": offset, "returned": batch.count,
                "items": batch.map { ["path": $0.relativePath, "name": $0.name, "kind": $0.package ? "package" : ($0.directory ? "folder" : "file"), "bytes": $0.bytes,
                                       "modified": $0.modified.map(formatter.string(from:)) as Any? ?? NSNull()] as [String: Any] }]
    }
    /// Opens a document in its default app under the file browser's rules: no apps, installers or scripts.
    static func openDocument(root: URL, relative: String, expecting ext: String? = nil, activates: Bool = true) async throws -> URL {
        let item = BrowserItem(relativePath: relative, name: (relative as NSString).lastPathComponent, directory: false, package: false, bytes: 0, modified: nil)
        let url = try await Task.detached { try ProjectBrowser.openable(item, root: root) }.value
        if let ext, url.pathExtension.lowercased() != ext { throw AppFailure("This is not a \(ext == "prproj" ? "Premiere project" : ext + " file").") }
        guard await NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { throw AppFailure("No app is registered for this file type. Install or choose the appropriate editor in macOS first.") }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = activates
        try await NSWorkspace.shared.open(url, configuration: configuration)
        return url
    }

    func controlRestoreIcons(_ record: ProjectRecord, _ params: [String: Any]) async throws -> [String: Any] {
        guard !record.isPlanned else { throw ControlFailure(code: "invalid_params", message: "An idea has no folder icons.") }
        try requireNoSheet(restoreIconsPrompt != nil, "icon restore window")
        let dryRun = params["dryRun"] as? Bool == true
        let formatName = params["formatAs"] as? String ?? record.format
        guard Library.formats.contains(formatName) else { throw ControlFailure(code: "invalid_params", message: "‘\(record.format)’ is not one of Long, Short, Podcast, Livestream; pass --format-as.") }
        let candidates = iconRestoreCandidates(for: record, format: formatName)
        let listing = candidates.map { ["set": $0.name, "id": $0.id.uuidString, "available": $0.available, "reason": $0.reason as Any? ?? NSNull()] as [String: Any] }
        var chosen: IconRestoreCandidate?
        if let reference = params["set"] as? String {
            let matches = candidates.filter { $0.id.uuidString.lowercased() == reference.lowercased() || $0.name == reference }
            guard matches.count == 1 else { throw ControlFailure(code: matches.isEmpty ? "not_found" : "ambiguous_set", message: "No unique template set matches ‘\(reference)’ for \(formatName). Sets: " + candidates.map(\.name).joined(separator: ", ")) }
            chosen = matches[0]
        } else {
            let usable = candidates.filter(\.available)
            if usable.count == 1 { chosen = usable[0] }
            else if !dryRun { throw ControlFailure(code: "ambiguous_set", message: (usable.isEmpty ? "No template set can restore icons onto this project: " : "Several sets can restore these icons; choose one with --set: ") + candidates.map { $0.name + ($0.available ? "" : " (unavailable)") }.joined(separator: ", ")) }
        }
        if dryRun {
            var reply: [String: Any] = ["dryRun": true, "format": formatName, "candidates": listing, "set": chosen?.name as Any? ?? NSNull()]
            if let chosen, chosen.available, let payload = library.resolve(setID: chosen.id, format: formatName) {
                let project = try projectFolderForAction(record)
                let root = store.payload(payload), fields = iconRestoreFields(record, format: formatName)
                let preview = try await Task.detached { try IconService.restorePreview(template: root, fields: fields, onto: project) }.value
                reply["folders"] = preview.restored; reply["inherited"] = preview.inherited; reply["ambiguous"] = preview.ambiguous
                reply["unmatched"] = preview.unmatched; reply["outerIcon"] = library.presets.first { $0.format == formatName }?.icon != nil
            }
            return reply
        }
        guard let chosen, chosen.available else { throw ControlFailure(code: "set_unavailable", message: chosen?.reason ?? "That template set cannot restore icons onto this project.") }
        try requireIdle()
        let report: IconRestoreReport = try await awaiting { done in restoreIcons(record, format: formatName, setID: chosen.id, onFinish: done) }
        var reply = try await controlReadBack(record.id)
        reply["set"] = chosen.name; reply["restored"] = report.restored; reply["inherited"] = report.inherited; reply["ambiguous"] = report.ambiguous
        reply["unmatched"] = report.unmatched; reply["failed"] = report.failed; reply["outerIconApplied"] = report.outerIconApplied
        reply["cancelled"] = report.cancelled; reply["summary"] = report.summary; reply["candidates"] = listing
        if report.cancelled { throw ControlFailure(code: "cancelled", message: report.summary + " Run it again to finish.") }
        return reply
    }

    func controlAddFiles(_ record: ProjectRecord, _ params: [String: Any]) async throws -> [String: Any] {
        let root = try await projectRoot(record)
        let source = try controlURL(params["from"] as! String)
        let forceCopy = params["copy"] as? Bool == true
        let destination: URL
        do { destination = try BrowserDropRoute.destination(root: root, displayed: params["to"] as? String ?? "", target: nil) }
        catch { throw ControlFailure(code: "invalid_params", message: error.localizedDescription) }
        if BrowserDropRoute.isNoOp([source], destination: destination, forceCopy: forceCopy) { return ["id": record.id.uuidString, "transferred": [String](), "note": "The item is already in that folder."] }
        let runtime = runtime
        if params["dryRun"] as? Bool == true {
            do { _ = try await Task.detached { try BrowserTransfer.transfer([source], into: destination, runtime: runtime, forceCopy: forceCopy, validateOnly: true) }.value }
            catch { throw ControlFailure(code: "invalid_params", message: error.localizedDescription) }
            return ["dryRun": true, "from": source.path, "into": destination.path, "wouldCopy": forceCopy, "valid": true]
        }
        try requireIdle()
        let done: [URL] = try await awaiting { finish in
            run("Transferring files into \(destination.lastPathComponent)", cancelNote: "Items already transferred stay where they landed.") { cancellation, progress in
                try BrowserTransfer.transfer([source], into: destination, runtime: runtime, forceCopy: forceCopy, cancellation: cancellation) { completed, total in
                    progress(Double(completed) / Double(total), "Transferred \(completed) of \(total) files")
                }
            } completion: { urls in
                self.status = "Transferred \(urls.count) item\(urls.count == 1 ? "" : "s") into \(destination.lastPathComponent)"
                finish(.success(urls))
            } failure: { finish(.failure(AppFailure($0))) }
        }
        browserRefresh += 1
        return ["id": record.id.uuidString, "transferred": done.map(\.path), "movedFromSource": !FileManager.default.fileExists(atPath: source.path)]
    }

    func controlMergeIdea(_ idea: ProjectRecord, _ params: [String: Any]) async throws -> [String: Any] {
        let dryRun = params["dryRun"] as? Bool == true
        guard idea.isPlanned else { throw ControlFailure(code: "invalid_params", message: "\(idea.name) is a project; only an idea can be merged into one.") }
        guard idea.ideaWorkspace == nil else { throw ControlFailure(code: "workspace_review", message: "This idea owns a workspace folder. Create the project with project create --from-idea, or Bin the idea's workspace first.") }
        var lookup: [String: Any] = ["project": params["into"] as! String]
        if let intoFormat = params["intoFormat"] { lookup["format"] = intoFormat }
        let target = try controlRecord(lookup)
        guard !target.isPlanned else { throw ControlFailure(code: "invalid_params", message: "‘\(target.name)’ is an idea; merge into a project.") }
        func merged(_ project: ProjectRecord, _ idea: ProjectRecord) -> (ProjectRecord, [[String: Any]]) {
            var result = project; var changes: [[String: Any]] = []
            func note(_ field: String, _ from: Any?, _ to: Any) { changes.append(["field": field, "from": from ?? NSNull(), "to": to]) }
            if (result.campaign ?? "").isEmpty, let value = idea.campaign, !value.isEmpty { note("campaign", result.campaign, value); result.campaign = value }
            if (result.editor ?? "").isEmpty, let value = idea.editor, !value.isEmpty { note("editor", result.editor, value); result.editor = value }
            if (result.series ?? []).isEmpty, let value = idea.series, !value.isEmpty { note("series", result.series, value); result.series = value }
            if (result.notionURL ?? "").isEmpty, let value = idea.notionURL, !value.isEmpty { note("notionURL", result.notionURL, value); result.notionURL = value }
            if let ideaNotes = idea.notes, !ideaNotes.isEmpty {
                let combined = (result.notes ?? "").isEmpty ? ideaNotes : result.notes! + "\n\n" + ideaNotes
                note("notes", result.notes, combined); result.notes = combined
            }
            return (result, changes)
        }
        let preview = merged(target, idea)
        if dryRun { return ["dryRun": true, "idea": controlSummary(idea), "into": controlSummary(target), "changes": preview.1, "ideaRemoved": true] }
        try requireIdle()
        busy = true
        defer { busy = false }
        try await commitDurably { lib in
            guard let t = lib.projects.firstIndex(where: { $0.id == target.id }), let i = lib.projects.firstIndex(where: { $0.id == idea.id }),
                  !lib.projects[t].isPlanned, lib.projects[i].isPlanned, lib.projects[i].ideaWorkspace == nil else { throw AppFailure("The idea or the project changed while merging. Nothing was merged.") }
            lib.projects[t] = merged(lib.projects[t], lib.projects[i]).0
            lib.projects.remove(at: i)
        }
        if pipelineSelection == idea.id { pipelineSelection = nil }
        var reply = try await controlReadBack(target.id)
        reply["merged"] = preview.1; reply["ideaRemoved"] = idea.id.uuidString
        return reply
    }
}
