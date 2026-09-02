import SwiftUI
import TemplateCore

/// The content column of Projects.
struct ProjectList: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                FormatButtons(selection: $m.formatFilter, includeAll: true).help("Filter by the format the project was created as.")
                Spacer()
            }.padding(.horizontal, 16).padding(.vertical, 10)
            List(m.filteredProjects, selection: $m.selectedProject) { record in
                HStack(alignment: .top, spacing: 10) {
                    FormatIcon(data: m.library.presets.first { $0.format == record.format }?.icon)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.name).font(.headline).lineLimit(2)
                        Text(record.volumeName ?? "Saved location").font(.caption).foregroundStyle(.secondary)
                        Text(record.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                }.padding(.vertical, 4).tag(record.id)
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
        .searchable(text: $m.search, placement: .toolbar, prompt: "Search projects and previous locations")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Folder of Projects or Drive…") { m.scanLocation() }
                    Button("One Existing Project…") { m.addExisting() }
                } label: { Label("Add", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $m.discoveryPresented) { DiscoveryView() }
    }
}

/// The detail column of Projects.
struct ProjectDetail: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        if let record = m.selectedRecord { ProjectInspector(record: record).id(record.id) }
        else {
            ContentUnavailableView("Your projects, wherever they live", systemImage: "externaldrive",
                                   description: Text("Select a project to browse its files. Names and locations stay searchable while a drive is disconnected."))
        }
    }
}

struct ProjectInspector: View {
    @EnvironmentObject var m: AppModel
    let record: ProjectRecord
    var inspection: ProjectInspection? { m.inspections[record.id] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                FormatIcon(data: m.library.presets.first { $0.format == record.format }?.icon, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.name).font(.title3.weight(.semibold)).textSelection(.enabled).lineLimit(2)
                    HStack(spacing: 6) {
                        Image(systemName: inspection == nil ? "circle.dotted" : (inspection!.available ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                            .foregroundStyle(inspection?.available == true ? .green : .orange)
                        Text(inspection?.status ?? "Checking location…").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
            }
            Text(record.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            HStack {
                Button("Open Folder") { m.open(record) }
                Button("Reveal in Finder") { m.reveal(record) }
                Menu("More") {
                    Button("Check Again") { m.inspectProject(record) }
                    Button("Locate Folder…") { m.locate(record) }
                    Divider()
                    Button("Remove from List", role: .destructive) { m.removeRecord(record) }
                }.fixedSize()
            }
            if let old = record.previousPaths, !old.isEmpty {
                DisclosureGroup("Previous locations") { Text(old.joined(separator: "\n")).font(.caption).textSelection(.enabled) }.font(.callout)
            }
            if inspection?.available == true {
                FolderBrowserHost(title: record.name, resolveRoot: { try ProjectBrowser.root(record) }, surface: .projectFiles)
            } else if inspection != nil {
                ContentUnavailableView("Folder unavailable", systemImage: "externaldrive.badge.xmark", description: Text("Reconnect the drive or use Locate Folder. The record stays in your list.")).frame(maxHeight: .infinity)
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
