import SwiftUI
import AppKit
import TemplateCore

@main struct ContentTemplateApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(CreatorOSDelegate.self) private var delegate
    init() {
        // macOS restores the windows an app had when it quit; after Junior closed the window and quit, that was none,
        // so a relaunch from Spotlight showed nothing. Always open the main window instead; it keeps its own frame below.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        // A second launch should activate the running app, not open a second
        // writer over the same library. Test bundles use a separate identifier.
        // A copy that is still finishing its quit (saving the library) must not swallow the new launch: Junior's
        // relaunch from Spotlight used to activate that departing copy and exit, so nothing opened. Wait for it first.
        if let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            // isTerminated only updates through the run loop, which is not running yet; ask the kernel instead.
            let pid = existing.processIdentifier
            func alive() -> Bool { kill(pid, 0) == 0 }
            let deadline = Date().addingTimeInterval(8)
            while alive() && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if alive() {
                existing.activate(options: [.activateAllWindows])
                exit(0)
            }
        }
    }
    var body: some Scene {
        WindowGroup(AppInfo.label) {
            MainView().environmentObject(model).frame(minWidth: 1000, minHeight: 680)
                .onAppear {
                    delegate.model = model
                    NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); model.refresh()
                    WindowSetup.apply(zoom: { model.zoom($0) }, reset: { model.zoomLevel = 0 })
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { model.newProjectPresented = true }.keyboardShortcut("n")
                Divider()
                Button("Refresh Project") { model.refreshProject() }.keyboardShortcut("r")
                Button("Find Missing Projects") { model.relinkAll() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.relinkBatchRunning)
                Button("Duplicates…") { model.duplicatesPresented = true }.disabled(model.duplicateGroups.isEmpty)
                Button("Check LucidLink Compatibility…") { model.checkCompatibility() }.disabled(model.busy)
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
            // The same actions as a project's right-click menu, for the selected project, so their shortcuts work anywhere.
            CommandMenu("Project") {
                if let record = model.page == .pipeline ? model.library.projects.first(where: { $0.id == model.pipelineSelection }) : model.selectedRecord {
                    ProjectActions(record: record).environmentObject(model)
                } else { Button("No Project Selected") {}.disabled(true) }
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

@MainActor final class CreatorOSDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    /// One window is the app, so closing it quits, like System Settings. A windowless copy left running was what a
    /// Spotlight or Dock relaunch activated, with nothing to show.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !model.busy else { model.error = "Wait for the current operation to finish or cancel it before quitting."; return .terminateCancel }
        Task {
            // Let the existing writer finish all queued snapshots; never race it with a second synchronous writer.
            // A save that never finishes must not leave a windowless process behind; after 15 seconds, ask.
            // (A task group would wait for the hung save too, so the first of two plain tasks decides.)
            let finished = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                let once = OnceFlag()
                Task { @MainActor in await model.saveTaskForWorkspace(); if once.take() { done.resume(returning: true) } }
                Task { @MainActor in try? await Task.sleep(for: .seconds(15)); if once.take() { done.resume(returning: false) } }
            }
            if finished && model.storeUsable { sender.reply(toApplicationShouldTerminate: true) }
            else {
                let alert = NSAlert()
                alert.messageText = finished ? "The latest library changes could not be saved." : "The library is still saving."
                alert.informativeText = "Quitting may discard unsaved changes. Your existing library remains on disk."
                alert.addButton(withTitle: "Keep Open"); alert.addButton(withTitle: "Quit Anyway")
                sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
            }
        }
        return .terminateLater
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
    private static var positionedTestWindow = false
    static func apply(zoom: @escaping (Int) -> Void, reset: @escaping () -> Void) {
        let args = ProcessInfo.processInfo.arguments
        if !positionedTestWindow, args.contains("--data-directory"), let index = args.firstIndex(of: "--display-name"), args.indices.contains(index + 1),
           let screen = NSScreen.screens.first(where: { $0.localizedName == args[index + 1] }),
           let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
            positionedTestWindow = true
        }
        for window in NSApp.windows where window.styleMask.contains(.titled) {
            window.collectionBehavior.insert(.fullScreenPrimary)
            // Reopen where it was last left: AppKit saves the frame under this name and restores it when set.
            if window.frameAutosaveName.isEmpty, !(window.identifier?.rawValue.contains("Settings") ?? false), !args.contains("--data-directory") {
                window.setFrameAutosaveName("CreatorOS Main Window")
            }
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
                    Text(AppInfo.name).font(.caption.weight(.medium))
                    HStack(spacing: 3) {
                        ReleaseVersionLabel(size: 11)
                        Text("· local and offline")
                    }.font(.caption2).foregroundStyle(.secondary)
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
        .alert(AppInfo.name, isPresented: Binding(get: { m.error != nil }, set: { if !$0 { m.error = nil } })) {
            Button("OK") { m.error = nil }
        } message: { Text(m.error ?? "") }
        .sheet(isPresented: $m.newProjectPresented) { NewProjectSheet() }
        .sheet(isPresented: $m.importPresented) { ImportSheet() }
        .sheet(isPresented: Binding(get: { m.compatibilityPresented && !m.newProjectPresented }, set: { m.compatibilityPresented = $0 })) { CompatibilitySheet() }
        .sheet(item: $m.workspacePrompt) { WorkspaceSheet(record: $0) }
        .sheet(item: $m.restoreIconsPrompt) { record in RestoreIconsSheet(record: record) }
        .sheet(item: $m.workspaceToBrowse) { record in
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text(record.name).font(.title2); Spacer(); Button("Done") { m.workspaceToBrowse = nil } }
                Text("Add attachments by opening this owned workspace in Finder. Start Project will copy this folder without merging another template.").font(.caption)
                Button("Open Workspace in Finder") { m.attempt { let root = try IdeaWorkspaceEngine.resolve(for: record); try m.runtime.requireWritable(root); NSWorkspace.shared.open(root) } }
                FolderBrowserHost(title: record.name, resolveRoot: { [runtime = m.runtime] in let url = try IdeaWorkspaceEngine.resolve(for: record); try runtime.requireWritable(url); return url })
            }.padding(20).frame(width: 820, height: 640)
        }
        .sheet(item: $m.workspaceCleanup) { record in
            VStack(alignment: .leading, spacing: 16) {
                Text("Keep the old idea workspace?").font(.title2)
                Text("The project has been saved. Its original workspace remains at \(record.ideaWorkspace?.path ?? "").").textSelection(.enabled)
                Text("Keep Folder and Detach leaves both folders intact and removes the old workspace link from this project. You can then remove the project from the list independently.").font(.caption)
                HStack { Button("Decide Later") { m.workspaceCleanup = nil }; Button("Keep Folder and Detach") { m.keepAndDetachWorkspace(record) }; Spacer(); Button("Review Bin Action…") { m.requestWorkspaceCleanup(record) } }.disabled(m.busy)
            }.padding(24).frame(width: 620)
        }
        .confirmationDialog(m.binIdea?.isPlanned == false ? "Put the old workspace in the Bin?" : "Bin this idea?", isPresented: Binding(get: { m.binIdea != nil }, set: { if !$0 { m.binIdea = nil } }), titleVisibility: .visible) {
            Button(m.confirmedWorkspaceURL == nil ? "Remove Idea" : "Move Owned Workspace to Bin", role: .destructive) { m.confirmBinIdea() }
            Button("Cancel", role: .cancel) { m.binIdea = nil }
        } message: {
            Text(m.confirmedWorkspaceURL.map { "Only this owned workspace will be moved to Finder's recoverable Bin: \($0.path)" } ?? "This idea has no workspace. Only its library record will be removed.")
        }
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

struct RestoreIconsSheet: View {
    @EnvironmentObject var m: AppModel
    let record: ProjectRecord
    @State private var format: String
    @State private var candidates: [IconRestoreCandidate] = []
    @State private var selectedSet: UUID?

    init(record: ProjectRecord) {
        self.record = record
        _format = State(initialValue: Library.formats.contains(record.format) ? record.format : "")
    }
    var selectedCandidate: IconRestoreCandidate? { candidates.first { $0.id == selectedSet } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restore Folder Icons").font(.title2.weight(.semibold))
            Text("Choose a set for this operation. New Project's saved set stays unchanged.").font(.callout)
            Text(record.name).font(.caption).foregroundStyle(.secondary)
            if !Library.formats.contains(record.format) {
                Picker("Project format", selection: $format) {
                    Text("Choose a format…").tag("")
                    ForEach(m.library.presets) { Text($0.label).tag($0.format) }
                }.onChange(of: format) { refreshCandidates() }
            } else {
                LabeledContent("Format", value: m.label(for: format))
            }
            if Library.formats.contains(format) {
                Picker("Template set", selection: $selectedSet) {
                    Text("Choose a set…").tag(UUID?.none)
                    ForEach(candidates) { candidate in
                        Text(candidate.name + (candidate.available ? "" : " · layout mismatch"))
                            .tag(Optional(candidate.id)).disabled(!candidate.available)
                    }
                }
                if candidates.isEmpty { Text("No set has a payload for this format.").foregroundStyle(.secondary) }
                if let reason = selectedCandidate?.reason { Text(reason).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                ForEach(candidates.filter { !$0.available }) { candidate in
                    Text("\(candidate.name): \(candidate.reason ?? "layout mismatch")")
                        .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            HStack {
                Button("Cancel") { m.restoreIconsPrompt = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Restore") {
                    guard let selectedSet else { return }
                    m.restoreIcons(record, format: format, setID: selectedSet)
                    m.restoreIconsPrompt = nil
                }.keyboardShortcut(.defaultAction)
                    .disabled(!Library.formats.contains(format) || selectedCandidate?.available != true || m.busy)
            }
        }
        .padding(22).frame(width: 520, height: 300)
        .onAppear { refreshCandidates() }
    }
    private func refreshCandidates() {
        candidates = m.iconRestoreCandidates(for: record, format: format)
        let available = candidates.filter(\.available)
        selectedSet = available.count == 1 ? available[0].id : nil
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

/// Main-actor flag that lets exactly one of two racing tasks resume a continuation.
@MainActor final class OnceFlag {
    private var taken = false
    func take() -> Bool { if taken { return false }; taken = true; return true }
}
