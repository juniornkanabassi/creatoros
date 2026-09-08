import Foundation
import TemplateCore

@main struct DurableSaveCheck {
    @MainActor static func main() async throws {
        let model = AppModel()
        precondition(model.storeUsable)
        try await model.commitDurably {
            $0.projects.append(ProjectRecord(planned: "Saved idea", format: "Short", stage: "Idea"))
        }
        let loaded = try model.store.load()
        precondition(model.storeUsable && loaded.projects.count == 1)
        let old = model.library.projects.map(\.id)
        do {
            try await model.commitDurably { _ in throw AppFailure("invalid input") }
            fatalError("invalid input accepted")
        } catch { precondition(model.storeUsable) }
        do {
            try await model.commitDurably { $0.presets[0].destination = "/" }
            fatalError("invalid destination accepted")
        } catch { precondition(model.storeUsable) }
        let bytes = try Data(contentsOf: model.store.file)
        let backup = model.store.root.appendingPathComponent("saved-library.json")
        try FileManager.default.moveItem(at: model.store.file, to: backup)
        try FileManager.default.createDirectory(at: model.store.file, withIntermediateDirectories: false)
        do {
            try await model.commitDurably { $0.projects.removeAll() }
            fatalError("blocked save accepted")
        } catch { precondition(!model.storeUsable) }
        precondition(model.library.projects.map(\.id) == old)
        let retained = try Data(contentsOf: backup)
        precondition(retained == bytes)
        do {
            try model.mutate { $0.projects.removeAll() }
            fatalError("mutation accepted after save failure")
        } catch {}
        // Restore this disposable store, then replace its file after a fresh model has loaded it.
        try FileManager.default.removeItem(at: model.store.file)
        try FileManager.default.moveItem(at: backup, to: model.store.file)
        let symlinkModel = AppModel()
        precondition(symlinkModel.storeUsable)
        let external = model.store.root.deletingLastPathComponent().appendingPathComponent("outside-library.json")
        try bytes.write(to: external)
        try FileManager.default.moveItem(at: model.store.file, to: backup)
        try FileManager.default.createSymbolicLink(at: model.store.file, withDestinationURL: external)
        do {
            try await symlinkModel.commitDurably { $0.projects.removeAll() }
            fatalError("symlink store accepted")
        } catch { precondition(!symlinkModel.storeUsable) }
        precondition(symlinkModel.library.projects.map(\.id) == old)
        let externalBytes = try Data(contentsOf: external)
        precondition(externalBytes == bytes)
        do {
            try symlinkModel.mutate { $0.projects.removeAll() }
            fatalError("mutation accepted after symlink failure")
        } catch {}
        print("PASS durable save: success persists; invalid input stays usable; storage failure and symlink replacement retain state and lock changes; external bytes unchanged")
    }
}
