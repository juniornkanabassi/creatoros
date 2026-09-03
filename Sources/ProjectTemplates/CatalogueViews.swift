import SwiftUI
import TemplateCore

/// The content column of Projects.
struct ProjectList: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(spacing: 0) {
            ProjectFilters().padding(.horizontal, 16).padding(.vertical, 10)
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
                    ContentUnavailableView("No projects yet", systemImage: "externaldrive", description: Text("Create a project, or add a folder of existing projects. Files stay where they are."))
                } else if m.filteredProjects.isEmpty {
                    ContentUnavailableView.search(text: m.search)
                }
            }
            Divider()
            DisclosureGroup {
                ForEach(m.library.locations ?? []) { location in
                    HStack {
                        Text(location.name).font(.caption).help(location.path)
                        Spacer()
                        Button("Scan Again") { m.rescanLocation(location) }.font(.caption)
                        Button { m.removeLocation(location) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("Forget this location. Projects already registered stay.")
                    }
                }
                if (m.library.locations ?? []).isEmpty { Text("None saved").font(.caption).foregroundStyle(.secondary) }
            } label: {
                Text("\(m.filteredProjects.count) projects · \((m.library.locations ?? []).count) saved locations").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }
        .searchable(text: $m.search, placement: .toolbar, prompt: "Search projects, notes and previous locations")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $m.groupByDate) { Label("Group by date", systemImage: "calendar") }.help("Group projects by when their folder was created")
                Menu {
                    Button("Folder of Projects or Drive…") { m.scanLocation() }
                    Button("One Existing Project…") { m.addExisting() }
                    Divider()
                    Button("Find Moved Folders") { m.relinkAll() }.help("Look on the connected drives for folders that have moved")
                } label: { Label("Add", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $m.discoveryPresented) { DiscoveryView() }
        .onAppear { m.refreshMounts() }
    }
}

struct ProjectRow: View {
    @EnvironmentObject var m: AppModel
    let record: ProjectRecord
    var unavailable: Bool { !m.mountedLocations.contains(record.location.key) || m.inspections[record.id]?.available == false }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            FormatIcon(data: m.library.presets.first { $0.format == record.format }?.icon)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if record.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    Text(record.name).font(.headline).lineLimit(2)
                }
                HStack(spacing: 6) {
                    LocationBadge(location: record.location)
                    if unavailable { UnavailableChip() }
                    StageBadge(stage: m.effectiveStage(record))
                    if let editor = record.editor { Label(editor, systemImage: "person").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                HStack(spacing: 6) {
                    Text(record.effectiveDate.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.tertiary)
                    Text(record.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
        }.padding(.vertical, 4)
    }
}

struct UnavailableChip: View {
    var body: some View {
        Label("Unavailable", systemImage: "externaldrive.badge.xmark").font(.caption.weight(.medium)).labelStyle(.titleAndIcon)
            .padding(.horizontal, 7).padding(.vertical, 2).background(Color.orange.opacity(0.16), in: Capsule()).foregroundStyle(.orange)
            .help("The drive or cloud folder is not connected right now")
    }
}

/// Shared actions for a project row, card or inspector menu.
struct ProjectActions: View {
    @EnvironmentObject var m: AppModel
    let record: ProjectRecord
    var body: some View {
        Button(record.isPinned ? "Unpin" : "Pin") { m.togglePin(record.id) }
        Button("Open Folder") { m.open(record) }
        Button("Reveal in Finder") { m.reveal(record) }
        Button("Show in Pipeline") { m.pipelineSelection = record.id; m.page = .pipeline }
        Menu("Move to Stage") { ForEach(m.moveTargets(for: record), id: \.self) { stage in Button(stage) { m.setStage(stage, for: record.id) }.disabled(stage == m.effectiveStage(record)) } }
        Divider()
        Button("Find Moved Folder") { m.relink(record) }
        Button("Locate Folder…") { m.locate(record) }
        Button("Restore Folder Icons") { m.restoreIcons(record) }.help("Put the content template's folder icons back after the project lived on a drive that cannot hold them")
        Divider()
        Button("Remove from List", role: .destructive) { m.removeRecord(record) }
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
    @State private var showStatus = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                FormatIcon(data: m.library.presets.first { $0.format == record.format }?.icon, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.name).font(.title3.weight(.semibold)).textSelection(.enabled).lineLimit(2)
                    HStack(spacing: 8) {
                        LocationBadge(location: record.location)
                        if m.relinking.contains(record.id) { ProgressView().controlSize(.mini); Text("Looking for the folder…").font(.callout).foregroundStyle(.secondary) }
                        else {
                            Image(systemName: inspection == nil ? "circle.dotted" : (inspection!.available ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                                .foregroundStyle(inspection?.available == true ? .green : .orange)
                            Text(inspection?.status ?? "Checking location…").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Text("Created \(record.effectiveDate.formatted(date: .long, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { m.togglePin(record.id) } label: { Image(systemName: record.isPinned ? "pin.fill" : "pin") }.help(record.isPinned ? "Unpin" : "Pin to the top of the list")
            }
            Text(record.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            if let candidates = m.relinkCandidates[record.id], !candidates.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Found \(candidates.count) folders with this name. Choose the right one:", systemImage: "arrow.triangle.2.circlepath").font(.callout)
                    ForEach(candidates, id: \.path) { url in
                        HStack { Text(url.path).font(.caption).lineLimit(1).truncationMode(.middle); Spacer(); Button("Relink") { m.relink(record, to: url) }.controlSize(.small) }
                    }
                }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("Open Folder") { m.open(record) }
                Button("Reveal in Finder") { m.reveal(record) }
                Menu("More") {
                    Button("Check Again") { m.inspectProject(record); m.refreshMounts() }
                    ProjectActions(record: record)
                }.fixedSize()
            }
            DisclosureGroup(isExpanded: $showStatus) {
                ProjectStatusEditor(record: record).padding(.top, 6)
            } label: {
                HStack(spacing: 8) { Text("Status").font(.headline); StageBadge(stage: m.effectiveStage(record)) }
            }
            if let old = record.previousPaths, !old.isEmpty {
                DisclosureGroup("Previous locations") { Text(old.joined(separator: "\n")).font(.caption).textSelection(.enabled) }.font(.callout)
            }
            if inspection?.available == true {
                FolderBrowserHost(title: record.name, resolveRoot: { try ProjectBrowser.root(record) }, surface: .projectFiles)
            } else if inspection != nil {
                ContentUnavailableView("Folder unavailable", systemImage: "externaldrive.badge.xmark",
                                       description: Text("Reconnect the drive, or use Find Moved Folder if it lives somewhere else now. The record stays in your list."))
                    .frame(maxHeight: .infinity)
            } else { Spacer() }
        }.padding(20)
    }
}

struct DiscoveryView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add projects to your list").font(.title2.weight(.semibold))
            Text(m.discovery?.location.path ?? "").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Select the folders to register. Recognition is based on folder structure. Nothing will be moved, renamed or deleted.").foregroundStyle(.secondary)
            List(m.discovery?.projects ?? []) { record in
                Toggle(isOn: Binding(get: { m.discoverySelection.contains(record.id) }, set: { if $0 { m.discoverySelection.insert(record.id) } else { m.discoverySelection.remove(record.id) } })) {
                    VStack(alignment: .leading) { Text(record.name); Text("\(record.format) · \(record.path)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
            }
            if let notes = m.discovery?.notes, !notes.isEmpty { DisclosureGroup("Scan notes") { ScrollView { Text(notes.joined(separator: "\n")).font(.caption) }.frame(maxHeight: 80) } }
            if m.discovery?.projects.isEmpty == true { Text("No projects recognised. Add one existing project manually, or choose a smaller folder.").font(.callout) }
            HStack {
                Button("Cancel") { m.discoveryPresented = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Register \(m.discoverySelection.count) Projects") { m.registerDiscovery() }.buttonStyle(.borderedProminent).disabled(m.discoverySelection.isEmpty)
            }
        }.padding(24).frame(width: 760, height: 560)
    }
}
