import Foundation
import AppKit
import TemplateCore

/// Control handlers that do not start from a project reference: boards, settings, formats, templates, sets, locations,
/// discovery, compatibility and cancellation. Same rules as ControlActions: one AppModel action, durable, read back.
extension AppModel {
    // MARK: Lookups

    func lookup<T>(_ items: [T], _ reference: String, id: (T) -> UUID, name: (T) -> String, kind: String) throws -> T {
        let matches = items.filter { id($0).uuidString.lowercased() == reference.lowercased() || name($0) == reference }
        guard !matches.isEmpty else { throw ControlFailure(code: "not_found", message: "No \(kind) matches ‘\(reference)’. Use its UUID or exact name.") }
        guard matches.count == 1 else { throw ControlFailure(code: "ambiguous_\(kind)", message: "More than one \(kind) is called ‘\(reference)’; use its UUID.") }
        return matches[0]
    }
    func lookupTemplate(_ reference: String) throws -> TemplateRecord { try lookup(library.templates, reference, id: \.id, name: \.name, kind: "template") }
    func lookupSet(_ reference: String) throws -> TemplateSet { try lookup(library.sets, reference, id: \.id, name: \.name, kind: "set") }
    func lookupField(_ reference: String) throws -> CustomField { try lookup(library.fieldList, reference, id: \.id, name: \.name, kind: "field") }
    func lookupSavedLocation(_ reference: String) throws -> CatalogueLocation {
        let saved = library.locations ?? []
        let matches = saved.filter { $0.id.uuidString.lowercased() == reference.lowercased() || $0.name == reference || $0.path == reference }
        guard !matches.isEmpty else { throw ControlFailure(code: "not_found", message: "No saved location matches ‘\(reference)’. See location list.") }
        guard matches.count == 1 else { throw ControlFailure(code: "ambiguous_location", message: "More than one saved location matches ‘\(reference)’; use its UUID.") }
        return matches[0]
    }
    func controlBoard(_ name: String?) throws -> PipelineKind {
        switch name { case "recordings": return .recordings; case "live": return .live
        default: throw ControlFailure(code: "invalid_params", message: "Use --board recordings or --board live.") }
    }
    /// Records the GUI would show on a board if no filter were set, leaving out those on unticked locations.
    func boardRecords(_ kind: PipelineKind) -> [ProjectRecord] {
        library.projects.filter { kind.includes(format: $0.format) && !controlHidden($0) }
    }
    func templateSummary(_ record: TemplateRecord) -> [String: Any] {
        ["id": record.id.uuidString, "name": record.name, "mode": record.mode.rawValue, "source": record.source, "payload": store.payload(record).path,
         "usedBy": library.usages(of: record.id)]
    }
    func setSummary(_ set: TemplateSet) -> [String: Any] {
        var variants: [String: Any] = [:]
        for variant in set.variants { variants[variant.format] = ["templateId": variant.templateID.uuidString, "template": library.template(variant.templateID)?.name as Any? ?? NSNull()] }
        return ["id": set.id.uuidString, "name": set.name, "variants": variants]
    }
    func formatSummary(_ preset: Preset) -> [String: Any] {
        let templated = library.sets.contains { library.resolve(setID: $0.id, format: preset.format) != nil } || !library.unassignedTemplates.isEmpty
        return ["format": preset.format, "label": preset.label, "destination": preset.destination, "hasIcon": preset.icon != nil,
                "iconSource": preset.iconSource as Any? ?? NSNull(), "ready": !preset.destination.isEmpty && templated]
    }
    func fieldSummary(_ field: CustomField) -> [String: Any] { ["id": field.id.uuidString, "name": field.name, "includeInName": field.includeInName] }
    func locationSummary(_ location: ProjectLocation) -> [String: Any] {
        let hidden = hiddenLocations.contains(location.key)
        return ["key": location.key, "label": location.label, "kind": location.kind.rawValue, "hidden": hidden,
                // A location that is unticked is never read, not even to see whether it is mounted.
                "mounted": hidden ? NSNull() : mountedLocations.contains(location.key) as Any, "colour": badgeColour(location).rawValue,
                "projects": library.projects.filter { !$0.isPlanned && $0.location.key == location.key }.count]
    }
    func tagCounts(_ outcomes: [TagOutcome]) -> [String: Int] {
        ["applied": outcomes.filter { $0 == .applied }.count, "skipped": outcomes.filter { $0 == .skipped }.count, "failed": outcomes.filter { $0 == .failed }.count]
    }

    // MARK: Dispatcher

    /// Returns nil for an action that starts from a project reference; the caller looks that up and goes on.
    func controlGlobal(_ action: String, _ params: [String: Any]) async throws -> [String: Any]? {
        let dryRun = params["dryRun"] as? Bool == true
        // Anything that can change what an open New Project, import or rename form is built from waits until it is closed.
        let changesFormSources: Set<String> = ["stage.set", "field.add", "field.update", "field.remove", "format.set-destination", "format.set-icon",
                                              "template.import", "template.remove", "set.create", "set.rename", "set.assign", "set.unassign", "set.remove"]
        if changesFormSources.contains(action), !dryRun {
            try requireNoSheet(newProjectPresented || importPresented || renamePrompt != nil || startingFrom != nil, "project form, rename or import window")
        }
        switch action {
        // Ideas
        case "idea.add":
            try requireIdle()
            let format = params["format"] as! String
            guard Library.formats.contains(format) else { throw ControlFailure(code: "invalid_params", message: "Use Long, Short, Podcast or Livestream.") }
            guard PipelineKind.of(format: format) == .recordings else { throw ControlFailure(code: "invalid_params", message: "Live streams are scheduled, not collected as ideas. Create the stream with project create.") }
            let record = try asInvalid { try addIdeaRecord(title: params["title"] as! String, format: format, campaign: params["campaign"] as? String ?? "", notes: params["notes"] as? String ?? "") }
            try await durable()
            return try await controlReadBack(record.id)

        case "project.register":
            let url = try controlURL(params["path"] as! String, directory: true, writable: true)
            let named = params["format"] as? String
            if let named, !(Library.formats + ["Existing"]).contains(named) { throw ControlFailure(code: "invalid_params", message: "Use Long, Short, Podcast, Livestream or Existing.") }
            try requireIdle()
            let already = library.projects.contains { $0.path == url.path }
            let record: ProjectRecord = try await awaiting { done in registerExisting(url, format: named, onFinish: done) }
            try await durable()
            var reply = try await controlReadBack(record.id)
            reply["alreadyRegistered"] = already
            return reply

        // Stages
        case "stage.list":
            let boards: [[String: Any]] = PipelineKind.allCases.map { kind in
                let records = boardRecords(kind), configured = library.stages(for: kind)
                let orphans = Dictionary(grouping: records.map(effectiveStage).filter { !configured.contains($0) }, by: { $0 }).mapValues(\.count)
                return ["board": kind.rawValue, "title": kind.title,
                        "stages": configured.map { stage in ["name": stage, "colour": library.colour(of: stage).rawValue, "count": records.filter { effectiveStage($0) == stage }.count] as [String: Any] },
                        "orphans": orphans.sorted { $0.key < $1.key }.map { ["name": $0.key, "count": $0.value] as [String: Any] }]
            }
            return ["boards": boards, "finderTags": library.finderTagsEnabled, "colours": StageColour.allCases.map(\.rawValue)]
        case "stage.set":
            let kind = try controlBoard(params["board"] as? String)
            let stages = try asInvalid { try Configuration.stages(params["stages"] as? [String] ?? []) }
            let orphaned = Dictionary(grouping: boardRecords(kind).compactMap(\.stage).filter { !stages.contains($0) }, by: { $0 }).mapValues(\.count)
            let report = orphaned.sorted { $0.key < $1.key }.map { ["stage": $0.key, "records": $0.value] as [String: Any] }
            if dryRun { return ["dryRun": true, "board": kind.rawValue, "stages": stages, "orphaned": report] }
            try requireIdle()
            try applyStages(stages, for: kind)
            try await durable()
            return ["board": kind.rawValue, "stages": library.stages(for: kind), "orphaned": report]
        case "stage.set-colour":
            let stage = params["stage"] as! String
            guard let colour = StageColour(rawValue: params["colour"] as! String) else { throw ControlFailure(code: "invalid_params", message: "Colour must be one of " + StageColour.allCases.map(\.rawValue).joined(separator: ", ") + ".") }
            guard visibleStages.contains(stage) else { throw ControlFailure(code: "invalid_stage", message: "‘\(stage)’ is not a stage. Stages: " + visibleStages.joined(separator: ", ")) }
            let tasks = try applyStageColour(colour, for: stage)
            try await durable()
            var outcomes: [TagOutcome] = []
            for task in tasks { outcomes.append(await task.value) }
            return ["stage": stage, "colour": library.colour(of: stage).rawValue, "finderTags": tagCounts(outcomes)]
        case "stage.move-all":
            let from = params["from"] as! String, target = params["to"] as! String
            var kinds = PipelineKind.allCases.filter { kind in library.stages(for: kind).contains(from) || boardRecords(kind).contains { effectiveStage($0) == from } }
            if let board = params["board"] as? String { kinds = [try controlBoard(board)] }
            guard kinds.count == 1, let kind = kinds.first else {
                throw ControlFailure(code: kinds.isEmpty ? "invalid_stage" : "ambiguous_board", message: kinds.isEmpty ? "No board has a stage called ‘\(from)’." : "‘\(from)’ exists on both boards; pass --board recordings or --board live.")
            }
            guard library.stages(for: kind).contains(target) else { throw ControlFailure(code: "invalid_stage", message: "‘\(target)’ is not a stage on the \(kind.title) board: " + library.stages(for: kind).joined(separator: ", ")) }
            // Every record in the stage on this board, whatever the GUI's search, format or stage filters currently hide.
            let records = boardRecords(kind).filter { effectiveStage($0) == from }
            if dryRun { return ["dryRun": true, "board": kind.rawValue, "from": from, "to": target, "count": records.count, "items": records.prefix(50).map(controlSummary)] }
            try requireIdle()
            guard !records.isEmpty, from != target else { return ["board": kind.rawValue, "from": from, "to": target, "moved": 0, "finderTags": tagCounts([])] }
            let tasks = try moveAll(ids: records.map(\.id), to: target)
            try await durable()
            var outcomes: [TagOutcome] = []
            for task in tasks { outcomes.append(await task.value) }
            return ["board": kind.rawValue, "from": from, "to": target, "moved": records.count, "finderTags": tagCounts(outcomes)]

        // Settings
        case "settings.finder-tags":
            try applyFinderTags(params["enabled"] as! Bool)
            try await durable()
            return ["finderTags": library.finderTagsEnabled]
        case "library.tag-folders":
            guard library.finderTagsEnabled else { throw ControlFailure(code: "tags_disabled", message: "Finder tags are off. Turn them on with settings finder-tags --enabled.") }
            try requireIdle()
            let report: TagReport = try await awaiting { done in tagAllFolders(dryRun: dryRun, onFinish: done) }
            var reply: [String: Any] = ["candidates": report.candidates, "tagged": report.tagged, "notFound": report.missing, "failed": report.failed,
                                        "offline": report.offline, "hiddenLocations": report.hidden]
            if dryRun { reply["dryRun"] = true }
            return reply
        case "field.list":
            return ["fields": library.fieldList.map(fieldSummary)]
        case "field.add":
            try requireNoSheet(newProjectPresented, "project form")
            let field = try asInvalid { try addField(params["name"] as! String, includeInName: params["excludeFromName"] as? Bool != true) }
            try await durable()
            return fieldSummary(field)
        case "field.update":
            try requireNoSheet(newProjectPresented, "project form")
            var field = try lookupField(params["field"] as! String)
            if params["includeInName"] != nil && params["excludeFromName"] != nil { throw ControlFailure(code: "invalid_params", message: "Use either --include-in-name or --exclude-from-name.") }
            guard params["name"] != nil || params["includeInName"] != nil || params["excludeFromName"] != nil else { throw ControlFailure(code: "invalid_params", message: "Give --name, --include-in-name or --exclude-from-name.") }
            if let name = params["name"] as? String { field.name = name }
            if let include = params["includeInName"] as? Bool { field.includeInName = include }
            if let exclude = params["excludeFromName"] as? Bool { field.includeInName = !exclude }
            try asInvalid { try replaceField(field) }
            try await durable()
            return fieldSummary(library.fieldList.first { $0.id == field.id } ?? field)
        case "field.remove":
            let field = try lookupField(params["field"] as! String)
            if dryRun { return ["dryRun": true, "field": fieldSummary(field), "creationFormValue": extraValues[field.id] as Any? ?? NSNull(), "recordsUnchanged": true] }
            try requireNoSheet(newProjectPresented, "project form")
            try deleteField(field.id)
            try await durable()
            return ["removed": fieldSummary(field)]

        // Formats
        case "format.list":
            return ["formats": library.presets.map(formatSummary)]
        case "format.set-destination":
            let name = params["format"] as! String
            guard Library.formats.contains(name) else { throw ControlFailure(code: "invalid_params", message: "Use Long, Short, Podcast or Livestream.") }
            try requireNoSheet(newProjectPresented && name == format, "project form")
            let url = try controlURL(params["path"] as! String, directory: true, writable: true)
            try setDestination(url, for: name)
            try await durable()
            return library.presets.first { $0.format == name }.map(formatSummary) ?? [:]
        case "format.set-icon":
            let name = params["format"] as! String
            guard Library.formats.contains(name) else { throw ControlFailure(code: "invalid_params", message: "Use Long, Short, Podcast or Livestream.") }
            guard (params["image"] == nil) != (params["fromFolder"] == nil) else { throw ControlFailure(code: "invalid_params", message: "Give exactly one of --image and --from-folder.") }
            let fromFolder = params["fromFolder"] != nil
            let url = try controlURL((params["image"] ?? params["fromFolder"]) as! String, directory: fromFolder)
            try asInvalid { try setFormatIcon(from: url, fromFolder: fromFolder, for: name) }
            try await durable()
            return library.presets.first { $0.format == name }.map(formatSummary) ?? [:]

        // Templates and sets
        case "template.list":
            return ["sets": library.sets.map(setSummary), "templates": library.templates.map(templateSummary)]
        case "template.files":
            let record = try lookupTemplate(params["template"] as! String)
            let root = store.payload(record)
            guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw ControlFailure(code: "unavailable", message: "The managed copy is missing from the template library.") }
            return try await listFolder(root: root, relative: params["path"] as? String ?? "", params: params)
        case "template.import":
            return try await controlImportTemplate(params)
        case "template.remove":
            let record = try lookupTemplate(params["template"] as! String)
            if dryRun { return ["dryRun": true, "template": templateSummary(record), "loseAssignment": library.usages(of: record.id), "payloadGoesToBin": true] }
            try requireIdle()
            let usages = library.usages(of: record.id)
            let bin = try await deleteTemplate(record)
            return ["removed": templateSummary(record), "assignmentsRemoved": usages, "binPath": bin?.path as Any? ?? NSNull()]
        case "set.create":
            try requireNoSheet(newSetPrompt != nil || newProjectPresented, "template set or project form")
            let source = try (params["fromTemplate"] as? String).map { try lookupTemplate($0).id }
            let made = try asInvalid { try createSet(named: params["name"] as! String, mapping: source) }
            try await durable()
            return setSummary(library.set(made.id) ?? made)
        case "set.rename":
            let set = try lookupSet(params["set"] as! String)
            try asInvalid { try applySetName(set.id, to: params["name"] as! String) }
            try await durable()
            return library.set(set.id).map(setSummary) ?? [:]
        case "set.assign", "set.unassign":
            let set = try lookupSet(params["set"] as! String)
            let name = params["format"] as! String
            guard Library.formats.contains(name) else { throw ControlFailure(code: "invalid_params", message: "Use Long, Short, Podcast or Livestream.") }
            if action == "set.assign" { try asInvalid { try assignTemplate(format: name, templateID: try lookupTemplate(params["template"] as! String).id, in: set.id) } }
            else { try unassignTemplate(format: name, in: set.id) }
            try await durable()
            return library.set(set.id).map(setSummary) ?? [:]
        case "set.remove":
            let set = try lookupSet(params["set"] as! String)
            if dryRun { return ["dryRun": true, "set": setSummary(set), "templatesKept": true] }
            try deleteSet(set.id)
            try await durable()
            return ["removed": setSummary(set), "templatesKept": true]

        // Library and locations
        case "library.find-missing":
            try requireIdle()
            let result: (checked: Int, outcomes: [RelinkOutcome]) = try await awaiting { done in relinkAll(reportWhenNothingMissing: false, apply: !dryRun, onFinish: done) }
            if !dryRun { try await durable() }
            var reply: [String: Any] = ["checked": result.checked, "missing": result.outcomes.count,
                "outcomes": result.outcomes.map { outcome -> [String: Any] in
                    var item = controlOutcome(outcome.kind)
                    item["id"] = outcome.id.uuidString; item["name"] = outcome.name; item["previousPath"] = outcome.previousPath
                    if dryRun, item["result"] as? String == "relinked" { item["result"] = "wouldRelink" }
                    return item
                }]
            if dryRun { reply["dryRun"] = true }
            return reply
        case "library.duplicates":
            return ["groups": duplicateGroups.map { group in
                ["name": group[0].name, "projects": group.map { record -> [String: Any] in
                    var item = controlSummary(record); item["likelyLive"] = likelyLive(record, among: group)
                    item["folderDate"] = ISO8601DateFormatter().string(from: record.effectiveDate); return item
                }] as [String: Any]
            }]
        case "location.list":
            return ["locations": distinctLocations.map(locationSummary),
                    "saved": (library.locations ?? []).map { ["id": $0.id.uuidString, "name": $0.name, "path": $0.path, "lastScanned": $0.lastScanned.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()] as [String: Any] }]
        case "location.set":
            let key = params["key"] as! String
            guard let location = distinctLocations.first(where: { $0.key == key }) else { throw ControlFailure(code: "not_found", message: "No location has the key ‘\(key)’. Keys: " + distinctLocations.map(\.key).joined(separator: ", ")) }
            if params["hidden"] != nil && params["visible"] != nil { throw ControlFailure(code: "invalid_params", message: "Use either --hidden or --visible.") }
            let hidden = (params["hidden"] as? Bool) ?? (params["visible"] as? Bool).map { !$0 }
            guard hidden != nil || params["colour"] != nil else { throw ControlFailure(code: "invalid_params", message: "Give --hidden, --visible or --colour.") }
            var colour: BadgeColour?
            if let name = params["colour"] as? String {
                guard let parsed = BadgeColour(rawValue: name) else { throw ControlFailure(code: "invalid_params", message: "Colour must be one of " + BadgeColour.allCases.map(\.rawValue).joined(separator: ", ") + ".") }
                colour = parsed
            }
            if let colour { setBadgeColour(colour, for: location) }
            if let hidden { setHidden(hidden, for: location) }
            return locationSummary(location)
        case "location.scan":
            return try await controlScanLocation(params)
        case "location.remove":
            let saved = try lookupSavedLocation(params["location"] as! String)
            if dryRun { return ["dryRun": true, "wouldForget": ["id": saved.id.uuidString, "name": saved.name, "path": saved.path], "projectsKept": true] }
            try forgetLocation(saved)
            try await durable()
            return ["forgot": ["id": saved.id.uuidString, "name": saved.name, "path": saved.path], "projectsKept": true]
        case "compat.check":
            return try await controlCompatibility(params)
        case "app.cancel":
            guard let owner = controlOwner, busy else { throw ControlFailure(code: "not_running", message: "No long operation started by a control request is running.") }
            guard owner == params["requestId"] as? String else { throw ControlFailure(code: "not_owner", message: "The running operation was started by a different request id.") }
            cancellation.cancel()
            return ["cancelling": true, "status": status]
        default:
            return nil
        }
    }

    // MARK: Larger handlers

    func controlImportTemplate(_ params: [String: Any]) async throws -> [String: Any] {
        let dryRun = params["dryRun"] as? Bool == true
        guard let mode = ImportMode(rawValue: params["mode"] as! String) else { throw ControlFailure(code: "invalid_params", message: "Use --mode full or --mode structure.") }
        let name = params["name"] as! String
        try asInvalid { try Naming.validate(name) }
        guard (params["set"] == nil) == (params["format"] == nil) else { throw ControlFailure(code: "invalid_params", message: "Give --set and --format together, or neither.") }
        var pending: PendingAssignment?
        if let reference = params["set"] as? String {
            let format = params["format"] as! String
            guard Library.formats.contains(format) else { throw ControlFailure(code: "invalid_params", message: "Use Long, Short, Podcast or Livestream.") }
            pending = PendingAssignment(setID: try lookupSet(reference).id, format: format)
        }
        let source = try controlURL(params["path"] as! String)
        try requireNoSheet(importPresented, "import window")
        if dryRun {
            let plan: CopyPlan
            do { plan = try await Task.detached { try TemplateReader.scan(source, mode: mode) }.value }
            catch { throw ControlFailure(code: "invalid_params", message: error.localizedDescription) }
            return ["dryRun": true, "name": name, "mode": mode.rawValue, "entries": plan.entries.count, "folders": plan.entries.filter(\.directory).count,
                    "files": plan.entries.filter { !$0.directory && !$0.metadata }.count, "iconFiles": plan.entries.filter(\.metadata).count, "bytes": plan.bytes,
                    "warnings": plan.excluded.prefix(50).map { $0 }, "assign": pending.map { ["set": $0.setID.uuidString, "format": $0.format] } as Any? ?? NSNull()]
        }
        try requireIdle()
        let plan: CopyPlan = try await awaiting { done in scanTemplate(source, mode: mode, onFinish: done) }
        let record: TemplateRecord = try await awaiting { done in registerImport(plan: plan, name: name, mode: mode, assigning: pending, onFinish: done) }
        try await durable()
        var reply = templateSummary(library.template(record.id) ?? record)
        reply["entries"] = plan.entries.count; reply["bytes"] = plan.bytes
        return reply
    }

    func controlScanLocation(_ params: [String: Any]) async throws -> [String: Any] {
        let dryRun = params["dryRun"] as? Bool == true
        try requireIdle()
        let root: URL?, saved: CatalogueLocation?
        if let path = params["path"] as? String {
            guard params["location"] == nil else { throw ControlFailure(code: "invalid_params", message: "Give --path or --location, not both.") }
            root = try controlURL(path, directory: true, writable: true); saved = nil
        } else {
            let location = try lookupSavedLocation(params["location"] as! String)
            guard !hiddenLocations.contains(ProjectLocation(path: location.path).key) else { throw ControlFailure(code: "location_hidden", message: "Tick this location in the GUI first.") }
            root = nil; saved = location
        }
        let discovery: DiscoveryResult
        if dryRun {
            // The same engine, without the progress and sheet a real scan shows.
            let target = root, location = saved
            do { discovery = try await Task.detached { try Catalogue.discover(root: target ?? location!.resolve()) }.value }
            catch { throw ControlFailure(code: "invalid_params", message: error.localizedDescription) }
        } else {
            discovery = try await awaiting { done in discoverProjects(root: root, saved: saved, label: saved == nil ? "Looking for projects without moving files" : "Checking saved location", onFinish: done) }
        }
        let known = Set(library.projects.map(\.path))
        let items = discovery.projects.map { ["path": $0.path, "name": $0.name, "format": $0.format, "alreadyRegistered": known.contains($0.path)] as [String: Any] }
        var chosen = Set(discovery.projects.map(\.id))
        if let only = params["only"] as? [String] {
            let wanted = Set(only), found = Set(discovery.projects.map(\.path))
            guard wanted.isSubset(of: found) else { throw ControlFailure(code: "invalid_params", message: "These paths were not discovered: " + wanted.subtracting(found).sorted().joined(separator: ", ")) }
            chosen = Set(discovery.projects.filter { wanted.contains($0.path) }.map(\.id))
        }
        var reply: [String: Any] = ["location": discovery.location.path, "discovered": discovery.projects.count, "projects": Array(items.prefix(500)), "truncated": items.count > 500, "notes": discovery.notes.prefix(50).map { $0 }]
        if dryRun { reply["dryRun"] = true; return reply }
        try registerDiscovered(discovery, selecting: chosen)
        try await durable()
        reply["registered"] = chosen.count; reply["locationSaved"] = true
        return reply
    }

    func controlCompatibility(_ params: [String: Any]) async throws -> [String: Any] {
        let dryRun = params["dryRun"] as? Bool == true
        let url: URL
        if params["project"] != nil {
            let record = try controlRecord(params)
            url = try projectFolderForAction(record)
        } else { url = try controlURL(params["path"] as! String, directory: true) }
        try requireIdle()
        let report: CompatibilityReport
        if dryRun {
            // The same scan engine, without the progress and status a real scan publishes in the app.
            do { report = try await Task.detached { try Compatibility.scan(url) }.value }
            catch { throw ControlFailure(code: "action_failed", message: error.localizedDescription) }
        } else { report = try await awaiting { done in scanCompatibility(url, onFinish: done) } }
        var reply = compatibilitySummary(report)
        guard let target = params["copyTo"] as? String else { return reply }
        guard report.canCopy else { throw ControlFailure(code: "cannot_copy", message: "This scan cannot make a corrected copy: it is incomplete or has name collisions.") }
        let destination = try controlURL(target, directory: true, writable: true)
        let proposal = try asInvalid { try Compatibility.proposal(report) }
        if dryRun {
            reply["dryRun"] = true; reply["outputName"] = proposal.outputName; reply["omittedIcons"] = proposal.omittedIcons.count
            reply["renames"] = proposal.renames.prefix(200).map { ["from": $0.from, "to": $0.to] }; reply["renameCount"] = proposal.renames.count
            return reply
        }
        let output: URL = try await awaiting { done in makeCorrectedCopy(report, to: destination, onFinish: done) }
        reply["copy"] = output.path; reply["renameCount"] = proposal.renames.count
        return reply
    }
}
