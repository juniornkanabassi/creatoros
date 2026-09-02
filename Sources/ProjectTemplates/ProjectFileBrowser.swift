import SwiftUI
import AppKit
import TemplateCore

struct FileArtwork: View {
    let url: URL
    var size: CGFloat = 24
    @State private var artwork: NSImage?
    var body: some View {
        Group {
            if let artwork { Image(nsImage: artwork).resizable().scaledToFit() }
            else { Image(systemName: "doc").resizable().scaledToFit().foregroundStyle(.secondary) }
        }.frame(width: size, height: size).accessibilityHidden(true)
            .task(id: url) { artwork = NSWorkspace.shared.icon(forFile: url.path) }
    }
}

struct ProjectFileBrowser: View {
    let record: ProjectRecord
    var managedTemplate = false
    @State private var root: URL?
    @State private var folder = ""
    @State private var files: [BrowserItem] = []
    @State private var selected: String?
    @State private var query = ""
    @State private var projectFilesOnly = false
    @State private var loading = false
    @State private var failure: String?
    @State private var openingError: String?
    @State private var token = Cancellation()
    @State private var generation = 0
    @State private var confirmTemplateOpen: BrowserItem?
    var shown: [BrowserItem] { files.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || (projectFilesOnly && $0.relativePath.localizedCaseInsensitiveContains(query)) } }
    var selectedItem: BrowserItem? { shown.first { $0.id == selected } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if managedTemplate { Label("Managed template. Opening a document may let its editor change this reusable copy.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
            Picker("Browse", selection: $projectFilesOnly) {
                Text("All files").tag(false)
                Text("Project documents").tag(true)
            }.pickerStyle(.segmented).onChange(of: projectFilesOnly) { load() }
            HStack {
                Button { folder = (folder as NSString).deletingLastPathComponent; load() } label: { Image(systemName: "chevron.up") }
                    .disabled(folder.isEmpty || projectFilesOnly).help("Parent folder").accessibilityLabel("Parent folder")
                Button("Root") { folder = ""; projectFilesOnly = false; load() }.disabled(folder.isEmpty)
                Text(projectFilesOnly ? "Premiere, After Effects, Photoshop and audio projects" : (folder.isEmpty ? record.name : folder)).font(.caption).lineLimit(2).textSelection(.enabled)
                Spacer()
                Button { load() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh files").accessibilityLabel("Refresh files")
            }
            TextField(projectFilesOnly ? "Search project documents" : "Search this folder", text: $query).textFieldStyle(.roundedBorder)
            if loading { ProgressView("Reading folder…").frame(maxWidth: .infinity).padding() }
            else if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Try again") { load() }
            } else {
                List(selection: $selected) {
                    ForEach(shown) { file in
                        HStack(spacing: 10) {
                            if let root { FileArtwork(url: root.appendingPathComponent(file.relativePath)) }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(file.name).font(.body.weight(.medium)).lineLimit(2)
                                Text(projectFilesOnly ? file.relativePath : (file.directory ? (file.package ? "Document package" : "Folder") : ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file))).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            if file.directory && !file.package { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                        }.padding(.vertical, 5).contentShape(Rectangle()).tag(file.id)
                    }
                }.contextMenu(forSelectionType: String.self) { selection in
                    if let file = shown.first(where: { selection.contains($0.id) }) {
                        Button(file.directory && !file.package ? "Browse folder" : "Open in default app") { activate(file) }
                    }
                } primaryAction: { selection in
                    if let file = shown.first(where: { selection.contains($0.id) }) { activate(file) }
                }
                    .listStyle(.inset).frame(minHeight: 230, idealHeight: 310)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                if shown.isEmpty { Text(projectFilesOnly ? "No matching project documents. Browse All files for a different layout." : "No matching visible files. Finder icon metadata stays hidden here.").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Text("\(shown.count) items").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button(selectedItem?.directory == true && selectedItem?.package == false ? "Browse folder" : "Open in default app") { if let file = selectedItem { activate(file) } }.disabled(selectedItem == nil)
                }
            }
        }.task(id: record.path) { load() }
            .onDisappear { token.cancel(); generation += 1 }
            .alert("Could not open file", isPresented: Binding(get: { openingError != nil }, set: { if !$0 { openingError = nil } })) { Button("OK") {} } message: { Text(openingError ?? "") }
            .confirmationDialog("Open a managed template document?", isPresented: Binding(get: { confirmTemplateOpen != nil }, set: { if !$0 { confirmTemplateOpen = nil } }), titleVisibility: .visible) {
                Button("Open reusable template") { if let file = confirmTemplateOpen { open(file) }; confirmTemplateOpen = nil }
                Button("Cancel", role: .cancel) { confirmTemplateOpen = nil }
            } message: { Text("Saving in its editor changes this managed template for future projects. Your original import source stays untouched. Create a new project first if you want to work on an independent copy.") }
    }
    func load() {
        token.cancel(); token = Cancellation(); generation += 1
        let current = generation; let token = token; let folder = folder; let projectOnly = projectFilesOnly
        loading = true; failure = nil; selected = nil; files = []
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let root = try ProjectBrowser.root(record)
                    let files = try projectOnly ? ProjectBrowser.projectFiles(root: root, cancellation: token) : ProjectBrowser.list(root: root, relative: folder, cancellation: token)
                    return (root, files)
                }.value
                guard current == generation else { return }
                root = result.0; files = result.1; loading = false
            } catch { guard current == generation else { return }; loading = false; failure = error.localizedDescription }
        }
    }
    func activate(_ file: BrowserItem) {
        if file.directory && !file.package { folder = file.relativePath; projectFilesOnly = false; query = ""; load() }
        else if managedTemplate { confirmTemplateOpen = file }
        else { open(file) }
    }
    func open(_ file: BrowserItem) {
        Task {
            do {
                let url = try await Task.detached { try ProjectBrowser.openable(file, root: ProjectBrowser.root(record)) }.value
                guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { throw AppFailure("No app is registered for this file type. Install or choose the appropriate editor in macOS first.") }
                NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error { Task { @MainActor in openingError = error.localizedDescription } }
                }
            } catch { openingError = error.localizedDescription }
        }
    }
}
