import SwiftUI
import AppKit
import TemplateCore

@main struct ContentTemplateApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Content Template") {
            MainView().environmentObject(model).frame(minWidth: 1000, minHeight: 680)
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); model.refresh() }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) { Button("New Project") { model.page = .newProject }.keyboardShortcut("n") }
            CommandGroup(before: .sidebar) {
                ForEach(BrowserViewMode.allCases) { mode in
                    Toggle(mode.menuTitle, isOn: Binding(get: { model.activeViewMode == mode }, set: { if $0 { model.setActiveViewMode(mode) } }))
                        .keyboardShortcut(mode.shortcut, modifiers: .command)
                        .disabled(model.activeSurface == nil)
                }
                Divider()
            }
        }
        Settings { SettingsView().environmentObject(model) }
    }
}

struct MainView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        NavigationSplitView {
            List(selection: $m.page) {
                ForEach(Page.allCases) { page in Label(page.rawValue, systemImage: page.systemImage).tag(page) }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Content Template").font(.caption.weight(.medium))
                    Text("\(AppInfo.version) · local and offline").font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        } content: {
            Group {
                switch m.page {
                case .newProject: CreationForm()
                case .projects: ProjectList()
                case .templates: TemplateSetList()
                }
            }
            .navigationSplitViewColumnWidth(min: 380, ideal: 440, max: 560)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch m.page {
                    case .newProject: CreationPreview()
                    case .projects: ProjectDetail()
                    case .templates: TemplateSetDetail()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if m.busy {
                    Divider()
                    HStack(spacing: 12) {
                        ProgressView(value: m.fraction).frame(width: 160)
                        Text(m.status).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { m.cancellation.cancel() }.keyboardShortcut(.cancelAction)
                    }.padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
                }
            }
            .navigationSplitViewColumnWidth(min: 420, ideal: 620)
        }
        .navigationTitle(m.page.rawValue)
        .disabled(!m.storeUsable)
        .alert("Content Template", isPresented: Binding(get: { m.error != nil }, set: { if !$0 { m.error = nil } })) {
            Button("OK") { m.error = nil }
        } message: { Text(m.error ?? "") }
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
