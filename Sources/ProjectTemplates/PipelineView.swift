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
        HStack(spacing: Space.xs) {
            Circle().fill(mounted ? colour : Color.clear)
                .overlay(Circle().strokeBorder(colour, lineWidth: 2))
                .frame(width: 8, height: 8)
            if !compact { Text(location.label).lineLimit(1) }
        }
        .font(TypeStyle.caption.weight(.semibold))
        .padding(.horizontal, compact ? Space.xs : Space.sm).padding(.vertical, Space.xs)
        .background(colour.opacity(0.16), in: Capsule())
        .foregroundStyle(colour)
        .help(location.label + (location.account.map { " · " + $0 } ?? "") + (mounted ? " · connected" : " · not connected"))
        .accessibilityLabel(location.label + (mounted ? ", connected" : ", not connected"))
    }
}

struct StageChip: View {
    let stage: String
    var body: some View {
        Text(stage).font(TypeStyle.caption.weight(.medium)).padding(.horizontal, Space.sm).padding(.vertical, Space.xxs)
            .background(.quaternary, in: Capsule()).foregroundStyle(.secondary)
    }
}

/// A stage in its own colour, the same colour Finder shows on the folder's tag.
struct StageBadge: View {
    @EnvironmentObject var m: AppModel
    let stage: String
    var body: some View {
        let colour = m.stageColour(stage)
        HStack(spacing: Space.xs) {
            Circle().fill(colour).frame(width: 8, height: 8)
            Text(stage).lineLimit(1)
        }
        .font(TypeStyle.caption.weight(.medium)).padding(.horizontal, Space.sm).padding(.vertical, Space.xxs)
        .background(colour.opacity(0.14), in: Capsule()).foregroundStyle(.primary)
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
        HStack(spacing: Space.sm) {
            Circle().fill(colour).frame(width: 8, height: 8)
            Menu {
                ForEach(m.moveTargets(for: record), id: \.self) { stage in
                    Button { m.setStage(stage, for: record.id) } label: { Label { Text(stage) } icon: { Image(nsImage: ColourDot.image(m.stageColour(stage))) } }
                        .disabled(stage == current)
                }
            } label: { Text(current).font(TypeStyle.caption.weight(.semibold)) }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.leading, Space.sm).padding(.trailing, Space.xs).padding(.vertical, Space.xs)
        .background(colour.opacity(0.2), in: Capsule())
        .overlay(Capsule().strokeBorder(colour.opacity(0.55), lineWidth: 1))
        .foregroundStyle(.primary)
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
                NSColor.alternateSelectedControlTextColor.setStroke(); tick.stroke()
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
    /// Pipeline keeps its board picker and location controls on one shared leading edge.
    var includeBoardPicker = false
    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if includeBoardPicker {
                FlowLayout(spacing: Space.md) {
                    Picker("Board", selection: $m.pipelineKind) { ForEach(PipelineKind.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .help("Recordings move from idea to published. Live streams are scheduled, then streamed.").accessibilityLabel("Board")
                    filterControls
                }
                FormatButtons(selection: $m.formatFilter, includeAll: true, kind: kind)
                    .help("Filter by the format the project was created as.")
            } else {
                if kind != .live {
                    FormatButtons(selection: $m.formatFilter, includeAll: true, kind: kind)
                        .help("Filter by the format the project was created as.")
                }
                FlowLayout(spacing: Space.md) { filterControls }
            }
        }
    }
    @ViewBuilder private var filterControls: some View {
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
            Button { m.refreshEverything() } label: { Image(systemName: "arrow.clockwise") }.controlSize(.small)
                .help("Refresh: check which drives are connected, check the selected project's folder again, and rerun the search")
                .accessibilityLabel("Refresh")
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
    /// What each field showed when it was last taken from the record. A field that still equals this is untouched by the user.
    @State private var loaded = Details()
    struct Details: Equatable { var campaign = "", editor = "", notes = "", series = "" }
    var stored: Details { Details(campaign: record.campaign ?? "", editor: record.editor ?? "", notes: record.notes ?? "", series: (record.series ?? []).joined(separator: ", ")) }
    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            TextField("Campaign", text: $campaign, prompt: Text("Campaign, if any")).onSubmit(save)
                .accessibilityLabel("Campaign").help("The campaign this project belongs to. Saved as you type; the folder name is not changed.")
            TextField("Editor", text: $editor, prompt: Text("Editor or collaborator")).onSubmit(save)
                .accessibilityLabel("Editor or collaborator").help("Who you are making this with. Shown on the card.")
            TextField("Series", text: $series, prompt: Text("Series, separated by commas")).onSubmit(save)
                .accessibilityLabel("Series").help("Series this belongs to. Separate several with commas.")
            TextField("Notes", text: $notes, prompt: Text("Notes"), axis: .vertical).lineLimit(2...5).onSubmit(save)
                .accessibilityLabel("Notes").help("Anything to remember about this project. Searchable from the toolbar.")
            if let link = record.notionURL, let url = URL(string: link) {
                Link(destination: url) { Label("Open in Notion", systemImage: "arrow.up.right.square") }.font(TypeStyle.callout)
            }
            let siblings = Numbering.siblings(of: record, in: m.library.projects)
            if !siblings.isEmpty {
                HStack(spacing: Space.sm) {
                    Text("Also on").font(TypeStyle.caption).foregroundStyle(.secondary)
                    ForEach(siblings) { twin in LocationBadge(location: twin.location) }
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: record.id) { reload() }
        // Something else changed the record (a command, or another window). Refresh only the fields the user has not touched,
        // so an edit in progress is kept and an untouched field never overwrites the newer value later.
        .onChange(of: stored) {
            let new = stored
            if campaign == loaded.campaign { campaign = new.campaign }
            if editor == loaded.editor { editor = new.editor }
            if notes == loaded.notes { notes = new.notes }
            if series == loaded.series { series = new.series }
            loaded = new
        }
        .onChange(of: campaign) { scheduleSave() }.onChange(of: editor) { scheduleSave() }.onChange(of: notes) { scheduleSave() }
        .onChange(of: series) { scheduleSave() }
        .onDisappear(perform: save)
    }
    @State private var saveTask: Task<Void, Never>?
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(for: .milliseconds(700)); if !Task.isCancelled { save() } }
    }
    func reload() {
        let now = stored
        loaded = now; campaign = now.campaign; editor = now.editor; notes = now.notes; series = now.series
    }
    /// Writes only the fields the user changed since they were loaded.
    func save() {
        func changed(_ value: String, _ original: String) -> String? { value != original ? value : nil }
        let c = changed(campaign, loaded.campaign), e = changed(editor, loaded.editor), n = changed(notes, loaded.notes)
        let s = changed(series, loaded.series).map(AppModel.splitSeries)
        guard c != nil || e != nil || n != nil || s != nil else { return }
        m.attempt { try m.saveDetails(record.id, campaign: c, editor: e, notes: n, series: s) }
    }
}

extension AppModel {
    /// The card shown in the Pipeline inspector, if it is still in the library.
    var pipelineSelectedRecord: ProjectRecord? { library.projects.first { $0.id == pipelineSelection } }
    /// Double-click, or the Open action: an idea fills in New Project, a project opens in Projects.
    func openPipelineCard(_ record: ProjectRecord) {
        if record.isPlanned { startPlanned(record) }
        else { selectedProject = record.id; page = .projects; selectProject() }
    }
}

/// Arrow-key movement between board cards. Columns are the cards' ids, left to right, top to bottom.
enum BoardNavigation {
    enum Move { case up, down, left, right }
    /// The card to focus next, or nil when there is nowhere to go. With nothing focused, the first card.
    static func target(from current: UUID?, _ move: Move, columns: [[UUID]]) -> UUID? {
        guard let current, let column = columns.firstIndex(where: { $0.contains(current) }),
              let row = columns[column].firstIndex(of: current) else { return columns.first { !$0.isEmpty }?.first }
        switch move {
        case .up: return row > 0 ? columns[column][row - 1] : nil
        case .down: return row + 1 < columns[column].count ? columns[column][row + 1] : nil
        case .left, .right:
            let step = move == .left ? -1 : 1
            var next = column + step
            while columns.indices.contains(next) {
                if !columns[next].isEmpty { return columns[next][min(row, columns[next].count - 1)] }
                next += step
            }
            return nil
        }
    }
}

/// Pipeline's toolbar, search and sheets, around the board and its inspector.
struct PipelinePageChrome: ViewModifier {
    @EnvironmentObject var m: AppModel
    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if m.pipelineKind == .recordings {
                        Button { m.newIdeaPresented = true } label: { Label("New Idea", systemImage: "lightbulb") }.help("Add an idea without a folder yet")
                    }
                    Button { m.newProjectPresented = true } label: { Label("Create Project", systemImage: "folder.badge.plus").labelStyle(.titleAndIcon) }
                        .buttonStyle(.borderedProminent).help(m.pipelineKind == .live ? "Create a project folder from a template (⌘N). Choose Live for this board." : "Create a project folder from a template (⌘N). Long, Short and Podcast appear on this board.")
                }
            }
            .searchable(text: $m.search, placement: .toolbar, prompt: "Search projects, notes and documents")
            .sheet(isPresented: $m.newIdeaPresented) { NewIdeaSheet() }
            .onAppear { m.refreshMounts() }
    }
}

/// The selected card's details, in the Pipeline inspector.
struct PipelineInspector: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Group {
            if let record = m.pipelineSelectedRecord {
                Form {
                    Section {
                        HStack(spacing: Space.md) {
                            FormatIcon(data: m.library.presets.first { $0.format == record.format }?.icon, size: 30)
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text(record.isPlanned ? record.name : record.title).font(TypeStyle.headline).fixedSize(horizontal: false, vertical: true)
                                FlowLayout(spacing: Space.sm) {
                                    if let number = record.number { Text(number).font(TypeStyle.caption.monospacedDigit()).foregroundStyle(.secondary) }
                                    Text(m.label(for: record.format)).font(TypeStyle.caption).foregroundStyle(.secondary)
                                    if record.isPlanned { StageChip(stage: record.ideaWorkspace == nil ? "Idea only, no folder yet" : "Idea workspace") } else { LocationBadge(location: record.location) }
                                    StageMenu(record: record)
                                }
                            }
                        }
                    }
                    Section("Details") { ProjectStatusEditor(record: record).id(record.id) }
                    Section {
                        FlowLayout(spacing: Space.sm) {
                            if record.isPlanned {
                                Button("Start Project…") { m.startPlanned(record) }.help("Fill in New Project with this idea")
                                if record.ideaWorkspace == nil {
                                    Button("Create Workspace…") { m.workspacePrompt = record }.help("Make a draft folder for this idea's notes and attachments")
                                } else { Button("Browse Workspace…") { m.workspaceToBrowse = record }.help("See the files in this idea's draft folder") }
                            } else {
                                Button("Show in Projects") { m.openPipelineCard(record) }.help("Open this project's files and details in Projects")
                                Button("Open in Finder") { m.open(record) }.help("Open the project folder in Finder")
                            }
                        }
                    } footer: {
                        if record.isPlanned { Text("Starting fills in New Project with this idea. The idea becomes the project once its folder is created.") }
                    }
                    Section {
                        Button(record.isPlanned ? "Bin Idea…" : "Remove from List", role: .destructive) { if record.isPlanned { m.requestBinIdea(record) } else { m.removeProject(record.id) } }
                            .help(record.isPlanned ? "Review this idea and its draft folder before putting it in the Bin." : "Take this project off the list. Its folder is not touched.")
                    } footer: {
                        Text(record.isPlanned ? "Its draft folder, if any, goes to the recoverable Bin after you confirm."
                                              : "Only the record is removed; the folder is not touched. Undo brings it back.")
                    }
                }.formStyle(.grouped)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar {
            ToolbarItem {
                Button { m.pipelineSelection = nil } label: { Label("Hide Details", systemImage: "sidebar.trailing") }
                    .help("Hide the card details (Escape on the board, or Control-Command-I)")
            }
        }
    }
}

/// Pipeline: the board selector and filters, then one column per stage, cards draggable between them.
struct PipelineBoard: View {
    @EnvironmentObject var m: AppModel
    @FocusState private var focusedCard: UUID?
    @State private var requestedCard: UUID?
    @State private var width: CGFloat = 0
    /// Columns share the width before the board scrolls, from 148 pt (scrolls) to 320 pt (few stages). Six recording stages
    /// need 6 x (148 + 2 x 8) + 5 x 8 + 2 x 16 = 1056 pt, which the 1064 pt beside the sidebar at the default 1280 pt window gives.
    private var columnWidth: CGFloat {
        let count = CGFloat(max(m.boardStages.count, 1))
        let share = (width - 2 * Space.lg - (count - 1) * Space.sm) / count - 2 * Space.sm
        return min(320, max(148, (share / 4).rounded(.down) * 4))
    }
    private var filtered: Bool { m.formatFilter != "All formats" || !m.hiddenLocations.isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProjectFilters(includeStage: false, kind: m.pipelineKind, includeBoardPicker: true)
                .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
            Divider()
            // One explanation for an empty board instead of an empty label in every column; the columns stay as drop targets.
            if m.boardStages.allSatisfy({ m.projects(in: $0).isEmpty }) {
                HStack(spacing: Space.md) {
                    Label((m.pipelineKind == .live
                           ? "No streams here yet. Create Project, then choose Live, makes the first one."
                           : "No projects here yet. New Idea or Create Project makes the first one.") + (filtered ? " Some may be hidden by the filters." : ""),
                          systemImage: "info.circle")
                        .font(TypeStyle.callout).foregroundStyle(.secondary)
                    if m.pipelineKind == .live {
                        Button("Create Project…") { m.newProjectPresented = true }.help("Create a project folder from a template (⌘N). Choose Live for this board.")
                    } else {
                        Button("New Idea…") { m.newIdeaPresented = true }.help("Add an idea without a folder yet")
                    }
                }.padding(.horizontal, Space.lg).padding(.top, Space.lg)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Space.sm) {
                        ForEach(m.boardStages, id: \.self) { stage in
                            StageColumn(stage: stage, width: columnWidth, focusedCard: $focusedCard, requestedCard: requestedCard)
                                .id(stage)
                        }
                    }.padding(Space.lg)
                }
                .scrollIndicators(.visible)
                .onChange(of: requestedCard) {
                    guard let id = requestedCard,
                          let stage = m.boardStages.first(where: { m.projects(in: $0).contains(where: { $0.id == id }) }) else { return }
                    proxy.scrollTo(stage, anchor: .center)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Surface.secondary)
        .onKeyPress(.upArrow) { move(.up) }
        .onKeyPress(.downArrow) { move(.down) }
        .onKeyPress(.leftArrow) { move(.left) }
        .onKeyPress(.rightArrow) { move(.right) }
        .onKeyPress(.return) { open() }
        .onKeyPress(.space) { open() }
        // Delete removes the focused card through the same action as its context menu, which registers Undo.
        .onDeleteCommand {
            guard let record = m.library.projects.first(where: { $0.id == focusedCard }) else { return }
            if record.isPlanned { m.requestBinIdea(record) } else { m.removeProject(record.id) }
        }
        .onKeyPress(.escape) {
            guard focusedCard != nil, m.pipelineSelection != nil else { return .ignored }
            m.pipelineSelection = nil
            return .handled
        }
        // A card selected elsewhere (Show in Pipeline, the inspector) is where the arrows continue from.
        .onChange(of: m.pipelineSelection) { if let id = m.pipelineSelection, focusedCard != nil { requestedCard = id } }
        .onChange(of: focusedCard) { if focusedCard == requestedCard { requestedCard = nil } }
    }
    private func move(_ direction: BoardNavigation.Move) -> KeyPress.Result {
        guard focusedCard != nil || requestedCard != nil else { return .ignored }
        let columns = m.boardStages.map { m.projects(in: $0).map(\.id) }
        guard let next = BoardNavigation.target(from: requestedCard ?? focusedCard, direction, columns: columns) else { return .handled }
        requestedCard = next
        // With the inspector open it follows the focused card, as a list selection would.
        if m.pipelineSelection != nil { m.pipelineSelection = next }
        return .handled
    }
    private func open() -> KeyPress.Result {
        guard let id = requestedCard ?? focusedCard else { return .ignored }
        m.pipelineSelection = id
        return .handled
    }
}

struct StageColumn: View {
    @EnvironmentObject var m: AppModel
    let stage: String
    var width: CGFloat = 252
    var focusedCard: FocusState<UUID?>.Binding
    var requestedCard: UUID?
    @State private var targeted = false
    var body: some View {
        let items = m.projects(in: stage)
        let colour = m.stageColour(stage)
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                Circle().fill(colour).frame(width: 8, height: 8)
                Text(stage).font(TypeStyle.headline).lineLimit(1)
                Text("\(items.count)").font(TypeStyle.caption.monospacedDigit()).foregroundStyle(.primary)
                    .padding(.horizontal, Space.xs).padding(.vertical, 1).background(.quaternary, in: Capsule())
                Spacer()
                Menu {
                    Menu("Move All \(items.count) to") {
                        ForEach(m.library.stages(for: m.pipelineKind), id: \.self) { target in
                            Button(target) { m.moveAll(from: stage, to: target) }.disabled(target == stage)
                        }
                    }.disabled(items.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Move every card in this column")
                    .accessibilityLabel("\(stage) column actions")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Space.sm) {
                        ForEach(items) { record in
                            ProjectCard(record: record, focusedCard: focusedCard).id(record.id)
                                .onAppear {
                                    if requestedCard == record.id { focusedCard.wrappedValue = record.id }
                                }
                        }
                        if items.isEmpty && m.boardStages.contains(where: { !m.projects(in: $0).isEmpty }) {
                            Text("Drag cards here").font(TypeStyle.caption).foregroundStyle(.secondary).padding(.top, Space.md)
                        }
                    }.padding(Space.xxs)
                }
                .task(id: requestedCard) {
                    guard let id = requestedCard, items.contains(where: { $0.id == id }) else { return }
                    proxy.scrollTo(id, anchor: .center)
                    // A lazy offscreen card needs a layout turn before it can receive keyboard focus.
                    await Task.yield()
                    guard !Task.isCancelled, requestedCard == id else { return }
                    focusedCard.wrappedValue = id
                }
            }
        }
        .frame(width: width)
        .padding(Space.sm)
        .gridArea("stage-column-" + stage, inset: 0)
        .background(RoundedRectangle(cornerRadius: Radius.lg).fill(targeted ? colour.opacity(0.18) : colour.opacity(0.06)))
        .background(RoundedRectangle(cornerRadius: Radius.lg).fill(Surface.control.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(.separator, lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(targeted ? colour : .clear, lineWidth: 2))
        .dropDestination(for: String.self) { ids, _ in
            for id in ids.compactMap(UUID.init) { m.setStage(stage, for: id) }
            return true
        } isTargeted: { targeted = $0 }
    }
}

struct ProjectCard: View {
    @EnvironmentObject var m: AppModel
    let record: ProjectRecord
    var focusedCard: FocusState<UUID?>.Binding
    var selected: Bool { m.pipelineSelection == record.id }
    private var gridID: String { "pipeline-card-" + record.id.uuidString }
    /// The full title first, since the card clips it at three lines.
    private var helpText: String {
        let action = record.isPlanned ? "Double-click to start this idea as a project" : "Double-click to open in Projects"
        return "\(record.isPlanned ? record.name : record.title)\n\(action)"
    }
    var body: some View {
        let stage = m.effectiveStage(record)
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                FormatIcon(data: m.library.presets.first { $0.format == record.format }?.icon, size: 16)
                Text(record.number ?? m.label(for: record.format)).font(TypeStyle.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if record.isPlanned {
                    Image(systemName: "lightbulb").font(TypeStyle.caption).foregroundStyle(.secondary)
                        .help("Idea without a folder yet").accessibilityLabel("Idea")
                }
                else { LocationBadge(location: record.location, compact: true) }
            }.gridProbe(gridID + "-metadata", area: gridID)
            Text(record.isPlanned ? record.name : record.title).font(TypeStyle.callout.weight(.medium)).lineLimit(3).multilineTextAlignment(.leading)
                .gridProbe(gridID + "-title", area: gridID)
            if record.campaign != nil || record.editor != nil {
                HStack(spacing: Space.sm) {
                    if let campaign = record.campaign { StageChip(stage: campaign) }
                    if let editor = record.editor { Label(editor, systemImage: "person").font(TypeStyle.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
        }
        .padding(Space.md).padding(.leading, Space.xs)
        .gridArea(gridID, inset: Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.md).fill(Surface.control))
        .overlay(alignment: .leading) {
            Capsule().fill(m.stageColour(stage)).frame(width: 4).padding(.vertical, Space.sm).padding(.leading, Space.xs)
        }
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: Radius.md))
        // Tab and the arrow keys reach every card; Return or Space shows its details (PipelineBoard).
        .focusable()
        .focused(focusedCard, equals: record.id)
        // Double-click opens the project in Projects; a single click selects it. The double-tap is registered first so it wins.
        .onTapGesture(count: 2) { m.openPipelineCard(record) }
        .onTapGesture { m.pipelineSelection = record.id; focusedCard.wrappedValue = record.id }
        .draggable(record.id.uuidString)
        .help(helpText)
        .contextMenu {
            Menu("Move to") { ForEach(m.moveTargets(for: record), id: \.self) { target in Button(target) { m.setStage(target, for: record.id) }.disabled(target == stage) } }
            if record.isPlanned {
                Button("Start Project…") { m.startPlanned(record) }
                if record.ideaWorkspace == nil { Button("Create Workspace…") { m.workspacePrompt = record } }
                else { Button("Browse Workspace…") { m.workspaceToBrowse = record } }
            }
            else { Button("Show in Projects") { m.openPipelineCard(record) }; Button("Open in Finder") { m.open(record) } }
            Divider()
            Button(record.isPlanned ? "Bin Idea…" : "Remove from List", role: .destructive) { if record.isPlanned { m.requestBinIdea(record) } else { m.removeProject(record.id) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel((record.isPlanned ? "Idea, " : "") + "\(record.name), \(stage)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { m.pipelineSelection = record.id }
        .accessibilityAction(named: Text(record.isPlanned ? "Start Project" : "Show in Projects")) { m.openPipelineCard(record) }
        // Switch Control and Voice Control move a card without dragging.
        .accessibilityActions {
            ForEach(m.moveTargets(for: record).filter { $0 != stage }, id: \.self) { target in
                Button("Move to \(target)") { m.setStage(target, for: record.id) }
            }
        }
    }
}

struct NewIdeaSheet: View {
    @EnvironmentObject var m: AppModel
    @State private var title = ""
    @State private var format = "Long"
    @State private var campaign = ""
    @State private var notes = ""
    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("New idea").font(TypeStyle.title2.weight(.semibold))
            Text("An idea sits in the first column without a number or folder. Start it from Pipeline when you are ready to make it.").foregroundStyle(.secondary)
            Form {
                TextField("Title", text: $title, prompt: Text("What the video is about")).help("A working title. You can change it when you start the project.")
                Picker("Format", selection: $format) { ForEach(m.library.presets.filter { PipelineKind.recordings.includes(format: $0.format) }) { Text($0.label).tag($0.format) } }
                    .help("The kind of video this idea will become")
                TextField("Campaign", text: $campaign, prompt: Text("Optional")).help("Optional campaign this idea belongs to")
                TextField("Notes", text: $notes, prompt: Text("Hook, angle, references"), axis: .vertical).lineLimit(2...6).help("Anything to remember about the idea")
            }.formStyle(.grouped).frame(height: 240)
            HStack {
                Button("Cancel") { m.newIdeaPresented = false }.keyboardShortcut(.cancelAction).help("Close without adding the idea")
                Spacer()
                Button("Add Idea") { m.addIdea(title: title, format: format, campaign: campaign, notes: notes); m.newIdeaPresented = false }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Put the idea in the first column of Recordings")
            }
        }.padding(Space.xxl).frame(width: 520)
        .onAppear { format = PipelineKind.recordings.includes(format: m.format) ? m.format : "Long" }
    }
}
