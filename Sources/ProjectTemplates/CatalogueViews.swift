import SwiftUI
import AVKit
import TemplateCore

struct NativeVideoPreview: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause(); view.player = nil }
}

struct FormatIcon: View {
    let data: Data?
    var size: CGFloat = 26
    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "folder.fill").resizable().scaledToFit().foregroundStyle(.secondary) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct CatalogueView: View {
    @EnvironmentObject var m: AppModel
    var exportsOnly = false
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Search projects, exports or previous locations", text: $m.search).textFieldStyle(.roundedBorder)
                Menu("Add") {
                    Button("Project Collection or Drive Folder…") { m.scanLocation() }
                    Button("One Existing Project…") { m.addExisting() }
                }
            }.padding(.horizontal, 20).padding(.top, 16)
            HStack {
                FormatButtons(selection: $m.formatFilter, includeAll: true).help("Format follows the parent project, including its video exports.")
                Spacer()
                if exportsOnly { Toggle("Finals only", isOn: $m.onlyFinals).toggleStyle(.switch).controlSize(.small) }
            }.padding(.horizontal, 20)
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    if exportsOnly { allExports }
                    else {
                        List(m.filteredProjects, selection: $m.selectedProject) { record in
                            HStack(alignment: .top, spacing: 10) {
                                FormatIcon(data: m.library.presets.first { $0.format == record.format }?.icon)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(record.name).font(.headline)
                                    Text("\(record.volumeName ?? "Saved location") · \((record.exports ?? []).count) exports").font(.caption).foregroundStyle(.secondary)
                                    Text(record.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }.padding(.vertical, 6).tag(record.id)
                        }.onChange(of: m.selectedProject) { m.selectProject() }
                    }
                    if m.library.projects.isEmpty {
                        Text("Add a collection folder to build your catalogue. Files stay where they are.").font(.callout).foregroundStyle(.secondary).padding()
                    }
                    DisclosureGroup("Saved locations (\((m.library.locations ?? []).count))") {
                        ForEach(m.library.locations ?? []) { location in
                            HStack { Text(location.name).font(.caption).help(location.path); Spacer(); Button("Scan") { m.rescanLocation(location) }.font(.caption) }
                        }
                    }.padding(12)
                }.frame(minWidth: 270, idealWidth: 420, maxWidth: 800, maxHeight: .infinity, alignment: .topLeading)
                if let record = m.selectedRecord { ProjectInspector(record: record).frame(minWidth: 400, idealWidth: 540, maxWidth: .infinity, maxHeight: .infinity) }
                else { ContentUnavailableView("Your projects, wherever they live", systemImage: "externaldrive", description: Text("Select a project or export. Cached names and locations remain searchable when a drive is disconnected.")).frame(minWidth: 400, idealWidth: 540, maxWidth: .infinity, maxHeight: .infinity) }
            }.frame(maxHeight: .infinity)
            Text("\(m.filteredProjects.count) projects · \(m.filteredProjects.reduce(0) { $0 + (exportsOnly ? m.matchingExports($1).count : ($1.exports ?? []).count) }) exports. Files stay in their original folders.")
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 12)
        }.sheet(isPresented: $m.discoveryPresented) { DiscoveryView() }
        .onAppear { m.inspectorTab = exportsOnly ? "Exports" : "Files" }
        .onDisappear { m.stopPreview() }
    }
    var allExports: some View {
        List {
            ForEach(m.filteredProjects) { record in
                ForEach(m.matchingExports(record)) { export in
                    Button {
                        m.selectedProject = record.id
                        m.inspectorTab = "Exports"
                        m.inspectProject(record)
                        m.preview(export, in: record)
                    } label: {
                        HStack(alignment: .top) {
                            FormatIcon(data: m.library.presets.first { $0.format == record.format }?.icon)
                            VStack(alignment: .leading, spacing: 4) {
                                Text((export.relativePath as NSString).lastPathComponent).lineLimit(2)
                                Text(record.name).font(.caption).foregroundStyle(.secondary)
                                Text(record.volumeName ?? record.path).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if record.markedFinals.contains(export.relativePath) { Image(systemName: "star.fill").foregroundStyle(.orange).accessibilityLabel("Marked final") }
                        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

struct ProjectInspector: View {
    @EnvironmentObject var m: AppModel
    let record: ProjectRecord
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) { FormatIcon(data: m.library.presets.first { $0.format == record.format }?.icon, size: 38); Text(record.name).font(.title3.weight(.semibold)).textSelection(.enabled) }
                Text(m.inspections[record.id]?.status ?? "Checking location…").font(.callout).foregroundStyle(.secondary)
                Text(record.path).font(.caption).textSelection(.enabled)
                HStack {
                    Button("Open Folder") { m.open(record) }
                    Button("Reveal") { m.reveal(record) }
                    Menu("More") {
                        Button("Refresh Exports") { m.inspectProject(record) }
                        Button("Locate Folder…") { m.locate(record) }
                        Button("Add Export Subfolder…") { m.addExportFolder(record) }
                        Button("Remove Catalogue Record") { m.removeRecord(record) }
                    }
                }
                if let old = record.previousPaths, !old.isEmpty {
                    DisclosureGroup("Previous locations") { Text(old.joined(separator: "\n")).font(.caption).textSelection(.enabled) }
                }
                Picker("Project contents", selection: $m.inspectorTab) { Text("Files").tag("Files"); Text("Video exports").tag("Exports") }.pickerStyle(.segmented)
                if m.inspectorTab == "Files" {
                    ProjectFileBrowser(record: record).id(record.id)
                } else {
                if let player = m.player, let export = m.selectedExport {
                    NativeVideoPreview(player: player).frame(height: 240)
                    Text((export.relativePath as NSString).lastPathComponent).font(.caption).lineLimit(2)
                    Text("Preview starts paused and muted. Cloud-only files may need downloading; unsupported codecs can be opened in another app.").font(.caption2).foregroundStyle(.secondary)
                }
                Divider()
                HStack { Text("Video exports").font(.headline); Spacer(); Text("\((record.exports ?? []).count)").foregroundStyle(.secondary) }
                if let indexed = record.lastIndexed { Text("Last indexed \(indexed.formatted())").font(.caption).foregroundStyle(.secondary) }
                if (record.exports ?? []).isEmpty {
                    Text("No video exports were found in the recognised export folders. Use More → Add Export Subfolder for a different structure.").foregroundStyle(.secondary)
                }
                ForEach(record.exports ?? []) { export in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            FormatIcon(data: m.library.presets.first { $0.format == record.format }?.icon, size: 22)
                            Text((export.relativePath as NSString).lastPathComponent).font(.subheadline.weight(.medium)).lineLimit(3)
                            if record.markedFinals.contains(export.relativePath) { Image(systemName: "star.fill").foregroundStyle(.orange).accessibilityLabel("Marked final") }
                        }
                        Text(export.relativePath).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(ByteCountFormatter.string(fromByteCount: export.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Preview") { m.preview(export, in: record) }
                            Button("Open") { m.preview(export, in: record, external: true) }
                            Button(record.markedFinals.contains(export.relativePath) ? "Unmark Final" : "Mark Final") { m.markFinal(export, in: record) }
                        }.font(.caption)
                    }.padding(.vertical, 7)
                    Divider()
                }
                ForEach(record.markedFinals.filter { final in !(record.exports ?? []).contains(where: { $0.relativePath == final }) }.sorted(), id: \.self) { final in
                    Text("Your marked final is not in the latest index: \(final). Its saved selection has been retained.").font(.caption).foregroundStyle(.orange)
                }
                if let notes = record.scanNotes, !notes.isEmpty { DisclosureGroup("Index notes") { Text(notes.joined(separator: "\n")).font(.caption) } }
                }
            }.padding(20)
        }
    }
}

struct DiscoveryView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add projects to your catalogue").font(.title2.weight(.semibold))
            Text(m.discovery?.location.path ?? "").font(.caption).textSelection(.enabled)
            Text("Select the detected projects to register. Recognition is based on folder structure, not proof that a project is finished. Nothing will be moved, renamed or deleted.").foregroundStyle(.secondary)
            List(m.discovery?.projects ?? []) { record in
                Toggle(isOn: Binding(get: { m.discoverySelection.contains(record.id) }, set: { if $0 { m.discoverySelection.insert(record.id) } else { m.discoverySelection.remove(record.id) } })) {
                    VStack(alignment: .leading) { Text(record.name); Text("\(record.format) · \((record.exports ?? []).count) exports · \(record.path)").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let notes = m.discovery?.notes, !notes.isEmpty { DisclosureGroup("Scan notes") { ScrollView { Text(notes.joined(separator: "\n")).font(.caption) }.frame(maxHeight: 80) } }
            if m.discovery?.projects.isEmpty == true { Text("No projects recognised. Add one existing project manually, or choose a smaller collection.").font(.callout) }
            HStack { Button("Cancel") { m.discoveryPresented = false }; Spacer(); Button("Register \(m.discoverySelection.count) Projects") { m.registerDiscovery() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 750, height: 570)
    }
}
