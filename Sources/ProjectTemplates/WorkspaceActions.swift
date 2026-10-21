import SwiftUI
import AppKit
import TemplateCore

extension AppModel {
    func checkCompatibility(_ record: ProjectRecord? = nil) {
        let url: URL
        do {
            if let record { url = try record.resolve() }
            else { guard let selected = folderPanel(title: "Check a folder for LucidLink compatibility") else { return }; url = selected }
        } catch { self.error = error.localizedDescription; return }
        scanCompatibility(url) {
            if case .success(let report) = $0 { self.compatibilityReport = report; self.compatibilityOutput = nil; self.compatibilityPresented = true }
        }
    }
    /// Reads a folder's names for LucidLink trouble. The sheet and control share it; only the sheet shows the result.
    func scanCompatibility(_ url: URL, onFinish: @escaping (Result<CompatibilityReport, Error>) -> Void) {
        run("Checking names for LucidLink", cancelNote: "Nothing was changed.") { token, _ in try Compatibility.scan(url, cancellation: token) }
            completion: { onFinish(.success($0)) } failure: { onFinish(.failure(AppFailure($0))) }
    }
    /// The report for the project in the New Project form, without showing it.
    func prospectiveCompatibility() -> CompatibilityReport? {
        guard let plan, let preview else { return nil }
        return Compatibility.scan(plan: plainFolders ? plan.withoutIconFiles : plan, outerName: preview.outerFolderName)
    }
    func checkProspectiveCompatibility() {
        guard let report = prospectiveCompatibility() else { return }
        compatibilityReport = report
        compatibilityOutput = nil; compatibilityPresented = true
    }
    func copyCorrected(to destination: URL) {
        guard let report = compatibilityReport else { return }
        makeCorrectedCopy(report, to: destination) { if case .success(let output) = $0 { self.compatibilityOutput = output } }
    }
    /// Writes a corrected copy of a scanned folder and leaves the original alone.
    func makeCorrectedCopy(_ report: CompatibilityReport, to destination: URL, onFinish: @escaping (Result<URL, Error>) -> Void) {
        let runtime = runtime
        run("Creating corrected copy", cancelNote: "The original is untouched; check the destination for a partial copy.") { token, progress in
            try runtime.requireWritable(destination)
            let proposal = try Compatibility.proposal(report)
            return try Compatibility.copy(proposal, destination: destination, cancellation: token, progress: progress)
        } completion: { output in
            self.status = "Corrected copy created at \(output.path). Original unchanged."
            onFinish(.success(output))
        } failure: { onFinish(.failure(AppFailure($0))) }
    }
    func createWorkspace(for idea: ProjectRecord, root: URL, templateID: UUID?, onFinish: ((Result<ProjectRecord, Error>) -> Void)? = nil) {
        let runtime = runtime
        let source = templateID.flatMap { library.template($0) }.map { store.payload($0) }
        run("Creating idea workspace", cancelNote: "Nothing was registered; check the Ideas folder for a partial workspace.") { token, progress in
            try runtime.requireWritable(root)
            return try IdeaWorkspaceEngine.create(for: idea, root: root, payload: source, cancellation: token, progress: progress)
        } completion: { workspace in
            self.busy = true
            Task {
                defer { self.busy = false }
                do {
                    try await self.commitDurably { library in
                        guard let i = library.projects.firstIndex(where: { $0.id == idea.id }), library.projects[i].isPlanned,
                              library.projects[i].ideaWorkspace == nil else { throw AppFailure("This idea changed while its workspace was being created.") }
                        library.projects[i].ideaWorkspace = workspace
                    }
                    self.workspacePrompt = nil
                    self.workspaceToBrowse = self.library.projects.first { $0.id == idea.id }
                    if let saved = self.workspaceToBrowse { onFinish?(.success(saved)) }
                } catch {
                    let failure = AppFailure("Workspace created at \(workspace.path), but its reference could not be saved. Keep it for recovery. \(error.localizedDescription)")
                    self.error = failure.localizedDescription
                    onFinish?(.failure(failure))
                }
            }
        } failure: { onFinish?(.failure(AppFailure($0))) }
    }
    /// The workspace folder this record owns, checked to be inside the writable area. Throws if it cannot be proved owned.
    func confirmedWorkspace(for record: ProjectRecord) throws -> URL {
        let url = try IdeaWorkspaceEngine.resolve(for: record)
        try runtime.requireWritable(url)
        return url
    }
    func requestBinIdea(_ record: ProjectRecord) {
        guard !busy else { return }
        do {
            confirmedWorkspaceURL = record.ideaWorkspace != nil ? try confirmedWorkspace(for: record) : nil
            binIdea = record
        } catch { self.error = error.localizedDescription }
    }
    func confirmBinIdea() {
        guard let record = binIdea, !busy else { return }
        binIdea = nil
        if record.ideaWorkspace == nil { removeProject(record.id); return }
        guard let confirmed = confirmedWorkspaceURL else { return }
        Task { do { try await trashWorkspace(record, at: confirmed, removingRecord: record.isPlanned) } catch { self.error = error.localizedDescription } }
    }
    func requestWorkspaceCleanup(_ record: ProjectRecord) {
        do {
            confirmedWorkspaceURL = try confirmedWorkspace(for: record); binIdea = record; workspaceCleanup = nil
        } catch { self.error = error.localizedDescription }
    }
    func keepAndDetachWorkspace(_ record: ProjectRecord) {
        guard !busy, !record.isPlanned else { return }
        Task { do { try await detachWorkspace(record) } catch { self.error = error.localizedDescription } }
    }
    /// Keeps the old workspace folder and stops linking it to the started project. Saved before it returns.
    func detachWorkspace(_ record: ProjectRecord) async throws {
        guard !writeLocked else { throw AppFailure(Self.writeLockedMessage) }
        busy = true
        defer { busy = false }
        do {
            try await commitDurably { lib in
                guard let i = lib.projects.firstIndex(where: { $0.id == record.id }), !lib.projects[i].isPlanned else {
                    throw AppFailure("The promoted project is no longer available.")
                }
                lib.projects[i].ideaWorkspace = nil
            }
        } catch { throw AppFailure("The workspace link was retained because the library could not be saved. \(error.localizedDescription)") }
        workspaceCleanup = nil
        status = "The old workspace stays at \(record.ideaWorkspace?.path ?? "its original location"). It is no longer managed by this project."
    }
    /// Moves an owned workspace to the Bin, then saves the record without it (or removes the idea). Returns the Bin location.
    @discardableResult
    func trashWorkspace(_ record: ProjectRecord, at confirmed: URL, removingRecord: Bool) async throws -> URL? {
        // Refused before anything goes to the Bin when another writer holds the slot.
        guard !writeLocked else { throw AppFailure(Self.writeLockedMessage) }
        busy = true
        defer { busy = false }
        var trashed = false
        var trashURL: URL?
        do {
            await saveTaskForWorkspace()
            guard storeUsable, let current = library.projects.first(where: { $0.id == record.id }) else { throw AppFailure("The record is unavailable; nothing was put in the Bin.") }
            try runtime.requireWritable(confirmed)
            trashURL = try IdeaWorkspaceEngine.trash(for: current, confirmedURL: confirmed)
            trashed = true
            try await commitDurably { lib in
                if removingRecord { lib.projects.removeAll { $0.id == record.id } }
                else if let i = lib.projects.firstIndex(where: { $0.id == record.id }) { lib.projects[i].ideaWorkspace = nil }
            }
            if removingRecord {
                if pipelineSelection == record.id { pipelineSelection = nil }
                if selectedProject == record.id { selectedProject = nil }
            }
            status = "Workspace moved to the Bin. Finder can restore it."
            return trashURL
        } catch {
            throw trashed
                ? AppFailure("The workspace from \(confirmed.path) is in the Bin\(trashURL.map { " at " + $0.path } ?? ""), but its library record could not be saved and is retained. Restore that folder using Finder's Bin. \(error.localizedDescription)")
                : error
        }
    }
}

struct CompatibilitySheet: View {
    @EnvironmentObject var m: AppModel
    @State private var destination: URL?
    @State private var confirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LucidLink compatibility").font(.title2.weight(.semibold))
            if let report = m.compatibilityReport {
                Text(report.rootName).font(.headline).textSelection(.enabled)
                Text(report.isComplete ? "\(report.entries) entries checked" : "Incomplete scan. Review the skipped items and errors below.")
                    .foregroundStyle(report.isComplete ? Color.secondary : .orange)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(report.findings.enumerated()), id: \.offset) { _, finding in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(finding.path).fontWeight(.medium)
                                Text(finding.problem).foregroundStyle(.secondary)
                                if let corrected = finding.corrected { Text("Proposed: \(corrected)") }
                            }
                        }
                        if !report.iconFiles.isEmpty { Text("\(report.iconFiles.count) Finder icon files will be omitted from a corrected copy.") }
                        ForEach(report.errors + report.skipped + report.collisions, id: \.self) { Text($0).foregroundStyle(.orange) }
                        if !report.packages.isEmpty { Text("Packages: \(report.packages.joined(separator: ", ")). Internal names are not repaired.") }
                        if !report.longPaths.isEmpty {
                            Text(report.pathLengthAssumption).foregroundStyle(.secondary)
                            ForEach(report.longPaths, id: \.self) { Text($0) }
                        }
                        if report.findings.isEmpty && report.iconFiles.isEmpty && report.longPaths.isEmpty && report.isComplete {
                            Text("No incompatible names or Finder icon files found.").foregroundStyle(.green)
                        }
                    }.font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("A corrected copy preserves the original and document contents. Renamed media may need relinking in Premiere Pro, OBS or Watchtower. A rename manifest is included.").font(.caption).foregroundStyle(.secondary)
                if let output = m.compatibilityOutput {
                    Text("Created: \(output.path)").textSelection(.enabled)
                    Button("Show Copy in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                } else if report.canCopy {
                    HStack {
                        Text(destination?.path ?? "Choose an alpha output folder").font(.caption).textSelection(.enabled)
                        Button("Choose Destination…") { destination = m.folderPanel(title: "Choose an output folder inside the alpha workspace") }
                    }
                } else { Text("This report cannot make a corrected copy. Prospective previews are read-only; scan the actual folder for a repair proposal.").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button(m.busy ? "Cancel Copy" : "Done") { if m.busy { m.cancellation.cancel() } else { m.compatibilityPresented = false } }.keyboardShortcut(.cancelAction)
                    if m.busy { ProgressView(value: m.fraction); Text(m.status).font(.caption) }
                    Spacer()
                    Button("Preview Copy…") { confirm = true }.buttonStyle(.borderedProminent)
                        .disabled(m.busy || !report.canCopy || destination == nil || m.compatibilityOutput != nil)
                }
            }
        }.padding(24).frame(width: 740, height: 620).interactiveDismissDisabled(m.busy)
        .sheet(isPresented: $confirm) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Create corrected copy?").font(.title2)
                if let report = m.compatibilityReport {
                    Text("\(report.rootName) → \(report.suggestedRootName)")
                    Text("Destination: \(destination?.path ?? "")").textSelection(.enabled)
                    ScrollView {
                        if let proposal = try? Compatibility.proposal(report) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(proposal.renames.enumerated()), id: \.offset) { _, rename in Text("\(rename.from) → \(rename.to)") }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Text("The original stays intact. Opaque project files are not rewritten; media references may need manual relinking.").font(.caption)
                HStack { Button("Cancel") { confirm = false }; Spacer(); Button("Create Copy") { confirm = false; if let destination { m.copyCorrected(to: destination) } }.buttonStyle(.borderedProminent) }
            }.padding(24).frame(width: 640, height: 420)
        }
    }
}

struct WorkspaceSheet: View {
    @EnvironmentObject var m: AppModel
    let record: ProjectRecord
    @State private var root: URL?
    @State private var templateID: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create workspace for \(record.name)").font(.title2)
            Text("An unnumbered local folder for this idea's documents and attachments. Start Project later copies and numbers it; it does not merge another template.")
            Text("Format: \(m.label(for: record.format))")
            Picker("Starter template", selection: $templateID) {
                Text("Empty workspace").tag(Optional<UUID>.none)
                ForEach(m.library.templates) { template in Text(template.name).tag(Optional(template.id)) }
            }
            HStack { Text((root ?? m.runtime.ideas).path).font(.caption).textSelection(.enabled); Button("Choose Ideas Folder…") { root = m.folderPanel(title: "Choose a local Ideas folder inside the alpha workspace") } }
            HStack {
                Button(m.busy ? "Cancel Creation" : "Cancel") { if m.busy { m.cancellation.cancel() } else { m.workspacePrompt = nil } }
                if m.busy { ProgressView(value: m.fraction) }
                Spacer()
                Button("Create Workspace") { m.createWorkspace(for: record, root: root ?? m.runtime.ideas, templateID: templateID) }.buttonStyle(.borderedProminent).disabled(m.busy)
            }
        }.padding(24).frame(width: 620).interactiveDismissDisabled(m.busy)
    }
}
