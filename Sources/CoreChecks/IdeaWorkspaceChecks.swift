import Foundation
import TemplateCore
import Darwin

func ideaWorkspaceChecks(base: URL) throws {
    let fm = FileManager.default
    let base = base.resolvingSymlinksInPath().appendingPathComponent("Idea workspaces")
    let root = base.appendingPathComponent("Ideas")
    let output = base.appendingPathComponent("Projects")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try fm.createDirectory(at: output, withIntermediateDirectories: false)
    var idea = ProjectRecord(planned: "2026 — Ideas — the literal title", format: "Short", stage: "Idea", campaign: "Campaign")
    idea.notes = "Keep my notes"; idea.series = ["Series"]; idea.editor = "Junior"; idea.notionURL = "https://notion.so/example"
    idea.pinned = true; idea.publishedDate = Date(timeIntervalSince1970: 12345); idea.scanNotes = ["Keep scan context"]
    idea.previousPaths = ["historical reference"]; idea.exportFolders = ["old exports"]; idea.lastIndexed = Date(timeIntervalSince1970: 23456)
    try check(idea.title == idea.name && idea.number == nil, "planned titles keep literal leading digits and separators")
    idea.ideaWorkspace = try IdeaWorkspaceEngine.create(for: idea, root: root)
    let workspace = try IdeaWorkspaceEngine.resolve(for: idea)
    var systemAlias = idea
    systemAlias.ideaWorkspace?.path = workspace.path.replacingOccurrences(of: "/private/var/", with: "/var/")
    systemAlias.ideaWorkspace?.rootPath = workspace.deletingLastPathComponent().path.replacingOccurrences(of: "/private/var/", with: "/var/")
    try check(try IdeaWorkspaceEngine.resolve(for: systemAlias) == workspace, "system private-var bookmark aliases resolve to the same owned workspace")
    try check(idea.path.isEmpty && idea.isPlanned && idea.number == nil && Numbering.next(for: "Short", in: [idea]) == "001", "creating a workspace does not allocate a production path or number")
    try check(try children(workspace) == [IdeaWorkspaceEngine.markerName], "empty workspace carries only its ownership marker")
    try rejects("workspace cannot be created twice") { _ = try IdeaWorkspaceEngine.create(for: idea, root: root) }
    try put(Data("opaque project bytes".utf8), at: workspace.appendingPathComponent("01 Documents/Template.txt"))
    try put(Data("keep this attachment".utf8), at: workspace.appendingPathComponent("01 Documents/notes.txt"))
    try put(Data("literal bracket filename".utf8), at: workspace.appendingPathComponent("01 Documents/[Campaign]/A-roll [take 2].mov"))
    try put(Data("literal token filename".utf8), at: workspace.appendingPathComponent("01 Documents/[Campaign].txt"))
    try put(Data("literal placeholder filename".utf8), at: workspace.appendingPathComponent("01 Documents/[Project Name].txt"))
    let before = try digestTree(workspace)
    let fields = ProjectFields(number: "001", format: "Short", campaign: "Campaign", title: idea.title)
    let cached = try IdeaWorkspaceEngine.scan(for: idea)
    let preview = PreviewRenderer.render(structure: cached.structure, fields: fields, renamingPaths: cached.renamingPaths)
    let cachedPlan = try TemplateReader.plan(from: cached.structure, fields: fields, renamingPaths: cached.renamingPaths)
    let freshPlan = try IdeaWorkspaceEngine.promotionPlan(for: idea, fields: fields)
    try check(preview.isExecutable && preview.entries.map(\.output) == cachedPlan.entries.map(\.output) &&
              cachedPlan.entries.map(\.output) == freshPlan.entries.map(\.output), "cached workspace preview and executable promotion agree for literal nested bracket attachments")
    try check(preview.entries.first(where: { $0.source == "01 Documents/[Project Name].txt" })?.placeholder == false, "literal placeholder-looking attachment is not marked as unresolved template output")
    let incomplete = PreviewRenderer.render(structure: cached.structure, fields: ProjectFields(number: "", format: "Short", title: ""), renamingPaths: cached.renamingPaths)
    try check(!incomplete.isExecutable && !incomplete.missingFields.isEmpty, "workspace placeholder preview cannot become executable before required fields are complete")
    let copied = try IdeaWorkspaceEngine.promote(for: idea, fields: fields, destination: output, expectedPlan: cachedPlan)
    let promoted = try idea.promoted(to: copied)
    try check(!promoted.isPlanned && promoted.number == "001" && promoted.id == idea.id, "promotion retains identity and allocates the chosen number")
    var originalJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(idea)) as! [String: Any]
    var promotedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(promoted)) as! [String: Any]
    for key in ["name", "path", "bookmark", "volumeName", "volumeID", "volumePath", "folderCreated", "planned"] {
        originalJSON.removeValue(forKey: key); promotedJSON.removeValue(forKey: key)
    }
    try check(NSDictionary(dictionary: originalJSON).isEqual(to: promotedJSON), "promotion preserves all non-location metadata, including stage, dates, pinned state and workspace reference")
    try check(fm.fileExists(atPath: copied.appendingPathComponent("01 Documents/" + fields.finalName() + ".txt").path), "promotion substitutes Template names")
    try check(try Data(contentsOf: copied.appendingPathComponent("01 Documents/notes.txt")) == Data("keep this attachment".utf8), "promotion preserves attachment bytes")
    try check(fm.fileExists(atPath: copied.appendingPathComponent("01 Documents/[Campaign]/A-roll [take 2].mov").path) &&
              fm.fileExists(atPath: copied.appendingPathComponent("01 Documents/[Campaign].txt").path), "nested bracket attachments keep literal token and unknown bracket names")
    try check(!fm.fileExists(atPath: copied.appendingPathComponent(IdeaWorkspaceEngine.markerName).path) && (try digestTree(workspace)) == before, "promotion omits ownership marker and preserves the entire original workspace")
    try rejects("promotion never overwrites existing destination") { _ = try IdeaWorkspaceEngine.promote(for: idea, fields: fields, destination: output) }
    let cancelled = Cancellation(); cancelled.cancel()
    try rejects("cancelled promotion leaves the idea workspace intact") {
        _ = try IdeaWorkspaceEngine.promote(for: idea, fields: ProjectFields(number: "002", format: "Short", title: "Cancelled"), destination: output, cancellation: cancelled)
    }
    try check(try digestTree(workspace) == before, "copy failures leave idea attachments unchanged")

    let store = LibraryStore(root: base.appendingPathComponent("Library"))
    var library = Library(); library.projects = [idea]
    try store.save(library)
    let loaded = try store.load()
    try check(loaded.schema == 6 && loaded.projects[0].ideaWorkspace?.owner == idea.ideaWorkspace?.owner, "schema six persists workspace ownership independently of production location")
    let impossibleRoot = base.appendingPathComponent("Not a directory")
    try Data("block library write".utf8).write(to: impossibleRoot)
    var candidate = library; candidate.projects[0] = promoted
    try rejects("failed durable registration reports an error") { try LibraryStore(root: impossibleRoot).save(candidate) }
    try check((try store.load()).projects[0].isPlanned && fm.fileExists(atPath: workspace.path) && fm.fileExists(atPath: copied.path), "save failure leaves durable idea, original workspace and recoverable copied output")

    var impostor = idea; impostor.id = UUID()
    try rejects("marker cannot be used by another record") { _ = try IdeaWorkspaceEngine.resolve(for: impostor) }
    impostor = idea; impostor.ideaWorkspace?.owner = UUID()
    try rejects("marker must match stored ownership UUID") { _ = try IdeaWorkspaceEngine.resolve(for: impostor) }
    impostor = idea; impostor.ideaWorkspace?.rootPath = output.path; impostor.ideaWorkspace?.rootBookmark = nil
    try rejects("workspace outside configured root is rejected") { _ = try IdeaWorkspaceEngine.resolve(for: impostor) }
    try rejects("Trash refuses a path different from the confirmed workspace") { try IdeaWorkspaceEngine.trash(for: idea, confirmedURL: output) }
    let alias = root.appendingPathComponent("Alias")
    try fm.createSymbolicLink(at: alias, withDestinationURL: workspace)
    impostor = idea; impostor.ideaWorkspace?.path = alias.path; impostor.ideaWorkspace?.bookmark = nil
    try rejects("symlink workspace is rejected") { _ = try IdeaWorkspaceEngine.resolve(for: impostor) }
    let rootAlias = base.appendingPathComponent("Root alias")
    try fm.createSymbolicLink(at: rootAlias, withDestinationURL: root)
    impostor = idea; impostor.ideaWorkspace?.rootPath = rootAlias.path; impostor.ideaWorkspace?.rootBookmark = nil
    impostor.ideaWorkspace?.path = rootAlias.appendingPathComponent(workspace.lastPathComponent).path; impostor.ideaWorkspace?.bookmark = nil
    try rejects("ordinary symlink ancestor is not treated as a system alias") { _ = try IdeaWorkspaceEngine.resolve(for: impostor) }
    impostor = idea; impostor.ideaWorkspace?.path = root.appendingPathComponent("Different bookmark target").path
    try rejects("bookmark target must match saved path after system alias normalisation") { _ = try IdeaWorkspaceEngine.resolve(for: impostor) }
    impostor = idea; impostor.ideaWorkspace?.path = root.appendingPathComponent("Offline").path; impostor.ideaWorkspace?.bookmark = nil
    try rejects("missing workspace is rejected") { _ = try IdeaWorkspaceEngine.resolve(for: impostor) }
    let marker = workspace.appendingPathComponent(IdeaWorkspaceEngine.markerName)
    let markerBytes = try Data(contentsOf: marker)
    try fm.removeItem(at: marker)
    try fm.createSymbolicLink(at: marker, withDestinationURL: copied.appendingPathComponent("01 Documents/notes.txt"))
    try rejects("symlink ownership marker is rejected") { _ = try IdeaWorkspaceEngine.resolve(for: idea) }
    try fm.removeItem(at: marker); try markerBytes.write(to: marker)

    let collision = workspace.appendingPathComponent("01 Documents/" + (try fields.finalName()) + ".txt")
    try Data("competing attachment".utf8).write(to: collision)
    try rejects("template substitution never merges colliding attachments") { _ = try IdeaWorkspaceEngine.promotionPlan(for: idea, fields: fields) }
    try fm.removeItem(at: collision)
    let changedFields = ProjectFields(number: "003", format: "Short", title: "Changed")
    let extra = workspace.appendingPathComponent("late attachment.txt")
    try rejects("new attachments arriving before commit invalidate promotion") {
        _ = try IdeaWorkspaceEngine.promote(for: idea, fields: changedFields, destination: output, progress: { _, label in
            if label == "Finalising" { try? Data("arrived during copy".utf8).write(to: extra) }
        })
    }
    try check(!fm.fileExists(atPath: output.appendingPathComponent(try changedFields.finalName()).path) && fm.fileExists(atPath: extra.path), "failed verification commits no output and retains the new attachment")

    let reviewedFields = ProjectFields(number: "005", format: "Short", title: "Reviewed workspace")
    let reviewed = try IdeaWorkspaceEngine.promotionPlan(for: idea, fields: reviewedFields)
    let preClick = workspace.appendingPathComponent("Added after preview.txt")
    try Data("not shown in preview".utf8).write(to: preClick)
    try rejects("attachment added before clicking Start requires a new preview") {
        _ = try IdeaWorkspaceEngine.promote(for: idea, fields: reviewedFields, destination: output, expectedPlan: reviewed)
    }
    let withAddition = try IdeaWorkspaceEngine.promotionPlan(for: idea, fields: reviewedFields)
    try fm.removeItem(at: preClick)
    try rejects("attachment deleted before clicking Start requires a new preview") {
        _ = try IdeaWorkspaceEngine.promote(for: idea, fields: reviewedFields, destination: output, expectedPlan: withAddition)
    }
    try check(!fm.fileExists(atPath: output.appendingPathComponent(try reviewedFields.finalName()).path), "stale preview rejects before any project is committed")

    let corruptedFields = ProjectFields(number: "004", format: "Short", title: "Corrupted copy")
    try rejects("byte verification rejects corruption with unchanged file length") {
        _ = try IdeaWorkspaceEngine.promote(for: idea, fields: corruptedFields, destination: output, progress: { _, label in
            if label == "Finalising",
               let stage = try? FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
                .first(where: { $0.lastPathComponent.hasPrefix(".project-templates-") }) {
                try? Data(repeating: 120, count: "keep this attachment".utf8.count)
                    .write(to: stage.appendingPathComponent("01 Documents/notes.txt"))
            }
        })
    }
    try check(!fm.fileExists(atPath: output.appendingPathComponent(try corruptedFields.finalName()).path), "unverified bytes never become a committed project")

    let payload = base.appendingPathComponent("Payload")
    try put(Data("template contents".utf8), at: payload.appendingPathComponent("Template.txt"))
    try put(Data("template token contents".utf8), at: payload.appendingPathComponent("[Campaign]/[Project Name].txt"))
    var seeded = ProjectRecord(planned: "Unnumbered", format: "Long", stage: "Writing")
    seeded.ideaWorkspace = try IdeaWorkspaceEngine.create(for: seeded, root: root, payload: payload)
    try check(fm.fileExists(atPath: (try IdeaWorkspaceEngine.resolve(for: seeded)).appendingPathComponent("Template.txt").path), "optional payload retains Template names until Start Project")
    let seededWorkspace = try IdeaWorkspaceEngine.resolve(for: seeded)
    try put(Data("added attachment".utf8), at: seededWorkspace.appendingPathComponent("[Campaign]/[Campaign].txt"))
    let seededFields = ProjectFields(number: "007", format: "Long", campaign: "Seed", title: "Token name")
    let seededCopy = try IdeaWorkspaceEngine.promote(for: seeded, fields: seededFields, destination: output)
    try check(fm.fileExists(atPath: seededCopy.appendingPathComponent("Seed/Token name.txt").path), "initial template token filenames and directories still substitute")
    try check(fm.fileExists(atPath: seededCopy.appendingPathComponent("Seed/[Campaign].txt").path), "new attachment keeps its literal filename inside a renamed template directory")
    let forkedAttachment = seededWorkspace.appendingPathComponent("resource-bearing document")
    try Data("ordinary data fork".utf8).write(to: forkedAttachment)
    let fork = Data("valuable resource fork".utf8)
    let wroteFork = fork.withUnsafeBytes { setxattr(forkedAttachment.path, "com.apple.ResourceFork", $0.baseAddress, fork.count, 0, XATTR_NOFOLLOW) }
    try check(wroteFork == 0, "resource-bearing attachment fixture created")
    let plainFields = ProjectFields(number: "008", format: "Long", campaign: "Seed", title: "Preserve resources")
    try rejects("plain promotion refuses ordinary attachment resource-fork data loss") {
        _ = try IdeaWorkspaceEngine.promote(for: seeded, fields: plainFields, destination: output, finderMetadata: false)
    }
    try check(!fm.fileExists(atPath: output.appendingPathComponent(try plainFields.finalName()).path) &&
              (try IconService.attribute("com.apple.ResourceFork", at: forkedAttachment)) == fork,
              "rejected plain promotion retains original resource fork and creates no output")
    let preservedCopy = try IdeaWorkspaceEngine.promote(for: seeded, fields: plainFields, destination: output)
    try check(try IconService.attribute("com.apple.ResourceFork", at: preservedCopy.appendingPathComponent("resource-bearing document")) == fork,
              "metadata-preserving promotion retains ordinary attachment resource fork")
    let normalReviewed = try TemplateReader.scan(payload, fields: seededFields)
    try check(normalReviewed.sameInventory(as: try TemplateReader.scan(payload, fields: seededFields)), "unchanged normal template matches its reviewed inventory")
    try put(Data("new template attachment".utf8), at: payload.appendingPathComponent("Added after normal preview.txt"))
    try check(!normalReviewed.sameInventory(as: try TemplateReader.scan(payload, fields: seededFields)), "normal template inventory catches an attachment added after preview")
}
