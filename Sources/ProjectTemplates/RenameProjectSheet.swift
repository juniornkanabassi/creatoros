import SwiftUI
import AppKit
import TemplateCore

extension AppModel {
    static func runningAdobeApps() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier?.lowercased(), ["premiere", "aftereffects", "photoshop", "audition"].contains(where: { id.contains($0) }) else { return nil }
            return app.localizedName ?? id
        }.sorted()
    }
    func requestRename(_ record: ProjectRecord) {
        attempt {
            guard !busy else { throw AppFailure("Wait for the current operation to finish.") }
            guard ProjectRename.fields(of: record) != nil else { throw AppFailure("Rename needs Number — Format — [Campaign — ]Title. Planned ideas have no folder to rename.") }
            _ = try projectFolderForAction(record)
            renamePrompt = record
        }
    }
    func renamePlan(for id: UUID, number: String, campaign: String, title: String, updateHeadings: Bool) async throws -> ProjectRenamePlan {
        guard storeUsable else { throw ControlFailure(code: "store_unavailable", message: "Resolve the library error first.") }
        guard let record = library.projects.first(where: { $0.id == id }) else { throw ControlFailure(code: "not_found", message: "Project is no longer registered.") }
        _ = try projectFolderForAction(record)
        let runtime = runtime
        return try await Task.detached(priority: .userInitiated) { try ProjectRename.plan(record: record, number: number, campaign: campaign, title: title, updateHeadings: updateHeadings, runtime: runtime) }.value
    }
    func renameProject(_ id: UUID, number: String, campaign: String, title: String, updateHeadings: Bool,
                       expectedChanges: [ProjectRenameChange]? = nil,
                       onFinish: @escaping (Result<ProjectRenameResult, Error>) -> Void = { _ in }) {
        guard !busy, storeUsable else { onFinish(.failure(ControlFailure(code: busy ? "busy" : "store_unavailable", message: "Wait for the operation or resolve the library error."))); return }
        guard let record = library.projects.first(where: { $0.id == id }) else { onFinish(.failure(ControlFailure(code: "not_found", message: "Project is no longer registered."))); return }
        do { _ = try projectFolderForAction(record) } catch { onFinish(.failure(error)); return }
        let runtime = runtime
        run("Renaming project") { token, _ in
            let plan = try ProjectRename.plan(record: record, number: number, campaign: campaign, title: title, updateHeadings: updateHeadings, runtime: runtime, cancellation: token)
            if let expectedChanges, plan.changes != expectedChanges { throw AppFailure("The rename list changed. Review a fresh plan before confirming.") }
            try token.check()
            return try ProjectRename.apply(plan, runtime: runtime)
        } completion: { result in
            self.busy = true
            Task {
                defer { self.busy = false }
                do {
                    try await self.commitDurably { lib in
                        guard let index = lib.projects.firstIndex(where: { $0.id == id }), lib.projects[index].path == record.path else { throw AppFailure("The project record changed during the rename.") }
                        try lib.projects[index].relocate(to: result.newRoot)
                        lib.projects[index].campaign = campaign.isEmpty ? nil : campaign
                    }
                    self.inspections[id] = nil; self.relinkCandidates[id] = nil
                    self.browserRefresh += 1; self.inspectionRevision += 1
                    if self.selectedProject == id { self.selectProject() }
                    self.renamePrompt = nil; self.status = "Renamed to " + result.newRoot.lastPathComponent
                    onFinish(.success(result))
                } catch {
                    let saveError = error
                    do { try await Task.detached { try ProjectRename.revert(result) }.value }
                    catch { let issue = AppFailure("Library save failed and rename rollback needs attention at \(result.newRoot.path): \(error.localizedDescription)"); self.error = issue.localizedDescription; onFinish(.failure(issue)); return }
                    self.error = "Library save failed; the original folder names were restored. " + saveError.localizedDescription
                    onFinish(.failure(saveError))
                }
            }
        } failure: { message in onFinish(.failure(ControlFailure(code: "rename_failed", message: message))) }
    }
}

struct RenameProjectSheet: View {
    @EnvironmentObject var m: AppModel
    let record: ProjectRecord
    @State private var number: String
    @State private var campaign: String
    @State private var title: String
    @State private var updateHeadings = false
    @State private var ignoreOpenApps = false
    @State private var plan: ProjectRenamePlan?
    @State private var issue: String?
    @State private var adobe: [String] = []
    init(record: ProjectRecord) {
        self.record = record
        let fields = ProjectRename.fields(of: record)
        _number = State(initialValue: fields?.number ?? "")
        _campaign = State(initialValue: fields?.campaign ?? "")
        _title = State(initialValue: fields?.title ?? "")
    }
    var input: [String] { [number, campaign, title, String(updateHeadings)] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Project").font(.title2.weight(.semibold))
            Text(record.name).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Number", text: $number).frame(width: 110).accessibilityLabel("Number")
                TextField("Campaign", text: $campaign).accessibilityLabel("Campaign")
            }
            TextField("Project Name", text: $title).accessibilityLabel("Project Name")
            Toggle("Also update Markdown headings", isOn: $updateHeadings)
            Text("Absolute media paths change. Relink Premiere media and update Watchtower paths separately.").font(.callout).foregroundStyle(.orange)
            if !adobe.isEmpty {
                Text("Running: " + adobe.joined(separator: ", ")).font(.caption).foregroundStyle(.orange)
                Toggle("Continue while these apps are running", isOn: $ignoreOpenApps)
            }
            if let issue { Text(issue).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            if let plan {
                Text("\(plan.changes.count) changes → \(plan.newName)").font(.headline)
                List(Array(plan.changes.enumerated()), id: \.offset) { _, change in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(change.path.isEmpty ? "Project folder" : change.path).font(.caption).foregroundStyle(.secondary)
                        Text(change.from + " → " + change.to).textSelection(.enabled)
                    }
                }
            } else { Spacer() }
            HStack {
                Button("Cancel") { m.renamePrompt = nil }.keyboardShortcut(.cancelAction).disabled(m.busy)
                Spacer()
                Button("Rename") {
                    guard let plan else { return }
                    adobe = AppModel.runningAdobeApps()
                    guard adobe.isEmpty || ignoreOpenApps else { return }
                    m.renameProject(record.id, number: number, campaign: campaign, title: title, updateHeadings: updateHeadings, expectedChanges: plan.changes) { result in
                        if case .failure(let error) = result { issue = error.localizedDescription; self.plan = nil }
                    }
                }.keyboardShortcut(.defaultAction).disabled(plan == nil || m.busy || (!adobe.isEmpty && !ignoreOpenApps))
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 720, height: 580)
            .interactiveDismissDisabled(m.busy)
            .task(id: input) {
                plan = nil; issue = nil; adobe = AppModel.runningAdobeApps()
                do {
                    let fresh = try await m.renamePlan(for: record.id, number: number, campaign: campaign, title: title, updateHeadings: updateHeadings)
                    if !Task.isCancelled { plan = fresh }
                } catch { if !Task.isCancelled { issue = error.localizedDescription } }
            }
    }
}
