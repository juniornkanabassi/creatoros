import SwiftUI
import AppKit
import TemplateCore

/// Where a project lives, as a coloured capsule with a mounted dot.
struct LocationBadge: View {
    @EnvironmentObject var m: AppModel
    let location: ProjectLocation
    var compact = false
    var body: some View {
        let colour = m.badgeColour(location).colour
        let mounted = m.mountedLocations.contains(location.key)
        HStack(spacing: 5) {
            Circle().fill(mounted ? colour : Color.clear)
                .overlay(Circle().strokeBorder(colour, lineWidth: 1.5))
                .frame(width: 7, height: 7)
            if !compact { Text(location.label).lineLimit(1) }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, compact ? 5 : 8).padding(.vertical, 3)
        .background(colour.opacity(0.16), in: Capsule())
        .foregroundStyle(colour)
        .help(location.label + (location.account.map { " · " + $0 } ?? "") + (mounted ? " · connected" : " · not connected"))
        .accessibilityLabel(location.label + (mounted ? ", connected" : ", not connected"))
    }
}

struct StageChip: View {
    let stage: String
    var body: some View {
        Text(stage).font(.caption.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 2)
            .background(.quaternary, in: Capsule()).foregroundStyle(.secondary)
    }
}

/// Filters shared by Projects and Pipeline: format buttons, location and stage menus.
struct ProjectFilters: View {
    @EnvironmentObject var m: AppModel
    var includeStage = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
        FormatButtons(selection: $m.formatFilter, includeAll: true).help("Filter by the format the project was created as.")
        HStack(spacing: 10) {
            Picker("Location", selection: $m.locationFilter) {
                Text("All locations").tag(Optional<String>.none)
                ForEach(m.distinctLocations, id: \.key) { location in
                    Label { Text(location.label) } icon: { Image(systemName: "circle.fill").foregroundStyle(m.badgeColour(location).colour) }.tag(Optional(location.key))
                }
            }.labelsHidden().fixedSize().controlSize(.small).help("Show projects on one drive or cloud folder")
            if includeStage {
                Picker("Stage", selection: $m.stageFilter) {
                    Text("All stages").tag(Optional<String>.none)
                    ForEach(m.visibleStages, id: \.self) { Text($0).tag(Optional($0)) }
                }.labelsHidden().fixedSize().controlSize(.small)
            }
            Spacer()
            Button { m.refreshMounts() } label: { Image(systemName: "arrow.clockwise") }.controlSize(.small).help("Check which drives are connected")
        }
        }
    }
}

/// Stage, campaign, editor and notes for one project. Saves on submit and when focus leaves a field.
struct ProjectStatusEditor: View {
    @EnvironmentObject var m: AppModel
    let record: ProjectRecord
    @State private var campaign = ""
    @State private var editor = ""
    @State private var notes = ""
    @State private var series = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Stage", selection: Binding(get: { m.effectiveStage(record) }, set: { m.setStage($0, for: record.id) })) {
                ForEach(m.visibleStages, id: \.self) { Text($0).tag($0) }
            }
            TextField("Campaign", text: $campaign, prompt: Text("None")).onSubmit(save)
            TextField("With", text: $editor, prompt: Text("Editor or collaborator")).onSubmit(save)
            TextField("Series", text: $series, prompt: Text("Separate series with commas")).onSubmit(save)
            TextField("Notes", text: $notes, prompt: Text("Short note"), axis: .vertical).lineLimit(2...5).onSubmit(save)
            if let link = record.notionURL, let url = URL(string: link) {
                Link(destination: url) { Label("Open in Notion", systemImage: "arrow.up.right.square") }.font(.callout)
            }
            let siblings = Numbering.siblings(of: record, in: m.library.projects)
            if !siblings.isEmpty {
                HStack(spacing: 6) {
                    Text("Also on").font(.caption).foregroundStyle(.secondary)
                    ForEach(siblings) { twin in LocationBadge(location: twin.location) }
                }
            }
        }
        .onAppear { campaign = record.campaign ?? ""; editor = record.editor ?? ""; notes = record.notes ?? ""; series = (record.series ?? []).joined(separator: ", ") }
        .onChange(of: campaign) { scheduleSave() }.onChange(of: editor) { scheduleSave() }.onChange(of: notes) { scheduleSave() }
        .onChange(of: series) { scheduleSave() }
        .onDisappear(perform: save)
    }
    @State private var saveTask: Task<Void, Never>?
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(for: .milliseconds(700)); if !Task.isCancelled { save() } }
    }
    func save() {
        let c = campaign.trimmingCharacters(in: .whitespaces), e = editor.trimmingCharacters(in: .whitespaces), n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = series.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard c != (record.campaign ?? "") || e != (record.editor ?? "") || n != (record.notes ?? "") || s != (record.series ?? []) else { return }
        m.updateProject(record.id) { $0.campaign = c.isEmpty ? nil : c; $0.editor = e.isEmpty ? nil : e; $0.notes = n.isEmpty ? nil : n; $0.series = s.isEmpty ? nil : s }
    }
}

/// Content column of Pipeline: filters, counts, and the selected card's details.
struct PipelineSidebar: View {
    @EnvironmentObject var m: AppModel
    var selected: ProjectRecord? { m.library.projects.first { $0.id == m.pipelineSelection } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProjectFilters(includeStage: false).padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if let record = selected {
                Form {
                    Section {
                        HStack(spacing: 10) {
                            FormatIcon(data: m.library.presets.first { $0.format == record.format }?.icon, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.isPlanned ? record.name : record.title).font(.headline).lineLimit(3)
                                HStack(spacing: 6) {
                                    if let number = record.number { Text(number).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                                    Text(m.label(for: record.format)).font(.caption).foregroundStyle(.secondary)
                                    if record.isPlanned { StageChip(stage: "Idea only, no folder yet") } else { LocationBadge(location: record.location) }
                                }
                            }
                        }
                    }
                    Section("Status") { ProjectStatusEditor(record: record).id(record.id) }
                    Section {
                        HStack {
                            if record.isPlanned {
                                Button("Start Project…") { m.startPlanned(record) }.buttonStyle(.borderedProminent)
                            } else {
                                Button("Show in Projects") { m.selectedProject = record.id; m.page = .projects; m.selectProject() }
                                Button("Open Folder") { m.open(record) }
                            }
                            Spacer()
                            Button(record.isPlanned ? "Delete Idea" : "Remove from List", role: .destructive) { m.removeProject(record.id) }
                        }
                    } footer: {
                        Text(record.isPlanned ? "Starting fills in New Project with this idea. The idea becomes the project once its folder is created." : "Removing only forgets the record. The folder is not touched.")
                    }
                }.formStyle(.grouped)
            } else {
                ContentUnavailableView("Your content, stage by stage", systemImage: "rectangle.3.group",
                                       description: Text("Select a card to edit its stage, campaign, editor and notes. Drag cards between columns to move them along."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { m.newIdeaPresented = true } label: { Label("New Idea", systemImage: "lightbulb") }.help("Add an idea without a folder yet")
            }
        }
        .sheet(isPresented: $m.newIdeaPresented) { NewIdeaSheet() }
        .onAppear { m.refreshMounts() }
    }
}

/// Detail column of Pipeline: one column per stage, cards draggable between them.
struct PipelineBoard: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(m.visibleStages, id: \.self) { stage in StageColumn(stage: stage) }
            }.padding(16)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

struct StageColumn: View {
    @EnvironmentObject var m: AppModel
    let stage: String
    @State private var targeted = false
    var body: some View {
        let items = m.projects(in: stage)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(stage).font(.headline)
                Text("\(items.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: Capsule())
                Spacer()
            }.padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items) { record in ProjectCard(record: record) }
                    if items.isEmpty { Text("Nothing here").font(.caption).foregroundStyle(.tertiary).padding(.top, 12) }
                }.padding(2)
            }
        }
        .frame(width: 250)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? Color.accentColor : .clear, lineWidth: 2))
        .dropDestination(for: String.self) { ids, _ in
            for id in ids.compactMap(UUID.init) { m.setStage(stage, for: id) }
            return true
        } isTargeted: { targeted = $0 }
    }
}

struct ProjectCard: View {
    @EnvironmentObject var m: AppModel
    let record: ProjectRecord
    var selected: Bool { m.pipelineSelection == record.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                FormatIcon(data: m.library.presets.first { $0.format == record.format }?.icon, size: 16)
                Text(record.number ?? m.label(for: record.format)).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if record.isPlanned { Image(systemName: "lightbulb").font(.caption).foregroundStyle(.secondary).help("Idea without a folder yet") }
                else { LocationBadge(location: record.location, compact: true) }
            }
            Text(record.isPlanned ? record.name : record.title).font(.callout.weight(.medium)).lineLimit(3).multilineTextAlignment(.leading)
            if record.campaign != nil || record.editor != nil {
                HStack(spacing: 6) {
                    if let campaign = record.campaign { StageChip(stage: campaign) }
                    if let editor = record.editor { Label(editor, systemImage: "person").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { if !record.isPlanned { m.selectedProject = record.id; m.page = .projects; m.selectProject() } })
        .simultaneousGesture(TapGesture().onEnded { m.pipelineSelection = record.id })
        .draggable(record.id.uuidString)
        .contextMenu {
            Menu("Move to") { ForEach(m.visibleStages, id: \.self) { stage in Button(stage) { m.setStage(stage, for: record.id) }.disabled(stage == record.stage) } }
            if record.isPlanned { Button("Start Project…") { m.startPlanned(record) } }
            else { Button("Show in Projects") { m.selectedProject = record.id; m.page = .projects; m.selectProject() }; Button("Open Folder") { m.open(record) } }
            Divider()
            Button(record.isPlanned ? "Delete Idea" : "Remove from List", role: .destructive) { m.removeProject(record.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.name), \(record.stage ?? "")")
    }
}

struct NewIdeaSheet: View {
    @EnvironmentObject var m: AppModel
    @State private var title = ""
    @State private var format = "Long"
    @State private var campaign = ""
    @State private var notes = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New idea").font(.title2.weight(.semibold))
            Text("An idea sits in the first column without a number or folder. Start it from Pipeline when you are ready to make it.").foregroundStyle(.secondary)
            Form {
                TextField("Title", text: $title, prompt: Text("What the video is about"))
                Picker("Format", selection: $format) { ForEach(m.library.presets) { Text($0.label).tag($0.format) } }
                TextField("Campaign", text: $campaign, prompt: Text("Optional"))
                TextField("Notes", text: $notes, prompt: Text("Hook, angle, references"), axis: .vertical).lineLimit(2...6)
            }.formStyle(.grouped).frame(height: 240)
            HStack {
                Button("Cancel") { m.newIdeaPresented = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add Idea") { m.addIdea(title: title, format: format, campaign: campaign, notes: notes); m.newIdeaPresented = false }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(24).frame(width: 520)
        .onAppear { format = m.format }
    }
}
