import SwiftUI
import AppKit
import TemplateCore

struct FormatButtons: View {
    @EnvironmentObject var m: AppModel
    @Binding var selection: String
    var includeAll = false
    var body: some View {
        HStack(spacing: 6) {
            if includeAll { formatButton("All formats", label: "All") }
            ForEach(m.library.presets) { preset in formatButton(preset.format, label: preset.format == "Livestream" ? "Live" : preset.format) }
            if includeAll && m.library.projects.contains(where: { $0.format == "Existing" }) { formatButton("Existing", label: "Other") }
        }.controlSize(.small)
    }
    func formatButton(_ format: String, label: String) -> some View {
        Button { selection = format } label: {
            HStack(spacing: 5) {
                if let preset = m.library.presets.first(where: { $0.format == format }) { FormatIcon(data: preset.icon, size: 18) }
                Text(label).font(.callout.weight(selection == format ? .semibold : .regular))
            }.padding(.horizontal, 5).padding(.vertical, 5)
                .frame(maxWidth: includeAll ? nil : .infinity)
        }.buttonStyle(.bordered).tint(selection == format ? .accentColor : .secondary)
            .accessibilityLabel(format).accessibilityAddTraits(selection == format ? .isSelected : [])
    }
}

struct CreationView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Start a project").font(.title3.weight(.semibold))
                    Text("Choose a format, fill in the details and check the result before creating your folder.").font(.callout).foregroundStyle(.secondary)
                    FormatButtons(selection: $m.format).onChange(of: m.format) { m.changeFormat() }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Project template").font(.headline)
                                Spacer()
                                Button("Import…") { m.beginImport() }
                            }
                            Picker("Project template", selection: $m.selected) {
                                Text(m.library.templates.isEmpty ? "Import a template to create projects" : "Choose a template").tag(Optional<UUID>.none)
                                ForEach(m.library.templates) { Text($0.name).tag(Optional($0.id)) }
                            }.labelsHidden().onChange(of: m.selected) { m.created = nil; m.refresh() }
                            if let template = m.template { Text("\(template.mode.title). Uses an independent managed copy.").font(.caption).foregroundStyle(.secondary) }
                            else { Text("You can fill out the parameters now. Import a template before creating the project.").font(.caption).foregroundStyle(.secondary) }
                        }.padding(8)
                    }
                    GroupBox {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 13) {
                            GridRow { Text("Parameter").font(.caption.weight(.semibold)); Text("Value").font(.caption.weight(.semibold)) }.foregroundStyle(.secondary)
                            Divider().gridCellColumns(2)
                            parameter("Project Number", text: $m.number, prompt: "For example, 168")
                            GridRow {
                                Text("Content Format").font(.callout.weight(.medium))
                                Picker("Content Format", selection: $m.format) { ForEach(m.library.presets) { Text($0.format).tag($0.format) } }.labelsHidden()
                            }
                            parameter("Campaign", text: $m.campaign, prompt: "Optional")
                            parameter("Project Name", text: $m.title, prompt: "Your project title")
                        }.padding(8)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Label("Destination", systemImage: "folder").font(.headline); Spacer(); Button("Choose…") { m.chooseDestination() } }
                            Text(m.destination.isEmpty ? "Choose where this format's new projects will go." : m.destination).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }.padding(8)
                    }
                    HStack(spacing: 12) {
                        FormatIcon(data: m.preset.icon, size: 36)
                        Text(m.preset.icon == nil ? "The template's folder icon is preserved." : "Your saved \(m.format) icon is applied automatically. Folder icons inside the template stay unchanged.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(22)
            }.frame(minWidth: 390, idealWidth: 440, maxWidth: 490)
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    FormatIcon(data: m.preset.icon, size: 48)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Project preview").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(m.finalName).font(.title3.weight(.semibold)).textSelection(.enabled)
                    }
                }
                if !m.destination.isEmpty { Text(m.destination + "/" + m.finalName).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                if let plan = m.plan {
                    Text("\(plan.visible.count) items · \(ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    TreePreview(plan: plan).clipShape(RoundedRectangle(cornerRadius: 12))
                    let renamed = plan.visible.filter { $0.source != $0.output }
                    if !renamed.isEmpty {
                        DisclosureGroup("\(renamed.count) template names will be replaced") {
                            ScrollView { VStack(alignment: .leading, spacing: 10) { ForEach(renamed) { entry in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.source).foregroundStyle(.secondary)
                                    Text("→ " + entry.output)
                                }.font(.caption).textSelection(.enabled)
                            } }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 145)
                        }.font(.callout)
                    }
                } else {
                    ContentUnavailableView("Ready when you are", systemImage: "folder.badge.plus", description: Text(m.validation)).frame(maxHeight: .infinity)
                }
                if let created = m.created {
                    HStack {
                        Label("Project created", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Browse project") { if let record = m.library.projects.first(where: { $0.path == created.path }) { m.selectedProject = record.id; m.page = "Projects"; m.selectProject() } }
                    }
                }
                Divider()
                HStack { Text("Original template stays untouched.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Create Project") { m.create() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!m.canCreate).keyboardShortcut(.return, modifiers: .command) }
            }.padding(24).frame(minWidth: 370, maxHeight: .infinity, alignment: .topLeading)
        }
    }
    func parameter(_ label: String, text: Binding<String>, prompt: String) -> some View {
        GridRow {
            Text(label).font(.callout.weight(.medium))
            TextField(prompt, text: text).textFieldStyle(.roundedBorder).accessibilityLabel(label)
                .onChange(of: text.wrappedValue) { m.created = nil; m.refresh() }
        }
    }
}
