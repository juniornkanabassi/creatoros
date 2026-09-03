import SwiftUI
import AppKit
import TemplateCore

struct SettingsView: View {
    @EnvironmentObject var m: AppModel
    @State private var newField = ""
    @State private var newStage = ""
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
                    HStack {
                        TextField("Name", text: Binding(get: { field.name }, set: { var f = field; f.name = $0; m.updateCustomField(f) })).labelsHidden()
                        Toggle("In folder name", isOn: Binding(get: { field.includeInName }, set: { var f = field; f.includeInName = $0; m.updateCustomField(f) })).toggleStyle(.checkbox)
                        Button { m.removeCustomField(field.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("Remove this field")
                    }
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
            Section {
                ForEach(Array(m.library.stageList.enumerated()), id: \.offset) { index, stage in
                    HStack {
                        TextField("Stage", text: Binding(get: { stage }, set: { var s = m.library.stageList; s[index] = $0; m.setStages(s) })).labelsHidden()
                        Button { var s = m.library.stageList; guard s.count > 2 else { return }; s.remove(at: index); m.setStages(s) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).disabled(m.library.stageList.count <= 2)
                    }
                }
                HStack {
                    TextField("New stage", text: $newStage, prompt: Text("For example, Thumbnail")).onSubmit { addStage() }
                    Button("Add") { addStage() }.disabled(newStage.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Reset to Idea, Writing, Filming, Editing, Published") { m.setStages(Library.defaultStages) }
            } header: { Text("Stages") } footer: {
                Text("The first stage holds ideas without a folder. A new project starts in the second stage. Projects already in a renamed stage keep their old stage name until you move them.")
            }
        }.formStyle(.grouped)
    }
    func addStage() {
        let clean = newStage.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !m.library.stageList.contains(clean) else { return }
        m.setStages(m.library.stageList + [clean]); newStage = ""
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
                LabeledContent("Text size") { HStack { Button("Smaller") { m.zoom(-1) }; Button("Actual") { m.zoomLevel = 0 }; Button("Bigger") { m.zoom(1) } }.controlSize(.small) }
                Text("Offline. No accounts or integrations. Not signed with Developer ID or notarised.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
