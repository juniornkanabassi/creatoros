import Foundation
import TemplateCore

@main struct ControlModelCheck {
    @MainActor static func main() async throws {
        let model = AppModel()
        precondition(model.runtime.isIsolated && model.storeUsable)
        model.destination = "/Volumes/Fixture/Fixture/Projects"
        precondition(model.plainFolders)
        model.library.presets[model.library.presets.firstIndex { $0.format == model.format }!].destination = model.destination
        model.plainFolders = false
        model.changeFormat()
        precondition(model.plainFolders)
        let destination = model.runtime.root.appendingPathComponent("Projects/Short")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        model.library.presets[model.library.presets.firstIndex { $0.format == "Short" }!].destination = destination.path
        let id = UUID()
        let payload = model.store.templates.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: payload.appendingPathComponent("Template.txt"))
        try Data("icon sentinel".utf8).write(to: payload.appendingPathComponent("Icon\r"))
        model.library.templates = [TemplateRecord(id: id, name: "Fixture", source: payload.path, mode: .full)]
        model.selection = .legacy(id)
        let extra = CustomField(name: "Sponsor")
        model.library.customFields = [extra]
        model.extraValues = [extra.id: "Cancelled form"]
        model.plainFolders = true
        let result = try await model.controlAction("project.create", ["format": "Short", "title": "Clean"])
        precondition(result["name"] as? String == "001 — Short — Clean")
        precondition(FileManager.default.fileExists(atPath: (result["path"] as! String) + "/Icon\r"))
        precondition(model.extraValues[extra.id] == "Cancelled form" && model.plainFolders)
        model.format = "Short"; model.changeFormat()
        precondition(!model.plainFolders)
        let ref = result["id"] as! String
        let record = model.library.projects.first { $0.id.uuidString == ref }!
        let stage = model.effectiveStage(record)
        model.search = "Clean"; model.formatFilter = "Short"; model.excludedStages = [stage, "Editing"]
        _ = try await model.controlAction("project.open", ["project": ref])
        precondition(model.search == "Clean" && model.formatFilter == "Short" && model.excludedStages == ["Editing"])
        precondition(model.defaults.stringArray(forKey: "excludedStages") == ["Editing"])
        model.search = "Unrelated"; model.formatFilter = "Long"
        _ = try await model.controlAction("project.open", ["project": ref])
        precondition(model.search.isEmpty && model.formatFilter == "All formats" && model.excludedStages == ["Editing"])
        print("PASS 9 control model checks: destination and format share Plain folders; CLI clears extras and restores form; open preserves unrelated and saved filters")
        model.newProjectPresented = true
        model.extraValues = [:]; model.title = "Sheet completion"; model.fieldChanged()
        await model.refreshTask?.value
        let created: ProjectRecord = try await withCheckedThrowingContinuation { done in model.create { done.resume(with: $0) } }
        while model.busy { await Task.yield() }; for task in model.tagTasks.values { _ = await task.value }
        precondition(model.newProjectPresented && model.created?.path == created.path && !model.canCreate)
        precondition(model.title == "Sheet completion" && model.selectedProject == created.id)
        let saved = try Data(contentsOf: model.store.file)
        model.nextProject()
        await model.refreshTask?.value
        precondition(model.newProjectPresented && model.created == nil && model.title.isEmpty && model.number == "003")
        let afterReset = try Data(contentsOf: model.store.file)
        precondition(afterReset == saved)
        model.newProjectPresented = false; model.title = "Background completion"; model.fieldChanged()
        await model.refreshTask?.value
        let _: ProjectRecord = try await withCheckedThrowingContinuation { done in
            model.create { done.resume(with: $0) }
            model.newProjectPresented = true
        }
        while model.busy { await Task.yield() }; for task in model.tagTasks.values { _ = await task.value }
        precondition(model.created == nil && model.title.isEmpty && model.number == "004")
        print("PASS 1 sheet completion check: saved project remains visible; Next Project resets only the form; background creation still resets if a sheet opens during its copy")
        var idea = ProjectRecord(planned: "Promoted idea", format: "Short", stage: "Idea", campaign: "Kept")
        idea.notes = "Kept notes"
        try await model.commitDurably { $0.projects.append(idea) }
        model.startPlanned(idea)
        await model.refreshTask?.value
        precondition(model.startingFrom == idea.id && model.newProjectPresented)
        let promoted: ProjectRecord = try await withCheckedThrowingContinuation { done in model.create { done.resume(with: $0) } }
        while model.busy { await Task.yield() }; for task in model.tagTasks.values { _ = await task.value }
        precondition(model.newProjectPresented && model.created?.path == promoted.path && model.startingFrom == nil)
        precondition(promoted.id == idea.id && !promoted.isPlanned && promoted.notes == "Kept notes" && promoted.campaign == "Kept")
        precondition(model.library.projects.filter { $0.id == idea.id }.count == 1 && model.workspaceCleanup == nil)
        model.nextProject()
        model.title = "After idea"; model.fieldChanged()
        await model.refreshTask?.value
        let ordinary: ProjectRecord = try await withCheckedThrowingContinuation { done in model.create { done.resume(with: $0) } }
        while model.busy { await Task.yield() }; for task in model.tagTasks.values { _ = await task.value }
        precondition(ordinary.id != idea.id && ordinary.campaign == nil && model.startingFrom == nil)
        precondition(model.library.projects.first { $0.id == idea.id }?.path == promoted.path)
        print("PASS 1 idea promotion check: kept-open sheet clears the idea link; identity and metadata kept; Next Project is ordinary creation")
        // A caller meeting an open GUI sheet is refused with form_in_use and nothing changes.
        func refusal(_ action: String, _ params: [String: Any]) async -> String? {
            do { _ = try await model.controlAction(action, params); return nil }
            catch let failure as ControlFailure { return failure.code } catch { return "other: \(error)" }
        }
        func expect(_ action: String, _ params: [String: Any], _ code: String) async {
            let got = await refusal(action, params)
            precondition(got == code, "\(action) answered \(String(describing: got)), expected \(code)")
        }
        let snapshot = try Data(contentsOf: model.store.file)
        let target = model.library.projects.first { !$0.isPlanned }!
        model.restoreIconsPrompt = target
        await expect("project.icons-strip", ["project": target.id.uuidString], "form_in_use")
        await expect("project.icons-restore", ["project": target.id.uuidString], "form_in_use")
        model.restoreIconsPrompt = nil
        model.newProjectPresented = true
        await expect("project.create", ["format": "Short", "title": "Blocked"], "form_in_use")
        await expect("field.add", ["name": "Blocked"], "form_in_use")
        await expect("set.create", ["name": "Blocked"], "form_in_use")
        await expect("format.set-destination", ["format": model.format, "path": model.runtime.projects.path], "form_in_use")
        model.newProjectPresented = false
        model.importPresented = true
        await expect("template.import", ["path": model.runtime.root.path, "name": "Blocked", "mode": "full"], "form_in_use")
        model.importPresented = false
        let guiHold = try model.acquireWriter(); model.busy = true
        let pinned = await refusal("project.pin", ["project": target.id.uuidString]); precondition(pinned != "form_in_use" && pinned != "busy" || pinned == "busy")
        await expect("project.icons-strip", ["project": target.id.uuidString], "busy")
        model.busy = false; model.releaseWriter(guiHold)
        let unchanged = try Data(contentsOf: model.store.file) == snapshot
        precondition(unchanged)
        print("PASS 1 sheet collision check: icon, form, import and busy states refuse control actions with form_in_use or busy and leave the library untouched")
        // A request id still matches when only the presentation flag `show` differs.
        let renameParams: [String: Any] = ["project": target.id.uuidString, "title": "Show flag", "requestId": "show-1", "ignoreOpenApps": true]
        let first = await model.control(["id": "a", "action": "project.rename", "params": renameParams.merging(["show": false]) { $1 }])
        let second = await model.control(["id": "b", "action": "project.rename", "params": renameParams])
        let firstResult = first["result"] as? [String: Any], secondResult = second["result"] as? [String: Any]
        precondition(first["ok"] as? Bool == true, "first rename failed: \(first)")
        precondition(second["ok"] as? Bool == true && secondResult?["newPath"] as? String == firstResult?["newPath"] as? String, "retry differing only in show was not served from the cache: \(second)")
        print("PASS 1 request fingerprint check: a retry that differs only in the show flag returns the first result and acts once")
        // Pipeline details: an untouched field is never overwritten by a stale form, and text is trimmed.
        try model.saveDetails(target.id, campaign: "  Trimmed  ", series: ["a", " ", "b"])
        precondition(model.library.projects.first { $0.id == target.id }?.campaign == "Trimmed" && model.library.projects.first { $0.id == target.id }?.series == ["a", "b"])
        try model.saveDetails(target.id, editor: "Only editor")
        let after = model.library.projects.first { $0.id == target.id }!
        precondition(after.campaign == "Trimmed" && after.editor == "Only editor")
        print("PASS 1 details check: saving one field leaves the others as they are")
        // The stage change itself refuses an unknown record and a stage from the other board.
        do { _ = try model.moveToStage("Idea", for: UUID()); preconditionFailure("unknown record accepted") } catch is AppFailure {}
        do { _ = try model.moveToStage("Streamed", for: target.id); preconditionFailure("live stage accepted on a recording") } catch is AppFailure {}
        print("PASS 1 stage boundary check: unknown ids and wrong-board stages are refused in the shared mutation")
        // A GUI operation in progress stops every control mutation, whichever handler it would reach.
        func controlCode(_ action: String, _ params: [String: Any]) async -> String? {
            let reply = await model.control(["id": "c", "action": action, "params": params])
            return (reply["error"] as? [String: Any])?["code"] as? String
        }
        let fieldsBefore = model.library.fieldList.count
        let guiHold2 = try model.acquireWriter(); model.busy = true
        let refused1 = await controlCode("field.add", ["name": "During GUI copy"]); precondition(refused1 == "busy")
        let refused2 = await controlCode("set.create", ["name": "During GUI copy"]); precondition(refused2 == "busy")
        let refused3 = await controlCode("settings.finder-tags", ["enabled": true]); precondition(refused3 == "busy")
        model.busy = false; model.releaseWriter(guiHold2)
        precondition(model.library.fieldList.count == fieldsBefore)
        print("PASS 1 busy guard check: field, set and settings mutations are refused while the GUI is busy")
        // Hiding a location while a deep search is waiting hides its projects from the answer too.
        let probe = Task { await model.control(["id": "p", "action": "project.list", "params": ["search": "Short", "deep": true]]) }
        await Task.yield()
        model.hiddenLocations.insert(target.location.key)
        let listed = await probe.value
        model.hiddenLocations.remove(target.location.key)
        let leaked = (listed["result"] as? [String: Any])?["total"] as? Int
        precondition(leaked == 0, "a hidden location leaked \(String(describing: leaked)) projects into a deep search")
        print("PASS 1 deep search check: visibility is read again after the wait")
        // A tag queued behind a slow one is not written if its location is hidden while it waits.
        let tagged = model.library.projects.first { !$0.isPlanned }!
        let tagURL = URL(fileURLWithPath: tagged.path)
        try FinderTags.write([], to: tagURL)
        model.library.finderTags = true
        if model.library.projects.first(where: { $0.id == tagged.id })?.stage == nil { try model.modifyProject(tagged.id) { $0.stage = "Writing" } }
        let slow = Task<TagOutcome, Never> { try? await Task.sleep(for: .milliseconds(300)); return .applied }
        model.tagTasks[tagged.id] = slow
        let queued = model.tagFolder(model.library.projects.first { $0.id == tagged.id }!)
        model.hiddenLocations.insert(tagged.location.key)
        let queuedOutcome = await queued.value
        model.hiddenLocations.remove(tagged.location.key)
        let leftTags = try FinderTags.read(tagURL)
        precondition(queuedOutcome == .skipped && leftTags.isEmpty, "queued tag wrote after its location was hidden: \(queuedOutcome) \(leftTags)")
        print("PASS 1 queued tag check: visibility and settings are checked again after the queue wait, immediately before writing")
        // A listing that waits is not answered once its location is hidden meanwhile, whichever handler produced it.
        model.mountedLocations.insert(target.location.key)
        model.controlPauseForTests = { model.hiddenLocations.insert(target.location.key) }
        let racing = await model.control(["id": "f", "action": "project.files", "params": ["project": target.id.uuidString]])
        model.controlPauseForTests = nil
        model.hiddenLocations.remove(target.location.key)
        let racingCode = (racing["error"] as? [String: Any])?["code"] as? String
        precondition(racingCode == "location_hidden", "a listing that waited answered after its location was hidden: \(racing)")
        print("PASS 1 delayed listing check: the answer is withheld when the location is hidden during the wait")
        // The project moves during the wait: the listing must not answer from the old folder, and must say why.
        let moving = model.library.projects.first { $0.id == target.id }!
        let oldFolder = URL(fileURLWithPath: moving.path)
        let newFolder = model.runtime.root.appendingPathComponent("MovedDuringWait")
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: oldFolder.appendingPathComponent("OLD.txt"))
        try Data("new".utf8).write(to: newFolder.appendingPathComponent("NEW.txt"))
        model.controlPauseForTests = { _ = try? model.relocate(moving, to: newFolder) }
        let moved = await model.control(["id": "m", "action": "project.files", "params": ["project": target.id.uuidString]])
        model.controlPauseForTests = nil
        let movedCode = (moved["error"] as? [String: Any])?["code"] as? String
        precondition(movedCode == "record_changed", "a listing answered after its project moved: \(moved)")
        let nowRecord = model.library.projects.first { $0.id == target.id }!
        _ = try model.relocate(nowRecord, to: oldFolder)
        // Hidden during the wait while asking for a folder that does not exist: location_hidden, not a filesystem error.
        model.controlPauseForTests = { model.hiddenLocations.insert(target.location.key) }
        let missing = await model.control(["id": "h", "action": "project.files", "params": ["project": target.id.uuidString, "path": "DOES_NOT_EXIST"]])
        model.controlPauseForTests = nil
        model.hiddenLocations.remove(target.location.key)
        let missingCode = (missing["error"] as? [String: Any])?["code"] as? String
        precondition(missingCode == "location_hidden", "an error path leaked past a hidden location: \(missing)")
        print("PASS 1 record change during a wait: a moved project gives record_changed and a hidden one gives location_hidden, on success and on error paths")
        // While a New Project, rename or start-from-idea form is open, nothing it is built from may change under it.
        let beforeForm = try Data(contentsOf: model.store.file)
        let guarded: [(String, [String: Any])] = [("set.unassign", ["set": "x", "format": "Short"]), ("set.assign", ["set": "x", "format": "Short", "template": "x"]),
            ("set.rename", ["set": "x", "name": "y"]), ("set.remove", ["set": "x"]), ("set.create", ["name": "y"]), ("template.remove", ["template": "x"]),
            ("template.import", ["path": "/x", "name": "y", "mode": "full"]), ("field.add", ["name": "y"]), ("field.update", ["field": "x", "name": "y"]),
            ("field.remove", ["field": "x"]), ("stage.set", ["board": "recordings", "stages": ["A", "B"]]), ("format.set-icon", ["format": "Short", "image": "/x"]),
            ("format.set-destination", ["format": "Long", "path": "/x"])]
        for opener in [{ model.newProjectPresented = true }, { model.importPresented = true }, { model.renamePrompt = target }, { model.startingFrom = UUID() }] as [() -> Void] {
            opener()
            for (action, params) in guarded { await expect(action, params, "form_in_use") }
            model.newProjectPresented = false; model.importPresented = false; model.renamePrompt = nil; model.startingFrom = nil
        }
        model.newProjectPresented = true
        let dryRefusal = await refusal("set.remove", ["set": "x", "dryRun": true])
        precondition(dryRefusal != "form_in_use", "a dry run was refused by an open form")
        model.newProjectPresented = false
        let formUnchanged = try Data(contentsOf: model.store.file) == beforeForm
        precondition(formUnchanged)
        print("PASS 1 open form check: set, template, field, format and stage-list changes are refused with form_in_use while a form is open, dry runs are not")
        // One writer at a time: while a command is changing the library, the app's own writes are told to retry.
        let lockedTarget = model.library.projects.first { !$0.isPlanned }!
        // Tag All Folders only reaches the slot with a staged folder on a connected drive and tags switched on.
        model.library.finderTags = true
        model.mountedLocations.insert(lockedTarget.location.key)
        if lockedTarget.stage == nil { try model.modifyProject(lockedTarget.id) { $0.stage = "Writing" } }
        await model.saveTaskForWorkspace()
        let lockedBefore = try Data(contentsOf: model.store.file)
        let lockedSnapshot = model.library.projects.count
        var expectedBusy = false  // busy is true while the operation under test holds the slot, and must not change
        func retryRefused(_ name: String, _ work: () throws -> Void) {
            do { try work(); preconditionFailure("\(name) was not refused while a command was writing") }
            catch let failure as AppFailure { precondition(failure.localizedDescription.contains("retry"), "\(name): \(failure.localizedDescription)") }
            catch { preconditionFailure("\(name): \(error)") }
        }
        // Every other entry point that writes, waits or runs is refused the same way, and the library is untouched.
        func retryRefusedAsync(_ name: String, _ work: () async throws -> Void) async {
            do { try await work(); preconditionFailure("\(name) was not refused while a command was writing") }
            catch let failure as AppFailure { precondition(failure.localizedDescription.contains("retry"), "\(name): \(failure.localizedDescription)") }
            catch { preconditionFailure("\(name): \(error)") }
        }
        func runRefused(_ name: String, _ start: () -> Void) {
            model.error = nil; start()
            precondition(model.error?.contains("retry") == true && model.busy == expectedBusy, "\(name) was not refused while a command was writing: \(String(describing: model.error))")
        }
        let someTemplate = model.library.templates.first!
        let someLocation = try CatalogueLocation(url: model.runtime.root)
        let emptyFolder = model.runtime.root.appendingPathComponent("EmptyForLock")
        try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        let someDiscovery = try Catalogue.discover(root: emptyFolder)
        let somePlan = try TemplateReader.scan(emptyFolder)
        let someSetID = UUID()
        func entryPointsRefused(_ who: String) async {
            expectedBusy = model.busy
            model.error = nil
            retryRefused("pin") { try model.setPinned(true, for: lockedTarget.id) }
            retryRefused("stage") { _ = try model.moveToStage("Idea", for: lockedTarget.id) }
            retryRefused("details") { try model.saveDetails(lockedTarget.id, notes: "x") }
            retryRefused("settings") { try model.applyFinderTags(false) }
            retryRefused("set") { _ = try model.createSet(named: "Locked", mapping: nil) }
            retryRefused("field") { _ = try model.addField("Locked") }
            retryRefused("remove") { try model.removeRecord(lockedTarget.id) }
            retryRefused("relocate") { _ = try model.relocate(lockedTarget, to: URL(fileURLWithPath: lockedTarget.path)) }
            model.error = nil
            model.stripFolderIcons(lockedTarget)
            precondition(model.error?.contains("retry") == true && model.busy == expectedBusy, "icons were not refused while a command was writing")
            model.error = nil
            let quiet = await model.searchForMoved(lockedTarget, quietly: true)
            if case .stillThere = quiet {} else { preconditionFailure("a quiet relink ran while a command was writing") }
            retryRefused("move all") { _ = try model.moveAll(ids: [lockedTarget.id], to: "Idea") }
            retryRefused("stage list") { try model.applyStages(["A", "B"], for: .recordings) }
            retryRefused("stage colour") { _ = try model.applyStageColour(.red, for: "Idea") }
            retryRefused("rename set") { try model.applySetName(someSetID, to: "x") }
            retryRefused("assign") { try model.assignTemplate(format: "Short", templateID: someTemplate.id, in: someSetID) }
            retryRefused("unassign") { try model.unassignTemplate(format: "Short", in: someSetID) }
            retryRefused("delete set") { try model.deleteSet(someSetID) }
            retryRefused("update field") { try model.replaceField(CustomField(name: "Locked")) }
            retryRefused("delete field") { try model.deleteField(UUID()) }
            retryRefused("add idea") { _ = try model.addIdeaRecord(title: "Locked", format: "Short", campaign: "", notes: "") }
            retryRefused("destination") { try model.setDestination(model.runtime.projects, for: "Short") }
            retryRefused("format icon") { try model.setFormatIcon(from: model.runtime.root, fromFolder: true, for: "Short") }
            retryRefused("forget location") { try model.forgetLocation(someLocation) }
            retryRefused("register discovery") { try model.registerDiscovered(someDiscovery) }
            await retryRefusedAsync("stage rename") { _ = try await model.renameStageCore("Idea", to: "Locked", on: .recordings) }
            await retryRefusedAsync("template delete") { _ = try await model.deleteTemplate(someTemplate) }
            await retryRefusedAsync("workspace bin") { _ = try await model.trashWorkspace(lockedTarget, at: model.runtime.root, removingRecord: false) }
            await retryRefusedAsync("workspace detach") { try await model.detachWorkspace(lockedTarget) }
            await retryRefusedAsync("commit") { try await model.commitDurably { $0.projects.removeAll() } }
            runRefused("import") { model.registerImport(plan: somePlan, name: "Locked", mode: .full, assigning: nil) { _ in } }
            runRefused("discovery") { model.discoverProjects(root: model.runtime.root) { _ in } }
            runRefused("register existing") { model.registerExisting(model.runtime.root) }
            runRefused("workspace create") { model.createWorkspace(for: ProjectRecord(planned: "Locked", format: "Short", stage: "Idea"), root: model.runtime.ideas, templateID: nil) }
            runRefused("compat scan") { model.scanCompatibility(model.runtime.root) { _ in } }
            runRefused("icon restore") { model.restoreIcons(lockedTarget, format: "Short", setID: someSetID) }
            runRefused("project rename") { model.renameProject(lockedTarget.id, number: "001", campaign: "", title: "Locked", updateHeadings: false) }
            // What a running command sees cannot be changed under it either.
            let hiddenBefore = model.hiddenLocations, colourBefore = model.badgeColour(lockedTarget.location)
            model.error = nil
            model.setHidden(true, for: lockedTarget.location)
            precondition(model.hiddenLocations == hiddenBefore && model.error?.contains("retry") == true, "hiding a location was allowed while a command was writing")
            model.error = nil
            model.setBadgeColour(colourBefore == .red ? .blue : .red, for: lockedTarget.location)
            precondition(model.badgeColour(lockedTarget.location) == colourBefore && model.error?.contains("retry") == true, "a badge colour changed while a command was writing")
            // Tagging every folder is a write too.
            model.error = nil
            model.tagAllFolders()
            precondition(model.error?.contains("retry") == true && !model.tagging, "tag all folders was not refused while \(who)")
        }
        // (a) a command holds the slot
        model.controlMutating = true
        await entryPointsRefused("a command held the slot")
        let identicalAfter = try Data(contentsOf: model.store.file) == lockedBefore
        precondition(identicalAfter && model.library.projects.count == lockedSnapshot, "a refused write changed the library")
        model.controlMutating = false
        // (b) an operation started in the app holds the slot: workspace detach, with the same entry points tried in its middle.
        let detachJSON = Data("{\"path\":\"\(model.runtime.ideas.path)/fake\",\"rootPath\":\"\(model.runtime.ideas.path)\",\"owner\":\"\(UUID().uuidString)\"}".utf8)
        let fakeWorkspace = try JSONDecoder().decode(IdeaWorkspace.self, from: detachJSON)
        try model.modifyProject(lockedTarget.id) { $0.ideaWorkspace = fakeWorkspace }
        let linked = model.library.projects.first { $0.id == lockedTarget.id }!
        let beforeDetach = try Data(contentsOf: model.store.file)
        // The hook runs inside the detach, as the holder; the entry points are tried as somebody else.
        model.writePauseForTests = { await AppModel.$me.withValue(nil) { await entryPointsRefused("a workspace detach was running") } }
        try await model.detachWorkspace(linked)
        model.writePauseForTests = nil
        precondition(model.writer == nil && !model.busy && model.library.projects.first { $0.id == lockedTarget.id }?.ideaWorkspace == nil, "the detach did not finish cleanly")
        _ = beforeDetach
        model.controlMutating = true
        // The command's own writes pass.
        try AppModel.$me.withValue(.control("control-test")) { try model.setPinned(lockedTarget.isPinned, for: lockedTarget.id) }
        model.controlMutating = false
        model.error = nil
        precondition(model.library.projects.count == lockedSnapshot)
        try model.setPinned(lockedTarget.isPinned, for: lockedTarget.id)
        _ = lockedBefore
        print("PASS 1 write lock check: every GUI write entry point (including tag all, hiding a location and a badge colour) is refused while a command holds the slot and while a running app operation holds it; the holder itself and later clicks are not")
        // Two stage renames at once: the second, started while the first waits, is refused and nothing is lost.
        var interleaved: String?
        model.writePauseForTests = {
            let reply = await model.control(["id": "w", "action": "stage.rename", "params": ["board": "recordings", "from": "Writing", "to": "Draft"]])
            interleaved = (reply["error"] as? [String: Any])?["code"] as? String
        }
        _ = try await model.renameStageCore("Idea", to: "Pitch", on: .recordings)
        model.writePauseForTests = nil
        let configured = model.library.stages(for: .recordings)
        precondition(interleaved == "busy" && configured.contains("Pitch") && configured.contains("Writing") && !configured.contains("Draft") && !configured.contains("Idea"), "a second rename ran while the first waited: \(String(describing: interleaved)) \(configured)")
        // And the other way round: a click is refused while a command holds the slot, then works once it is released.
        model.controlMutating = true
        await retryRefusedAsync("rename during command") { _ = try await model.renameStageCore("Pitch", to: "Idea", on: .recordings) }
        model.controlMutating = false
        _ = try await model.renameStageCore("Pitch", to: "Idea", on: .recordings)
        precondition(model.library.stages(for: .recordings).contains("Idea") && model.writer == nil)
        print("PASS 1 single owner check: a second rename is refused while the first waits, and the slot is released afterwards")
        // A tag write holds the slot from its last check until the write is done: a hide or a rename started meanwhile is refused.
        let tagRec = model.library.projects.first { !$0.isPlanned }!
        try model.modifyProject(tagRec.id) { $0.stage = "Writing" }
        model.library.finderTags = true
        model.mountedLocations.insert(tagRec.location.key)
        let tagURL2 = URL(fileURLWithPath: tagRec.path)
        try FinderTags.write([], to: tagURL2)
        var midWrite: [String?] = []
        model.writePauseForTests = {
            await AppModel.$me.withValue(nil) {
                for (action, params) in [("location.set", ["key": tagRec.location.key, "hidden": true] as [String: Any]), ("stage.rename", ["board": "recordings", "from": "Writing", "to": "Cutting"])] {
                    let reply = await model.control(["id": "t", "action": action, "params": params])
                    midWrite.append((reply["error"] as? [String: Any])?["code"] as? String)
                }
            }
        }
        let written = await model.tagFolder(model.library.projects.first { $0.id == tagRec.id }!).value
        model.writePauseForTests = nil
        precondition(written == .applied && midWrite == ["busy", "busy"] && !model.hiddenLocations.contains(tagRec.location.key), "a hide or rename ran during the tag write: \(written) \(midWrite)")
        let namesAfterWrite = try FinderTags.read(tagURL2).map(\.name)
        precondition(namesAfterWrite == ["Writing"] && model.writer == nil, "the tag or the slot is wrong after the write")
        let after1 = await model.control(["id": "u", "action": "stage.rename", "params": ["board": "recordings", "from": "Writing", "to": "Cutting"]])
        let namesAfterRename = try FinderTags.read(tagURL2).map(\.name)
        precondition(after1["ok"] as? Bool == true && namesAfterRename == ["Cutting"], "the rename after the write did not retag: \(after1)")
        _ = await model.control(["id": "v", "action": "stage.rename", "params": ["board": "recordings", "from": "Cutting", "to": "Writing"]])
        print("PASS 1 tag write check: a hide or rename during a tag write is refused as busy, and a rename right after retags the folder")
        // Ambiguity messages name visible projects only; a hidden-only match is a refusal, not a list.
        func lookupCode(_ ref: String) -> (String?, String) {
            do { _ = try model.controlRecord(["project": ref]); return (nil, "") }
            catch let failure as ControlFailure { return (failure.code, failure.message) } catch { return ("other", "\(error)") }
        }
        func duplicate(_ name: String, at path: String) -> ProjectRecord {
            var record = ProjectRecord(planned: name, format: "Short", stage: "Writing")
            record.planned = false; record.path = path; record.name = name
            return record
        }
        let dupA = duplicate("Dup Name", at: model.runtime.root.appendingPathComponent("DupA/Dup Name").path)
        let dupB = duplicate("Dup Name", at: model.runtime.root.appendingPathComponent("DupB/Dup Name").path)
        let dupHidden = duplicate("Dup Name", at: "/Volumes/Hidden Drive/Dup Name")
        let dupBefore = model.library.projects
        model.library.projects += [dupA, dupB, dupHidden]
        model.hiddenLocations.insert(dupHidden.location.key)
        let mixed = lookupCode("Dup Name")
        precondition(mixed.0 == "ambiguous_project" && mixed.1.components(separatedBy: "; ").count == 2, "an ambiguity message named a hidden project: \(mixed)")
        model.library.projects = dupBefore + [dupHidden]
        let hiddenOnly = lookupCode("Dup Name")
        precondition(hiddenOnly.0 == "location_hidden" && !hiddenOnly.1.contains("Dup Name"), "a hidden-only match was listed: \(hiddenOnly)")
        model.library.projects = dupBefore + [dupA, dupHidden]
        precondition(lookupCode("Dup Name").0 == nil, "the one visible match should resolve")
        model.library.projects = dupBefore
        model.hiddenLocations.remove(dupHidden.location.key)
        print("PASS 1 hidden ambiguity check: only visible records are counted or named; a hidden-only match is location_hidden")
        // A window or prompt that an action would invalidate blocks it with form_in_use.
        let sheetTarget = model.library.projects.first { !$0.isPlanned }!
        let someTemplateRecord = model.library.templates.first!
        let sheetCases: [(String, () -> Void, () -> Void, String, [String: Any])] = [
            ("New Set prompt", { model.newSetPrompt = NewSetPrompt(mappingTemplateID: someTemplateRecord.id, name: "x") }, { model.newSetPrompt = nil }, "template.remove", ["template": someTemplateRecord.id.uuidString]),
            ("New Set prompt vs set", { model.newSetPrompt = NewSetPrompt(mappingTemplateID: nil, name: "x") }, { model.newSetPrompt = nil }, "set.rename", ["set": "x", "name": "y"]),
            ("Restore Icons prompt vs set", { model.restoreIconsPrompt = sheetTarget }, { model.restoreIconsPrompt = nil }, "set.unassign", ["set": "x", "format": "Short"]),
            ("Restore Icons prompt vs record", { model.restoreIconsPrompt = sheetTarget }, { model.restoreIconsPrompt = nil }, "project.relocate", ["project": sheetTarget.id.uuidString, "path": "/x"]),
            ("Create Workspace prompt vs template", { model.workspacePrompt = sheetTarget }, { model.workspacePrompt = nil }, "template.remove", ["template": "x"]),
            ("Create Workspace prompt vs record", { model.workspacePrompt = sheetTarget }, { model.workspacePrompt = nil }, "project.remove", ["project": sheetTarget.id.uuidString]),
            ("Bin confirmation", { model.binIdea = sheetTarget }, { model.binIdea = nil }, "project.remove", ["project": sheetTarget.id.uuidString]),
            ("old workspace review", { model.workspaceCleanup = sheetTarget }, { model.workspaceCleanup = nil }, "project.workspace-detach", ["project": sheetTarget.id.uuidString]),
            ("workspace browser", { model.workspaceToBrowse = sheetTarget }, { model.workspaceToBrowse = nil }, "project.remove", ["project": sheetTarget.id.uuidString]),
            ("discovery window", { model.discoveryPresented = true }, { model.discoveryPresented = false }, "location.remove", ["location": "x"]),
            ("discovery window vs register", { model.discoveryPresented = true }, { model.discoveryPresented = false }, "project.register", ["path": "/x"]),
            ("compatibility report", { model.compatibilityPresented = true }, { model.compatibilityPresented = false }, "project.remove", ["project": sheetTarget.id.uuidString]),
            ("template browser", { model.templateToBrowse = someTemplateRecord }, { model.templateToBrowse = nil }, "template.remove", ["template": "x"]),
            ("rename window vs record", { model.renamePrompt = sheetTarget }, { model.renamePrompt = nil }, "project.find-moved", ["project": sheetTarget.id.uuidString]),
        ]
        let sheetsBefore = try Data(contentsOf: model.store.file)
        for (name, open, close, action, params) in sheetCases {
            open()
            await expect(action, params, "form_in_use")
            let dry = await refusal(action, params.merging(["dryRun": true]) { $1 })
            precondition(dry != "form_in_use" || action == "location.remove" && false, "\(name): a dry run was refused")
            close()
        }
        let sheetsAfter = try Data(contentsOf: model.store.file) == sheetsBefore
        precondition(sheetsAfter)
        print("PASS 1 open window check: every window or prompt that an action would invalidate blocks it with form_in_use, dry runs excepted")
        // A dry-run compatibility check leaves the app's status text alone.
        let compatRoot = model.runtime.root.appendingPathComponent("CompatDry")
        try FileManager.default.createDirectory(at: compatRoot.appendingPathComponent("Out"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: compatRoot.appendingPathComponent("bad|name.txt"))
        model.status = "Previous GUI status"
        let dry = try await model.controlAction("compat.check", ["path": compatRoot.path, "copyTo": compatRoot.appendingPathComponent("Out").path, "dryRun": true])
        precondition(dry["dryRun"] as? Bool == true && model.status == "Previous GUI status" && !model.busy)
        print("PASS 1 compatibility dry-run check: no status or progress is published")
        // An idea's folder to show is its owned workspace; one without a workspace is refused, never called hidden.
        let bare = ProjectRecord(planned: "Reveal idea", format: "Short", stage: "Idea")
        try await model.commitDurably { $0.projects.append(bare) }
        do { _ = try await model.folderToShow(bare); preconditionFailure("an idea without a workspace was shown") } catch let failure as ControlFailure { precondition(failure.code == "invalid_params") }
        let withWorkspace: ProjectRecord = try await withCheckedThrowingContinuation { done in model.createWorkspace(for: bare, root: model.runtime.ideas, templateID: nil) { done.resume(with: $0) } }
        let shown = try await model.folderToShow(withWorkspace)
        precondition(shown.lastPathComponent == URL(fileURLWithPath: withWorkspace.ideaWorkspace!.path).lastPathComponent)
        print("PASS 1 idea workspace check: reveal and browsing resolve an idea's owned workspace")
    }
}
