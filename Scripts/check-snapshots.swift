import AppKit
import SwiftUI
import TemplateCore

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
            for page in Page.allCases {
                model.page = page
                model.pipelineKind = .recordings
                try await capture(page.rawValue.lowercased(), MainView(), size: CGSize(width: 1280, height: 820), scheme: scheme)
                if page == .pipeline {
                    model.pipelineKind = .live
                    try await capture("pipeline-live", MainView(), size: CGSize(width: 1280, height: 820), scheme: scheme)
                }
            }
            for tab in ["Formats", "Naming", "Pipeline", "Locations"] {
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
            model.error = "The selected folder is no longer available. Reconnect its drive, then choose the folder again."
            model.page = .projects
            try await capture("projects-error", MainView(), size: CGSize(width: 1280, height: 820), scheme: scheme)
            model.error = nil
        }
        await model.saveTaskForWorkspace()
        checkNoWindows()
        print("RESULT \(captures) off-screen light/dark content snapshots passed; no visible windows. Compositor appearance and gestures still require a live visual check.")
        print("SNAPSHOTS \(output.path)")
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
        model.destination = model.preset.destination
        model.title = "A new disposable project"
        model.number = "003"
        model.mountedLocations = Set(model.distinctLocations.map(\.key))
        model.refresh()
        await model.refreshTask?.value
        return root
    }
}
