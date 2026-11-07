import SwiftUI
import AppKit
import TemplateCore

/// The content column of Projects.
struct ProjectList: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(spacing: 0) {
            ProjectFilters().padding(.horizontal, Space.lg).padding(.vertical, Space.md)
            let duplicates = m.duplicateGroups
            if !duplicates.isEmpty {
                Button { m.duplicatesPresented = true } label: {
                    Label("\(duplicates.count) \(duplicates.count == 1 ? "name appears" : "names appear") more than once", systemImage: "doc.on.doc").font(TypeStyle.caption)
                }.buttonStyle(.plain).foregroundStyle(.orange).padding(.horizontal, Space.lg).padding(.bottom, Space.sm)
                    .help("Projects registered under the same name in more than one place. Open the list to see which is likely the live one.")
            }
            List(selection: $m.selectedProject) {
                if !m.pinnedProjects.isEmpty {
                    Section { ForEach(m.pinnedProjects) { ProjectRow(record: $0).tag($0.id) } } header: { Label("Pinned", systemImage: "pin.fill") }
                }
                ForEach(m.groupedProjects, id: \.title) { group in
                    Section(group.title) { ForEach(group.records) { ProjectRow(record: $0).tag($0.id) } }
                }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let record = m.library.projects.first(where: { ids.contains($0.id) }) { ProjectActions(record: record) }
            }
            .onChange(of: m.selectedProject) { m.selectProject() }
            .overlay {
                if m.library.projects.isEmpty {
                    ContentUnavailableView {
                        Label("No projects yet", systemImage: "externaldrive")
                    } description: {
                        Text("CreatorOS makes correctly named project folders from your templates, then tracks them through your pipeline.\n\n1. Import a template in Templates.\n2. Create a project from it and name it.\n3. Follow it on the Pipeline board.\n\nAlready have projects? Choose File, Add Existing Project. Files stay where they are.")
                    } actions: {
                        if m.library.templates.isEmpty {
                            Button("Import Template…") { m.beginImport() }.help("Choose a template folder or Post Haste package to copy into CreatorOS. Your original is never changed.")
                        }
                    }
                } else if m.filteredProjects.isEmpty {
                    ContentUnavailableView.search(text: m.search)
                }
            }
            Divider()
            DisclosureGroup {
                ForEach(m.library.locations ?? []) { location in
                    HStack {
                        Text(location.name).font(TypeStyle.caption).help(location.path)
                        Spacer()
                        Button("Scan Again") { m.rescanLocation(location) }.font(TypeStyle.caption).help("Look through this location again for projects that are not in the list yet")
                        Button { m.removeLocation(location) } label: { Image(systemName: "minus.circle").frame(minWidth: 28, minHeight: 28).contentShape(Rectangle()) }.buttonStyle(.plain).help("Forget this location. Projects already registered stay.")
                            .accessibilityLabel("Forget \(location.name)")
                    }
                }
                if (m.library.locations ?? []).isEmpty { Text("None saved").font(TypeStyle.caption).foregroundStyle(.secondary) }
            } label: {
                Text("\(m.filteredProjects.count) \(m.filteredProjects.count == 1 ? "project" : "projects") · \((m.library.locations ?? []).count) saved \((m.library.locations ?? []).count == 1 ? "location" : "locations")").font(TypeStyle.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                .help("Folders and drives you added with Add Existing. Scan one again to pick up new projects.")
        }
        .searchable(text: $m.search, placement: .toolbar, prompt: "Search projects, notes and documents")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { m.newProjectPresented = true } label: { Label("Create Project", systemImage: "folder.badge.plus").labelStyle(.titleAndIcon) }
                    .buttonStyle(.borderedProminent).help("Create a project folder from a template (⌘N)")
                Button { m.relinkAll() } label: {
                    if m.relinkBatchRunning { ProgressView().controlSize(.small).frame(width: 20) } else { Label("Find Missing Projects", systemImage: "arrow.triangle.2.circlepath") }
                }
                    .help("Check every project on the ticked drives, relink the ones that moved to a place you already use, and list the rest for you to locate. (⌘⇧R)")
                    .disabled(m.relinkBatchRunning)
                Toggle(isOn: $m.groupByDate) { Label("Group by date", systemImage: "calendar") }.help("Group projects by when their folder was created")
                Menu {
                    Button("Folder of Projects or Drive…") { m.scanLocation() }.help("Look through a folder or drive and pick the projects to add")
                    Button("One Existing Project…") { m.addExisting() }.help("Add a single project folder made outside the app")
                } label: { Label("Add Existing", systemImage: "plus") }.help("Register projects that already exist on a drive")
            }
        }
        .sheet(isPresented: $m.discoveryPresented) { DiscoveryView().errorNotice() }
        .sheet(item: $m.relinkReport) { _ in RelinkReportSheet().errorNotice() }
        .sheet(isPresented: $m.duplicatesPresented) { DuplicatesSheet().errorNotice() }
        .onAppear { m.refreshMounts() }
    }
}

struct ProjectRow: View {
    @EnvironmentObject var m: AppModel
    let record: ProjectRecord
    var unavailable: Bool { !m.mountedLocations.contains(record.location.key) || m.inspections[record.id]?.available == false }
    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            FormatIcon(data: m.library.presets.first { $0.format == record.format }?.icon)
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.sm) {
                    if record.isPinned { Image(systemName: "pin.fill").font(TypeStyle.caption2).foregroundStyle(.secondary) }
                    Text(record.name).font(TypeStyle.headline).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Space.sm) {
                    LocationBadge(location: record.location)
                    if unavailable { UnavailableChip() }
                    StageBadge(stage: m.effectiveStage(record))
                    if let editor = record.editor { Label(editor, systemImage: "person").font(TypeStyle.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                HStack(spacing: Space.sm) {
                    Text(record.effectiveDate.formatted(date: .abbreviated, time: .omitted)).font(TypeStyle.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, Space.xs).help(record.path)
    }
}

struct UnavailableChip: View {
    var body: some View {
        Label("Unavailable", systemImage: "externaldrive.badge.xmark").font(TypeStyle.caption.weight(.medium)).labelStyle(.titleAndIcon)
            .padding(.horizontal, Space.sm).padding(.vertical, Space.xxs).background(Color.orange.opacity(0.16), in: Capsule()).foregroundStyle(.orange)
            .help("Unavailable: this project's drive or cloud folder is not connected, or the folder has moved. The record stays in your list; reconnect the drive or use Find Moved Folders.")
    }
}

/// Shared actions for a project row, card or inspector menu.
/// The shortcuts are shown beside each item wherever this menu appears (right-click, More, and the Project menu in
/// the menu bar, where they act on the selected project), so Junior can learn them from the menus.
struct ProjectActions: View {
    @EnvironmentObject var m: AppModel
    let record: ProjectRecord
    /// The inspector's More menu sits beside the stage pill, so it leaves stages out (Junior, 23 Sep).
    var showStages = true
    var body: some View {
        // Read the pin state live: the menu bar keeps this view alive across library changes.
        let pinned = m.library.projects.first { $0.id == record.id }?.isPinned ?? record.isPinned
        Button(pinned ? "Unpin" : "Pin") { m.togglePin(record.id) }.keyboardShortcut("p", modifiers: [.command, .shift]).help("Pinned projects stay at the top of the list")
        Button("Rename Project…") { m.requestRename(record) }.disabled(m.busy).help("Rename the folder and the files named after it, after reviewing every change")
        Button("Open in Finder") { m.open(record) }.keyboardShortcut("o").help("Open the project folder in Finder")
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.path, forType: .string)
        }.help("Copy this project's full folder path")
        Button("Show in Pipeline") { m.pipelineSelection = record.id; m.page = .pipeline }.keyboardShortcut("p", modifiers: [.command, .option]).help("Select this project on the Pipeline board")
        if showStages { Menu("Move to Stage") { ForEach(m.moveTargets(for: record), id: \.self) { stage in Button(stage) { m.setStage(stage, for: record.id) }.disabled(stage == m.effectiveStage(record)) } } }
        Section("Advanced") {
            Button("Find Moved Folder") { m.relink(record) }.keyboardShortcut("r", modifiers: [.command, .option]).help("Search the connected drives for a folder with this project's name")
            Button("Locate Folder…") { m.locate(record) }.keyboardShortcut("l", modifiers: [.command, .option]).help("Point the record at the folder yourself")
            Button("Remove Folder Icons") { m.removeFolderIcons(record) }.help("Take the folder icons off so the project can be copied to LucidLink; Restore Folder Icons puts them back")
            Button("Restore Folder Icons") { m.restoreIcons(record) }.help("Put the template's folder icons back after the project lived on a drive that cannot hold them")
            Button("Check LucidLink Compatibility…") { m.checkCompatibility(record) }.disabled(m.busy).help("Look for file and folder names that LucidLink cannot hold")
            if record.ideaWorkspace != nil { Button("Review Old Idea Workspace…") { m.workspaceCleanup = record }.help("Decide whether to keep the draft folder this project started from") }
        }
        Divider()
        Button("Remove from List", role: .destructive) { m.removeProject(record.id) }.help("Take this project off the list. Its folder is not touched.")
    }
}

/// The detail column of Projects.
struct ProjectDetail: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        if let record = m.selectedRecord { ProjectInspector(record: record).id(record.id) }
        else {
            ContentUnavailableView("Your projects, wherever they live", systemImage: "externaldrive",
                                   description: Text("Select a project to browse its files and update its stage. Names and locations stay searchable while a drive is disconnected."))
        }
    }
}

struct ProjectInspector: View {
    @EnvironmentObject var m: AppModel
    let record: ProjectRecord
    var inspection: ProjectInspection? { m.inspections[record.id] }
    @State private var showStatus = false
    @State private var findingPremiere = false
    @State private var premiereDocuments: [BrowserItem] = []
    @State private var choosePremiere = false
    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                FormatIcon(data: m.library.presets.first { $0.format == record.format }?.icon, size: 40)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(record.name).font(TypeStyle.title3.weight(.semibold)).textSelection(.enabled).lineLimit(2).help(record.path)
                    HStack(spacing: Space.sm) {
                        LocationBadge(location: record.location)
                        if m.relinking.contains(record.id) { ProgressView().controlSize(.mini); Text("Looking for the folder…").font(TypeStyle.callout).foregroundStyle(.secondary) }
                        else {
                            Image(systemName: inspection == nil ? "circle.dotted" : (inspection!.available ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                                .foregroundStyle(inspection?.available == true ? .green : .orange)
                            Text(inspection?.status ?? "Checking location…").font(TypeStyle.callout).foregroundStyle(.secondary).lineLimit(2)
                                .help(inspection == nil ? "Checking whether the folder is reachable right now."
                                      : inspection!.available ? "Available: the folder is at this path on a connected drive. It can be opened, browsed and tagged, and its files are the ones the list refers to."
                                      : "Unavailable: the folder is not at this path right now. The drive may be disconnected, or the folder may have moved. Nothing has been deleted from your list; use Find Moved Folders or Locate Folder.")
                        }
                    }
                    Text("Created \(record.effectiveDate.formatted(date: .long, time: .omitted))").font(TypeStyle.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { m.togglePin(record.id) } label: { Image(systemName: record.isPinned ? "pin.fill" : "pin") }.help(record.isPinned ? "Unpin (⇧⌘P)" : "Pin to the top of the list (⇧⌘P)")
                    .accessibilityLabel(record.isPinned ? "Unpin" : "Pin")
            }
            if let candidates = m.relinkCandidates[record.id], !candidates.isEmpty {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Label("Found \(candidates.count) \(candidates.count == 1 ? "folder" : "folders") with this name. Choose the right one:", systemImage: "arrow.triangle.2.circlepath").font(TypeStyle.callout)
                    ForEach(candidates, id: \.path) { url in
                        HStack { Text(url.path).font(TypeStyle.caption).lineLimit(1).truncationMode(.middle); Spacer(); Button("Relink") { m.relink(record, to: url) }.controlSize(.small).help("Point this project at this folder") }
                    }
                }.padding(Space.md).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.md))
            }
            // Rename lives in More with the other shared project actions; this row keeps the everyday ones.
            FlowLayout(spacing: Space.sm) {
                Button("Open in Finder") { m.open(record) }.help("Open the project folder in Finder, showing what is inside it (⌘O)")
                Button { findPremiere() } label: {
                    if findingPremiere { ProgressView().controlSize(.small) } else { Text("Open Premiere Project") }
                }
                .disabled(findingPremiere || inspection?.available != true)
                .help("Open the Premiere project directly, or choose one when this folder contains several")
                .accessibilityLabel("Open Premiere Project")
                Menu("More") {
                    Button("Refresh Project") { m.refreshProject() }.keyboardShortcut("r").help("Read this folder again, check it is still there, and look for any moved projects")
                    ProjectActions(record: record, showStages: false)
                }.fixedSize().help("Rename, pin, relink and other actions for this project, with their keyboard shortcuts")
            }
            DisclosureGroup(isExpanded: $showStatus) {
                // Outside a Form a TextField hides its title; the columns style shows Campaign, Editor, Series and Notes.
                Form { ProjectStatusEditor(record: record) }.formStyle(.columns).padding(.top, Space.sm)
            } label: {
                HStack(spacing: Space.sm) { Text("Details").font(TypeStyle.headline); StageMenu(record: record) }
            }
            if let old = record.previousPaths, !old.isEmpty {
                DisclosureGroup("Previous locations") { Text(old.joined(separator: "\n")).font(TypeStyle.caption).textSelection(.enabled) }.font(TypeStyle.callout)
            }
            if inspection?.available == true {
                FolderBrowserHost(title: record.name, resolveRoot: { try ProjectBrowser.root(record) }, surface: .projectFiles)
            } else if inspection != nil {
                ContentUnavailableView("Folder unavailable", systemImage: "externaldrive.badge.xmark",
                                       description: Text("Reconnect the drive, or use Find Moved Folder if it lives somewhere else now. The record stays in your list."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { Spacer() }
        }
        .padding(Space.xl)
        .confirmationDialog("Choose a Premiere project", isPresented: $choosePremiere, titleVisibility: .visible) {
            ForEach(premiereDocuments) { item in
                Button(item.relativePath) { openPremiere(item) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This project contains more than one Premiere document.")
        }
    }

    func findPremiere() {
        guard !findingPremiere else { return }
        findingPremiere = true
        let record = record
        Task {
            do {
                let files = try await Task.detached(priority: .userInitiated) {
                    try ProjectBrowser.premiereFiles(root: ProjectBrowser.root(record))
                }.value
                findingPremiere = false
                switch files.count {
                case 0: m.error = "No Premiere project was found in this folder."
                case 1: openPremiere(files[0])
                default: premiereDocuments = files; choosePremiere = true
                }
            } catch { findingPremiere = false; m.error = error.localizedDescription }
        }
    }

    func openPremiere(_ item: BrowserItem) {
        let record = record
        Task {
            do {
                let root = try await Task.detached(priority: .userInitiated) { try ProjectBrowser.root(record) }.value
                _ = try await AppModel.openDocument(root: root, relative: item.relativePath, expecting: "prproj")
            } catch { m.error = error.localizedDescription }
        }
    }
}

/// The outcome of Find Missing Projects, like an editor's offline-media list: every project that was missing, with a
/// green tick once it is linked (by the pass or by hand while the sheet is open), orange when there is a choice to make,
/// red while it is still missing. Rows stay put so the change from red to green is visible.
struct RelinkReportSheet: View {
    @EnvironmentObject var m: AppModel
    var report: RelinkReport? { m.relinkReport }
    var body: some View {
        let report = report ?? RelinkReport(checked: 0, outcomes: [])
        let linked = report.relinked.count, open = report.unresolved.count
        VStack(alignment: .leading, spacing: Space.lg) {
            if report.outcomes.isEmpty {
                ContentUnavailableView("Nothing is missing", systemImage: "checkmark.circle",
                                       description: Text("All ^[\(report.checked) project](inflect: true) on the ticked drives are where the list says. Nothing needed relinking."))
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                Text("Missing Projects").font(TypeStyle.title2.weight(.semibold))
                HStack(spacing: Space.lg) {
                    Text("\(report.checked) checked").foregroundStyle(.secondary)
                    Label("\(linked) linked", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Label("\(open) still missing", systemImage: open == 0 ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(open == 0 ? .green : .red)
                }.font(TypeStyle.callout)
                List { ForEach(report.outcomes) { row($0).id($0.kind) } }
                if open == 0 { Label("Everything is linked again.", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
            }
            HStack { Spacer(); Button("Done") { m.relinkReport = nil }.keyboardShortcut(.defaultAction).help("Close this list. Projects still missing stay in your list.") }
        }.padding(Space.xxl).frame(width: 760, height: report.outcomes.isEmpty ? 340 : 580)
    }
    func record(_ outcome: RelinkOutcome) -> ProjectRecord? { m.library.projects.first { $0.id == outcome.id } }
    @ViewBuilder func row(_ outcome: RelinkOutcome) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            statusMark(outcome.kind).frame(width: 24)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(record(outcome)?.name ?? outcome.name).font(TypeStyle.headline)
                switch outcome.kind {
                case .relinked(let url):
                    Text("Linked · " + url.path).font(TypeStyle.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                case .candidates(let urls):
                    Text("Was at " + outcome.previousPath).font(TypeStyle.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    ForEach(urls, id: \.path) { url in candidateRow(outcome, url: url) }
                    Text(urls.count > 1 ? "More than one folder has this name, so none was chosen for you." : "The original still exists, so this may be a copy rather than a move.")
                        .font(TypeStyle.caption).foregroundStyle(.secondary)
                case .notFound, .stillThere:
                    Text("Was at " + outcome.previousPath).font(TypeStyle.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    HStack {
                        Text("Missing: not found in any place you use on the ticked drives.").font(TypeStyle.caption).foregroundStyle(.red)
                        Spacer()
                        Button("Locate Folder…") { if let record = record(outcome) { m.locate(record) } }.controlSize(.small).help("Point the record at the folder yourself")
                    }
                }
            }
        }.padding(.vertical, Space.xs)
    }
    @ViewBuilder func statusMark(_ kind: RelinkOutcome.Kind) -> some View {
        switch kind {
        case .relinked: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(TypeStyle.title3).help("Linked")
        case .candidates: Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange).font(TypeStyle.title3).help("Choose the right folder")
        case .notFound, .stillThere: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(TypeStyle.title3).help("Missing")
        }
    }
    func candidateRow(_ outcome: RelinkOutcome, url: URL) -> some View {
        HStack {
            Text(url.path).font(TypeStyle.caption).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Use This Folder") { if let record = record(outcome) { m.relink(record, to: url) } }.controlSize(.small).help("Point this project at this folder")
        }
    }
}

/// Projects registered under one name in several places. Nothing on disk is touched; the list only forgets a copy.
struct DuplicatesSheet: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        let groups = m.duplicateGroups
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Duplicates").font(TypeStyle.title2.weight(.semibold))
            Text("The same project name is registered in more than one place. The copy under a format's destination is marked as the likely live one; otherwise the newest folder is. Removing a copy from the list never touches its files.").foregroundStyle(.secondary)
            if groups.isEmpty {
                ContentUnavailableView("No duplicates", systemImage: "checkmark.circle", description: Text("Every registered project name appears once.")).frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        Section(group[0].name) {
                            ForEach(group) { record in
                                HStack(alignment: .top, spacing: Space.md) {
                                    VStack(alignment: .leading, spacing: Space.xs) {
                                        HStack(spacing: Space.sm) {
                                            LocationBadge(location: record.location)
                                            StageBadge(stage: m.effectiveStage(record))
                                            if m.likelyLive(record, among: group) { Label("Likely live", systemImage: "star.fill").font(TypeStyle.caption.weight(.semibold)).foregroundStyle(.green) }
                                        }
                                        Text(record.path).font(TypeStyle.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                        Text("Folder from " + record.effectiveDate.formatted(date: .abbreviated, time: .omitted)).font(TypeStyle.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Show") { m.selectedProject = record.id; m.page = .projects; m.selectProject(); m.duplicatesPresented = false }.controlSize(.small).help("Close this list and select this copy in Projects")
                                    Button("Remove from List") { m.removeProject(record.id) }.controlSize(.small).help("Take this copy off the list. Its folder stays where it is.")
                                }.padding(.vertical, Space.xxs)
                            }
                        }
                    }
                }
            }
            HStack { Spacer(); Button("Done") { m.duplicatesPresented = false }.keyboardShortcut(.defaultAction).help("Close this list") }
        }.padding(Space.xxl).frame(width: 760, height: 560)
    }
}

struct DiscoveryView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Add projects to your list").font(TypeStyle.title2.weight(.semibold))
            Text(m.discovery?.location.path ?? "").font(TypeStyle.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Select the folders to register. Recognition is based on folder structure. Nothing will be moved, renamed or deleted.").foregroundStyle(.secondary)
            List(m.discovery?.projects ?? []) { record in
                Toggle(isOn: Binding(get: { m.discoverySelection.contains(record.id) }, set: { if $0 { m.discoverySelection.insert(record.id) } else { m.discoverySelection.remove(record.id) } })) {
                    VStack(alignment: .leading) { Text(record.name); Text("\(record.format) · \(record.path)").font(TypeStyle.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
            }
            if let notes = m.discovery?.notes, !notes.isEmpty { DisclosureGroup("Scan notes") { ScrollView { Text(notes.joined(separator: "\n")).font(TypeStyle.caption) }.frame(maxHeight: 80) } }
            if m.discovery?.projects.isEmpty == true { Text("No projects recognised. Add one existing project manually, or choose a smaller folder.").font(TypeStyle.callout) }
            HStack {
                Button("Cancel") { m.discoveryPresented = false }.keyboardShortcut(.cancelAction).help("Close without adding anything")
                Spacer()
                Button("Register \(m.discoverySelection.count) \(m.discoverySelection.count == 1 ? "Project" : "Projects")") { m.registerDiscovery() }.buttonStyle(.borderedProminent).disabled(m.discoverySelection.isEmpty)
                    .help("Add the ticked folders to your project list. Nothing on disk changes.")
            }
        }.padding(Space.xxl).frame(width: 760, height: 560)
    }
}
