import SwiftUI
import TemplateCore

/// The content column of Templates: content template sets, then legacy templates that belong to none.
struct TemplateSetList: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        List(selection: $m.templatesSelection) {
            Section("Content templates") {
                ForEach(m.library.sets) { set in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(set.name).font(.headline)
                        Text(readiness(set)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 3).tag(TemplateSelection.set(set.id))
                }
                if m.library.sets.isEmpty { Text("None yet. Create one, or turn a legacy template into one.").font(.callout).foregroundStyle(.secondary) }
            }
            if !m.library.unassignedTemplates.isEmpty {
                Section("Legacy templates") {
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
                ContentUnavailableView("No templates yet", systemImage: "square.stack.3d.up", description: Text("Import a folder or a Post Haste package. The copy belongs to this app; your original is never edited."))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { m.promptNewSet() } label: { Label("New Content Template", systemImage: "plus") }.help("Create a brand or campaign template set")
                Button { m.beginImport() } label: { Label("Import Template", systemImage: "square.and.arrow.down") }.help("Import a folder or .pht as a managed template")
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
        ContentUnavailableView("Content templates", systemImage: "square.stack.3d.up",
                               description: Text("A content template is a brand, client or campaign. Each of its four formats can point at its own folders and starter files, or share another format's."))
    }
}

struct SetDetail: View {
    @EnvironmentObject var m: AppModel
    let set: TemplateSet
    @State private var name = ""
    @State private var confirmDelete = false
    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name).onSubmit { if name != set.name { m.renameSet(set.id, to: name) } }
                LabeledContent("Created", value: set.created.formatted(date: .abbreviated, time: .omitted))
            } header: { Text("CONTENT TEMPLATE") } footer: { Text("Press Return to rename.") }
            Section("Formats") {
                ForEach(m.library.presets) { preset in VariantRow(set: set, preset: preset) }
            }
            Section {
                HStack {
                    Button("Use for New Project") { m.useForNewProject(.set(set.id)) }
                    Spacer()
                    Button("Delete Content Template…", role: .destructive) { confirmDelete = true }
                }
            } footer: { Text("Deleting a content template only removes the grouping. Managed templates and their files stay.") }
        }
        .formStyle(.grouped)
        .onAppear { name = set.name }
        .confirmationDialog("Delete \(set.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Content Template", role: .destructive) { m.removeSet(set.id) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Its four format assignments are removed. The managed templates they pointed at are kept.") }
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
                    Label("Payload missing", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Not set up").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let record { Button("Browse Files") { m.browseTemplate(record) }.controlSize(.small) }
            if record == nil { AssignMenu(set: set, format: preset.format) }
            else {
                Menu("Change") {
                    Button("Import New Payload…") { m.beginImport(assigning: PendingAssignment(setID: set.id, format: preset.format)) }
                    Section("Use existing") {
                        ForEach(m.library.templates) { candidate in Button(candidate.name) { m.assign(format: preset.format, templateID: candidate.id, in: set.id) } }
                    }
                    Divider()
                    Button("Remove Assignment") { m.unassign(format: preset.format, in: set.id) }
                }.controlSize(.small).fixedSize()
            }
        }.padding(.vertical, 4)
    }
}

struct LegacyTemplateDetail: View {
    @EnvironmentObject var m: AppModel
    let record: TemplateRecord
    @State private var confirmDelete = false
    var usages: [String] { m.library.usages(of: record.id) }
    var body: some View {
        Form {
            Section {
                LabeledContent("Name", value: record.name)
                LabeledContent("Import", value: record.mode.title)
                LabeledContent("Imported", value: record.imported.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Original source") { Text(record.source).lineLimit(2).truncationMode(.middle).textSelection(.enabled) }
                LabeledContent("Managed copy") { Text(m.store.payload(record).path).lineLimit(2).truncationMode(.middle).textSelection(.enabled) }
            } header: { Text("LEGACY TEMPLATE") } footer: {
                Text("A legacy template is used directly for every format. Turn it into a content template to give each format its own payload later.")
            }
            Section {
                HStack {
                    Button("Create Content Template from It…") { m.promptNewSet(mapping: record.id) }.buttonStyle(.borderedProminent)
                    Button("Browse Files") { m.browseTemplate(record) }
                    Button("Use for New Project") { m.useForNewProject(.legacy(record.id)) }
                    Spacer()
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete \(record.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Move Managed Copy to Trash", role: .destructive) { m.removeTemplate(record) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(usages.isEmpty ? "The managed copy moves to the Trash. Your original import source is untouched." : "Used by \(usages.joined(separator: ", ")). Those formats will need a new payload. The original import source is untouched.")
        }
    }
}

struct NewSetSheet: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(m.newSetPrompt?.mappingTemplateID == nil ? "New content template" : "Create a content template from this template").font(.title2.weight(.semibold))
            Text(m.newSetPrompt?.mappingTemplateID == nil
                 ? "Name the brand, client or campaign. You then give each format its payload."
                 : "All four formats will start with this template's payload, shown as shared. Replace any format later with its own payload.")
                .foregroundStyle(.secondary)
            TextField("Name", text: Binding(get: { m.newSetPrompt?.name ?? "" }, set: { m.newSetPrompt?.name = $0 }), prompt: Text("For example, Junior Nkana Bassi or DAZN48"))
                .textFieldStyle(.roundedBorder).onSubmit { m.confirmNewSet() }
            HStack {
                Button("Cancel") { m.newSetPrompt = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") { m.confirmNewSet() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled((m.newSetPrompt?.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(24).frame(width: 460)
    }
}
