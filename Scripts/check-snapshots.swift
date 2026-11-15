import AppKit
import SwiftUI
import TemplateCore
import SocialsCore

/// Off-screen content captures only. These do not certify window compositing, focus or native gestures.
@main struct SnapshotChecks {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        if let icon = NSImage(contentsOfFile: "Resources/AppIcon.icns") { app.applicationIconImage = icon }
        FrameAutosave.refuse()
        let model = AppModel()
        defer { model.runtime.removeDisposablePreferences() }
        precondition(model.runtime.isIsolated && model.storeUsable, "Snapshots require a disposable data root")
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNAPSHOT_OUTPUT"] ?? model.runtime.root.appendingPathComponent("Snapshots").path)
        try model.runtime.requireWritable(model.runtime.root)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = try await seed(model)
        let socials = try seedSocials(model)
        var captures = 0
        let probeOwner = UUID()
        GridProbes.shared.update(.init(kind: .probe, name: "previous-capture", area: "previous", edge: nil,
                                      inset: 0, x: 0, y: 0, width: 4, height: 4), owner: probeOwner)
        GridProbes.shared.reset()
        precondition(GridProbes.shared.probes.isEmpty, "Grid probes must reset between captures")

        func checkNoWindows() {
            precondition(!app.windows.contains(where: \.isVisible), "A snapshot window became visible")
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            precondition(!windows.contains { ($0[kCGWindowOwnerPID as String] as? Int) == Int(ProcessInfo.processInfo.processIdentifier) }, "Snapshot process appeared on screen")
        }

        func capture<V: View>(_ name: String, _ view: V, size: CGSize, scheme: ColorScheme, fitHeight: Bool = false) async throws {
            if name == "projects" || name == "projects-error", let record = model.selectedRecord {
                model.setViewMode(.list, for: .projectFiles)
                model.inspections[record.id] = nil
                model.selectProject()
                for _ in 0..<100 {
                    if model.inspections[record.id]?.available == true { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                precondition(model.inspections[record.id]?.available == true,
                             "Selected fixture project did not become available within five seconds")
            }
            checkNoWindows()
            GridProbes.shared.reset()
            let content = view.environmentObject(model).environment(\.colorScheme, scheme)
                .frame(width: size.width, height: fitHeight ? nil : size.height)
                .background(Surface.window)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -100_000, y: -100_000), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            host.frame = CGRect(origin: .zero, size: size)
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                if fitHeight {
                    let height = min(max(host.fittingSize.height, 120), 720)
                    host.setFrameSize(CGSize(width: size.width, height: height))
                    window.setContentSize(host.frame.size)
                }
            }
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Cannot allocate \(name) snapshot") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode \(name) snapshot") }
            precondition(bitmap.pixelsWide >= Int(size.width) && bitmap.pixelsHigh >= 120, "Snapshot dimensions are invalid")
            // Check more than transparent or single-colour pixels; an empty hosting surface must fail.
            var colours = Set<UInt32>()
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 100)) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 100)) {
                    if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0 {
                        let rgb = (UInt32(c.redComponent * 255) << 16) | (UInt32(c.greenComponent * 255) << 8) | UInt32(c.blueComponent * 255)
                        colours.insert(rgb)
                    }
                }
            }
            precondition(colours.count > 8, "\(name) rendered blank or flat")
            let base = output.appendingPathComponent(name + "-" + (scheme == .dark ? "dark" : "light"))
            try png.write(to: base.appendingPathExtension("png"))
            GridProbes.shared.write(to: base.path + "-layout.json", window: host.bounds.size)
            checkNoWindows()
            window.contentView = nil
            window.close()
            captures += 1
            print("PASS snapshot \(base.lastPathComponent) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh), \(colours.count) sampled colours")
        }

        for scheme in [ColorScheme.light, .dark] {
            model.error = nil
            for surface in BrowserSurface.allCases { model.setViewMode(.list, for: surface) }
            for page in Page.allCases {
                model.page = page
                model.pipelineKind = .recordings
                if page == .socials {
                    // Connected, lapsed and not set up, from a fixture cache and file credential in the scratch root.
                    model.socials.load(socials.connected, configured: true)
                    try await capture("socials", MainView(), size: CGSize(width: 1280, height: 820), scheme: scheme)
                    model.socials.load(socials.lapsed, configured: true)
                    try await capture("socials-reconnect", MainView(), size: CGSize(width: 1280, height: 820), scheme: scheme)
                    model.socials.load(SocialsSnapshot(), configured: false)
                    try await capture("socials-setup", MainView(), size: CGSize(width: 1280, height: 820), scheme: scheme)
                    model.socials.load(socials.connected, configured: true)
                    continue
                }
                try await capture(page.rawValue.lowercased(), MainView(), size: CGSize(width: 1280, height: 820), scheme: scheme)
                if page == .pipeline {
                    model.pipelineKind = .live
                    try await capture("pipeline-live", MainView(), size: CGSize(width: 1280, height: 820), scheme: scheme)
                }
            }
            for tab in ["Formats", "Naming", "Pipeline", "Finder", "Locations"] {
                model.defaults.set(tab, forKey: "settings.tab")
                try await capture("settings-" + tab.lowercased(), SettingsView(), size: CGSize(width: 520, height: 640), scheme: scheme, fitHeight: true)
            }
            try await capture("about", AboutSettingsView(), size: CGSize(width: 520, height: 640), scheme: scheme, fitHeight: true)
            try await capture("new-project", NewProjectSheet(), size: CGSize(width: min(1280, (NSScreen.main?.visibleFrame.width ?? 1280) - 40), height: min(800, (NSScreen.main?.visibleFrame.height ?? 800) - 40)), scheme: scheme)
            for mode in BrowserViewMode.allCases {
                model.setViewMode(mode, for: .projectFiles)
                try await capture("browser-" + mode.rawValue, FolderBrowserHost(title: "Disposable project files", resolveRoot: { fixture }),
                                  size: CGSize(width: 820, height: 640), scheme: scheme)
            }
            // Inspector contents are captured directly as well as the native board container.
            // NSHostingView does not always composite a native inspector in a hidden window.
            let detailFixtures = [
                ("pipeline-project-details", model.library.projects.first { !$0.isPlanned && $0.format == "Short" }!),
                ("pipeline-idea-details", model.library.projects.first { $0.isPlanned }!),
                ("pipeline-live-details", model.library.projects.first { $0.format == "Livestream" }!)
            ]
            for (name, record) in detailFixtures {
                model.pipelineKind = PipelineKind.of(format: record.format)
                model.pipelineSelection = record.id
                try await capture(name, PipelineInspector(), size: CGSize(width: 340, height: 720), scheme: scheme)
            }
            model.pipelineSelection = nil
            model.error = "The selected folder is no longer available. Reconnect its drive, then choose the folder again."
            model.errorAction = ("Choose…", {})
            model.page = .projects
            try await capture("projects-error", MainView(), size: CGSize(width: 1280, height: 820), scheme: scheme)
            model.error = nil

            // First-run states are a separate part of every appearance gate.
            let populatedLibrary = model.library
            let populatedDraft = model.draft
            let projectSelection = model.selectedProject
            let creationSelection = model.selection
            let templatesSelection = model.templatesSelection
            try await model.commitDurably { library in
                library.projects = []
                library.templates = []
                library.templateSets = []
            }
            model.selectedProject = nil
            model.selection = nil
            model.templatesSelection = nil
            for page in Page.allCases where page != .socials {  // Socials has no library data; its states are captured above
                model.page = page
                model.pipelineKind = .recordings
                try await capture(page.rawValue.lowercased() + "-empty", MainView(), size: CGSize(width: 1280, height: 820), scheme: scheme)
                if page == .pipeline {
                    model.pipelineKind = .live
                    try await capture("pipeline-live-empty", MainView(), size: CGSize(width: 1280, height: 820), scheme: scheme)
                }
            }
            try await model.commitDurably { $0 = populatedLibrary }
            model.selectedProject = projectSelection
            model.selection = creationSelection
            model.templatesSelection = templatesSelection
            model.draft = populatedDraft
            model.refresh()
            await model.refreshTask?.value
        }
        await model.saveTaskForWorkspace()
        checkNoWindows()
        print("RESULT \(captures) off-screen light/dark content snapshots passed; no visible windows. Compositor appearance and gestures still require a live visual check.")
        print("SNAPSHOTS \(output.path)")
    }

    /// A Socials cache and file credential written into the scratch root before Socials first loads, then two states of it.
    @MainActor private static func seedSocials(_ model: AppModel) throws -> (connected: SocialsSnapshot, lapsed: SocialsSnapshot) {
        let directory = model.runtime.root.appendingPathComponent("Socials")
        try FileCredentialStore(directory: directory).write("snapshot-token")
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func ymd(_ back: Int) -> String { SocialsModel.ymd(calendar.date(byAdding: .day, value: -back, to: today)!) }
        let now = Date()
        let read = now.formatted(.iso8601)
        func json<T: Decodable>(_ text: String) throws -> T { try SocialsJSON.decoder.decode(T.self, from: Data(text.utf8)) }
        // Deterministic, plausible daily figures; the last 3 days are not reported yet.
        let rows = (3..<28).map { back -> String in
            let views = 900 + (back * 37) % 400 + (back % 7 == 2 ? 1400 : 0)
            return #"{"date":"\#(ymd(back))","views":\#(views),"estimatedMinutesWatched":\#(views * 3),"subscribersGained":\#(4 + back % 9),"subscribersLost":\#(back % 3)}"#
        }
        func status(_ state: String) -> String {
            #"{"serverTime":"\#(read)","platforms":[{"platform":"youtube","state":"\#(state)","account":"Junior Nkana Bassi","lastGoodReadAt":"\#(read)","lastAttemptAt":"\#(read)","lastError":null,"readIntervalMinutes":15,"gaps":[{"from":"\#(now.addingTimeInterval(-2 * 86_400).formatted(.iso8601))","to":"\#(now.addingTimeInterval(-2 * 86_400 + 2700).formatted(.iso8601))"}]}],"deletions":[]}"#
        }
        func summary(_ state: String) -> String {
            #"{"serverTime":"\#(read)","youtube":{"state":"\#(state)","channelTitle":"Junior Nkana Bassi","subscriberCount":4810,"subscriberCountHidden":false,"countsReadAt":"\#(read)","window":{"startDate":"\#(ymd(30))","endDate":"\#(ymd(3))","partial":false,"views":34120,"estimatedMinutesWatched":102360,"subscribersGained":201,"subscribersLost":27,"readAt":"\#(read)"},"newestVideo":{"id":"fixture","title":"Why is Yamal a better Champions League player than Doué?","publishedAt":"\#(now.addingTimeInterval(-3 * 86_400).formatted(.iso8601))","viewCount":12840,"url":"https://www.youtube.com/watch?v=fixture"}}}"#
        }
        let history: SocialsHistory = try json(#"{"platform":"youtube","readAt":"\#(read)","rows":[\#(rows.joined(separator: ","))],"lastReportedDate":"\#(ymd(3))"}"#)
        let connected = SocialsSnapshot(summary: try json(summary("connected")), status: try json(status("connected")), history: [28: history], lastContact: now)
        let lapsed = SocialsSnapshot(summary: try json(summary("needsReconnect")), status: try json(status("needsReconnect")), history: [28: history], lastContact: now)
        try SocialsCache(directory: directory).save(connected)
        model.socials.range = 28
        precondition(model.socials.configured && model.socials.snapshot.summary?.youtube != nil, "Socials fixture did not load from the scratch root")
        return (connected, lapsed)
    }

    @MainActor private static func seed(_ model: AppModel) async throws -> URL {
        let fm = FileManager.default
        let projects = model.runtime.projects
        let root = projects.appendingPathComponent("001 — Short — A long project title for readable wrapping and accessible controls")
        for folder in ["01 Documents", "02 Project Files", "03 Media"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data("# Disposable script\nA short paragraph for the browser fixture.\n".utf8).write(to: root.appendingPathComponent("01 Documents/Script.md"))
        try Data("Project fixture".utf8).write(to: root.appendingPathComponent("02 Project Files/Template.prproj"))
        let template = TemplateRecord(id: UUID(), name: "Channel template", source: root.path, mode: .full)
        let payload = model.store.payload(template)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        try fm.createDirectory(at: payload.appendingPathComponent("01 Documents"), withIntermediateDirectories: true)
        try Data("# Template\n".utf8).write(to: payload.appendingPathComponent("01 Documents/Template.md"))
        let set = TemplateSet(name: "Channel videos", variants: Library.formats.map { TemplateVariant(format: $0, templateID: template.id) })
        var project = try ProjectRecord(url: root, format: "Short")
        project.stage = "Editing"
        project.notes = "A disposable project showing a long title, notes, metadata and native controls."
        project.campaign = "Autumn videos"
        project.pinned = true
        let idea = ProjectRecord(planned: "A new idea with a deliberately long title to check wrapping on pipeline cards", format: "Short", stage: "Idea")
        let liveRoot = projects.appendingPathComponent("002 — Livestream — Matchday watch-along")
        try fm.createDirectory(at: liveRoot, withIntermediateDirectories: true)
        var live = try ProjectRecord(url: liveRoot, format: "Livestream")
        live.stage = "Scheduled"
        try await model.commitDurably { library in
            library.projects = [project, idea, live]
            library.templates = [template]
            library.templateSets = [set]
            library.customFields = [CustomField(name: "Sponsor", includeInName: false)]
            library.finderTags = false
        }
        model.selectedProject = project.id
        model.templatesSelection = .set(set.id)
        model.selection = .set(set.id)
        model.format = "Short"
        model.draft.destination = model.preset.destination
        model.draft.title = "A new disposable project"
        model.draft.number = "003"
        model.numberEdited()
        model.mountedLocations = Set(model.distinctLocations.map(\.key))
        model.refresh()
        await model.refreshTask?.value
        return root
    }
}
