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

/// A stage in its own colour, the same colour Finder shows on the folder's tag.
struct StageBadge: View {
    @EnvironmentObject var m: AppModel
    let stage: String
    /// A chevron marks the badge as the control that changes the stage.
    var interactive = false
    var body: some View {
        let colour = m.stageColour(stage)
        HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 7, height: 7)
            Text(stage).lineLimit(1)
            if interactive { Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)) }
        }
        .font(.caption.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 2)
        .background(colour.opacity(0.14), in: Capsule()).foregroundStyle(colour == .secondary ? Color.secondary : colour)
        .accessibilityLabel("Stage \(stage)")
    }
}

/// The badge as the one control for a project's stage: click it to move the project. Replaces the separate picker.
struct StageMenu: View {
    @EnvironmentObject var m: AppModel
    let record: ProjectRecord
    var body: some View {
        let current = m.effectiveStage(record)
        // A Menu label on macOS keeps only its text and the button style ignores tint, so the pill is drawn around the
        // menu: the stage colour as the capsule and the dot, the menu itself borderless inside it.
        let colour = m.stageColour(current) == .secondary ? Color.gray : m.stageColour(current)
        HStack(spacing: 6) {
            Circle().fill(colour).frame(width: 8, height: 8)
            Menu {
                ForEach(m.moveTargets(for: record), id: \.self) { stage in
                    Button { m.setStage(stage, for: record.id) } label: { Label { Text(stage) } icon: { Image(nsImage: ColourDot.image(m.stageColour(stage))) } }
                        .disabled(stage == current)
                }
            } label: { Text(current).font(.caption.weight(.semibold)) }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.leading, 9).padding(.trailing, 4).padding(.vertical, 3)
        .background(colour.opacity(0.2), in: Capsule())
        .overlay(Capsule().strokeBorder(colour.opacity(0.55), lineWidth: 1))
        .foregroundStyle(colour)
        .help("Move this project to another stage. Finder's tag follows when the drive is connected.")
        .accessibilityLabel("Stage \(current), change")
    }
}

/// Menus draw SwiftUI images as templates, which loses their colour. A real coloured image keeps it.
@MainActor enum ColourDot {
    private static var cache: [String: NSImage] = [:]
    /// The tick of a checklist: a filled blue circle with a white tick when on, an empty ring when off.
    static func tick(_ on: Bool) -> NSImage {
        let key = on ? "tick.on" : "tick.off"
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let circle = rect.insetBy(dx: 1.5, dy: 1.5)
            if on {
                NSColor.controlAccentColor.setFill(); NSBezierPath(ovalIn: circle).fill()
                let tick = NSBezierPath(); tick.lineWidth = 1.8; tick.lineCapStyle = .round; tick.lineJoinStyle = .round
                tick.move(to: NSPoint(x: 4.6, y: 8.2)); tick.line(to: NSPoint(x: 7.0, y: 5.8)); tick.line(to: NSPoint(x: 11.6, y: 10.6))
                NSColor.white.setStroke(); tick.stroke()
            } else {
                let ring = NSBezierPath(ovalIn: circle); ring.lineWidth = 1.3
                NSColor.secondaryLabelColor.setStroke(); ring.stroke()
            }
            return true
        }
        image.isTemplate = false
        cache[key] = image
        return image
    }
    static func image(_ colour: Color) -> NSImage {
        let key = colour.description
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(colour).setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill(); return true
        }
        image.isTemplate = false
        cache[key] = image
        return image
    }
}

/// Filters shared by Projects and Pipeline: format buttons, location and stage menus.
struct ProjectFilters: View {
    @EnvironmentObject var m: AppModel
    var includeStage = true
    /// On Pipeline the buttons follow the board; Projects shows every format.
    var kind: PipelineKind? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
        if kind != .live { FormatButtons(selection: $m.formatFilter, includeAll: true, kind: kind).help("Filter by the format the project was created as.") }
        FlowLayout(spacing: 10) {
            let locations = m.distinctLocations
            let shownLocations = locations.filter { !m.hiddenLocations.contains($0.key) }.count
            Menu {
                ForEach(locations, id: \.key) { location in
                    let shown = !m.hiddenLocations.contains(location.key)
                    Button { m.setHidden(shown, for: location) } label: {
                        Label { Text(location.label + (location.account.map { " · " + $0 } ?? "")) } icon: { Image(nsImage: ColourDot.tick(shown)) }
                    }
                }
                Divider()
                Button("Show All") { for location in locations { m.setHidden(false, for: location) } }.disabled(m.hiddenLocations.isEmpty)
            } label: {
                Label(shownLocations == locations.count ? "All locations" : "\(shownLocations) of \(locations.count) locations", systemImage: "externaldrive")
            }.controlSize(.small).fixedSize()
                .help("Tick the drives and cloud folders to show. An unticked drive is never read, so a slow archive drive can stay unticked on normal days.")
            if includeStage {
                let stages = m.visibleStages
                let shownStages = stages.filter { !m.excludedStages.contains($0) }.count
                Menu {
                    ForEach(stages, id: \.self) { stage in
                        let shown = !m.excludedStages.contains(stage)
                        Button { m.setExcluded(shown, stage: stage) } label: {
                            Label { Text(stage) } icon: { Image(nsImage: ColourDot.tick(shown)) }
                        }
                    }
                    Divider()
                    Button("Show All") { m.excludedStages = [] }.disabled(m.excludedStages.isEmpty)
                } label: {
                    Label(shownStages == stages.count ? "All stages" : "\(shownStages) of \(stages.count) stages", systemImage: "circle.lefthalf.filled")
                }.controlSize(.small).fixedSize().help("Tick the stages to show, for example only what is still being written")
            }
            Button { m.refreshMounts() } label: { Image(systemName: "arrow.clockwise") }.controlSize(.small).help("Check again which drives and cloud folders are connected")
        }
        }
    }
}

/// Campaign, editor, series and notes for one project. Saves on submit and when focus leaves a field.
/// The stage is changed from the StageMenu badge beside the project's name.
struct ProjectStatusEditor: View {
    @EnvironmentObject var m: AppModel
    let record: ProjectRecord
    @State private var campaign = ""
    @State private var editor = ""
    @State private var notes = ""
    @State private var series = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Campaign", text: $campaign, prompt: Text("Campaign, if any")).onSubmit(save)
            TextField("With", text: $editor, prompt: Text("Editor or collaborator")).onSubmit(save)
            TextField("Series", text: $series, prompt: Text("Series, separated by commas")).onSubmit(save)
            TextField("Notes", text: $notes, prompt: Text("Notes"), axis: .vertical).lineLimit(2...5).onSubmit(save)
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
        let c = campaign.trimmingCharacters(in: .whitespacesAndNewlines), e = editor.trimmingCharacters(in: .whitespacesAndNewlines), n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = series.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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
            Picker("Board", selection: $m.pipelineKind) { ForEach(PipelineKind.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 16).padding(.top, 12)
                .help("Recordings move from idea to published. Live streams are scheduled, then streamed.")
            ProjectFilters(includeStage: false, kind: m.pipelineKind).padding(.horizontal, 16).padding(.vertical, 10)
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
                                StageMenu(record: record)
                            }
                        }
                    }
                    Section("Details") { ProjectStatusEditor(record: record).id(record.id) }
                    Section {
                        HStack {
                            if record.isPlanned {
                                Button("Start Project…") { m.startPlanned(record) }.buttonStyle(.borderedProminent).help("Fill in New Project with this idea")
                            } else {
                                Button("Show in Projects") { m.selectedProject = record.id; m.page = .projects; m.selectProject() }.help("Open this project's files and details in Projects")
                                Button("Open in Finder") { m.open(record) }.help("Open the project folder in Finder")
                            }
                            Spacer()
                            Button(record.isPlanned ? "Delete Idea" : "Remove from List", role: .destructive) { m.removeProject(record.id) }
                                .help(record.isPlanned ? "Delete this idea. Nothing on disk is affected." : "Forget this project. Its folder is not touched.")
                        }
                    } footer: {
                        Text(record.isPlanned ? "Starting fills in New Project with this idea. The idea becomes the project once its folder is created." : "Removing only forgets the record. The folder is not touched.")
                    }
                }.formStyle(.grouped)
            } else {
                ContentUnavailableView(m.pipelineKind == .live ? "Streams, scheduled and streamed" : "Your content, stage by stage",
                                       systemImage: m.pipelineKind == .live ? "dot.radiowaves.left.and.right" : "rectangle.3.group",
                                       description: Text(m.pipelineKind == .live
                                                         ? "Select a stream to edit its details. Drag it to Streamed once it is done. Each stage's colour is also the folder's tag colour in Finder."
                                                         : "Select a card to edit its stage, campaign, editor and notes. Drag cards between columns to move them along. Each stage's colour is also the folder's tag colour in Finder."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { m.newIdeaPresented = true } label: { Label("New Idea", systemImage: "lightbulb") }.help("Add an idea without a folder yet")
                    .disabled(m.pipelineKind == .live)
            }
        }
        .searchable(text: $m.search, placement: .toolbar, prompt: "Search projects, notes and documents")
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
                ForEach(m.boardStages, id: \.self) { stage in StageColumn(stage: stage) }
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
        let colour = m.stageColour(stage)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(colour).frame(width: 10, height: 10)
                Text(stage).font(.headline)
                Text("\(items.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: Capsule())
                Spacer()
                Menu {
                    Menu("Move All \(items.count) to") {
                        ForEach(m.library.stages(for: m.pipelineKind), id: \.self) { target in
                            Button(target) { m.moveAll(from: stage, to: target) }.disabled(target == stage)
                        }
                    }.disabled(items.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().help("Move every card in this column")
            }.padding(.horizontal, 4)
            Rectangle().fill(colour.opacity(0.5)).frame(height: 3).clipShape(Capsule()).padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items) { record in ProjectCard(record: record) }
                    if items.isEmpty { Text("Nothing here").font(.caption).foregroundStyle(.tertiary).padding(.top, 12) }
                }.padding(2)
            }
        }
        .frame(width: 250)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? colour.opacity(0.18) : colour.opacity(0.06)))
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? colour : .clear, lineWidth: 2))
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
        .padding(10).padding(.leading, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(m.stageColour(m.effectiveStage(record))).frame(width: 4).padding(.vertical, 8).padding(.leading, 4)
        }
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { if !record.isPlanned { m.selectedProject = record.id; m.page = .projects; m.selectProject() } })
        .simultaneousGesture(TapGesture().onEnded { m.pipelineSelection = record.id })
        .draggable(record.id.uuidString)
        .contextMenu {
            Menu("Move to") { ForEach(m.moveTargets(for: record), id: \.self) { stage in Button(stage) { m.setStage(stage, for: record.id) }.disabled(stage == m.effectiveStage(record)) } }
            if record.isPlanned { Button("Start Project…") { m.startPlanned(record) } }
            else { Button("Show in Projects") { m.selectedProject = record.id; m.page = .projects; m.selectProject() }; Button("Open in Finder") { m.open(record) } }
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
                Picker("Format", selection: $format) { ForEach(m.library.presets.filter { PipelineKind.recordings.includes(format: $0.format) }) { Text($0.label).tag($0.format) } }
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
        .onAppear { format = PipelineKind.recordings.includes(format: m.format) ? m.format : "Long" }
    }
}
