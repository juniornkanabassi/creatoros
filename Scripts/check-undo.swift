import Foundation
import AppKit
import SwiftUI
import TemplateCore

private final class InvisibleKeyWindow: NSWindow {
    var simulatedKey = false
    var scopedUndoManager: UndoManager?
    override var isKeyWindow: Bool { simulatedKey }
    override var undoManager: UndoManager? { scopedUndoManager }
}

@main struct UndoChecks {
    @MainActor static func main() async throws {
        let model = AppModel()
        defer { model.runtime.removeDisposablePreferences() }
        precondition(model.runtime.ownsDisposablePreferences && model.storeUsable)
        let manager = UndoManager()
        manager.groupsByEvent = false
        model.undoManager = manager
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            let result = try condition()
            precondition(result, label)
            checks += 1
            print("PASS undo: \(label)")
        }
        func event(_ change: () -> Void) {
            manager.beginUndoGrouping(); change(); manager.endUndoGrouping()
        }
        func encoded(_ record: ProjectRecord) throws -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            return try encoder.encode(record)
        }
        func settle() async {
            for task in model.tagTasks.values { _ = await task.value }
            await model.saveTaskForWorkspace()
        }
        let firstWindowManager = UndoManager(), secondWindowManager = UndoManager()
        let firstWindow = InvisibleKeyWindow(contentRect: CGRect(x: -100_000, y: -100_000, width: 240, height: 160), styleMask: .borderless, backing: .buffered, defer: false)
        let secondWindow = InvisibleKeyWindow(contentRect: CGRect(x: -100_000, y: -100_000, width: 240, height: 160), styleMask: .borderless, backing: .buffered, defer: false)
        firstWindow.isReleasedWhenClosed = false; secondWindow.isReleasedWhenClosed = false
        firstWindow.scopedUndoManager = firstWindowManager; secondWindow.scopedUndoManager = secondWindowManager
        defer { firstWindow.close(); secondWindow.close() }
        firstWindow.simulatedKey = true
        firstWindow.contentView = NSHostingView(rootView: Text("First").modifier(UndoContext()).environmentObject(model))
        firstWindow.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        try check(model.undoManager === firstWindowManager, "UndoContext binds the first invisible window's manager")
        firstWindow.simulatedKey = false; secondWindow.simulatedKey = true
        secondWindow.contentView = NSHostingView(rootView: Text("Second").modifier(UndoContext()).environmentObject(model))
        secondWindow.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        try check(model.undoManager === secondWindowManager, "UndoContext switches to the second invisible window's manager")
        secondWindow.simulatedKey = false; firstWindow.simulatedKey = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: firstWindow)
        try check(model.undoManager === firstWindowManager && !firstWindow.isVisible && !secondWindow.isVisible,
                  "UndoContext restores the first manager on its key notification without displaying either window")
        model.undoManager = manager
        let folder = model.runtime.root.appendingPathComponent("001 — Short — Keep metadata")
        let secondFolder = model.runtime.root.appendingPathComponent("002 — Short — Other project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        var record = try ProjectRecord(url: folder, format: "Short")
        record.stage = "Writing"; record.campaign = "Campaign"; record.notes = "Do not lose this"
        record.editor = "Editor"; record.series = ["Series"]; record.pinned = true
        record.previousPaths = [model.runtime.root.appendingPathComponent("Old location").path]
        var second = try ProjectRecord(url: secondFolder, format: "Short"); second.stage = "Writing"
        try await model.commitDurably { $0.projects = [record, second]; $0.finderTags = true }
        try FinderTags.write([.init(name: "Client", colour: .red)], to: folder)
        let original = try encoded(record)
        model.selectedProject = record.id
        event { model.removeProject(record.id) }
        await settle()
        try check(manager.undoActionName == "Remove from List" && model.library.projects.count == 1, "GUI removal has a named undo step")
        try check(FileManager.default.fileExists(atPath: folder.path), "removal never touches the project folder")
        let unrelated = ProjectRecord(planned: "New unrelated idea", format: "Short", stage: "Idea")
        try model.mutate { $0.projects.append(unrelated) }
        let otherWindowManager = UndoManager()
        model.undoManager = otherWindowManager
        manager.undo(); await settle()
        try check(manager.canRedo && !otherWindowManager.canUndo, "redo stays with the originating window after the active manager changes")
        model.undoManager = manager
        try check(try encoded(model.library.projects.first { $0.id == record.id }!) == original, "undo restores every stored metadata field")
        try check(model.library.projects.contains { $0.id == unrelated.id }, "undo preserves records added after removal")
        manager.redo(); await settle()
        try check(!model.library.projects.contains { $0.id == record.id } && model.library.projects.contains { $0.id == unrelated.id }, "redo removes only the original record")
        manager.undo(); await settle()
        try model.modifyProject(record.id) { $0.notes = "Changed by another caller" }
        manager.redo(); await settle()
        try check(model.library.projects.first { $0.id == record.id }?.notes == "Changed by another caller" && model.error?.contains("changed") == true, "redo refuses a record changed by another caller")
        manager.removeAllActions(); model.error = nil

        event { model.setStage("Editing", for: record.id) }; await settle()
        try check(model.library.projects.first { $0.id == record.id }?.stage == "Editing" && manager.canUndo, "GUI stage move registers undo")
        manager.undo(); await settle()
        try check(model.library.projects.first { $0.id == record.id }?.stage == "Writing", "undo restores the previous stage")
        try check(try FinderTags.read(folder).contains { $0.name == "Writing" } && FinderTags.read(folder).contains { $0.name == "Client" }, "stage undo updates Finder stage tag and preserves unrelated tags")
        manager.redo(); await settle()
        try check(model.library.projects.first { $0.id == record.id }?.stage == "Editing", "redo reapplies the stage")
        manager.removeAllActions()
        try FinderTags.write([.init(name: "Client", colour: .red)], to: folder)
        event { model.setStage("Editing", for: record.id) }; await settle()
        try check(manager.undoActionName.isEmpty, "reselecting the same stage registers no named undo action")
        try check(FinderTags.stage(of: folder, knownStages: model.library.allStages) == "Editing",
                  "reselecting the same stage still repairs its Finder tag")
        manager.removeAllActions() // UndoManager keeps even an explicitly empty test group.
        _ = try model.moveToStage("Editing", for: second.id); await settle()
        try check(!manager.canUndo, "CLI stage API does not pollute GUI undo history")
        event { model.moveAll(from: "Editing", to: "Published") }; await settle()
        manager.undo(); await settle()
        try check(model.library.projects.filter { [record.id, second.id].contains($0.id) }.allSatisfy { $0.stage == "Editing" }, "bulk move undo restores both cards")
        manager.redo(); await settle()
        try model.modifyProject(second.id) { $0.notes = "Concurrent note" }
        manager.undo(); await settle()
        try check(model.library.projects.filter { [record.id, second.id].contains($0.id) }.allSatisfy { $0.stage == "Published" }, "one changed card refuses the whole bulk inverse without partial changes")
        manager.removeAllActions(); model.error = nil
        event { model.setStage("Editing", for: record.id) }; await settle()
        let owner = try model.acquireWriter()
        manager.undo()
        try check(model.library.projects.first { $0.id == record.id }?.stage == "Editing" && model.canRetryUndo, "busy undo keeps a pending retry without changing the stage")
        try check(!manager.canUndo && !manager.canRedo, "native undo entry is consumed while the exact pending inverse is retained")
        model.retryUndo()
        try check(model.canRetryUndo && model.library.projects.first { $0.id == record.id }?.stage == "Editing", "retry while still busy changes nothing and retains recovery")
        model.releaseWriter(owner)
        model.retryUndo(); await settle()
        try check(!model.canRetryUndo && manager.canRedo && model.library.projects.first { $0.id == record.id }?.stage == "Published", "idle retry applies stage undo and produces native redo")
        manager.redo(); await settle()
        manager.removeAllActions(); model.error = nil

        let beforeBusyRemoval = try encoded(model.library.projects.first { $0.id == record.id }!)
        event { model.removeProject(record.id) }; await settle()
        let removalOwner = try model.acquireWriter()
        manager.undo(); model.retryUndo()
        try check(model.canRetryUndo && !model.library.projects.contains { $0.id == record.id }, "busy removal undo and retry preserve pending metadata recovery")
        model.releaseWriter(removalOwner)
        let later = try model.addIdeaRecord(title: "Later unrelated", format: "Short", campaign: "", notes: "Keep")
        model.retryUndo(); await settle()
        try check(try encoded(model.library.projects.first { $0.id == record.id }!) == beforeBusyRemoval
                  && model.library.projects.contains { $0.id == later.id } && manager.canRedo,
                  "removal retry restores exact metadata and preserves a later unrelated write")
        manager.redo(); await settle()
        try check(!model.library.projects.contains { $0.id == record.id } && model.library.projects.contains { $0.id == later.id }, "native redo after removal retry affects only its record")
        manager.undo(); await settle()
        manager.removeAllActions()
        event { model.removeProject(record.id) }; await settle()
        manager.undo(); await settle()
        let redoOwner = try model.acquireWriter(); manager.redo(); model.releaseWriter(redoOwner)
        try check(model.library.projects.contains { $0.id == record.id } && !model.canRetryUndo
                  && model.error?.contains("Cannot redo") == true,
                  "busy redo preserves restored data and never offers an inverted Undo retry")
        manager.removeAllActions(); model.error = nil

        let eventManager = UndoManager()
        eventManager.groupsByEvent = true; model.undoManager = eventManager
        eventManager.beginUndoGrouping(); model.removeProject(record.id); eventManager.endUndoGrouping()
        await settle()
        let eventOwner = try model.acquireWriter(); eventManager.undo(); model.releaseWriter(eventOwner)
        eventManager.beginUndoGrouping()
        eventManager.registerUndo(withTarget: model) { $0.status = "Unrelated event was undone" }
        model.retryUndo()
        try check(model.canRetryUndo && !model.library.projects.contains { $0.id == record.id }, "retry preserves an active native event group")
        eventManager.endUndoGrouping()
        // Let AppKit close its automatic outer group, rather than manually ending its scheduled event group.
        for _ in 0..<20 where eventManager.groupingLevel > 0 { try await Task.sleep(for: .milliseconds(25)) }
        try check(eventManager.groupingLevel == 0, "native event grouping ends naturally before a retry")
        model.retryUndo(); await settle()
        try check(model.library.projects.contains { $0.id == record.id } && eventManager.canRedo,
                  "groupsByEvent retry restores the record with native redo after the event ends")
        eventManager.redo(); await settle()
        try check(!model.library.projects.contains { $0.id == record.id }, "groupsByEvent redo reapplies the removal")
        eventManager.undo(); await settle()
        eventManager.undo()
        try check(model.status == "Unrelated event was undone", "retry did not consume an unrelated event-group action")
        eventManager.removeAllActions(); model.undoManager = manager; model.error = nil

        let firstMetadata = try encoded(model.library.projects.first { $0.id == record.id }!)
        let secondMetadata = try encoded(model.library.projects.first { $0.id == second.id }!)
        event { model.removeProject(record.id) }
        event { model.removeProject(second.id) }
        await settle()
        let queueOwner = try model.acquireWriter()
        manager.undo(); manager.undo(); model.releaseWriter(queueOwner)
        try check(model.pendingUndos.count == 2 && model.error?.contains("2 undo steps") == true,
                  "two busy undo attempts retain both popped actions in order")
        let queuedLater = try model.addIdeaRecord(title: "Added while undo waits", format: "Short", campaign: "", notes: "Keep")
        model.retryUndo(); await settle()
        try check(!model.canRetryUndo && (try encoded(model.library.projects.first { $0.id == record.id }!)) == firstMetadata
                  && (try encoded(model.library.projects.first { $0.id == second.id }!)) == secondMetadata
                  && model.library.projects.contains { $0.id == queuedLater.id },
                  "one queued retry restores both records exactly and preserves later unrelated work")
        manager.redo(); await settle()
        try check(!model.library.projects.contains { [record.id, second.id].contains($0.id) }
                  && model.library.projects.contains { $0.id == queuedLater.id }, "one native redo reapplies every recovered removal")
        manager.undo(); await settle()
        try check(model.library.projects.contains { $0.id == record.id } && model.library.projects.contains { $0.id == second.id },
                  "one native undo restores the whole recovered removal group again")
        manager.removeAllActions(); model.error = nil

        event { model.removeProject(record.id) }; event { model.removeProject(second.id) }; await settle()
        let conflictOwner = try model.acquireWriter(); manager.undo(); manager.undo(); model.releaseWriter(conflictOwner)
        var competing = second; competing.notes = "Re-added by another caller"
        try model.mutate { $0.projects.append(competing) }
        model.retryUndo(); await settle()
        try check(model.library.projects.first { $0.id == second.id }?.notes == competing.notes
                  && model.library.projects.contains { $0.id == record.id } && model.error?.contains("could not be recovered") == true,
                  "a conflicted queued retry reports partial recovery without overwriting the competing record")
        manager.redo(); await settle()
        try check(!model.library.projects.contains { $0.id == record.id }
                  && model.library.projects.first { $0.id == second.id }?.notes == competing.notes,
                  "partial recovery still retains redo for its successful inverse")
        manager.undo(); await settle()
        manager.removeAllActions(); model.error = nil

        _ = try model.moveToStage("Writing", for: record.id); await settle()
        event { model.setStage("Editing", for: record.id) }; await settle()
        event { model.setStage("Published", for: record.id) }; await settle()
        let overlappingOwner = try model.acquireWriter(); manager.undo(); manager.undo(); model.releaseWriter(overlappingOwner)
        model.retryUndo(); await settle()
        try check(model.library.projects.first { $0.id == record.id }?.stage == "Writing", "queued overlapping stage moves replay in original undo order")
        manager.redo(); await settle()
        try check(model.library.projects.first { $0.id == record.id }?.stage == "Published", "one redo reapplies every overlapping stage move in forward order")
        manager.undo(); await settle()
        manager.removeAllActions(); model.error = nil

        let otherManager = UndoManager(); otherManager.groupsByEvent = false
        event { model.removeProject(record.id) }
        model.undoManager = otherManager
        otherManager.beginUndoGrouping(); model.removeProject(second.id); otherManager.endUndoGrouping()
        await settle()
        let mixedOwner = try model.acquireWriter(); manager.undo(); otherManager.undo(); model.releaseWriter(mixedOwner)
        model.retryUndo(); await settle()
        try check(model.library.projects.contains { $0.id == record.id } && model.library.projects.contains { $0.id == second.id }
                  && manager.canRedo && otherManager.canRedo, "mixed-window retry restores both records and preserves both originating redo stacks")
        manager.redo(); await settle()
        try check(!model.library.projects.contains { $0.id == record.id } && model.library.projects.contains { $0.id == second.id },
                  "first window redo affects only its own recovered action")
        manager.undo(); await settle()
        otherManager.redo(); await settle()
        try check(model.library.projects.contains { $0.id == record.id } && !model.library.projects.contains { $0.id == second.id },
                  "second window redo affects only its own recovered action")
        otherManager.undo(); await settle()
        manager.removeAllActions(); otherManager.removeAllActions(); model.undoManager = manager; model.error = nil

        _ = try model.moveToStage("Published", for: record.id); await settle()
        event { model.setStage("Writing", for: record.id) }; await settle()
        let dismissalOwner = try model.acquireWriter(); manager.undo(); model.releaseWriter(dismissalOwner)
        model.error = nil
        try check(!model.canRetryUndo, "dismissing the recovery message clears the pending action")
        manager.removeAllActions()
        event { model.setStage("Editing", for: record.id) }; await settle()
        let errorOwner = try model.acquireWriter(); manager.undo(); model.releaseWriter(errorOwner)
        model.error = "A different error"
        try check(!model.canRetryUndo, "a new unrelated error clears the pending action")
        manager.removeAllActions(); model.error = nil

        let field = try model.addField("Sponsor"), retained = try model.addField("Episode")
        model.draft.extraValues[field.id] = "Original sponsor"
        model.draft.extraValues[retained.id] = "Keep episode"
        event { model.removeCustomField(field.id) }; await settle()
        let added = try model.addField("Later field")
        manager.undo(); await settle()
        try check(model.library.fieldList.contains(field) && model.library.fieldList.contains(added), "field undo restores only its field and keeps later fields")
        try check(model.draft.extraValues[field.id] == "Original sponsor" && model.draft.extraValues[retained.id] == "Keep episode", "field undo restores its draft value without replacing other values")
        manager.redo(); await settle()
        try check(!model.library.fieldList.contains(field) && model.library.fieldList.contains(added), "field redo keeps unrelated definitions")
        manager.undo(); await settle()
        var changedField = field; changedField.name = "Changed sponsor"
        try model.replaceField(changedField)
        manager.redo(); await settle()
        try check(model.library.fieldList.contains(changedField), "field redo refuses a renamed field")
        manager.removeAllActions(); model.error = nil

        let draftField = try model.addField("Draft field")
        model.draft.extraValues[draftField.id] = "Old project answer"
        event { model.removeCustomField(draftField.id) }; await settle()
        model.nextProject(); model.draft.title = "New project"; model.draft.extraValues[retained.id] = "New answer"
        manager.undo(); await settle()
        try check(model.library.fieldList.contains(draftField) && model.draft.title == "New project"
                  && model.draft.extraValues[draftField.id] == nil && model.draft.extraValues[retained.id] == "New answer",
                  "field undo after Next Project restores its definition without reviving old form answers")
        manager.redo(); await settle()
        try check(!model.library.fieldList.contains(draftField) && model.draft.title == "New project", "field redo uses the actual restored empty value")
        manager.removeAllActions(); model.error = nil

        let oldStages = model.library.stageList
        event { model.setStages(oldStages.filter { $0 != "Editing" }) }; await settle()
        manager.undo(); await settle()
        try check(model.library.stageList == oldStages && model.library.projects.contains { $0.id == unrelated.id }, "stage-list undo restores its list without replacing records")
        manager.redo(); await settle()
        try model.applyStages(model.library.stageList + ["External stage"])
        manager.undo(); await settle()
        try check(model.library.stageList.contains("External stage") && !model.library.stageList.contains("Editing"), "stage-list undo refuses a later configuration change")
        manager.removeAllActions(); model.error = nil

        _ = try model.moveToStage("Writing", for: record.id); await settle()
        manager.beginUndoGrouping()
        try await model.renameStage("Writing", to: "Drafting", on: .recordings)
        manager.endUndoGrouping(); await settle()
        try check(manager.undoActionName == "Rename Stage" && model.library.stageList.contains("Drafting") && !model.library.stageList.contains("Writing")
                  && model.library.projects.first { $0.id == record.id }?.stage == "Drafting", "stage rename registers one named undo step")
        manager.undo(); await settle()
        try check(model.library.stageList.contains("Writing") && !model.library.stageList.contains("Drafting")
                  && model.library.projects.first { $0.id == record.id }?.stage == "Writing", "undo restores the old stage name on the list and its cards")
        try check(try FinderTags.read(folder).contains { $0.name == "Writing" } && !FinderTags.read(folder).contains { $0.name == "Drafting" }, "stage rename undo puts the old Finder tag back")
        manager.redo(); await settle()
        try check(model.library.stageList.contains("Drafting") && model.library.projects.first { $0.id == record.id }?.stage == "Drafting", "redo applies the rename again")
        manager.undo(); await settle()
        manager.removeAllActions(); model.error = nil

        let savedLocation = try CatalogueLocation(url: model.runtime.root)
        try model.mutate { $0.locations = [savedLocation] }
        event { model.removeLocation(savedLocation) }; await settle()
        try check(manager.undoActionName == "Forget Location" && (model.library.locations ?? []).isEmpty, "forgetting a saved location registers a named undo step")
        manager.undo(); await settle()
        try check(model.library.locations?.map(\.id) == [savedLocation.id], "undo restores the forgotten location")
        manager.redo(); await settle()
        try check((model.library.locations ?? []).isEmpty, "redo forgets the location again")
        manager.undo(); await settle()
        manager.removeAllActions(); model.error = nil

        let presetIndex = model.library.presets.firstIndex { $0.format == model.format }!
        let gone = model.runtime.root.appendingPathComponent("Destination that goes away")
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        let goneBookmark = try gone.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        try model.mutate { $0.presets[presetIndex].destinationBookmark = goneBookmark }
        try FileManager.default.removeItem(at: gone)
        model.changeFormat()
        try check(model.error?.contains("Destination is unavailable") == true && model.errorAction?.title == "Choose…", "the unavailable destination error offers Choose…")
        model.error = nil
        try check(model.errorAction == nil, "clearing the error clears its action")
        try model.mutate { $0.presets[presetIndex].destinationBookmark = nil }
        model.changeFormat(); model.error = nil
        model.undoManager = nil
        model.setStage("Writing", for: record.id); await settle()
        try check(model.library.projects.first { $0.id == record.id }?.stage == "Writing" && !manager.canUndo, "missing UndoManager preserves normal operation without creating history")
        try check(try model.store.load().projects.first { $0.id == record.id }?.stage == "Writing", "undo operations persist through the existing durable-save path")
        print("RESULT \(checks) undo checks passed")
    }
}
