import Foundation
import AppKit
import SwiftUI
import TemplateCore

/// User edits keep small, conditional inverses. Replaying never restores a whole library over newer work.
extension AppModel {
    final class PendingUndo {
        let name: String
        weak var manager: UndoManager?
        let action: @MainActor (AppModel, UndoManager) throws -> Void
        var message: String { "Cannot undo \(name.lowercased()) while another change is in progress. Use Retry Undo when it finishes." }
        init(name: String, manager: UndoManager, action: @escaping @MainActor (AppModel, UndoManager) throws -> Void) {
            self.name = name; self.manager = manager; self.action = action
        }
    }
    var canRetryUndo: Bool { pendingUndos.contains { $0.manager != nil } }
    var pendingUndoMessage: String? {
        guard let first = pendingUndos.first else { return nil }
        return first.message + (pendingUndos.count > 1 ? " \(pendingUndos.count) undo steps are waiting." : "")
    }
    private func reportUndoError(_ message: String) {
        reportingUndoError = true
        let count = pendingUndos.count
        error = message + (canRetryUndo ? " \(count) other undo \(count == 1 ? "step is" : "steps are") waiting. Use Retry Undo to continue." : "")
        reportingUndoError = false
    }
    private final class UndoRecoveryResult {
        var recovered = 0
        var failures: [String] = []
    }

    /// Recover each window's rejected actions as one group, so a later retry cannot erase an earlier redo.
    func retryUndo() {
        var groups: [(manager: UndoManager, entries: [PendingUndo])] = []
        for pending in pendingUndos {
            guard let manager = pending.manager else { continue }
            if let index = groups.firstIndex(where: { $0.manager === manager }) { groups[index].entries.append(pending) }
            else { groups.append((manager, [pending])) }
        }
        guard !groups.isEmpty else { reportUndoError("The original window is closed, so its undo history cannot be recovered."); return }
        // Never let undo() close an active event group containing somebody else's edit.
        guard !writeLocked && !busy && groups.allSatisfy({ $0.manager.groupingLevel == 0 && $0.manager.isUndoRegistrationEnabled
            && !$0.manager.isUndoing && !$0.manager.isRedoing }) else {
            error = pendingUndoMessage; return
        }
        pendingUndos.removeAll { $0.manager != nil }
        error = pendingUndoMessage
        let result = UndoRecoveryResult()
        for group in groups {
            group.manager.beginUndoGrouping()
            // NSUndoManager plays a group backwards; register backwards to recover in original pop order.
            for pending in group.entries.reversed() {
                registerUndo(pending.name, manager: group.manager, recovery: result, action: pending.action)
            }
            group.manager.endUndoGrouping()
            group.manager.undo()
        }
        let recovered = "\(result.recovered) change\(result.recovered == 1 ? "" : "s")"
        if !result.failures.isEmpty {
            reportUndoError("Recovered \(recovered). \(result.failures.count) could not be recovered. \(result.failures[0])")
        } else if !pendingUndos.isEmpty {
            reportUndoError("Recovered \(recovered). Some undo steps could not be retried.")
        }
    }

    private func registerUndo(_ name: String, manager: UndoManager?, recovery: UndoRecoveryResult? = nil,
                              action: @escaping @MainActor (AppModel, UndoManager) throws -> Void) {
        guard let manager else { return }
        manager.registerUndo(withTarget: self) { [weak manager] model in
            MainActor.assumeIsolated {
                guard let manager else { return }
                if model.writeLocked || model.busy {
                    guard !manager.isRedoing else {
                        model.reportUndoError("Cannot redo \(name.lowercased()) while another change is in progress. Nothing changed. Repeat the change when it finishes.")
                        return
                    }
                    let pending = PendingUndo(name: name, manager: manager, action: action)
                    // One entry per native action actually popped, in that same order; no background queue growth.
                    model.pendingUndos.append(pending)
                    model.error = model.pendingUndoMessage
                    return
                }
                do { try action(model, manager); recovery?.recovered += 1 }
                catch {
                    if let recovery { recovery.failures.append(error.localizedDescription) }
                    else { model.reportUndoError(error.localizedDescription) }
                }
            }
        }
        manager.setActionName(name)
    }

    private func sameRecord(_ first: ProjectRecord, _ second: ProjectRecord) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(first) == encoder.encode(second)
    }

    func registerProjectUndo(_ record: ProjectRecord, index: Int, restoring: Bool, manager: UndoManager?) {
        registerUndo("Remove from List", manager: manager) { model, manager in
            try model.mutate { library in
                if restoring {
                    let path = URL(fileURLWithPath: record.path)
                    guard !library.projects.contains(where: {
                        let currentPath = URL(fileURLWithPath: $0.path)
                        return $0.id == record.id || (!record.isPlanned && AppRuntime.contains(path, currentPath) && AppRuntime.contains(currentPath, path))
                    }) else {
                        throw AppFailure("Cannot undo this removal because the project has been added again. No records were changed.")
                    }
                    library.projects.insert(record, at: min(index, library.projects.count))
                } else {
                    guard let current = library.projects.first(where: { $0.id == record.id }), try model.sameRecord(current, record) else {
                        throw AppFailure("Cannot redo this removal because the project has changed. No records were changed.")
                    }
                    library.projects.removeAll { $0.id == record.id }
                }
            }
            if !restoring {
                if model.selectedProject == record.id { model.selectedProject = nil }
                if model.pipelineSelection == record.id { model.pipelineSelection = nil }
            }
            model.registerProjectUndo(record, index: index, restoring: !restoring, manager: manager)
        }
    }

    func registerStageUndo(before: [ProjectRecord], after: [ProjectRecord], manager: UndoManager?) {
        let name = before.count == 1 ? "Move Project" : "Move Projects"
        registerUndo(name, manager: manager) { model, manager in
            try model.mutate { library in
                for expected in after {
                    guard let current = library.projects.first(where: { $0.id == expected.id }), try model.sameRecord(current, expected) else {
                        throw AppFailure("Cannot undo this stage move because a project has changed. No stages were changed.")
                    }
                }
                for record in before {
                    guard let index = library.projects.firstIndex(where: { $0.id == record.id }) else {
                        throw AppFailure("Cannot undo this stage move because a project is no longer in the list.")
                    }
                    library.projects[index].stage = record.stage
                }
            }
            for record in before { model.tagFolder(record) }
            model.registerStageUndo(before: after, after: before, manager: manager)
        }
    }

    func registerFieldUndo(_ field: CustomField, index: Int, value: String?, expectedDraft: ProjectDraft, restoring: Bool, manager: UndoManager?) {
        registerUndo("Remove Field", manager: manager) { model, manager in
            // Restoring a definition is safe after Next Project; reviving an old answer in that new form is not.
            let restoredValue = restoring && model.draft == expectedDraft ? value : nil
            try model.mutate { library in
                var fields = library.fieldList
                if restoring {
                    guard !fields.contains(where: { $0.id == field.id }), model.draft.extraValues[field.id] == nil else {
                        throw AppFailure("Cannot undo this field removal because the field has changed. No fields were changed.")
                    }
                    _ = try Configuration.fieldName(field.name, others: fields.map(\.name))
                    fields.insert(field, at: min(index, fields.count))
                } else {
                    guard fields.first(where: { $0.id == field.id }) == field, model.draft.extraValues[field.id] == value else {
                        throw AppFailure("Cannot redo this field removal because the field has changed. No fields were changed.")
                    }
                    fields.removeAll { $0.id == field.id }
                }
                library.customFields = fields
            }
            model.draft.extraValues[field.id] = restoredValue
            model.refresh()
            model.registerFieldUndo(field, index: index, value: restoring ? restoredValue : value,
                                    expectedDraft: model.draft, restoring: !restoring, manager: manager)
        }
    }

    /// Undo renames `new` back to `old`, with the records, colour and Finder tags that went with it. Redo does the reverse.
    func registerStageRenameUndo(old: String, new: String, kind: PipelineKind, manager: UndoManager?) {
        registerUndo("Rename Stage", manager: manager) { model, manager in
            let stages = model.library.stages(for: kind)
            guard let index = stages.firstIndex(of: new), !stages.contains(old) else {
                throw AppFailure("Cannot undo this stage rename because the stages have changed again. No stages were changed.")
            }
            var renamed = stages; renamed[index] = old
            let checked = try Configuration.stages(renamed)
            let ids = Set(model.library.projects.filter { kind.includes(format: $0.format) && $0.stage == new }.map(\.id))
            try model.mutate { model.applyRename(&$0, from: new, to: old, checked: checked, on: kind) }
            model.startedRename(from: new, to: old, on: kind, ids: ids)
            model.registerStageRenameUndo(old: new, new: old, kind: kind, manager: manager)
        }
    }

    func registerLocationUndo(_ location: CatalogueLocation, index: Int, restoring: Bool, manager: UndoManager?) {
        registerUndo("Forget Location", manager: manager) { model, manager in
            try model.mutate { library in
                var locations = library.locations ?? []
                let saved = locations.contains { $0.id == location.id }
                guard saved != restoring else {
                    throw AppFailure("Cannot \(restoring ? "undo" : "redo") forgetting this location because the saved locations have changed. No locations were changed.")
                }
                if restoring { locations.insert(location, at: min(index, locations.count)) }
                else { locations.removeAll { $0.id == location.id } }
                library.locations = locations
            }
            model.registerLocationUndo(location, index: index, restoring: !restoring, manager: manager)
        }
    }

    func registerStageListUndo(before: [String], after: [String], kind: PipelineKind, manager: UndoManager?) {
        registerUndo("Change Stages", manager: manager) { model, manager in
            guard model.library.stages(for: kind) == after else {
                throw AppFailure("Cannot undo this stage list change because the stages have changed again. No stages were changed.")
            }
            try model.applyStages(before, for: kind)
            model.registerStageListUndo(before: after, after: before, kind: kind, manager: manager)
        }
    }
}

/// Each window supplies its own undo stack when it becomes key; native text-field undo stays with AppKit.
struct UndoContext: ViewModifier {
    @Environment(\.undoManager) private var manager
    @EnvironmentObject private var model: AppModel
    func body(content: Content) -> some View {
        content.background(UndoWindowContext(model: model, manager: manager))
    }
}

private struct UndoWindowContext: NSViewRepresentable {
    let model: AppModel
    let manager: UndoManager?
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.model = model
        view.manager = manager
        view.bindIfKey()
    }
    final class Probe: NSView {
        weak var model: AppModel?
        weak var manager: UndoManager?
        private var observer: NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.bindIfKey() }
            }
            bindIfKey()
        }
        func bindIfKey() {
            guard let window, window.isKeyWindow else { return }
            model?.undoManager = manager ?? window.undoManager
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
