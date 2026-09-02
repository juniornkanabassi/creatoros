import SwiftUI
import AppKit
import TemplateCore

struct SettingsView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Form {
            Section("Format defaults") {
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
            }
            Section("Naming") {
                LabeledContent("Order", value: "Project Number — Content Format — Campaign — Project Name")
                Text("A blank Campaign is left out. Numbers are typed by hand and keep leading zeroes. Files that begin with Template, such as Template.prproj or Template Description.rtf, take the full project name; [template] and the four field tokens also work. File contents are never rewritten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: "Content Template \(AppInfo.version), development build")
                LabeledContent("Data") {
                    HStack { Text(m.store.root.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled); Button("Show") { NSWorkspace.shared.open(m.store.root) } }
                }
                Text("Offline. No accounts or integrations. Not signed with Developer ID or notarised.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 560).frame(minHeight: 540)
    }
}
