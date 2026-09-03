import SwiftUI
import AppKit
import TemplateCore

struct SettingsView: View {
    @EnvironmentObject var m: AppModel
    @State private var newField = ""
    @State private var newStage = ""
    @State private var newLiveStage = ""
    var body: some View {
        TabView {
            formatTab.tabItem { Label("Formats", systemImage: "folder") }
            namingTab.tabItem { Label("Naming", systemImage: "textformat") }
            pipelineTab.tabItem { Label("Pipeline", systemImage: "rectangle.3.group") }
            locationsTab.tabItem { Label("Locations", systemImage: "externaldrive") }
            aboutTab.tabItem { Label("About", systemImage: "info.circle") }
        }.frame(width: 600).frame(minHeight: 480)
    }

    var formatTab: some View {
        Form {
            Section {
                Picker("Content Format", selection: $m.format) { ForEach(m.library.presets) { Text($0.label).tag($0.format) } }.onChange(of: m.format) { m.changeFormat() }
                LabeledContent("Folder icon") {
                    HStack(spacing: 12) {
                        if let data = m.preset.icon, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().frame(width: 56, height: 56) }
                        else { Image(systemName: "folder").font(.largeTitle).frame(width: 56, height: 56).foregroundStyle(.secondary) }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(m.preset.icon == nil ? "No saved \(m.formatLabel) icon" : "Applied to every new \(m.formatLabel) project").font(.callout)
                            if m.editingIcon || m.preset.icon == nil {
                                HStack { Button("Choose Image…") { m.chooseIcon(fromFolder: false) }; Button("Use a Folder's Icon…") { m.chooseIcon(fromFolder: true) } }
                            } else { Button("Change Saved Icon…") { m.editingIcon = true } }
                        }
                    }
                }
                LabeledContent("Destination") {
                    HStack {
                        Text(m.destination.isEmpty ? "Not chosen" : m.destination).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        Button("Choose…") { m.chooseDestination() }
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
                Text("A blank Campaign or extra field is left out. Files that begin with Template, such as Template.prproj, take the full name; [template], the four field tokens and any extra field in brackets also work. File contents are never rewritten.")
            }
            Section {
                ForEach(m.library.fieldList) { field in
                    CustomFieldRow(field: field)
                }
                HStack {
                    TextField("New field", text: $newField, prompt: Text("For example, Sponsor or Client")).onSubmit { m.addCustomField(newField); newField = "" }
                    Button("Add") { m.addCustomField(newField); newField = "" }.disabled(newField.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: { Text("Extra fields") } footer: {
                Text("Extra fields appear in New Project after Campaign. Tick In folder name to have their value join the folder name; leave it off to keep the value for tokens only.")
            }
        }.formStyle(.grouped)
    }

    var pipelineTab: some View {
        Form {
            stageSection(.recordings, header: "Recording stages", newPrompt: "For example, Thumbnail",
                         footer: "Long, Short and Podcast projects. The first stage holds ideas without a folder; a new project starts in the second stage. Projects already in a renamed stage keep their old stage name until you move them.",
                         reset: Library.defaultStages)
            stageSection(.live, header: "Live stream stages", newPrompt: "For example, Clipped",
                         footer: "Live streams. A new stream starts in the first stage. Streams already in a renamed stage keep their old stage name until you move them.",
                         reset: Library.defaultLiveStages)
            Section {
                Toggle("Show each stage as a Finder tag on the folder", isOn: Binding(get: { m.library.finderTagsEnabled }, set: { m.setFinderTags($0) }))
                HStack {
                    Button("Tag All Folders Now") { m.tagAllFolders() }.disabled(m.tagging || !m.library.finderTagsEnabled)
                    if m.tagging { ProgressView().controlSize(.small) }
                    Text(m.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            } header: { Text("Finder") } footer: {
                Text("Moving a project to a stage puts a tag with that stage's name and colour on its folder, replacing the previous stage tag and keeping any other tags. Tags are only written when the drive is connected; Tag All Folders Now catches up the rest. The app never moves, renames or deletes folders.")
            }
        }.formStyle(.grouped)
        .onAppear { if !m.tagging { m.status = "" } }
    }
    func stageSection(_ kind: PipelineKind, header: String, newPrompt: String, footer: String, reset: [String]) -> some View {
        let stages = m.library.stages(for: kind)
        return Section {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                StageSettingsRow(kind: kind, index: index, stage: stage)
            }
            HStack {
                TextField("New stage", text: kind == .live ? $newLiveStage : $newStage, prompt: Text(newPrompt)).onSubmit { addStage(kind) }
                Button("Add") { addStage(kind) }.disabled((kind == .live ? newLiveStage : newStage).trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Button("Reset to \(reset.joined(separator: ", "))") { m.setStages(reset, for: kind) }
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
                    HStack {
                        LocationBadge(location: location)
                        if let account = location.account { Text(account).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text(m.mountedLocations.contains(location.key) ? "Connected" : "Not connected").font(.caption).foregroundStyle(.secondary)
                        Picker("Colour", selection: Binding(get: { m.badgeColour(location) }, set: { m.setBadgeColour($0, for: location) })) {
                            ForEach(BadgeColour.allCases) { colour in Label { Text(colour.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(colour.colour) }.tag(colour) }
                        }.labelsHidden().fixedSize()
                    }
                }
                if m.distinctLocations.isEmpty { Text("Locations appear here once projects are registered.").foregroundStyle(.secondary) }
            } header: { Text("Drives and cloud folders") } footer: {
                Text("Each location gets a colour badge in the project list. A filled dot means the drive or cloud folder is connected right now; the check runs every twenty seconds and never opens cloud files.")
            }
        }.formStyle(.grouped)
    }

    var aboutTab: some View {
        Form {
            Section("About") {
                LabeledContent("Version", value: "Content Template \(AppInfo.version), development build")
                LabeledContent("Data") {
                    HStack { Text(m.store.root.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled); Button("Show") { NSWorkspace.shared.open(m.store.root) } }
                }
                LabeledContent("Interface size") {
                    HStack {
                        Button("Smaller") { m.zoom(-1) }
                        Button("Actual") { m.zoomLevel = 0 }
                        Button("Bigger") { m.zoom(1) }
                        Text("\(Int((m.uiScale * 100).rounded()))%").monospacedDigit()
                    }.controlSize(.small)
                }
                Text("Offline. No accounts or integrations. Not signed with Developer ID or notarised.").font(.caption).foregroundStyle(.secondary)
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
            TextField("Name", text: $name).labelsHidden().onSubmit(save)
            Button("Save") { save() }.disabled(name == field.name)
            Toggle("In folder name", isOn: Binding(get: { field.includeInName }, set: { var f = field; f.includeInName = $0; m.updateCustomField(f) })).toggleStyle(.checkbox)
            Button { m.removeCustomField(field.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("Remove this field")
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
                        Label { Text(colour.title) } icon: { Image(systemName: colour == .none ? "circle" : "circle.fill").foregroundStyle(colourValue(colour)) }
                    }
                }
            } label: {
                Circle().fill(m.stageColour(stage)).frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Colour for \(stage), in the app and on the folder's Finder tag")
            TextField("Stage", text: $name).labelsHidden().onSubmit(save)
            Button("Save") { save() }.disabled(name == stage)
            Button { var s = stages; guard s.count > 2, s.indices.contains(index) else { return }; s.remove(at: index); m.setStages(s, for: kind) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).disabled(stages.count <= 2)
        }.onAppear { name = stage }.onChange(of: stage) { name = stage }
    }
    func save() { var s = stages; guard s.indices.contains(index) else { return }; s[index] = name; m.setStages(s, for: kind) }
    func colourValue(_ colour: StageColour) -> Color {
        switch colour { case .none: .secondary; case .gray: .gray; case .green: .green; case .purple: .purple; case .blue: .blue; case .yellow: .yellow; case .red: .red; case .orange: .orange }
    }
}
