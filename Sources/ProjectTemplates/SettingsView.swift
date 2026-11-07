import SwiftUI
import AppKit
import TemplateCore

/// The app spells colours the British way; the raw colour names come from the case names.

/// The form owns scrolling, while the window follows the selected tab's contents.
private struct SettingsFormSize: ViewModifier {
    @State private var height: CGFloat = 400

    func body(content: Content) -> some View {
        VStack(spacing: Space.xs) {
            Group {
                if #available(macOS 15, *) {
                    content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                        geometry.contentSize.height.rounded(.up)
                    } action: { _, measured in
                        if measured > 0 { height = measured }
                    }
                } else {
                    content.background(SettingsContentProbe(height: $height))
                }
            }
            .frame(height: min(height, 600))
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.visible)
            .contentMargins(.bottom, Space.md, for: .scrollContent)
            if height > 600 {
                Label("Scroll to see all settings", systemImage: "arrow.down")
                    .font(TypeStyle.caption).foregroundStyle(.secondary)
                    .padding(.bottom, Space.sm)
            }
        }
    }
}

/// macOS 14 has no scroll-geometry callback. Read only this form's native scroll view.
private struct SettingsContentProbe: NSViewRepresentable {
    @Binding var height: CGFloat
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let parent = view.superview else { return }
            func scrollView(in candidate: NSView) -> NSScrollView? {
                if let scroll = candidate as? NSScrollView { return scroll }
                return candidate.subviews.lazy.compactMap { scrollView(in: $0) }.first
            }
            guard let scroll = scrollView(in: parent), let document = scroll.documentView else { return }
            let measured = document.frame.height.rounded(.up)
            if measured > 0, abs(height - measured) >= 1 { height = measured }
        }
    }
}

private struct SettingsInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { window.makeFirstResponder(nil) }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var m: AppModel
    @State private var newField = ""
    @State private var newStage = ""
    @State private var newLiveStage = ""
    @State private var showNamingAdvanced = false
    @State private var showFinderAdvanced = false
    @State private var selectedTab = "Formats"
    var body: some View {
        Group {
            if #available(macOS 15, *) { tabs.tabViewStyle(.grouped) }
            else { tabs }
        }
        .frame(width: 520)
            .modifier(UndoContext())
            .overlay { if GridOverlay.enabled { GridOverlay() } }
            .background(SettingsInitialFocus())
            .onAppear {
                showNamingAdvanced = m.defaults.bool(forKey: "disclosure.settingsNaming")
                showFinderAdvanced = m.defaults.bool(forKey: "disclosure.settingsFinder")
                if let saved = m.defaults.string(forKey: "settings.tab"), ["Formats", "Naming", "Pipeline", "Finder", "Locations"].contains(saved) { selectedTab = saved }
            }
            .onChange(of: showNamingAdvanced) { m.defaults.set(showNamingAdvanced, forKey: "disclosure.settingsNaming") }
            .onChange(of: showFinderAdvanced) { m.defaults.set(showFinderAdvanced, forKey: "disclosure.settingsFinder") }
            .onChange(of: selectedTab) { m.defaults.set(selectedTab, forKey: "settings.tab") }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            formatTab.tag("Formats").tabItem { Label("Formats", systemImage: "folder") }
            namingTab.tag("Naming").tabItem { Label("Naming", systemImage: "textformat") }
            pipelineTab.tag("Pipeline").tabItem { Label("Pipeline", systemImage: "rectangle.3.group") }
            finderTab.tag("Finder").tabItem { Label("Finder", systemImage: "tag") }
            locationsTab.tag("Locations").tabItem { Label("Locations", systemImage: "externaldrive") }
        }
    }

    var formatTab: some View {
        Form {
            Section {
                Picker("Content Format", selection: $m.format) { ForEach(m.library.presets) { Text($0.label).tag($0.format) } }.onChange(of: m.format) { m.changeFormat() }.disabled(m.draft.startingFrom != nil)
                    .help("The format whose icon, destination and next number are shown below")
                LabeledContent("Folder icon") {
                    HStack(spacing: Space.md) {
                        if let data = m.preset.icon, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().frame(width: 56, height: 56) }
                        else { Image(systemName: "folder").font(TypeStyle.largeTitle).frame(width: 56, height: 56).foregroundStyle(.secondary) }
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Text(m.preset.icon == nil ? "No saved \(m.formatLabel) icon" : "Applied to every new \(m.formatLabel) project").font(TypeStyle.callout)
                            if m.editingIcon || m.preset.icon == nil {
                                VStack(alignment: .leading, spacing: Space.xs) {
                                    Button("Choose Image…") { m.chooseIcon(fromFolder: false) }.help("Use an image file as the folder icon for new \(m.formatLabel) projects")
                                    Button("Use a Folder's Icon…") { m.chooseIcon(fromFolder: true) }.help("Copy the icon from an existing folder")
                                }
                            } else { Button("Change Saved Icon…") { m.editingIcon = true }.help("Pick a different icon for new \(m.formatLabel) projects") }
                        }
                    }
                }
                LabeledContent("Destination") {
                    HStack {
                        Text(m.draft.destination.isEmpty ? "Not chosen" : m.draft.destination).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        Button("Choose…") { m.chooseDestination() }.help("Choose where \(m.formatLabel) projects are created")
                    }
                }
                LabeledContent("Next number", value: m.suggestedNumber)
            } header: { Text("Format defaults") } footer: {
                Text("The next number is counted from the \(m.formatLabel) projects in your list, so each format keeps its own sequence. Type a different number in New Project whenever you need one.")
            }
        }.formStyle(.grouped).modifier(SettingsFormSize())
    }

    var namingTab: some View {
        Form {
            Section {
                LabeledContent("Order", value: (["Project Number", "Content Format", "Campaign"] + m.library.fieldList.filter(\.includeInName).map(\.name) + ["Project Name"]).joined(separator: " — "))
            } header: { Text("Folder name") } footer: {
                Text("A blank Campaign or extra field is left out.")
            }
            Section {
                ForEach(m.library.fieldList) { field in
                    CustomFieldRow(field: field)
                }
                HStack {
                    TextField("New field", text: $newField, prompt: Text("For example, Sponsor or Client")).onSubmit(addField)
                        .help("Name of an extra field to offer in New Project")
                    Button("Add", action: addField).disabled(newField.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Add this extra field to New Project")
                }
            } header: { Text("Extra fields") } footer: {
                Text("Extra fields appear under Advanced in New Project. Tick In folder name to add their value to the folder name.")
            }
            Section {
                DisclosureGroup("Names inside the template", isExpanded: $showNamingAdvanced) {
                    Text("Files that begin with Template, such as Template.prproj, take the full project name. In other file and folder names, [template], the four field tokens and any extra field in brackets are replaced too. An extra field left out of the folder name can still be used this way. File contents are never rewritten.")
                        .font(TypeStyle.callout).foregroundStyle(.secondary)
                }.accessibilityAction { showNamingAdvanced.toggle() }
            }
        }.formStyle(.grouped).modifier(SettingsFormSize())
    }

    var pipelineTab: some View {
        Form {
            stageSection(.recordings, header: "Recording stages", newPrompt: "For example, Thumbnail",
                         footer: "Ideas sit in the first stage. A new Long, Short or Podcast starts in the second.")
            stageSection(.live, header: "Live stream stages", newPrompt: "For example, Clipped",
                         footer: "Live streams. A new stream starts in the first stage.")
        }.formStyle(.grouped).modifier(SettingsFormSize())
    }

    var finderTab: some View {
        Form {
            Section {
                Toggle("Show stages as Finder tags", isOn: Binding(get: { m.library.finderTagsEnabled }, set: { m.setFinderTags($0) }))
                    .help("When a project changes stage, tag its folder with the stage's name and colour")
            } header: { Text("Finder") } footer: {
                Text("The folder gets a tag in the stage's colour. Folders are never moved, renamed or deleted.")
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $showFinderAdvanced) {
                    Text("Renaming a stage moves its cards, its colour and the Finder tags on their folders with it. Abandoned is for projects that never saw the light of day. Resetting puts back the original stages.")
                        .font(TypeStyle.callout).foregroundStyle(.secondary)
                    Button("Reset Recording Stages") { m.setStages(Library.defaultStages, for: .recordings) }
                        .help("Replace the recording stages with: " + Library.defaultStages.joined(separator: ", "))
                    Text(Library.defaultStages.joined(separator: " → "))
                        .font(TypeStyle.caption).foregroundStyle(.secondary)
                    Button("Reset Live Stages") { m.setStages(Library.defaultLiveStages, for: .live) }
                        .help("Replace the live stream stages with: " + Library.defaultLiveStages.joined(separator: ", "))
                    Text(Library.defaultLiveStages.joined(separator: " → "))
                        .font(TypeStyle.caption).foregroundStyle(.secondary)
                    Text("A stage tag replaces the folder's previous stage tag and keeps any other tags. Tags are only written while the drive is connected; Tag All Folders Now catches up the rest.")
                        .font(TypeStyle.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Tag All Folders Now") { m.tagAllFolders() }.disabled(m.tagging || !m.library.finderTagsEnabled)
                            .help("Write the current stage tag on every connected project folder")
                        if m.tagging { ProgressView().controlSize(.small) }
                        Text(m.status).font(TypeStyle.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }.accessibilityAction { showFinderAdvanced.toggle() }
            }
        }.formStyle(.grouped).modifier(SettingsFormSize())
        .onAppear { if !m.tagging { m.status = "" } }
    }
    func stageSection(_ kind: PipelineKind, header: String, newPrompt: String, footer: String) -> some View {
        let stages = m.library.stages(for: kind)
        return Section {
            ForEach(stages, id: \.self) { stage in
                StageSettingsRow(kind: kind, stage: stage)
            }
            HStack {
                TextField("New stage", text: kind == .live ? $newLiveStage : $newStage, prompt: Text(newPrompt)).onSubmit { addStage(kind) }
                    .help("Name of a stage to add at the end of the board")
                Button("Add") { addStage(kind) }.disabled((kind == .live ? newLiveStage : newStage).trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Add this stage as the last column")
            }
        } header: { Text(header) } footer: { Text(footer) }
    }
    private func addField() {
        do { _ = try m.addField(newField); newField = "" }
        catch { m.error = error.localizedDescription }
    }

    func addStage(_ kind: PipelineKind) {
        let clean = (kind == .live ? newLiveStage : newStage).trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !m.library.stages(for: kind).contains(clean) else { return }
        m.setStages(m.library.stages(for: kind) + [clean], for: kind)
        if kind == .live { newLiveStage = "" } else { newStage = "" }
    }

    var locationsTab: some View {
        Form {
            Section {
                ForEach(m.distinctLocations, id: \.key) { location in
                    let hidden = m.hiddenLocations.contains(location.key)
                    LabeledContent {
                        VStack(alignment: .trailing, spacing: Space.xs) {
                            Text(hidden ? "Unticked in Projects" : m.mountedLocations.contains(location.key) ? "Connected" : "Not connected")
                                .font(TypeStyle.callout).foregroundStyle(.secondary)
                            Picker("Colour", selection: Binding(get: { m.badgeColour(location) }, set: { m.setBadgeColour($0, for: location) })) {
                                ForEach(BadgeColour.allCases) { colour in Label { Text(colour.title) } icon: { Image(nsImage: ColourDot.image(colour.colour)) }.tag(colour) }
                            }.labelsHidden().fixedSize().help("The colour of this location's badge in lists and on cards")
                                .accessibilityLabel("Badge colour for \(location.label)")
                        }
                    } label: {
                        HStack(spacing: Space.sm) {
                            LocationBadge(location: location)
                            if let account = location.account { Text(account).font(TypeStyle.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                }
                if m.distinctLocations.isEmpty { Text("Locations appear here once projects are registered.").foregroundStyle(.secondary) }
            } header: { Text("Drives and cloud folders") } footer: {
                Text("Each location gets a colour badge. A filled dot means it is connected. Use the Locations filter to choose which drives are checked.")
                    .help("Connection checks run every twenty seconds and never open cloud files. Unticked locations are never read, so an archive drive can stay unticked when it is not needed.")
            }
        }.formStyle(.grouped).modifier(SettingsFormSize())
    }

}

struct AboutSettingsView: View {
    @EnvironmentObject var m: AppModel
    @State private var showAboutAdvanced = false
    var body: some View {
        Form {
            Section {
                HStack(spacing: Space.md) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit()
                        .frame(width: 64, height: 64).accessibilityHidden(true)
                    Text(AppInfo.name).font(TypeStyle.title2)
                }
            }
            Section("About") {
                LabeledContent("Version") { ReleaseVersionLabel(includeName: true) }
                Text("Offline. No accounts or integrations.").font(TypeStyle.caption).foregroundStyle(.secondary)
                DisclosureGroup("Advanced", isExpanded: $showAboutAdvanced) {
                    Text(m.runtime.isIsolated ? "Disposable launch: every write stays inside this test data folder." : "Everyday CreatorOS uses the preserved Project Templates library and your saved project locations.").font(TypeStyle.caption).foregroundStyle(.secondary)
                    LabeledContent("Data") {
                        HStack {
                            Text(m.store.root.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            Button("Show") { NSWorkspace.shared.openOutsideChecks(m.store.root) }.help("Open the folder where CreatorOS keeps its library and template copies")
                        }
                    }
                    Text("Not signed with Developer ID or notarised.").font(TypeStyle.caption).foregroundStyle(.secondary)
                }.accessibilityAction { showAboutAdvanced.toggle() }
            }
            Section {
                Text("© 2026 Junior Nkanabassi. Free software under the GNU GPL v3 or later.").font(TypeStyle.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }.formStyle(.grouped).modifier(SettingsFormSize())
            .frame(width: 520)
            .overlay { if GridOverlay.enabled { GridOverlay() } }
            .background(SettingsInitialFocus())
            .onAppear { showAboutAdvanced = m.defaults.bool(forKey: "disclosure.settingsAbout") }
            .onChange(of: showAboutAdvanced) { m.defaults.set(showAboutAdvanced, forKey: "disclosure.settingsAbout") }
    }
}

private struct CustomFieldRow: View {
    @EnvironmentObject var m: AppModel
    let field: CustomField
    @State private var name = ""
    @State private var removing = false
    @FocusState private var nameFocused: Bool
    var body: some View {
        HStack {
            TextField("Name", text: $name).labelsHidden().focused($nameFocused).onSubmit(save)
                .accessibilityLabel("Field name").help("Rename this field. It saves when you press Return or leave the field.")
            Toggle("In folder name", isOn: Binding(get: { field.includeInName }, set: { value in
                guard var latest = m.library.fieldList.first(where: { $0.id == field.id }) else { return }
                latest.includeInName = value; m.updateCustomField(latest)
            })).toggleStyle(.checkbox)
                .help("Add this field's value to the project folder name")
            Button {
                removing = true
                m.removeCustomField(field.id)
                Task {
                    await Task.yield()
                    if m.library.fieldList.contains(where: { $0.id == field.id }) { removing = false }
                }
            } label: { Image(systemName: "minus.circle").frame(minWidth: 28, minHeight: 28).contentShape(Rectangle()).padding(.vertical, -Space.sm) }
                .buttonStyle(.plain).help("Remove this field").accessibilityLabel("Remove \(field.name)")
        }
        .onAppear { name = field.name }
        .onChange(of: field.name) { name = field.name }
        .onChange(of: nameFocused) { if !nameFocused { Task { await Task.yield(); save() } } }
        .onDisappear(perform: save)
    }
    func save() {
        guard !removing, var latest = m.library.fieldList.first(where: { $0.id == field.id }), name != latest.name else { return }
        latest.name = name; m.updateCustomField(latest)
    }
}

private struct StageSettingsRow: View {
    @EnvironmentObject var m: AppModel
    let kind: PipelineKind
    let stage: String
    @State private var name = ""
    @State private var saving = false
    @State private var removing = false
    @FocusState private var nameFocused: Bool
    var stages: [String] { m.library.stages(for: kind) }
    var body: some View {
        HStack {
            Menu {
                ForEach(StageColour.allCases, id: \.self) { colour in
                    Button { m.setStageColour(colour, for: stage) } label: {
                        Label { Text(colour.title) } icon: { Image(nsImage: ColourDot.image(colourValue(colour))) }
                    }
                }
            } label: {
                Image(nsImage: ColourDot.image(m.stageColour(stage)))
            }.menuStyle(.borderlessButton).fixedSize().help("Choose the colour for \(stage), in the app and on the folder's Finder tag")
                .accessibilityLabel("Colour for \(stage)")
            TextField("Stage", text: $name).labelsHidden().focused($nameFocused).onSubmit(save).disabled(saving)
                .accessibilityLabel("Stage name").help("Rename this stage. It saves when you press Return or leave the field.")
            if saving { ProgressView().controlSize(.small) }
            Button {
                guard stages.count > 2, let index = stages.firstIndex(of: stage) else { return }
                removing = true
                var updated = stages; updated.remove(at: index); m.setStages(updated, for: kind)
                Task {
                    await Task.yield()
                    if stages.contains(stage) { removing = false }
                }
            } label: { Image(systemName: "minus.circle").frame(minWidth: 28, minHeight: 28).contentShape(Rectangle()).padding(.vertical, -Space.sm) }
                .buttonStyle(.plain).disabled(stages.count <= 2 || saving)
                .help(stages.count <= 2 ? "A board needs at least two stages" : "Remove \(stage) from this board")
                .accessibilityLabel("Remove \(stage)")
        }
        .onAppear { name = stage }
        .onChange(of: stage) { name = stage }
        .onChange(of: nameFocused) { if !nameFocused { Task { await Task.yield(); save() } } }
        .onDisappear(perform: save)
    }
    func save() {
        guard !saving, !removing, stages.contains(stage), name != stage else { return }
        saving = true
        let entered = name
        Task {
            defer { saving = false }
            guard !removing, stages.contains(stage) else { return }
            do { try await m.renameStage(stage, to: entered, on: kind) }
            catch { m.error = error.localizedDescription }
        }
    }
    func colourValue(_ colour: StageColour) -> Color {
        BadgeColour(rawValue: colour.rawValue)?.colour ?? .secondary
    }
}
