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
    }
}
