import SwiftUI
import AppKit
import TemplateCore

@main struct ContentTemplateApp: App {
    @StateObject private var model = AppModel()
    init() {
        // A second launch should activate the running app, not open a second
        // writer over the same library. Test bundles use a separate identifier.
        if let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateAllWindows])
            exit(0)
        }
    }
    var body: some Scene {
        WindowGroup("Content Template") {
            MainView().environmentObject(model).frame(minWidth: 1000, minHeight: 680)
                .onAppear {
                    NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); model.refresh()
                    WindowSetup.apply(zoom: { model.zoom($0) }, reset: { model.zoomLevel = 0 })
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { model.newProjectPresented = true }.keyboardShortcut("n")
                Divider()
                Button("Refresh Project") { model.refreshProject() }.keyboardShortcut("r").disabled(model.selectedProject == nil && model.pipelineSelection == nil)
                Button("Find Missing Projects") { model.relinkAll() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.relinkBatchRunning)
                Button("Duplicates…") { model.duplicatesPresented = true }.disabled(model.duplicateGroups.isEmpty)
            }
            CommandGroup(after: .textEditing) {
                Button("Find") { AppModel.focusSearchField() }.keyboardShortcut("f")
            }
            CommandGroup(before: .sidebar) {
                ForEach(BrowserViewMode.allCases) { mode in
                    Toggle(mode.menuTitle, isOn: Binding(get: { model.activeViewMode == mode }, set: { if $0 { model.setActiveViewMode(mode) } }))
                        .keyboardShortcut(mode.shortcut, modifiers: .command)
                        .disabled(model.activeSurface == nil)
                }
                Divider()
                Button("Bigger Text") { model.zoom(1) }.keyboardShortcut("=", modifiers: .command)
                Button("Smaller Text") { model.zoom(-1) }.keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { model.zoomLevel = 0 }.keyboardShortcut("0", modifiers: .command)
                Button("Toggle Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }.keyboardShortcut("f", modifiers: [.control, .command])
                Divider()
            }
            CommandMenu("Go") {
                ForEach(Array(Page.allCases.enumerated()), id: \.element) { index, page in
                    Button(page.rawValue) { model.page = page }.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .shift])
                }
            }
        }
        // Settings is a standard window at standard size. It is not zoomed: the AppKit tab view inside a scaled
        // subtree drew in one place and took clicks in another, which is why nothing in Settings responded when zoomed.
        Settings {
            SettingsView().environmentObject(model).frame(width: 640, height: 560)
        }
    }
}

/// macOS does not scale this interface's semantic fonts with Dynamic Type.
/// Scale layout and hit targets together, with horizontal scrolling at narrow
/// widths rather than clipping controls or shrinking the text back down.
struct ZoomedInterface<Content: View>: View {
    let scale: CGFloat
    let minimumWidth: CGFloat
    @ViewBuilder let content: () -> Content
    var body: some View {
        GeometryReader { geometry in
            let width = max(minimumWidth, geometry.size.width / scale)
            ScrollView(.horizontal) {
                content()
                    .frame(width: width, height: geometry.size.height / scale)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: width * scale, height: geometry.size.height, alignment: .topLeading)
            }
        }
    }
}

/// Full screen and text zoom are keyboard habits. macOS 15 moved the system Enter Full Screen shortcut to the Globe key,
/// so the View menu item is given back its Control-Command-F equivalent here.
enum WindowSetup {
    private static var keyMonitor: Any?
    static func apply(zoom: @escaping (Int) -> Void, reset: @escaping () -> Void) {
        for window in NSApp.windows where window.styleMask.contains(.titled) {
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
        // Command with = + - 0 zooms from anywhere in the window, including while a text field has focus,
        // and Command-Shift-= (the + key) counts as Command-+. Handled here so the menu equivalents never double up.
        // Junior asked for Command on 3 September after first saying Control; Control-Command-F stays for full screen.
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .numericPad, .function])
                guard flags == .command else { return event }
                // Key codes cover every layout; the characters cover keyboards where = and - sit elsewhere.
                let characters = event.charactersIgnoringModifiers ?? ""
                switch (event.keyCode, characters) {
                case (24, _), (69, _), (_, "="), (_, "+"): zoom(1); return nil
                case (27, _), (78, _), (_, "-"), (_, "_"): zoom(-1); return nil
                case (29, _), (82, _), (_, "0"): reset(); return nil
                default: return event
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let view = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu else { return }
            for item in view.items where item.action == #selector(NSWindow.toggleFullScreen(_:)) {
                item.keyEquivalent = "f"
                item.keyEquivalentModifierMask = [.control, .command]
            }
        }
    }
}

struct MainView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        NavigationSplitView {
            // Icon, gap and row height scale together with the text, so a zoomed sidebar keeps Finder's proportions.
            List(selection: $m.page) {
                ForEach(Page.allCases) { page in
                    HStack(spacing: 10 * m.uiScale) {
                        Image(systemName: page.systemImage).font(.system(size: 17 * m.uiScale)).frame(width: 26 * m.uiScale, alignment: .center)
                        Text(page.rawValue).font(.system(size: 15 * m.uiScale, weight: .medium))
                    }
                    .padding(.vertical, 6 * m.uiScale).tag(page).help(page.hint)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190 * m.uiScale, ideal: 215 * m.uiScale, max: 280 * m.uiScale)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Content Template").font(.caption.weight(.medium))
                    Text("\(AppInfo.version) · local and offline").font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        } content: {
            ZoomedInterface(scale: m.uiScale, minimumWidth: 300) {
            Group {
                switch m.page {
                case .pipeline: PipelineSidebar()
                case .projects: ProjectList()
                case .templates: TemplateSetList()
                }
            }
            }
            .navigationSplitViewColumnWidth(min: 360 * m.uiScale, ideal: 440 * m.uiScale, max: 600 * m.uiScale)
        } detail: {
            ZoomedInterface(scale: m.uiScale, minimumWidth: 360) {
            VStack(spacing: 0) {
                Group {
                    switch m.page {
                    case .pipeline: PipelineBoard()
                    case .projects: ProjectDetail()
                    case .templates: TemplateSetDetail()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if m.busy || (!m.status.isEmpty && m.status.hasPrefix("Looking")) {
                    Divider()
                    HStack(spacing: 12) {
                        if m.busy { ProgressView(value: m.fraction).frame(width: 160) }
                        Text(m.status).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if m.busy { Button("Cancel") { m.cancellation.cancel() }.keyboardShortcut(.cancelAction) }
                    }.padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
                }
            }
            }
            .navigationSplitViewColumnWidth(min: 420 * m.uiScale, ideal: 640 * m.uiScale)
        }
        .navigationTitle(m.page.rawValue)
        .disabled(!m.storeUsable)
        .alert("Content Template", isPresented: Binding(get: { m.error != nil }, set: { if !$0 { m.error = nil } })) {
            Button("OK") { m.error = nil }
        } message: { Text(m.error ?? "") }
        .sheet(isPresented: $m.newProjectPresented) { NewProjectSheet() }
        .sheet(isPresented: $m.importPresented) { ImportSheet() }
        .sheet(item: $m.newSetPrompt) { _ in NewSetSheet() }
        .sheet(item: $m.templateToBrowse) { record in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.name).font(.title2.weight(.semibold))
                        Text("Managed template · \(record.mode.title)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Done") { m.finishedBrowsingTemplate() }.keyboardShortcut(.cancelAction)
                }
                FolderBrowserHost(title: record.name, resolveRoot: { [store = m.store] in
                    let url = store.payload(record)
                    guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw AppFailure("The managed copy is missing from the template library.") }
                    return url
                }, managedTemplate: true, surface: .managedTemplate)
            }.padding(20).frame(width: 820, height: 640)
        }
    }
}

struct ImportSheet: View {
    @EnvironmentObject var m: AppModel
    @State private var folder = ""
    @State private var selection: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(m.pendingAssignment == nil ? "Import an independent template" : "Import a payload for \(m.label(for: m.pendingAssignment!.format)) in \(m.library.set(m.pendingAssignment!.setID)?.name ?? "")")
                .font(.title2.weight(.semibold))
            Text(m.importSource?.path ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            TextField("Template name", text: $m.importName).textFieldStyle(.roundedBorder).accessibilityLabel("Template name")
            Picker("Import", selection: $m.importMode) { ForEach(ImportMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().onChange(of: m.importMode) { m.scanImport() }.disabled(m.busy)
            if let plan = m.importPlan {
                Text("\(plan.visible.count) items · \(ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file)) of file data, plus Finder metadata").font(.caption).foregroundStyle(.secondary)
                FileBrowserView(dataSource: PreviewDataSource(rendering: PreviewRenderer.render(structure: plan, fields: ProjectFields(number: "", format: "", title: ""))),
                                mode: .column, folder: $folder, selection: $selection, reloadKey: plan.entries.count)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                if !plan.excluded.isEmpty {
                    DisclosureGroup("\(plan.excluded.count) excluded items") {
                        ScrollView { Text(plan.excluded.joined(separator: "\n")).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 90)
                    }.font(.callout)
                }
            } else { Spacer(); ProgressView("Inspecting…").frame(maxWidth: .infinity); Spacer() }
            Text("Files and folders copies everything, so importing a folder with media is a deliberate choice. Folder structure only keeps directories and their icons. The original stays untouched.").font(.caption).foregroundStyle(.secondary)
            HStack {
                if m.busy { ProgressView(value: m.fraction).frame(width: 140); Text(m.status).font(.caption).lineLimit(1) }
                Spacer()
                Button(m.busy ? "Cancel Import" : "Cancel") { if m.busy { m.cancellation.cancel() } else { m.importPresented = false; m.pendingAssignment = nil } }.keyboardShortcut(.cancelAction)
                Button("Import Copy") { m.commitImport() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(m.busy || m.importPlan == nil || m.importName.isEmpty)
            }
        }.padding(24).frame(width: 720, height: 620).interactiveDismissDisabled(m.busy)
    }
}
