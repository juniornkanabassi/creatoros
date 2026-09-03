import SwiftUI
import AppKit
import TemplateCore

struct FormatIcon: View {
    let data: Data?
    var size: CGFloat = 26
    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "folder.fill").resizable().scaledToFit().foregroundStyle(.secondary) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct FormatButtons: View {
    @EnvironmentObject var m: AppModel
    @Binding var selection: String
    var includeAll = false
    var showReadiness = false
    /// Limit the buttons to one board's formats; nil shows every preset.
    var kind: PipelineKind? = nil
    var body: some View {
        HStack(spacing: 6) {
            if includeAll { formatButton("All formats", label: "All") }
            ForEach(m.library.presets.filter { kind?.includes(format: $0.format) ?? true }) { preset in formatButton(preset.format, label: preset.label) }
            if includeAll && m.library.projects.contains(where: { $0.format == "Existing" }) { formatButton("Existing", label: "Other") }
        }.controlSize(.small)
    }
    func formatButton(_ format: String, label: String) -> some View {
        let missing = showReadiness && !m.isReady(format: format)
        return Button { selection = format } label: {
            HStack(spacing: 5) {
                if let preset = m.library.presets.first(where: { $0.format == format }) {
                    FormatIcon(data: preset.icon, size: 18).overlay(alignment: .bottomTrailing) {
                        if missing { Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9)).foregroundStyle(.orange).offset(x: 3, y: 3) }
                    }
                }
                Text(label).font(.callout.weight(selection == format ? .semibold : .regular))
            }.padding(.horizontal, 5).padding(.vertical, 5).frame(maxWidth: includeAll ? nil : .infinity)
        }.buttonStyle(.bordered).tint(selection == format ? .accentColor : .secondary)
            .help(missing ? "\(label) is not set up in this content template yet" : label)
            .accessibilityLabel(label).accessibilityAddTraits(selection == format ? .isSelected : [])
    }
}

/// The content column of New Project.
struct CreationForm: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Form {
            if let origin = m.startingFrom.flatMap({ id in m.library.projects.first { $0.id == id } }) {
                Section {
                    HStack {
                        Label("Starting from the idea “\(origin.name)”", systemImage: "lightbulb").font(.callout)
                        Spacer()
                        Button("Forget") { m.startingFrom = nil }.controlSize(.small)
                    }
                }
            }
            Section {
                Picker("Content template", selection: $m.selection) {
                    if m.library.sets.isEmpty && m.library.unassignedTemplates.isEmpty { Text("None yet").tag(Optional<TemplateSelection>.none) }
                    ForEach(m.library.sets) { set in Text(set.name).tag(Optional(TemplateSelection.set(set.id))) }
                    if !m.library.unassignedTemplates.isEmpty {
                        Divider()
                        ForEach(m.library.unassignedTemplates) { record in Text("\(record.name) (legacy)").tag(Optional(TemplateSelection.legacy(record.id))) }
                    }
                }.onChange(of: m.selection) { m.changeSelection() }
                variantStatus
            } header: {
                Text("CONTENT TEMPLATE")
            } footer: {
                Text("Choose a brand or campaign template set. Each format inside it can have its own folders and starter files.")
            }
            Section("Content format") {
                FormatButtons(selection: $m.format, showReadiness: m.selectedSet != nil).onChange(of: m.format) { m.changeFormat() }
            }
            Section {
                TextField("Project Number", text: $m.number, prompt: Text(m.suggestedNumber)).onChange(of: m.number) { m.numberEdited() }
                TextField("Campaign", text: $m.campaign, prompt: Text("Optional")).onChange(of: m.campaign) { m.fieldChanged() }
                ForEach(m.library.fieldList) { field in
                    TextField(field.name, text: Binding(get: { m.extraValues[field.id] ?? "" }, set: { m.extraValues[field.id] = $0 }), prompt: Text(field.includeInName ? "Optional, goes in the folder name" : "Optional"))
                        .onChange(of: m.extraValues[field.id]) { m.fieldChanged() }
                }
                TextField("Project Name", text: $m.title, prompt: Text("Your project title")).onChange(of: m.title) { m.fieldChanged() }
            } header: {
                Text("Project")
            } footer: {
                Text(m.numberIsAutomatic
                     ? "Next \(m.formatLabel) is \(m.suggestedNumber), counted from your \(m.formatLabel) projects. Change it if this one is different."
                     : "Using your own number. Clear the field to go back to the next \(m.formatLabel) number, \(m.suggestedNumber).")
            }
            Section("Destination") {
                LabeledContent("Folder") {
                    Text(m.destination.isEmpty ? "Not chosen for \(m.formatLabel) yet" : m.destination)
                        .foregroundStyle(m.destination.isEmpty ? .secondary : .primary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                Button("Choose…") { m.chooseDestination() }
                Toggle("Plain folders, no icons", isOn: $m.plainFolders)
                    .help("Copies the template without its Mac folder icons, for LucidLink and other drives that cannot hold them. Restore Folder Icons in Projects puts them back later.")
                    .onChange(of: m.destination) { if ProjectLocation(path: m.destination).label == "LucidLink" { m.plainFolders = true } }
            }
        }.formStyle(.grouped)
    }

    @ViewBuilder var variantStatus: some View {
        switch m.variantState {
        case .ready(let record, let shared):
            Label { Text("\(m.formatLabel) uses \(record.name)").font(.callout) + Text(shared.isEmpty ? "" : ", shared with \(shared.joined(separator: ", "))").font(.callout).foregroundStyle(.secondary) } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .missing(let setName):
            VStack(alignment: .leading, spacing: 8) {
                Label("\(m.formatLabel) is not set up in \(setName)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                if let set = m.selectedSet { AssignMenu(set: set, format: m.format) }
            }
        case .legacy(let record):
            VStack(alignment: .leading, spacing: 8) {
                Label("\(record.name) is a legacy template used directly for every format", systemImage: "clock.arrow.circlepath").font(.callout).foregroundStyle(.secondary)
                Button("Create Content Template from It…") { m.promptNewSet(mapping: record.id) }
            }
        case .none:
            HStack {
                Text("Import a template or create a content template to begin.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Import Template…") { m.beginImport() }
            }
        }
    }
}

/// Actions that give a format its payload: import new, reuse an existing template, or share another format's payload.
struct AssignMenu: View {
    @EnvironmentObject var m: AppModel
    let set: TemplateSet
    let format: String
    var body: some View {
        HStack(spacing: 8) {
            Button("Import Payload…") { m.beginImport(assigning: PendingAssignment(setID: set.id, format: format)) }
            Menu("Use Existing") {
                let others = set.variants.filter { $0.format != format }
                if !others.isEmpty {
                    Section("Same as another format in \(set.name)") {
                        ForEach(others) { variant in
                            Button("Same as \(m.label(for: variant.format)) · \(m.library.template(variant.templateID)?.name ?? "missing")") {
                                m.assign(format: format, templateID: variant.templateID, in: set.id)
                            }
                        }
                    }
                }
                Section("Managed templates") {
                    ForEach(m.library.templates) { record in Button(record.name) { m.assign(format: format, templateID: record.id, in: set.id) } }
                }
            }.fixedSize()
        }.controlSize(.small)
    }
}

/// The detail column of New Project: the whole prospective project, live.
struct CreationPreview: View {
    @EnvironmentObject var m: AppModel
    @State private var folder = ""
    @State private var selection: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                FormatIcon(data: m.preset.icon, size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("PROJECT PREVIEW").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(m.preview?.outerFolderName ?? "No preview yet").font(.title3.weight(.semibold)).textSelection(.enabled).lineLimit(2)
                    Text(m.destination.isEmpty ? "Choose a destination for \(m.formatLabel) projects." : m.destination + "/" + (m.preview?.outerFolderName ?? ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
            }
            if let preview = m.preview {
                if !preview.missingFields.isEmpty {
                    Label("Still needed: " + preview.missingFields.joined(separator: ", "), systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(preview.issues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                if !m.validation.isEmpty { Label(m.validation, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange) }
                HStack {
                    Text("\(preview.visible.count) items · \(ByteCountFormatter.string(fromByteCount: preview.bytes, countStyle: .file))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    ViewModePicker(surface: .creationPreview)
                }
                FileBrowserView(dataSource: PreviewDataSource(rendering: preview), mode: m.viewMode(.creationPreview), folder: $folder, selection: $selection,
                                reloadKey: preview.entries.hashValue)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                    .onAppear { m.activate(.creationPreview) }.onDisappear { m.deactivate(.creationPreview) }
                let renamed = preview.renamedEntries
                if !renamed.isEmpty {
                    DisclosureGroup("\(renamed.count) names will be replaced") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(renamed) { entry in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.source).foregroundStyle(.secondary)
                                        Text(entry.output).foregroundStyle(entry.placeholder ? .secondary : .primary)
                                    }.font(.caption).textSelection(.enabled)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 140)
                    }.font(.callout)
                }
            } else {
                ContentUnavailableView(m.validation == "Reading template…" ? "Reading template" : "Nothing to preview yet",
                                       systemImage: m.validation == "Reading template…" ? "hourglass" : "folder.badge.plus",
                                       description: Text(m.validation)).frame(maxHeight: .infinity)
            }
            if let created = m.created {
                HStack {
                    Label("Project created", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(created.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([created]) }
                    Button("Browse Project") {
                        if let record = m.library.projects.first(where: { $0.path == created.path }) { m.selectedProject = record.id; m.page = .projects; m.selectProject() }
                    }
                    Button("Next Project") { m.nextProject() }.buttonStyle(.borderedProminent)
                }
            }
            Divider()
            HStack {
                Text("The original template stays untouched.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Create Project") { m.create() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!m.canCreate).keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(20)
    }
}
