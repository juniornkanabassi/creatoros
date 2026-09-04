import SwiftUI
import AppKit
import TemplateCore

/// Finder's list view: an outline with disclosure triangles, resizable columns, and a header divider that
/// double-clicks between "fit the longest name" and the default width. Items are the nodes' ids, so the
/// outline keeps its expansion and selection across reloads while folders load in the background.
struct OutlineBrowser: NSViewRepresentable {
    let nodes: [String: [FileBrowserNode]]
    let root: String
    let filter: String
    @Binding var selection: String?
    let onExpand: (String) -> Void
    let onActivate: (FileBrowserNode) -> Void
    /// The interface zoom. AppKit views sit outside SwiftUI's scale effect, so text, rows and icons are scaled here.
    var scale: CGFloat = 1

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = BrowserOutlineView()
        outline.headerView = FitHeaderView()
        outline.rowHeight = 24 * scale
        outline.indentationPerLevel = 16 * scale
        outline.allowsMultipleSelection = false
        outline.usesAlternatingRowBackgroundColors = true
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.focusRingType = .none
        for spec in ColumnSpec.all {
            let column = NSTableColumn(identifier: spec.identifier)
            column.title = spec.title; column.width = spec.width; column.minWidth = spec.minWidth; column.maxWidth = 2000
            column.resizingMask = .userResizingMask
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked)
        outline.onReturn = { [weak coordinator = context.coordinator] in coordinator?.activateSelection() }
        let menu = NSMenu(); menu.delegate = context.coordinator; outline.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.outline = outline
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let structureChanged = coordinator.parent.nodes != nodes || coordinator.parent.root != root || coordinator.parent.filter != filter
        let scaleChanged = coordinator.parent.scale != scale
        coordinator.parent = self
        guard let outline = coordinator.outline else { return }
        if scaleChanged { outline.rowHeight = 24 * scale; outline.indentationPerLevel = 16 * scale }
        if structureChanged || scaleChanged { coordinator.syncing = true; outline.reloadData(); coordinator.syncing = false }
        let current = outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? String : nil
        if current != selection {
            coordinator.syncing = true
            if let selection, case let row = outline.row(forItem: selection), row >= 0 {
                outline.selectRowIndexes([row], byExtendingSelection: false); outline.scrollRowToVisible(row)
            } else { outline.deselectAll(nil) }
            coordinator.syncing = false
        }
    }

    struct ColumnSpec {
        let identifier: NSUserInterfaceItemIdentifier, title: String, width: CGFloat, minWidth: CGFloat
        static let all = [
            ColumnSpec(identifier: .init("name"), title: "Name", width: 320, minWidth: 140),
            ColumnSpec(identifier: .init("modified"), title: "Date Modified", width: 150, minWidth: 90),
            ColumnSpec(identifier: .init("size"), title: "Size", width: 80, minWidth: 60),
            ColumnSpec(identifier: .init("kind"), title: "Kind", width: 150, minWidth: 80),
        ]
        static func spec(for column: NSTableColumn) -> ColumnSpec? { all.first { $0.identifier == column.identifier } }
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: OutlineBrowser
        weak var outline: NSOutlineView?
        var syncing = false
        private var byID: [String: FileBrowserNode] = [:]
        static let dateFormatter: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f }()
        init(_ parent: OutlineBrowser) { self.parent = parent }

        func children(of item: Any?) -> [FileBrowserNode] {
            let path = item as? String ?? parent.root
            let list = (parent.nodes[path] ?? []).filter { parent.filter.isEmpty || $0.name.localizedCaseInsensitiveContains(parent.filter) }
            for node in list { byID[node.id] = node }
            return list
        }
        func node(_ item: Any?) -> FileBrowserNode? { (item as? String).flatMap { byID[$0] } }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(of: item).count }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { children(of: item)[index].id }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { node(item)?.browsable ?? false }
        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let id = notification.userInfo?["NSObject"] as? String, parent.nodes[id] == nil else { return }
            parent.onExpand(id)
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let tableColumn, let node = node(item) else { return nil }
            let identifier = tableColumn.identifier
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView) ?? Self.makeCell(identifier, scale: parent.scale)
            cell.textField?.font = .systemFont(ofSize: NSFont.systemFontSize * parent.scale)
            cell.textField?.stringValue = Self.text(for: node, column: identifier)
            cell.textField?.textColor = node.badge == .placeholder || identifier != .init("name") ? .secondaryLabelColor : .labelColor
            cell.textField?.toolTip = node.subtitle
            if identifier == .init("name") {
                cell.imageView?.image = Self.icon(for: node, size: 16 * parent.scale)
                cell.toolTip = node.badge == nil ? nil : node.subtitle
            }
            return cell
        }
        static func makeCell(_ identifier: NSUserInterfaceItemIdentifier, scale: CGFloat) -> NSTableCellView {
            let cell = NSTableCellView(); cell.identifier = identifier
            let text = NSTextField(labelWithString: ""); text.lineBreakMode = .byTruncatingTail; text.font = .systemFont(ofSize: NSFont.systemFontSize * scale)
            text.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(text); cell.textField = text
            var leading = text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2)
            if identifier == .init("name") {
                let image = NSImageView(); image.imageScaling = .scaleProportionallyUpOrDown
                image.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(image); cell.imageView = image
                NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                             image.widthAnchor.constraint(equalToConstant: 16 * scale), image.heightAnchor.constraint(equalToConstant: 16 * scale)])
                leading = text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6)
            } else if identifier == .init("size") { text.alignment = .right }
            NSLayoutConstraint.activate([leading, text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        static func icon(for node: FileBrowserNode, size: CGFloat) -> NSImage {
            let image: NSImage
            if let url = node.artworkURL { image = NSWorkspace.shared.icon(forFile: url.path) }
            else { image = NSWorkspace.shared.icon(for: node.directory ? .folder : .data) }
            image.size = NSSize(width: size, height: size)
            return image
        }
        static func text(for node: FileBrowserNode, column: NSUserInterfaceItemIdentifier) -> String {
            switch column.rawValue {
            case "name": return node.name
            case "modified": return node.modified.map { dateFormatter.string(from: $0) } ?? "--"
            case "size": return node.directory ? "--" : ByteCountFormatter.string(fromByteCount: node.bytes, countStyle: .file)
            default:
                if node.badge != nil { return node.subtitle }
                if node.directory { return node.package ? "Document package" : "Folder" }
                let ext = (node.name as NSString).pathExtension
                return ext.isEmpty ? "Document" : ext.uppercased() + " file"
            }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let outline else { return }
            let id = outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? String : nil
            if parent.selection != id { parent.selection = id }
        }
        @objc func doubleClicked() {
            guard let outline, outline.clickedRow >= 0, let node = node(outline.item(atRow: outline.clickedRow)) else { return }
            parent.onActivate(node)
        }
        func activateSelection() {
            guard let outline, outline.selectedRow >= 0, let node = node(outline.item(atRow: outline.selectedRow)) else { return }
            parent.onActivate(node)
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, outline.clickedRow >= 0, let node = node(outline.item(atRow: outline.clickedRow)) else { return }
            let item = NSMenuItem(title: node.browsable ? "Browse Folder" : "Open", action: #selector(menuActivate(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = node.id; menu.addItem(item)
        }
        @objc func menuActivate(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? String, let node = byID[id] { parent.onActivate(node) }
        }

        /// Width that shows every visible value in a column, measured from the data rather than the recycled cells.
        func fittedWidth(for column: NSTableColumn) -> CGFloat {
            guard let outline else { return column.width }
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize * parent.scale)
            var widest: CGFloat = 0
            for row in 0..<outline.numberOfRows {
                guard let node = node(outline.item(atRow: row)) else { continue }
                var width = (Self.text(for: node, column: column.identifier) as NSString).size(withAttributes: [.font: font]).width + 12
                if column.identifier == .init("name") { width += CGFloat(outline.level(forRow: row) + 1) * outline.indentationPerLevel + 16 * parent.scale + 8 + 12 }
                widest = max(widest, width)
            }
            return min(max(widest.rounded(.up), column.minWidth), column.maxWidth)
        }
    }
}

/// Return opens the selection, as in Finder with Command-Down; the arrow keys already move and expand.
final class BrowserOutlineView: NSOutlineView {
    var onReturn: () -> Void = {}
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn() } else { super.keyDown(with: event) }
    }
}

/// Double-click on a column divider fits the column to its longest value; double-click again returns the default width.
/// Everything else, including drag-to-resize, is the standard header behaviour.
final class FitHeaderView: NSTableHeaderView {
    private var fitted: Set<NSUserInterfaceItemIdentifier> = []
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, let outline = tableView as? NSOutlineView,
              let column = dividerColumn(at: convert(event.locationInWindow, from: nil)),
              let coordinator = outline.dataSource as? OutlineBrowser.Coordinator else { super.mouseDown(with: event); return }
        if fitted.contains(column.identifier) {
            column.width = OutlineBrowser.ColumnSpec.spec(for: column)?.width ?? column.width
            fitted.remove(column.identifier)
        } else {
            column.width = coordinator.fittedWidth(for: column)
            fitted.insert(column.identifier)
        }
    }
    override func resetCursorRects() { super.resetCursorRects() }
    private func dividerColumn(at point: NSPoint) -> NSTableColumn? {
        guard let tableView else { return nil }
        for (index, column) in tableView.tableColumns.enumerated() where !column.isHidden {
            let rect = headerRect(ofColumn: index)
            if abs(point.x - rect.maxX) <= 4 { return column }
        }
        return nil
    }
}
