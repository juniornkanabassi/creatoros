import Foundation
import AppKit
import SwiftUI
import TemplateCore

/// Pipeline keyboard and open behaviour on a real model, and the main window's error row against the page it reports on.
/// Run through Scripts/check-durable-save.sh (CONTENT_TEMPLATE_CHECK_SOURCE): TestOffscreen keeps every window invisible.
@main struct CouncilUIChecks {
    @MainActor static func main() async throws {
        setenv("APP_SNAPSHOT", "1", 1) // records layout probes; read before GridProbes is first used
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        FrameAutosave.refuse()
        let model = AppModel()
        defer { model.runtime.removeDisposablePreferences() }
        precondition(model.runtime.isIsolated && model.storeUsable, "Council checks require a disposable data root")
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, "FAIL council ui: " + label)
            checks += 1
            print("PASS council ui: \(label)")
        }

        // Fixture: Idea holds an idea and a project, Writing is empty, Filming holds one project, Editing two.
        func folder(_ name: String) throws -> URL {
            let url = model.runtime.projects.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        var ideaProject = try ProjectRecord(url: folder("001 — Short — Idea stage project"), format: "Short"); ideaProject.stage = "Idea"
        var filming = try ProjectRecord(url: folder("002 — Long — Filming project"), format: "Long"); filming.stage = "Filming"
        var editingOld = try ProjectRecord(url: folder("003 — Short — Older edit"), format: "Short"); editingOld.stage = "Editing"
        var editingNew = try ProjectRecord(url: folder("004 — Short — Newer edit"), format: "Short"); editingNew.stage = "Editing"
        let idea = ProjectRecord(planned: "An idea without a folder", format: "Short", stage: "Idea")
        try await model.commitDurably { library in
            library.projects = [ideaProject, filming, editingOld, editingNew, idea]
            library.finderTags = false
        }
        model.mountedLocations = Set(model.distinctLocations.map(\.key))
        model.page = .pipeline
        model.pipelineKind = .recordings

        // Arrow keys walk the columns the board actually shows.
        let columns = model.boardStages.map { model.projects(in: $0).map(\.id) }
        check(model.boardStages.prefix(4) == ["Idea", "Writing", "Filming", "Editing"], "the recordings board shows its stages in order")
        check(columns[0] == [idea.id, ideaProject.id] && columns[1].isEmpty && columns[3] == [editingNew.id, editingOld.id],
              "fixture columns hold ideas first, then newer numbers")
        typealias Nav = BoardNavigation
        check(Nav.target(from: nil, .down, columns: columns) == idea.id, "the first arrow press focuses the first card")
        check(Nav.target(from: idea.id, .down, columns: columns) == ideaProject.id, "down moves within a column")
        check(Nav.target(from: ideaProject.id, .down, columns: columns) == nil, "down stops at the bottom of a column")
        check(Nav.target(from: idea.id, .up, columns: columns) == nil, "up stops at the top of a column")
        check(Nav.target(from: ideaProject.id, .right, columns: columns) == filming.id, "right skips an empty stage and keeps the nearest row")
        check(Nav.target(from: filming.id, .right, columns: columns) == editingNew.id, "right lands on the same row in the next stage")
        check(Nav.target(from: editingOld.id, .left, columns: columns) == filming.id, "left clamps to the last card of a shorter column")
        check(Nav.target(from: idea.id, .left, columns: columns) == nil, "left stops at the first stage")
        check(Nav.target(from: UUID(), .down, columns: columns) == idea.id, "a card that left the board restarts at the first card")

        // Return or Space selects; the inspector shows that record and closes when it disappears.
        model.pipelineSelection = filming.id
        check(model.pipelineSelectedRecord?.id == filming.id, "a selected card opens its details in the inspector")
        model.pipelineSelection = UUID()
        check(model.pipelineSelectedRecord == nil, "a selection that is no longer in the library closes the inspector")

        // Double-click (and the accessibility action) opens a project in Projects and an idea in New Project.
        model.openPipelineCard(filming)
        check(model.page == .projects && model.selectedProject == filming.id, "opening a project card shows it in Projects")
        model.page = .pipeline
        model.openPipelineCard(idea)
        check(model.newProjectPresented && model.draft.startingFrom == idea.id && model.draft.title == idea.name, "opening an idea fills in New Project")
        model.newProjectPresented = false
        model.forgetStartingIdea()

        // Named move actions reach every other stage.
        check(model.moveTargets(for: filming).filter { $0 != model.effectiveStage(filming) }.count == model.library.stages(for: .recordings).count - 1,
              "every other stage has a Move to action")
        model.setStage("Published", for: filming.id)
        check(model.library.projects.first { $0.id == filming.id }?.stage == "Published", "a Move to action changes the stage")

        // Layout: render the real MainView off screen and read its probes.
        func render(width: CGFloat) async throws -> [String: GridProbes.Probe] {
            GridProbes.shared.reset()
            let size = CGSize(width: width, height: 820)
            let host = NSHostingView(rootView: MainView().environmentObject(model).frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -100_000, y: -100_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = CGRect(origin: .zero, size: size)
            for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)) }
            precondition(!app.windows.contains(where: \.isVisible), "A check window became visible")
            let probes = GridProbes.shared.probes
            window.contentView = nil
            window.close()
            return Dictionary(probes.values.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        }
        model.error = "The selected folder is no longer available. Reconnect its drive, then choose the folder again."
        for page in [Page.pipeline, .projects] {
            model.page = page
            model.pipelineSelection = nil
            let probes = try await render(width: 1280)
            guard let notice = probes["error-notice"], let content = probes["work-page"] else {
                preconditionFailure("FAIL council ui: \(page.rawValue) did not record the error and page probes")
            }
            check(notice.height > 0 && notice.y + notice.height <= content.y + 0.5, "\(page.rawValue): the error is a row above the page, not over it")
            if page == .pipeline {
                check(content.width >= 960, "pipeline: the board takes the window beside the sidebar (\(Int(content.width)) pt at 1280)")
            }
        }
        model.error = nil
        model.page = .pipeline
        let clear = try await render(width: 1280)
        check(clear["error-notice"] == nil && clear["work-page"] != nil, "no error row is drawn without an error")

        // At the default window every recording stage is on screen without scrolling the board.
        if let work = clear["work-page"] {
            let stages = model.boardStages
            let columns = stages.compactMap { clear["stage-column-" + $0] }
            check(stages.count == 6 && columns.count == stages.count, "the recordings board records its six stage columns")
            let clipped = columns.filter { $0.x < work.x - 0.5 || $0.x + $0.width > work.x + work.width + 0.5 }.map(\.name)
            check(clipped.isEmpty, "all six stage columns fit the \(Int(work.width)) pt board at 1280 pt (clipped: \(clipped))")
        }

        print("RESULT \(checks) council ui checks passed")
    }
}
