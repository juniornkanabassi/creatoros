import SwiftUI
import TemplateCore

/// The content column of Templates: template sets, then standalone (legacy) templates that belong to none.
struct TemplateSetList: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        List(selection: $m.templatesSelection) {
            Section("Template sets") {
                ForEach(m.library.sets) { set in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(set.name).font(.headline)
                        Text(readiness(set)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 3).tag(TemplateSelection.set(set.id))
                }
                if m.library.sets.isEmpty { Text("None yet. Create one, or turn a standalone template into one.").font(.callout).foregroundStyle(.secondary) }
            }
            if !m.library.unassignedTemplates.isEmpty {
                Section("Standalone templates") {
                    ForEach(m.library.unassignedTemplates) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.name).font(.headline)
                            Text("\(record.mode.title) · imported \(record.imported.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 3).tag(TemplateSelection.legacy(record.id))
                    }
                }
            }
        }
        .overlay {
            if m.library.sets.isEmpty && m.library.templates.isEmpty {
                ContentUnavailableView("No templates yet", systemImage: "square.stack.3d.up", description: Text("A template is a folder of folders and starter files, such as a Premiere project, that every new project copies. Import one to begin: a folder or a Post Haste package. CreatorOS keeps its own copy; your original is never edited."))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { m.promptNewSet() } label: { Label("New Template Set", systemImage: "plus") }.help("Create a set of templates for one channel, client or campaign")
                Button { m.beginImport() } label: { Label("Import Template", systemImage: "square.and.arrow.down").labelStyle(.titleAndIcon) }
                    .buttonStyle(.borderedProminent).help("Copy a template folder or Post Haste package into CreatorOS. Your original is never changed.")
            }
        }
    }
    func readiness(_ set: TemplateSet) -> String {
        let ready = Library.formats.filter { m.library.resolve(setID: set.id, format: $0) != nil }
        if ready.count == 4 { return "All four formats ready" }
        if ready.isEmpty { return "No formats set up yet" }
        let missing = Library.formats.filter { !ready.contains($0) }.map(m.label(for:)).joined(separator: ", ")
        return "\(ready.count) of 4 formats ready · \(missing) missing"
    }
}

/// The detail column of Templates.
struct TemplateSetDetail: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        switch m.templatesSelection {
        case .set(let id):
            if let set = m.library.set(id) { SetDetail(set: set).id(set.id) } else { placeholder }
        case .legacy(let id):
            if let record = m.library.template(id) { LegacyTemplateDetail(record: record).id(record.id) } else { placeholder }
        case nil: placeholder
        }
    }
    var placeholder: some View {
        ContentUnavailableView("Template sets", systemImage: "square.stack.3d.up",
                               description: Text("A template set is a collection of templates for one channel, client or campaign. Each of its four formats can use its own folders and starter files, or share another format's. Select one to set up its formats."))
    }
}

struct SetDetail: View {
    @EnvironmentObject var m: AppModel
    let set: TemplateSet
    @State private var name = ""
    @State private var confirmDelete = false
    @State private var showAdvanced = false
    var body: some View {
        Form {
            Section {
                ForEach(m.library.presets) { preset in VariantRow(set: set, preset: preset) }
            } header: { Text(set.name) } footer: {
                Text("Each format copies its own template files: the folders and starter files of a new project. A format can also share another format's files.")
            }
            Section {
                Button("Use for New Project") { m.useForNewProject(.set(set.id)) }.help("Open New Project with this template set chosen")
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    Text("Rename or delete this set. Deleting removes only the grouping; the template files stay.").font(.caption).foregroundStyle(.secondary)
                    TextField("Name", text: $name).onSubmit { if name != set.name { m.renameSet(set.id, to: name) } }
                        .accessibilityLabel("Template set name")
                        .help("Type a new name and press Return to rename this set")
                    LabeledContent("Created", value: set.created.formatted(date: .abbreviated, time: .omitted))
                    Button("Delete Template Set…", role: .destructive) { confirmDelete = true }.help("Remove this set. Its template files stay in CreatorOS.")
                }.accessibilityAction { showAdvanced.toggle() }
            }
        }
        .formStyle(.grouped)
        .onAppear { name = set.name; showAdvanced = m.defaults.bool(forKey: "disclosure.templateAdvanced") }
        .onChange(of: showAdvanced) { m.defaults.set(showAdvanced, forKey: "disclosure.templateAdvanced") }
        .confirmationDialog("Delete \(set.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Template Set", role: .destructive) { m.removeSet(set.id) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Its four format choices are removed. The template files they used are kept.") }
    }
}

struct VariantRow: View {
    @EnvironmentObject var m: AppModel
    let set: TemplateSet
    let preset: Preset
    var record: TemplateRecord? { m.library.resolve(setID: set.id, format: preset.format) }
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            FormatIcon(data: preset.icon, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(preset.label).font(.headline)
                if let record {
                    let shared = set.formatsSharing(record.id, excluding: preset.format).map(m.label(for:))
                    Text(record.name + (shared.isEmpty ? "" : " · shared with " + shared.joined(separator: ", "))).font(.caption).foregroundStyle(.secondary)
                } else if set.variant(for: preset.format) != nil {
                    Label("Template files missing", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Not set up").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let record { Button("Browse Files") { m.browseTemplate(record) }.controlSize(.small).help("See the folders and starter files \(preset.label) projects copy") }
            if record == nil { AssignMenu(set: set, format: preset.format) }
            else {
                Menu("Change") {
                    Button("Import New Template Files…") { m.beginImport(assigning: PendingAssignment(setID: set.id, format: preset.format)) }
                    Section("Use existing") {
                        ForEach(m.library.templates) { candidate in Button(candidate.name) { m.assign(format: preset.format, templateID: candidate.id, in: set.id) } }
                    }
                    Divider()
                    Button("Stop Using for \(preset.label)") { m.unassign(format: preset.format, in: set.id) }
                }.controlSize(.small).fixedSize().help("Choose different template files for \(preset.label), or stop using these. Files stay in CreatorOS.")
                    .accessibilityLabel("Change \(preset.label) template files")
            }
        }.padding(.vertical, 4)
    }
}

struct LegacyTemplateDetail: View {
    @EnvironmentObject var m: AppModel
    let record: TemplateRecord
    @State private var confirmDelete = false
    @State private var showAdvanced = false
    var usages: [String] { m.library.usages(of: record.id) }
    var body: some View {
        Form {
            Section {
                LabeledContent("Name", value: record.name)
                LabeledContent("Copied", value: record.mode.title)
                LabeledContent("Imported", value: record.imported.formatted(date: .abbreviated, time: .shortened))
            } header: { Text("Standalone template") } footer: {
                Text("A standalone template is used for every format. Turn it into a template set to give each format its own files later.")
            }
            Section {
                FlowLayout(spacing: 8) {
                    Button("Use for New Project") { m.useForNewProject(.legacy(record.id)) }.help("Open New Project with this template chosen")
                    Button("Browse Files") { m.browseTemplate(record) }.help("See the folders and starter files new projects copy")
                    Button("Create Template Set from It…") { m.promptNewSet(mapping: record.id) }
                        .help("Make a template set that starts with this template for all four formats")
                }
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    Text("Where this template came from and where CreatorOS keeps its copy. Deleting moves the copy to the Trash; your original stays.").font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Original source") { Text(record.source).lineLimit(2).truncationMode(.middle).textSelection(.enabled) }
                    LabeledContent("CreatorOS copy") { Text(m.store.payload(record).path).lineLimit(2).truncationMode(.middle).textSelection(.enabled) }
                    Button("Delete…", role: .destructive) { confirmDelete = true }.help("Move CreatorOS's copy of this template to the Trash")
                }.accessibilityAction { showAdvanced.toggle() }
            }
        }
        .formStyle(.grouped)
        .onAppear { showAdvanced = m.defaults.bool(forKey: "disclosure.templateAdvanced") }
        .onChange(of: showAdvanced) { m.defaults.set(showAdvanced, forKey: "disclosure.templateAdvanced") }
        .confirmationDialog("Delete \(record.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Move CreatorOS Copy to Trash", role: .destructive) { m.removeTemplate(record) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(usages.isEmpty ? "CreatorOS's copy moves to the Trash. Your original import source is untouched." : "Used by \(usages.joined(separator: ", ")). Those formats will need new template files. The original import source is untouched.")
        }
    }
}

struct NewSetSheet: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(m.newSetPrompt?.mappingTemplateID == nil ? "New template set" : "Create a template set from this template").font(.title2.weight(.semibold))
            Text(m.newSetPrompt?.mappingTemplateID == nil
                 ? "A template set collects the templates for one channel, client or campaign. Name it, then give each format its template files."
                 : "All four formats will start with this template's files, shown as shared. Replace any format later with its own files.")
                .foregroundStyle(.secondary)
            TextField("Name", text: Binding(get: { m.newSetPrompt?.name ?? "" }, set: { m.newSetPrompt?.name = $0 }), prompt: Text("For example, Junior Nkana Bassi or DAZN48"))
                .textFieldStyle(.roundedBorder).onSubmit { m.confirmNewSet() }
                .accessibilityLabel("Template set name").help("The channel, client or campaign this set is for")
            HStack {
                Button("Cancel") { m.newSetPrompt = nil }.keyboardShortcut(.cancelAction).help("Close without creating a set")
                Spacer()
                Button("Create") { m.confirmNewSet() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).help("Create the template set")
                    .disabled((m.newSetPrompt?.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(24).frame(width: 460)
    }
}
