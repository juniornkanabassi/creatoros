import SwiftUI
import AppKit
import TemplateCore
import UniformTypeIdentifiers

enum BrowserViewMode: String, CaseIterable, Identifiable {
    case icon, list, column
    var id: String { rawValue }
    var title: String { switch self { case .icon: "Icons"; case .list: "List"; case .column: "Columns" } }
    var menuTitle: String { "as " + title }
    var systemImage: String { switch self { case .icon: "square.grid.2x2"; case .list: "list.bullet"; case .column: "rectangle.split.3x1" } }
    var shortcut: KeyEquivalent { switch self { case .icon: "1"; case .list: "2"; case .column: "3" } }
}

enum BrowserBadge: Hashable { case renamed(from: String), placeholder, issue(String) }

struct FileBrowserNode: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let directory: Bool
    let package: Bool
    let bytes: Int64
    let modified: Date?
    let artworkURL: URL?
    let badge: BrowserBadge?
    var browsable: Bool { directory && !package }
    var subtitle: String {
        switch badge {
        case .renamed(let from): "was " + from
        case .placeholder: "waits for the missing fields"
        case .issue(let text): text
        case nil: directory ? (package ? "Document package" : "Folder") : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }
}

protocol FileBrowserDataSource: Sendable {
    /// True when children are available instantly on the main actor, as for a rendered preview.
    var isSynchronous: Bool { get }
    func children(of folder: String, cancellation: Cancellation) throws -> [FileBrowserNode]
}

/// A real folder, listed with every safety rule in ProjectBrowser.
struct FolderDataSource: FileBrowserDataSource {
    let root: URL
    var isSynchronous: Bool { false }
    func children(of folder: String, cancellation: Cancellation) throws -> [FileBrowserNode] {
        try ProjectBrowser.list(root: root, relative: folder, cancellation: cancellation).map {
            FileBrowserNode(id: $0.relativePath, name: $0.name, directory: $0.directory, package: $0.package, bytes: $0.bytes,
                            modified: $0.modified, artworkURL: root.appendingPathComponent($0.relativePath), badge: nil)
        }
    }
}

/// The prospective project. Read-only, never opens anything, shows badges for renamed and placeholder names.
struct PreviewDataSource: FileBrowserDataSource {
    let rendering: PreviewRendering
    /// Plain folders: the project will be copied without its folder icons, so folders show as Finder's plain folder.
    var plain = false
    var isSynchronous: Bool { true }
    func children(of folder: String, cancellation: Cancellation) throws -> [FileBrowserNode] {
        rendering.children(of: folder).map { entry in
            let badge: BrowserBadge? = entry.issue.map { .issue($0) } ?? (entry.placeholder ? .placeholder : (entry.renamed ? .renamed(from: entry.sourceName) : nil))
            return FileBrowserNode(id: entry.source, name: entry.name, directory: entry.directory, package: entry.package, bytes: entry.bytes,
                                   modified: nil, artworkURL: plain && entry.directory ? nil : rendering.root.appendingPathComponent(entry.source), badge: badge)
        }
    }
}

struct FileArtwork: View {
    let url: URL?
    var size: CGFloat = 24
    var fallback: String = "doc"
    @State private var artwork: NSImage?
    var body: some View {
        Group {
            if let artwork { Image(nsImage: artwork).resizable().scaledToFit() }
            else if fallback == "folder.fill" { Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable().scaledToFit() }
            else { Image(systemName: fallback).resizable().scaledToFit().foregroundStyle(.secondary).padding(size * 0.12) }
        }.frame(width: size, height: size).accessibilityHidden(true)
            .task(id: url) { if let url { artwork = NSWorkspace.shared.icon(forFile: url.path) } }
    }
}

struct ViewModePicker: View {
    @EnvironmentObject var m: AppModel
    let surface: BrowserSurface
    var body: some View {
        Picker("View", selection: Binding(get: { m.viewMode(surface) }, set: { m.setViewMode($0, for: surface) })) {
            ForEach(BrowserViewMode.allCases) { mode in Image(systemName: mode.systemImage).help(mode.title + " (⌘" + String(mode.shortcut.character) + ")").tag(mode) }
        }.pickerStyle(.segmented).labelsHidden().fixedSize().accessibilityLabel("View mode")
    }
}

/// One browser, three Finder-style views. The (folder, selection) pair is the whole navigation state,
/// so switching views never loses the place.
struct FileBrowserView: View {
    @EnvironmentObject var m: AppModel
    let dataSource: any FileBrowserDataSource
    let mode: BrowserViewMode
    @Binding var folder: String
    @Binding var selection: String?
    var filter = ""
    var reloadKey: AnyHashable = 0
    var onActivate: (FileBrowserNode) -> Void = { _ in }
    /// Shows the item in Finder. Nil for previews, which have no real files yet.
    var onReveal: ((FileBrowserNode) -> Void)? = nil
    var dragURL: ((FileBrowserNode) -> URL?)? = nil
    var fileDrop = BrowserFileDrop()
    @State private var loaded: [String: [FileBrowserNode]] = [:]
    @State private var loading: Set<String> = []
    @State private var failure: String?
    @State private var token = Cancellation()
    @State private var generation = 0
    @FocusState private var focusedColumn: Int?
    /// Column view widths by folder path; a divider drag sets one, a double-click fits it to the longest name and back.
    @State private var columnWidths: [String: CGFloat] = [:]
    static let defaultColumnWidth: CGFloat = 230

    var columnPaths: [String] {
        guard !folder.isEmpty else { return [""] }
        var paths = [""]; var current = ""
        for part in folder.split(separator: "/") { current = current.isEmpty ? String(part) : current + "/" + part; paths.append(current) }
        return paths
    }
    func nodes(in path: String) -> [FileBrowserNode] {
        (loaded[path] ?? []).filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        Group {
            if let failure {
                ContentUnavailableView("Cannot read this folder", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else {
                switch mode {
                case .list: listView(path: folder)
                case .icon: iconView(path: folder)
                case .column: columnView
                }
            }
        }
        .task(id: reloadKey) { reloadAll() }
        .onChange(of: folder) { ensureLoaded() }
        .onChange(of: mode) { ensureLoaded() }
        .onDisappear { token.cancel() }
    }

    // MARK: Loading

    func ensureLoaded() { for path in (mode == .column ? columnPaths : [folder]) where loaded[path] == nil { load(path) } }
    /// Reads every folder again, including subfolders that are expanded in the list view; a refresh that only re-read
    /// the top level left an expanded folder empty, so a file dropped into it never appeared. Loads that were still in
    /// flight are forgotten rather than left blocking the next read.
    func reloadAll() {
        let wanted = Set(loaded.keys).union(mode == .column ? columnPaths : [folder])
        loading = []; failure = nil; generation += 1
        // The old listing stays on screen until the new one replaces it, so expanded folders and the selection keep
        // their places instead of collapsing while the drive answers.
        for path in wanted { load(path) }
    }
    func load(_ path: String) {
        guard !loading.contains(path) else { return }
        let source = dataSource
        if source.isSynchronous {
            do { loaded[path] = try source.children(of: path, cancellation: Cancellation()) } catch { failure = error.localizedDescription }
            return
        }
        loading.insert(path)
        let current = generation; let token = token
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try source.children(of: path, cancellation: token) }.value
                guard current == generation else { return }
                loaded[path] = result; loading.remove(path)
            } catch {
                guard current == generation else { return }
                loading.remove(path); failure = error.localizedDescription
            }
        }
    }

    // MARK: Navigation

    func activate(_ node: FileBrowserNode) {
        if node.browsable { folder = node.id; selection = nil } else { onActivate(node) }
    }
    func goToParent() {
        guard !folder.isEmpty else { return }
        let previous = folder
        folder = (folder as NSString).deletingLastPathComponent; selection = previous
    }

    // MARK: List

    /// Finder's list view: an outline whose folders expand in place, with resizable columns. Double-clicking a folder
    /// still steps into it, and double-clicking a file opens it under the same rules as the other views.
    func listView(path: String) -> some View {
        let items = nodes(in: path)
        return OutlineBrowser(nodes: loaded, root: path, filter: filter, selection: $selection, onExpand: { load($0) }, onActivate: { activate($0) }, scale: m.uiScale, onReveal: onReveal, dragURL: dragURL, fileDrop: fileDrop)
            .overlay { if loading.contains(path) && loaded[path] == nil { ProgressView() } else if items.isEmpty && loaded[path] != nil { emptyLabel } }
    }

    // MARK: Icons

    func iconView(path: String) -> some View {
        let items = nodes(in: path)
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 128), spacing: 6)], spacing: 10) {
                ForEach(items) { node in
                    VStack(spacing: 6) {
                        FileArtwork(url: node.artworkURL, size: 52, fallback: node.directory ? "folder.fill" : "doc")
                        Text(node.name).font(.caption).multilineTextAlignment(.center).lineLimit(3)
                            .foregroundStyle(node.badge == .placeholder ? .secondary : .primary)
                        if node.badge != nil { BadgeMark(badge: node.badge!) }
                    }
                    .padding(8).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selection == node.id ? Color.accentColor.opacity(0.22) : .clear))
                    .contentShape(Rectangle())
                    .gesture(TapGesture(count: 2).onEnded { activate(node) })
                    .simultaneousGesture(TapGesture().onEnded { selection = node.id })
                    .contextMenu {
                        Button(node.browsable ? "Browse Folder" : "Open") { activate(node) }
                        if let onReveal { Button("Reveal in Finder") { onReveal(node) } }
                    }
                    .help(node.subtitle)
                    .accessibilityElement(children: .combine).accessibilityLabel(node.name).accessibilityHint(node.subtitle)
                    .accessibilityAddTraits(selection == node.id ? .isSelected : [])
                    .modifier(BrowserFileDrag(enabled: dragURL != nil && !node.directory, url: { dragURL?(node) }))
                    .modifier(BrowserFolderDrop(fileDrop: fileDrop, target: node.browsable ? node.id : nil))
                }
            }.padding(10)
        }
        .focusable()
        .onKeyPress(.return) { if let node = items.first(where: { $0.id == selection }) { activate(node); return .handled }; return .ignored }
        .onKeyPress(.rightArrow) { step(items, by: 1) }
        .onKeyPress(.leftArrow) { step(items, by: -1) }
        .onKeyPress(.downArrow) { step(items, by: 4) }
        .onKeyPress(.upArrow) { step(items, by: -4) }
        .overlay { if loading.contains(path) { ProgressView() } else if items.isEmpty { emptyLabel } }
    }
    func step(_ items: [FileBrowserNode], by delta: Int) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        let index = items.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : items.count)
        let next = min(max(index + delta, 0), items.count - 1)
        selection = items[next].id
        return .handled
    }

    // MARK: Columns

    var columnView: some View {
        let paths = columnPaths
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(paths.enumerated()), id: \.element) { index, path in
                        column(index: index, path: path, isLast: index == paths.count - 1)
                            .frame(width: columnWidths[path] ?? Self.defaultColumnWidth).id(path)
                        ColumnDivider(width: Binding(get: { columnWidths[path] ?? Self.defaultColumnWidth }, set: { columnWidths[path] = $0 }),
                                      fitted: { fittedWidth(for: path) }, defaultWidth: Self.defaultColumnWidth)
                    }
                }
            }
            .onChange(of: folder) { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(paths.last, anchor: .trailing) } }
            .onAppear { proxy.scrollTo(paths.last, anchor: .trailing) }
        }
    }
    func column(index: Int, path: String, isLast: Bool) -> some View {
        let items = nodes(in: path)
        let highlighted = Binding<String?>(
            get: { isLast ? selection : columnPaths[index + 1] },
            set: { chosen in
                guard let chosen, let node = items.first(where: { $0.id == chosen }) else { if isLast { selection = nil }; return }
                if node.browsable { folder = node.id; selection = nil } else { folder = path; selection = node.id }
            })
        return List(selection: highlighted) {
            ForEach(items) { node in
                HStack(spacing: 8) {
                    BrowserRow(node: node, artworkSize: 20, compact: true)
                    if node.browsable { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                }.tag(node.id)
                    .modifier(BrowserFileDrag(enabled: dragURL != nil && !node.directory, url: { dragURL?(node) }))
                    .modifier(BrowserFolderDrop(fileDrop: fileDrop, target: node.browsable ? node.id : nil))
            }
        }
        .listStyle(.plain)
        .modifier(BrowserFolderDrop(fileDrop: fileDrop, target: path))
        .focused($focusedColumn, equals: index)
        .contextMenu(forSelectionType: String.self) { ids in
            if let node = items.first(where: { ids.contains($0.id) }) {
                if !node.browsable { Button("Open") { onActivate(node) } }
                if let onReveal { Button("Reveal in Finder") { onReveal(node) } }
            }
        } primaryAction: { ids in
            if let node = items.first(where: { ids.contains($0.id) }), !node.browsable { onActivate(node) }
        }
        .onKeyPress(.leftArrow) {
            guard index > 0 else { return .ignored }
            folder = columnPaths[index - 1]; selection = path; focusedColumn = index - 1; return .handled
        }
        .onKeyPress(.rightArrow) {
            guard !isLast, let first = nodes(in: columnPaths[index + 1]).first else { return .ignored }
            if first.browsable { folder = first.id; selection = nil } else { selection = first.id }
            focusedColumn = index + 1; return .handled
        }
        .overlay { if loading.contains(path) { ProgressView() } else if items.isEmpty { emptyLabel } }
    }

    /// The width that shows every name in a column in full: icon, gap, text, chevron and padding.
    func fittedWidth(for path: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize * m.uiScale)
        let widest = nodes(in: path).map { ($0.name as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return max(Self.defaultColumnWidth, (widest + 20 * m.uiScale + 8 + 24 + 28).rounded(.up))
    }
    var emptyLabel: some View {
        Text(filter.isEmpty ? "Empty folder" : "No matches").font(.callout).foregroundStyle(.secondary)
    }
}

/// NSURL provides a native file URL that Finder and browser upload targets can read.
struct BrowserFileDrag: ViewModifier {
    let enabled: Bool
    let url: () -> URL?
    @State private var source = BrowserDragSourceView()
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.background(BrowserDragAnchor(source: source).allowsHitTesting(false))
                .simultaneousGesture(DragGesture(minimumDistance: 5).onChanged { _ in
                    source.begin(url: url)
                })
        } else { content }
    }
    static let operations: NSDragOperation = [.copy, .move]
    static func operations(for context: NSDraggingContext) -> NSDragOperation { operations }
    static func provider(_ url: URL) -> NSItemProvider { NSItemProvider(object: url as NSURL) }
}

private struct BrowserDragAnchor: NSViewRepresentable {
    let source: BrowserDragSourceView
    func makeNSView(context: Context) -> BrowserDragSourceView { source }
    func updateNSView(_ nsView: BrowserDragSourceView, context: Context) {}
}

/// SwiftUI owns hit testing and click/selection gestures, including when zoomed.
/// AppKit supplies file drag negotiation; Finder performs its own moves.
final class BrowserDragSourceView: NSView, NSDraggingSource {
    private var dragging = false
    func begin(url: () -> URL?) {
        guard !dragging, let event = NSApp.currentEvent, event.type == .leftMouseDragged,
              event.window == window, let url = url() else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48),
                              contents: NSWorkspace.shared.icon(forFile: url.path))
        dragging = true
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        BrowserFileDrag.operations(for: context)
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
    }
}

/// Shared by the SwiftUI content area and the native outline, including empty space.
struct BrowserFileDrop: DropDelegate {
    var receive: (([NSItemProvider], Bool, String?) -> Bool)? = nil
    var target: String? = nil

    func validateDrop(info: DropInfo) -> Bool {
        receive != nil && info.hasItemsConforming(to: [UTType.fileURL.identifier])
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Acceptance starts an asynchronous transfer. Copy transport keeps the source from deleting
        // originals on drag-end; the engine alone commits filesystem moves after validation.
        DropProposal(operation: receive == nil ? .cancel : .copy)
    }
    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [UTType.fileURL.identifier])
        return receive?(providers, NSEvent.modifierFlags.contains(.option), target) ?? false
    }
    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

private struct BrowserFolderDrop: ViewModifier {
    let fileDrop: BrowserFileDrop
    let target: String?
    @ViewBuilder func body(content: Content) -> some View {
        if let target { content.onDrop(of: [UTType.fileURL.identifier], delegate: BrowserFileDrop(receive: fileDrop.receive, target: target)) }
        else { content }
    }
}

/// The line between two columns in column view: drag it to resize the column on its left, double-click it to fit
/// that column to its longest name, double-click again to return to the default width. Finder's behaviour.
struct ColumnDivider: View {
    @Binding var width: CGFloat
    let fitted: () -> CGFloat
    let defaultWidth: CGFloat
    @State private var startWidth: CGFloat?
    @State private var isFitted = false
    var body: some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
            .padding(.horizontal, 3).contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            // Global coordinates: the divider itself moves as the column grows, so a local translation would feed back into the drag.
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { value in
                if startWidth == nil { startWidth = width }
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { width = min(max((startWidth ?? width) + value.translation.width, 120), 900) }
                isFitted = false
            }.onEnded { _ in startWidth = nil })
            .onTapGesture(count: 2) {
                if isFitted { width = defaultWidth; isFitted = false } else { width = fitted(); isFitted = true }
            }
            .help("Drag to resize. Double-click to fit the longest name, double-click again for the default width.")
            .accessibilityLabel("Column divider")
    }
}

struct BrowserRow: View {
    let node: FileBrowserNode
    var artworkSize: CGFloat = 26
    var compact = false
    var body: some View {
        HStack(spacing: 10) {
            FileArtwork(url: node.artworkURL, size: artworkSize, fallback: node.directory ? "folder.fill" : "doc")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(node.name).lineLimit(compact ? 1 : 2).foregroundStyle(node.badge == .placeholder ? .secondary : .primary)
                    if let badge = node.badge, !compact { BadgeMark(badge: badge) }
                }
                if !compact { Text(node.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }.padding(.vertical, compact ? 1 : 3).help(node.subtitle)
    }
}

struct BadgeMark: View {
    let badge: BrowserBadge
    var body: some View {
        switch badge {
        case .renamed: Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(Color.accentColor).accessibilityLabel("Renamed")
        case .placeholder: Image(systemName: "square.dashed").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("Waits for missing fields")
        case .issue: Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange).accessibilityLabel("Problem")
        }
    }
}
