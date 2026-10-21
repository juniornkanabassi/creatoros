import SwiftUI
import AppKit
import TemplateCore

struct SettingsView: View {
    @EnvironmentObject var m: AppModel
    @State private var newField = ""
    @State private var newStage = ""
    @State private var newLiveStage = ""
    @State private var showNamingAdvanced = false
    @State private var showPipelineAdvanced = false
    @State private var showAboutAdvanced = false
    var body: some View {
        TabView {
            formatTab.tabItem { Label("Formats", systemImage: "folder") }
            namingTab.tabItem { Label("Naming", systemImage: "textformat") }
            pipelineTab.tabItem { Label("Pipeline", systemImage: "rectangle.3.group") }
            locationsTab.tabItem { Label("Locations", systemImage: "externaldrive") }
            aboutTab.tabItem { Label("About", systemImage: "info.circle") }
        }.frame(width: 600).frame(minHeight: 480)
            .onAppear {
                showNamingAdvanced = m.defaults.bool(forKey: "disclosure.settingsNaming")
                showPipelineAdvanced = m.defaults.bool(forKey: "disclosure.settingsPipeline")
                showAboutAdvanced = m.defaults.bool(forKey: "disclosure.settingsAbout")
            }
            .onChange(of: showNamingAdvanced) { m.defaults.set(showNamingAdvanced, forKey: "disclosure.settingsNaming") }
            .onChange(of: showPipelineAdvanced) { m.defaults.set(showPipelineAdvanced, forKey: "disclosure.settingsPipeline") }
            .onChange(of: showAboutAdvanced) { m.defaults.set(showAboutAdvanced, forKey: "disclosure.settingsAbout") }
    }

    var formatTab: some View {
        Form {
            Section {
                Picker("Content Format", selection: $m.format) { ForEach(m.library.presets) { Text($0.label).tag($0.format) } }.onChange(of: m.format) { m.changeFormat() }.disabled(m.startingFrom != nil)
                    .help("The format whose icon, destination and next number are shown below")
                LabeledContent("Folder icon") {
                    HStack(spacing: 12) {
                        if let data = m.preset.icon, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().frame(width: 56, height: 56) }
                        else { Image(systemName: "folder").font(.largeTitle).frame(width: 56, height: 56).foregroundStyle(.secondary) }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(m.preset.icon == nil ? "No saved \(m.formatLabel) icon" : "Applied to every new \(m.formatLabel) project").font(.callout)
                            if m.editingIcon || m.preset.icon == nil {
                                HStack {
                                    Button("Choose Image…") { m.chooseIcon(fromFolder: false) }.help("Use an image file as the folder icon for new \(m.formatLabel) projects")
                                    Button("Use a Folder's Icon…") { m.chooseIcon(fromFolder: true) }.help("Copy the icon from an existing folder")
                                }
                            } else { Button("Change Saved Icon…") { m.editingIcon = true }.help("Pick a different icon for new \(m.formatLabel) projects") }
                        }
                    }
                }
                LabeledContent("Destination") {
                    HStack {
                        Text(m.destination.isEmpty ? "Not chosen" : m.destination).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        Button("Choose…") { m.chooseDestination() }.help("Choose where \(m.formatLabel) projects are created")
                    }
                }
                LabeledContent("Next number", value: m.suggestedNumber)
            } header: { Text("Format defaults") } footer: {
                Text("The next number is counted from the \(m.formatLabel) projects in your list, so each format keeps its own sequence. Type a different number in New Project whenever you need one.")
            }
        }.formStyle(.grouped)
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
                    TextField("New field", text: $newField, prompt: Text("For example, Sponsor or Client")).onSubmit { m.addCustomField(newField); newField = "" }
                        .help("Name of an extra field to offer in New Project")
                    Button("Add") { m.addCustomField(newField); newField = "" }.disabled(newField.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Add this extra field to New Project")
                }
            } header: { Text("Extra fields") } footer: {
                Text("Extra fields appear under Advanced in New Project. Tick In folder name to add their value to the folder name.")
            }
            Section {
                DisclosureGroup("Advanced: names inside the template", isExpanded: $showNamingAdvanced) {
                    Text("Files that begin with Template, such as Template.prproj, take the full project name. In other file and folder names, [template], the four field tokens and any extra field in brackets are replaced too. An extra field left out of the folder name can still be used this way. File contents are never rewritten.")
                        .font(.callout).foregroundStyle(.secondary)
                }.accessibilityAction { showNamingAdvanced.toggle() }
            }
        }.formStyle(.grouped)
    }

    var pipelineTab: some View {
        Form {
            stageSection(.recordings, header: "Recording stages", newPrompt: "For example, Thumbnail",
                         footer: "Long, Short and Podcast projects. Ideas sit in the first stage; a new project starts in the second.")
            stageSection(.live, header: "Live stream stages", newPrompt: "For example, Clipped",
                         footer: "Live streams. A new stream starts in the first stage.")
            Section {
                Toggle("Show each stage as a Finder tag on the folder", isOn: Binding(get: { m.library.finderTagsEnabled }, set: { m.setFinderTags($0) }))
                    .help("When a project changes stage, tag its folder with the stage's name and colour")
            } header: { Text("Finder") } footer: {
                Text("The folder gets a tag in the stage's colour. Folders are never moved, renamed or deleted.")
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $showPipelineAdvanced) {
                    Text("Renaming a stage moves its cards, its colour and the Finder tags on their folders with it. Abandoned is for projects that never saw the light of day. Resetting puts back the original stages.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Reset Recording Stages to \(Library.defaultStages.joined(separator: ", "))") { m.setStages(Library.defaultStages, for: .recordings) }
                        .help("Replace the recording stages with the original list")
                    Button("Reset Live Stages to \(Library.defaultLiveStages.joined(separator: ", "))") { m.setStages(Library.defaultLiveStages, for: .live) }
                        .help("Replace the live stream stages with the original list")
                    Text("A stage tag replaces the folder's previous stage tag and keeps any other tags. Tags are only written while the drive is connected; Tag All Folders Now catches up the rest.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Tag All Folders Now") { m.tagAllFolders() }.disabled(m.tagging || !m.library.finderTagsEnabled)
                            .help("Write the current stage tag on every connected project folder")
                        if m.tagging { ProgressView().controlSize(.small) }
                        Text(m.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }.accessibilityAction { showPipelineAdvanced.toggle() }
            }
        }.formStyle(.grouped)
        .onAppear { if !m.tagging { m.status = "" } }
    }
    func stageSection(_ kind: PipelineKind, header: String, newPrompt: String, footer: String) -> some View {
        let stages = m.library.stages(for: kind)
        return Section {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                StageSettingsRow(kind: kind, index: index, stage: stage)
            }
            HStack {
                TextField("New stage", text: kind == .live ? $newLiveStage : $newStage, prompt: Text(newPrompt)).onSubmit { addStage(kind) }
                    .help("Name of a stage to add at the end of the board")
                Button("Add") { addStage(kind) }.disabled((kind == .live ? newLiveStage : newStage).trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Add this stage as the last column")
            }
        } header: { Text(header) } footer: { Text(footer) }
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
                        HStack(spacing: 14) {
                            Text(hidden ? "Unticked in Projects" : m.mountedLocations.contains(location.key) ? "Connected" : "Not connected")
                                .font(.callout).foregroundStyle(.secondary).frame(width: 130, alignment: .trailing)
                            Picker("Colour", selection: Binding(get: { m.badgeColour(location) }, set: { m.setBadgeColour($0, for: location) })) {
                                ForEach(BadgeColour.allCases) { colour in Label { Text(colour.title) } icon: { Image(nsImage: ColourDot.image(colour.colour)) }.tag(colour) }
                            }.labelsHidden().fixedSize().frame(width: 130, alignment: .trailing).help("The colour of this location's badge in lists and on cards")
                                .accessibilityLabel("Badge colour for \(location.label)")
                        }
                    } label: {
                        HStack(spacing: 8) {
                            LocationBadge(location: location)
                            if let account = location.account { Text(account).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                }
                if m.distinctLocations.isEmpty { Text("Locations appear here once projects are registered.").foregroundStyle(.secondary) }
            } header: { Text("Drives and cloud folders") } footer: {
                Text("Each location gets a colour badge in the project list. A filled dot means the drive or cloud folder is connected right now; the check runs every twenty seconds and never opens cloud files. Which drives are shown is the Locations filter on Projects and Pipeline: an unticked drive is never read, so a mechanical archive drive can stay unticked on normal days.")
            }
        }.formStyle(.grouped)
    }

    var aboutTab: some View {
        Form {
            Section("About") {
                LabeledContent("Version") { ReleaseVersionLabel(includeName: true) }
                LabeledContent("Interface size") {
                    HStack {
                        Button("Smaller") { m.zoom(-1) }.help("Make the main window's text and controls smaller (⌘-)")
                        Button("Actual") { m.zoomLevel = 0 }.help("Return to the standard size (⌘0)")
                        Button("Bigger") { m.zoom(1) }.help("Make the main window's text and controls bigger (⌘=)")
                        Text("\(Int((m.uiScale * 100).rounded()))%").monospacedDigit()
                    }.controlSize(.small)
                }
                Text("Offline. No accounts or integrations.").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Advanced", isExpanded: $showAboutAdvanced) {
                    Text(m.runtime.isIsolated ? "Disposable launch: every write stays inside this test data folder." : "Everyday CreatorOS uses the preserved Project Templates library and your saved project locations.").font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Data") {
                        HStack {
                            Text(m.store.root.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            Button("Show") { NSWorkspace.shared.open(m.store.root) }.help("Open the folder where CreatorOS keeps its library and template copies")
                        }
                    }
                    Text("Not signed with Developer ID or notarised.").font(.caption).foregroundStyle(.secondary)
                }.accessibilityAction { showAboutAdvanced.toggle() }
            }
            Section {
                Text("© 2026 Junior Nkana Bassi. All rights reserved.").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }.formStyle(.grouped)
    }
}

private struct CustomFieldRow: View {
    @EnvironmentObject var m: AppModel
    let field: CustomField
    @State private var name = ""
    var body: some View {
        HStack {
            TextField("Name", text: $name).labelsHidden().onSubmit(save).accessibilityLabel("Field name").help("Rename this field, then press Return or Save")
            Button("Save") { save() }.disabled(name == field.name).help("Save the new name for \(field.name)")
            Toggle("In folder name", isOn: Binding(get: { field.includeInName }, set: { var f = field; f.includeInName = $0; m.updateCustomField(f) })).toggleStyle(.checkbox)
                .help("Add this field's value to the project folder name")
            Button { m.removeCustomField(field.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("Remove this field")
                .accessibilityLabel("Remove \(field.name)")
        }.onAppear { name = field.name }.onChange(of: field.name) { name = field.name }
    }
    func save() { var f = field; f.name = name; m.updateCustomField(f) }
}

private struct StageSettingsRow: View {
    @EnvironmentObject var m: AppModel
    let kind: PipelineKind
    let index: Int
    let stage: String
    @State private var name = ""
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
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Colour for \(stage), in the app and on the folder's Finder tag")
                .accessibilityLabel("Colour for \(stage)")
            TextField("Stage", text: $name).labelsHidden().onSubmit(save).accessibilityLabel("Stage name").help("Rename this stage, then press Return or Save")
            Button("Save") { save() }.disabled(name == stage).help("Save the new name for \(stage)")
            Button { var s = stages; guard s.count > 2, s.indices.contains(index) else { return }; s.remove(at: index); m.setStages(s, for: kind) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).disabled(stages.count <= 2)
                .help(stages.count <= 2 ? "A board needs at least two stages" : "Remove \(stage) from this board")
                .accessibilityLabel("Remove \(stage)")
        }.onAppear { name = stage }.onChange(of: stage) { name = stage }
    }
    func save() { guard stages.indices.contains(index), name != stage else { return }; m.renameStage(stage, to: name, on: kind) }
    func colourValue(_ colour: StageColour) -> Color {
        BadgeColour(rawValue: colour.rawValue)?.colour ?? .secondary
    }
}
