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
        while model.busy { await Task.yield() }
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
        while model.busy { await Task.yield() }
        precondition(model.created == nil && model.title.isEmpty && model.number == "004")
        print("PASS 1 sheet completion check: saved project remains visible; Next Project resets only the form; background creation still resets if a sheet opens during its copy")
        var idea = ProjectRecord(planned: "Promoted idea", format: "Short", stage: "Idea", campaign: "Kept")
        idea.notes = "Kept notes"
        try await model.commitDurably { $0.projects.append(idea) }
        model.startPlanned(idea)
        await model.refreshTask?.value
        precondition(model.startingFrom == idea.id && model.newProjectPresented)
        let promoted: ProjectRecord = try await withCheckedThrowingContinuation { done in model.create { done.resume(with: $0) } }
        while model.busy { await Task.yield() }
        precondition(model.newProjectPresented && model.created?.path == promoted.path && model.startingFrom == nil)
        precondition(promoted.id == idea.id && !promoted.isPlanned && promoted.notes == "Kept notes" && promoted.campaign == "Kept")
        precondition(model.library.projects.filter { $0.id == idea.id }.count == 1 && model.workspaceCleanup == nil)
        model.nextProject()
        model.title = "After idea"; model.fieldChanged()
        await model.refreshTask?.value
        let ordinary: ProjectRecord = try await withCheckedThrowingContinuation { done in model.create { done.resume(with: $0) } }
        while model.busy { await Task.yield() }
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
        model.busy = true
        let pinned = await refusal("project.pin", ["project": target.id.uuidString]); precondition(pinned != "form_in_use" && pinned != "busy" || pinned == "busy")
        await expect("project.icons-strip", ["project": target.id.uuidString], "busy")
        model.busy = false
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
        model.busy = true
        let refused1 = await controlCode("field.add", ["name": "During GUI copy"]); precondition(refused1 == "busy")
        let refused2 = await controlCode("set.create", ["name": "During GUI copy"]); precondition(refused2 == "busy")
        let refused3 = await controlCode("settings.finder-tags", ["enabled": true]); precondition(refused3 == "busy")
        model.busy = false
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
