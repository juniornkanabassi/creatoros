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
    }
}
