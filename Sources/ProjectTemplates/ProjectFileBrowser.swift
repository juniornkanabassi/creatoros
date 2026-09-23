import SwiftUI
import AppKit
import TemplateCore
import UniformTypeIdentifiers

/// Browses a real folder, a registered project or a managed template payload, with opening rules and view modes.
struct FolderBrowserHost: View {
    @EnvironmentObject var m: AppModel
    let title: String
    let resolveRoot: @Sendable () throws -> URL
    var managedTemplate = false
    var surface: BrowserSurface = .projectFiles
    @State private var root: URL?
    @State private var folder = ""
    @State private var selection: String?
    @State private var query = ""
    @State private var projectFilesOnly = false
    @State private var projectFiles: [BrowserItem] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var openingError: String?
    @State private var confirmTemplateOpen: FileBrowserNode?
    @State private var refreshCount = 0
    @State private var token = Cancellation()
    @State private var generation = 0
    @State private var fileObserver: RootFileObserver?

    var shownDocuments: [BrowserItem] { projectFiles.filter { query.isEmpty || $0.relativePath.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if managedTemplate {
                Label("Managed template. Opening a document lets its editor change this reusable copy.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Picker("Show", selection: $projectFilesOnly) { Text("All files").tag(false); Text("Project documents").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().onChange(of: projectFilesOnly) { if projectFilesOnly { loadDocuments() } }
                Spacer()
                if !projectFilesOnly { ViewModePicker(surface: surface) }
                Button { refreshCount += 1; if projectFilesOnly { loadDocuments() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh").accessibilityLabel("Refresh")
            }
            HStack(spacing: 8) {
                Button { goUp() } label: { Image(systemName: "chevron.up") }.disabled(folder.isEmpty || projectFilesOnly).help("Enclosing folder").accessibilityLabel("Enclosing folder")
                Button("Root") { folder = ""; selection = nil; projectFilesOnly = false }.disabled(folder.isEmpty && !projectFilesOnly)
                Button { if let root { NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(selection ?? folder)]) } } label: { Image(systemName: "arrow.up.forward.app") }
                    .disabled(root == nil).help("Reveal in Finder: the selected item, or this folder when nothing is selected, ready to drag into YouTube or anywhere else")
                Text(projectFilesOnly ? "Premiere, After Effects, Photoshop and audio projects" : (folder.isEmpty ? title : folder))
                    .font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                TextField(projectFilesOnly ? "Search documents" : "Search this folder", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
            }
            if !managedTemplate && !projectFilesOnly, root != nil {
                Label("Drop files anywhere below into \(folder.isEmpty ? title : folder). Hold Option to copy.", systemImage: "square.and.arrow.down")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Moves files on the same volume; copies between volumes. Option always copies. Existing names are never replaced. Up to 100 regular files; folders are not supported.")
            }
            Group {
                if let failure {
                    ContentUnavailableView("Cannot browse this folder", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else if let root {
                    if projectFilesOnly { documentList(root: root) }
                    else {
                        FileBrowserView(dataSource: FolderDataSource(root: root), mode: m.viewMode(surface), folder: $folder, selection: $selection,
                                        filter: query, reloadKey: "\(root.path)#\(refreshCount)", onActivate: { node in requestOpen(node) },
                                        onReveal: { node in NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(node.id)]) },
                                        dragURL: managedTemplate ? nil : { node in outgoing(root: root, path: node.id) },
                                        fileDrop: fileDrop)
                    }
                } else { ProgressView("Checking folder…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            .contentShape(Rectangle())
            .onDrop(of: [UTType.fileURL.identifier], delegate: fileDrop)
            HStack {
                Text(selection.map { ($0 as NSString).lastPathComponent } ?? "Nothing selected").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Open in Default App") { if let selection { requestOpen(path: selection) } }.disabled(selection == nil || selection == folder)
            }
        }
        .task(id: refreshCount) { resolve() }
        .onChange(of: m.browserRefresh) { refreshCount += 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshCount += 1 }
        .onAppear { m.activate(surface) }
        .onDisappear { m.deactivate(surface); token.cancel(); generation += 1; fileObserver?.stop(); fileObserver = nil }
        .alert("Could not open file", isPresented: Binding(get: { openingError != nil }, set: { if !$0 { openingError = nil } })) { Button("OK") {} } message: { Text(openingError ?? "") }
        .confirmationDialog("Open a managed template document?", isPresented: Binding(get: { confirmTemplateOpen != nil }, set: { if !$0 { confirmTemplateOpen = nil } }), titleVisibility: .visible) {
            Button("Open Reusable Template") { if let node = confirmTemplateOpen { open(path: node.id) }; confirmTemplateOpen = nil }
            Button("Cancel", role: .cancel) { confirmTemplateOpen = nil }
        } message: { Text("Saving in its editor changes this managed template for future projects. Your original import source stays untouched. Create a project first if you want an independent copy.") }
    }

    func documentList(root: URL) -> some View {
        List(selection: $selection) {
            ForEach(shownDocuments) { item in
                HStack(spacing: 10) {
                    FileArtwork(url: root.appendingPathComponent(item.relativePath))
                    VStack(alignment: .leading, spacing: 2) { Text(item.name).lineLimit(1); Text(item.relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }.tag(item.relativePath)
                    .modifier(BrowserFileDrag(enabled: !managedTemplate, url: { outgoing(root: root, path: item.relativePath) }))
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in if let id = ids.first { Button("Open") { requestOpen(path: id) } } } primaryAction: { ids in if let id = ids.first { requestOpen(path: id) } }
        .overlay { if loading { ProgressView() } else if shownDocuments.isEmpty { Text("No project documents found. Browse All files for a different layout.").font(.callout).foregroundStyle(.secondary).padding() } }
    }

    func outgoing(root: URL, path: String) -> URL? {
        guard !managedTemplate else { return nil }
        do { return try BrowserTransfer.dragURL(root: root, relative: path) }
        catch { m.error = error.localizedDescription; return nil }
    }

    var fileDrop: BrowserFileDrop {
        guard !managedTemplate, !projectFilesOnly, !m.busy, m.storeUsable, failure == nil, let root else { return BrowserFileDrop() }
        let currentFolder = folder
        return BrowserFileDrop { providers, forceCopy, target in
            receive(providers, root: root, folder: currentFolder, target: target, forceCopy: forceCopy)
        }
    }

    func receive(_ providers: [NSItemProvider], root: URL, folder: String, target: String?, forceCopy: Bool) -> Bool {
        guard !managedTemplate, !projectFilesOnly, !m.busy, m.storeUsable, failure == nil else { return false }
        guard !providers.isEmpty, providers.count <= 100,
              providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            m.error = "Drop between 1 and 100 files from Finder. Web links, text and folders are not supported."
            return false
        }
        let destination: URL
        do { destination = try BrowserDropRoute.destination(root: root, displayed: folder, target: target) }
        catch { m.error = error.localizedDescription; return false }
        let runtime = m.runtime
        m.run("Reading dropped files") { cancellation, progress in
            do {
                let sources = try await BrowserDropURLs.load(providers, cancellation: cancellation)
                if BrowserDropRoute.isNoOp(sources, destination: destination, forceCopy: forceCopy) { return [] }
                progress(0, "Transferring files into \(destination.lastPathComponent)")
                return try BrowserTransfer.transfer(sources, into: destination, runtime: runtime, forceCopy: forceCopy, cancellation: cancellation) { completed, total in
                    progress(Double(completed) / Double(total), "Transferred \(completed) of \(total) files")
                }
            } catch is CancellationError {
                throw AppFailure("Transfer cancelled. Check the destination for any files already transferred.")
            }
        } completion: { copied in
            if self.root == root { refreshCount += 1 }
            m.status = copied.isEmpty ? "Files are already in \(destination.lastPathComponent)" : "Transferred \(copied.count) file\(copied.count == 1 ? "" : "s") into \(destination.lastPathComponent)"
        } failure: { _ in
            if self.root == root { refreshCount += 1 }
        }
        return true
    }

    func goUp() {
        let previous = folder
        folder = (folder as NSString).deletingLastPathComponent; selection = previous
    }
    func resolve() {
        token.cancel(); token = Cancellation(); generation += 1
        let current = generation; let resolver = resolveRoot
        // On a refresh the browser stays on screen while the folder is checked again; clearing the root would rebuild
        // it and lose every expanded folder. The root is only replaced when it resolves somewhere else.
        failure = nil
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) { try resolver() }.value
                guard current == generation else { return }
                if root != url { root = url }
                observe(url)
                if projectFilesOnly { loadDocuments() }
            } catch {
                guard current == generation else { return }
                fileObserver?.stop(); fileObserver = nil
                failure = error.localizedDescription
            }
        }
    }
    func loadDocuments() {
        guard let root else { return }
        token.cancel(); token = Cancellation(); generation += 1
        let current = generation; let token = token
        loading = true; projectFiles = []; selection = nil
        Task {
            do {
                let files = try await Task.detached(priority: .userInitiated) { try ProjectBrowser.projectFiles(root: root, cancellation: token) }.value
                guard current == generation else { return }
                projectFiles = files; loading = false
            } catch { guard current == generation else { return }; loading = false; failure = error.localizedDescription }
        }
    }
    func observe(_ root: URL) {
        guard fileObserver?.root != root else { return }
        fileObserver?.stop()
        fileObserver = RootFileObserver(root: root) { refreshCount += 1 }
    }
    func requestOpen(_ node: FileBrowserNode) { if managedTemplate { confirmTemplateOpen = node } else { open(path: node.id) } }
    func requestOpen(path: String) {
        let node = FileBrowserNode(id: path, name: (path as NSString).lastPathComponent, directory: false, package: false, bytes: 0, modified: nil, artworkURL: nil, badge: nil)
        requestOpen(node)
    }
    func open(path: String) {
        guard let root else { return }
        let item = BrowserItem(relativePath: path, name: (path as NSString).lastPathComponent, directory: false, package: false, bytes: 0, modified: nil)
        Task {
            do {
                let url = try await Task.detached { try ProjectBrowser.openable(item, root: root) }.value
                guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { throw AppFailure("No app is registered for this file type. Install or choose the appropriate editor in macOS first.") }
                NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error { Task { @MainActor in openingError = error.localizedDescription } }
                }
            } catch { openingError = error.localizedDescription }
        }
    }
}

/// Watches the browsed directory so Finder's asynchronous outbound moves update the current view.
private final class RootFileObserver: NSObject, NSFilePresenter {
    let root: URL
    var presentedItemURL: URL? { root }
    let presentedItemOperationQueue = OperationQueue()
    private let didChange: () -> Void
    private var observing = true

    init(root: URL, didChange: @escaping () -> Void) {
        self.root = root
        self.didChange = didChange
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    func presentedItemDidChange() { notify() }
    func presentedSubitemDidAppear(at url: URL) { notify() }
    func presentedSubitemDidChange(at url: URL) { notify() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { notify() }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        notify()
        completionHandler(nil)
    }

    func stop() {
        guard observing else { return }
        observing = false
        NSFileCoordinator.removeFilePresenter(self)
    }

    private func notify() {
        DispatchQueue.main.async { [didChange] in didChange() }
    }
}

enum BrowserDropURLs {
    static func load(_ providers: [NSItemProvider], cancellation: Cancellation = Cancellation()) async throws -> [URL] {
        guard !providers.isEmpty, providers.count <= 100,
              providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            throw AppFailure("Drop between 1 and 100 files from Finder.")
        }
        var urls: [URL] = []
        for provider in providers {
            try cancellation.check()
            let loaded = ProviderResult()
            let progress = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                loaded.lock.withLock {
                    loaded.result = error.map { .failure($0) } ?? data.map { .success($0) }
                        ?? .failure(AppFailure("The dropped file did not provide a file URL."))
                }
            }
            defer { progress.cancel() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while loaded.lock.withLock({ loaded.result == nil }) {
                try cancellation.check()
                guard ContinuousClock.now < deadline else { throw AppFailure("The file provider did not respond. Try dragging the files again from Finder.") }
                try await Task.sleep(for: .milliseconds(50))
            }
            let data = try loaded.lock.withLock { try loaded.result!.get() }
            guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                throw AppFailure("Only local file URLs can be transferred. Web links and text are not supported.")
            }
            urls.append(url)
        }
        return urls
    }

    private final class ProviderResult: @unchecked Sendable {
        let lock = NSLock()
        var result: Result<Data, Error>?
    }
}
