import SwiftUI
import AppKit
import TemplateCore

@main struct ProjectTemplatesApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Project Templates") {
            MainView().environmentObject(model).frame(minWidth: 1000, minHeight: 680)
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); model.refresh() }
        }.defaultSize(width: 1200, height: 780)
        .commands { CommandGroup(replacing: .newItem) { Button("New Project") { model.page = "New Project" }.keyboardShortcut("n") } }
    }
}

struct TreeNode: Identifiable {
    var id: String
    var name: String
    var directory: Bool
    var children: [TreeNode]?
    static func build(_ entries: [Entry], parent: String = "") -> [TreeNode] {
        entries.filter { (($0.output as NSString).deletingLastPathComponent) == parent && !$0.metadata }.map {
            TreeNode(id: $0.output, name: ($0.output as NSString).lastPathComponent, directory: $0.directory,
                     children: $0.directory ? build(entries, parent: $0.output) : nil)
        }
    }
}
struct TreePreview: View {
    let plan: CopyPlan
    var body: some View {
        List(TreeNode.build(plan.entries), children: \.children) { item in
            HStack(spacing: 8) {
                if let entry = plan.entries.first(where: { $0.output == item.id }) { FileArtwork(url: plan.root.appendingPathComponent(entry.source), size: 20) }
                Text(item.name).lineLimit(2)
            }.help(item.id)
        }.listStyle(.inset)
    }
}
struct MainView: View {
    @EnvironmentObject var m: AppModel
    let pages = ["New Project", "Projects", "Exports", "Templates", "Settings"]
    let icons = ["folder.badge.plus", "externaldrive", "play.rectangle", "square.stack.3d.up", "gearshape"]
    var body: some View {
        NavigationSplitView {
            List(selection: $m.page) {
                ForEach(Array(zip(pages, icons)), id: \.0) { page, icon in Label(page, systemImage: icon).tag(page) }
            }.navigationSplitViewColumnWidth(min: 165, ideal: 185, max: 240)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Development build").font(.caption.weight(.medium))
                    Text("0.3.0 • Local and offline").font(.caption2).foregroundStyle(.secondary)
                }.padding()
            }.disabled(m.busy)
        } detail: {
            VStack(spacing: 0) {
                HStack { Text(m.page).font(.title2.weight(.semibold)); Spacer() }.padding(24).fixedSize(horizontal: false, vertical: true)
                Divider()
                Group {
                    switch m.page {
                    case "Projects": CatalogueView()
                    case "Exports": CatalogueView(exportsOnly: true)
                    case "Templates": templates
                    case "Settings": settings
                    default: newProject
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).disabled(m.busy || !m.storeUsable)
                if m.busy {
                    Divider()
                    HStack {
                        ProgressView(value: m.fraction).frame(width: 140)
                        Text(m.status).lineLimit(1).font(.caption)
                        Spacer()
                        Button("Cancel") { m.cancellation.cancel() }.keyboardShortcut(.cancelAction)
                    }.padding()
                }
            }
        }
        .alert("Project Templates", isPresented: Binding(get: { m.error != nil }, set: { if !$0 { m.error = nil } })) {
            Button("OK") { m.error = nil }
        } message: { Text(m.error ?? "") }
        .sheet(isPresented: $m.importPresented) { importSheet }
        .sheet(item: $m.templateToBrowse) { record in
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(record.name).font(.title2.weight(.semibold)); Spacer(); Button("Done") { m.templateToBrowse = nil } }
                ProjectFileBrowser(record: record, managedTemplate: true)
            }.padding(24).frame(width: 760, height: 640)
        }
    }
    var newProject: some View { CreationView() }
    var templates: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Managed copies belong to this app. Your originals are never edited.").foregroundStyle(.secondary)
            HStack {
                Button("Import Template…") { m.beginImport() }
                Button("Open Template Library") { NSWorkspace.shared.open(m.store.templates) }
            }
            List(m.library.templates) { record in
                HStack {
                    VStack(alignment: .leading) { Text(record.name).font(.headline); Text("\(record.mode.title) · \(record.imported.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Use") { m.selected = record.id; m.page = "New Project"; m.refresh() }
                    Button("Browse files") { m.browseTemplate(record) }
                }.padding(.vertical, 6)
            }
            Text("This first milestone imports whole folders. Drag-and-drop, branch selection, template editing and portable sharing are planned, not yet available.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24)
    }
    var settings: some View {
        Form {
            Section("Format defaults") {
                Picker("Content Format", selection: $m.format) { ForEach(m.library.presets) { Text($0.format).tag($0.format) } }.onChange(of: m.format) { m.changeFormat() }
                HStack {
                    if let data = m.preset.icon, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().frame(width: 64, height: 64) }
                    else { Image(systemName: "folder").font(.largeTitle).frame(width: 64, height: 64).accessibilityLabel("Use the template root icon") }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(m.preset.icon == nil ? "No fixed format icon yet" : "Saved for every new \(m.format) project").font(.headline)
                        Text("The icon stays fixed until you explicitly change it. Switching templates does not replace it.").font(.caption).foregroundStyle(.secondary)
                        if m.editingIcon || m.preset.icon == nil {
                            Button("Choose Image…") { m.chooseIcon(fromFolder: false) }
                            Button("Use Icon from Folder…") { m.chooseIcon(fromFolder: true) }
                        } else { Button("Change Saved Icon…") { m.editingIcon = true } }
                    }
                }
                Text(m.destination.isEmpty ? "No destination selected" : m.destination).font(.caption).textSelection(.enabled)
                Button("Choose Destination…") { m.chooseDestination() }
            }
            Section("Naming") {
                Text("Project Number — Content Format — Campaign — Project Name")
                Text("Blank campaigns are omitted. Numbers are entered manually and leading zeroes are retained. Automatic counters and custom naming rules are still to come.").foregroundStyle(.secondary)
                Text("Files beginning with Template, such as Template.prproj or Template Description.rtf, receive the full project name. [template] and named field tokens are also supported. File contents are never rewritten.").font(.caption).foregroundStyle(.secondary)
            }
            Section("About this build") {
                Text("0.3.0 development milestone. Offline, no accounts or external integrations. Not signed with Developer ID or notarised.")
                Text("Data is stored in \(m.store.root.path)").font(.caption).textSelection(.enabled)
            }
        }.formStyle(.grouped)
    }
    var importSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import an independent template").font(.title2.weight(.semibold))
            Text(m.importSource?.path ?? "").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            TextField("Template name", text: $m.importName).textFieldStyle(.roundedBorder).accessibilityLabel("Template name")
            Picker("Import", selection: $m.importMode) { ForEach(ImportMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).onChange(of: m.importMode) { m.scanImport() }.disabled(m.busy)
            if let plan = m.importPlan {
                Text("\(plan.visible.count) items · \(ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file)) of file data, plus Finder metadata")
                TreePreview(plan: plan)
                if !plan.excluded.isEmpty {
                    DisclosureGroup("\(plan.excluded.count) excluded items") {
                        ScrollView { Text(plan.excluded.joined(separator: "\n")).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100)
                    }
                }
            } else { Spacer(); ProgressView("Inspecting…"); Spacer() }
            Text("Full imports include real files and may be large. Structure-only keeps directories and folder icons but excludes documents, media and packages. The original stays untouched.").font(.caption).foregroundStyle(.secondary)
            HStack {
                if m.busy { ProgressView(value: m.fraction).frame(width: 130); Text(m.status).font(.caption).lineLimit(1) }
                Spacer()
                Button(m.busy ? "Cancel Operation" : "Cancel") { if m.busy { m.cancellation.cancel() } else { m.importPresented = false } }
                Button("Import Copy") { m.commitImport() }.buttonStyle(.borderedProminent).disabled(m.busy || m.importPlan == nil || m.importName.isEmpty)
            }
        }.padding(24).frame(width: 680, height: 640).interactiveDismissDisabled(m.busy)
    }
}
