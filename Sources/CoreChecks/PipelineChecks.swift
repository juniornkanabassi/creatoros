import Foundation
import TemplateCore

func pipelineChecks(base: URL) throws {
    try check(try Configuration.fieldName(" Sponsor ", others: []) == "Sponsor", "custom field names trim whitespace")
    for name in ["", "template", "project number", "[Client]", "Client\nName", "Sponsor"] {
        do { _ = try Configuration.fieldName(name, others: ["Sponsor"]); throw AppFailure("invalid custom field accepted") }
        catch { try check(error.localizedDescription != "invalid custom field accepted", "reject invalid or duplicate field \(name)") }
    }
    do { _ = try Configuration.stages(["Idea", "idea"]); throw AppFailure("duplicate stages accepted") }
    catch { try check(error.localizedDescription != "duplicate stages accepted", "stage names cannot collide ignoring case") }
    let folder = base.appendingPathComponent("Pipeline/01 Longs/230 — Long — Lille vs PSG | Post-Game Reaction")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var record = try ProjectRecord(url: folder, format: "Long")
    try check(record.number == "230" && record.title == "Lille vs PSG | Post-Game Reaction" && !record.isPlanned, "number and title parse from the folder name")
    var planned = ProjectRecord(planned: "Doué is a better UCL player than Yamal", format: "Short", stage: "Idea", campaign: nil)
    try check(planned.isPlanned && planned.number == nil && planned.location.key == "planned", "planned idea has no folder, number or location")
    try rejects("planned record cannot resolve a folder") { _ = try planned.resolve() }
    planned.editor = "Editor name"; planned.notes = "Hook idea"
    try check(planned.searchableText.contains("Editor name") && planned.searchableText.contains("Hook idea"), "search covers editor and notes")

    var projects = [record]
    for n in ["001", "168", "175"] { projects.append(ProjectRecord(planned: "x", format: "Short", stage: "Idea")); projects[projects.count - 1].path = "/tmp/\(n) — Short — x"; projects[projects.count - 1].name = "\(n) — Short — x"; projects[projects.count - 1].planned = false }
    try check(Numbering.next(for: "Long", in: projects) == "231" && Numbering.next(for: "Short", in: projects) == "176", "next number is per format")
    try check(Numbering.next(for: "Podcast", in: projects) == "001", "first number of a format starts at 001")
    try check(Numbering.next(for: "Short", in: [planned]) == "001", "planned ideas do not consume numbers")
    var huge = record; huge.name = "9223372036854775807 — Long — Large number"
    try check(Numbering.next(for: "Long", in: [huge]) == "9223372036854775808", "next number does not overflow machine integers")
    huge.name = "4294967295 — Long — Large number"
    try check(Numbering.next(for: "Long", in: [huge]) == "4294967296", "next number is not truncated to 32 bits")
    var twin = record; twin.id = UUID(); twin.path = "/Volumes/Naruto Uzumaki/01 Video Project Archive/01 Recordings/01 Longs/" + record.name
    try check(Numbering.siblings(of: record, in: [record, twin]).count == 1, "same number and format on another drive is a sibling")
    twin.name = "230 — Long — Another client's unrelated project"
    try check(Numbering.siblings(of: record, in: [record, twin]).isEmpty, "same number alone does not claim an unrelated project is another copy")

    let external = ProjectLocation(path: "/Volumes/Naruto Uzumaki/01 Video Project Archive/01 Recordings/01 Longs/230 — Long — X", volumeName: "Naruto Uzumaki")
    try check(external.kind == .external && external.label == "Naruto Uzumaki" && external.defaultColour == "orange" && external.mountPath == "/Volumes/Naruto Uzumaki", "external drive classified with its default colour")
    let cloud = ProjectLocation(path: "/Users/j/Library/CloudStorage/GoogleDrive-jnb@example.com/Shared drives/Shared Content Creation/Short — X")
    try check(cloud.kind == .cloud && cloud.label == "Google Drive" && cloud.account == "jnb@example.com" && cloud.defaultColour == "green", "cloud folder classified by provider and account")
    let local = ProjectLocation(path: "/Users/j/Content Creation/02 Live Projects/x", volumeName: "Macintosh HD")
    try check(local.kind == .local && local.label == "Macintosh HD" && local.defaultColour == "gray" && local.isMounted, "boot drive classified as local")
    try check(!ProjectLocation(path: "/Volumes/ContentTemplate-Not-Mounted/x").isMounted, "unmounted volume reports not mounted")
    let lucid = ProjectLocation(path: "/Volumes/junior-nkanabassi/junior-nkanabassi/000 — Short — LucidLink Test 01")
    try check(lucid.kind == .cloud && lucid.label == "LucidLink" && lucid.account == "junior-nkanabassi" && lucid.mountPath == "/Volumes/junior-nkanabassi/junior-nkanabassi" && lucid.defaultColour == "indigo", "LucidLink filespace classified as a cloud drive")
    try check(ProjectLocation(path: "/Volumes/junior-nkanabassi/Other/x").kind == .external, "a plain volume with a different second folder stays external")

    let fields = ProjectFields(number: "007", format: "Short", campaign: "Series", title: "Episode",
                               extras: [ExtraValue(name: "Sponsor", value: "Surfshark", includeInName: true), ExtraValue(name: "Client", value: "DAZN", includeInName: false)])
    try check(fields.finalName() == "007 — Short — Series — Surfshark — Episode", "custom field joins after the campaign when included in the name")
    try check(Naming.render("[Client] brief [Sponsor].txt", fields: fields) == "DAZN brief Surfshark.txt", "custom fields work as tokens even when not in the name")
    let blankExtras = ProjectFields(number: "007", format: "Short", title: "Episode", extras: [ExtraValue(name: "Sponsor", value: "", includeInName: true)])
    try check(blankExtras.finalName() == "007 — Short — Episode", "blank custom field disappears cleanly")
    try rejects("invalid custom field value rejected") { _ = try ProjectFields(number: "1", format: "Short", title: "T", extras: [ExtraValue(name: "Sponsor", value: "a/b", includeInName: true)]).finalName() }
    let preview = blankExtras.previewName()
    try check(preview.name == "007 — Short — Episode" && preview.tokens["Sponsor"] == "", "preview naming includes custom field tokens")

    let store = LibraryStore(root: base.appendingPathComponent("Pipeline library"))
    var library = Library()
    library.projects = [planned, record]
    library.customFields = [CustomField(name: "Sponsor")]
    library.stages = ["Idea", "Scripting", "Done"]
    record.stage = "Editing"; record.editor = "Freelancer"; record.campaign = "DAZN48"; record.notionURL = "https://notion.so/x"
    library.projects[1] = record
    try store.save(library)
    let back = try store.load()
    try check(back.schema == Library.currentSchema && back.projects[1].stage == "Editing" && back.projects[1].editor == "Freelancer" && back.projects[0].isPlanned && back.fieldList.first?.name == "Sponsor" && back.stageList == ["Idea", "Scripting", "Done"], "pipeline fields, custom fields and stages persist")
    try check(Library().stageList == Library.defaultStages, "default stages apply when none are saved")
}

/// Two boards, stage colours and Finder tags.
func boardChecks(base: URL) throws {
    try check(PipelineKind.of(format: "Livestream") == .live && PipelineKind.of(format: "Long") == .recordings && PipelineKind.of(format: "Existing") == .recordings, "live streams have their own board, everything else is a recording")
    var library = Library()
    try check(library.stages(for: .live) == Library.defaultLiveStages && library.stages(for: .recordings) == Library.defaultStages, "default stages per board")
    try check(library.colour(of: "Published") == .green && library.colour(of: "Scheduled") == .blue && library.colour(of: "Unclassified") == .none, "default stage colours, none for unknown stages")
    library.stageColours = ["Published": "red"]
    library.liveStages = ["Booked", "Streamed", "Clipped"]
    library.finderTags = false
    try check(library.colour(of: "Published") == .red && library.allStages == Library.defaultStages + ["Booked", "Streamed", "Clipped"] && !library.finderTagsEnabled, "colour overrides, custom live stages and the Finder switch")
    let store = LibraryStore(root: base.appendingPathComponent("Board library"))
    try store.save(library)
    let back = try store.load()
    try check(back.liveStageList == ["Booked", "Streamed", "Clipped"] && back.colour(of: "Published") == .red && back.finderTags == false && back.schema == Library.currentSchema, "live stages, colours and the Finder switch persist in the current schema")
    for colour in StageColour.allCases { try check(StageColour(finderIndex: colour.finderIndex) == colour, "Finder colour index round-trips for \(colour.rawValue)") }

    let folder = base.appendingPathComponent("Board/231 — Livestream — Lille vs PSG")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try check(try FinderTags.read(folder).isEmpty, "a fresh folder has no tags")
    try FinderTags.write([.init(name: "Client", colour: .red)], to: folder)
    let known = Library().allStages
    try check(try FinderTags.apply(stage: "Scheduled", colour: .blue, knownStages: known, to: folder), "applying a stage tag reports a change")
    try check(try FinderTags.read(folder) == [.init(name: "Client", colour: .red), .init(name: "Scheduled", colour: .blue)], "the stage tag joins the folder's own tags")
    try check(!(try FinderTags.apply(stage: "Scheduled", colour: .blue, knownStages: known, to: folder)), "applying the same stage again changes nothing")
    try FinderTags.apply(stage: "Streamed", colour: .green, knownStages: known, to: folder)
    try check(try FinderTags.read(folder) == [.init(name: "Client", colour: .red), .init(name: "Streamed", colour: .green)], "moving stage replaces only the stage tag")
    try check(FinderTags.stage(of: folder, knownStages: known) == "Streamed", "the folder reports its stage from Finder")
    let raw = try PropertyListSerialization.propertyList(from: try IconService.attribute(FinderTags.attribute, at: folder) ?? Data(), format: nil) as? [String]
    try check(raw == ["Client\n6", "Streamed\n2"], "tags are stored the way Finder stores them")
    try FinderTags.clear(knownStages: known, from: folder)
    try check(try FinderTags.read(folder) == [.init(name: "Client", colour: .red)], "clearing stage tags keeps the rest")
    try FinderTags.write([], to: folder)
    try check(try FinderTags.read(folder).isEmpty && FinderTags.stage(of: folder, knownStages: known) == nil, "an empty tag list removes the attribute")
    try rejects("tags cannot be read from a missing folder") { _ = try FinderTags.read(base.appendingPathComponent("Board/missing")) }
}

/// Plain copies for filesystems that cannot hold Finder icon files.
func plainCopyChecks(base: URL) throws {
    let template = base.appendingPathComponent("Plain/Template")
    let inner = template.appendingPathComponent("01 Documents")
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
    try Data("brief".utf8).write(to: inner.appendingPathComponent("[Project Number] brief.txt"))
    try Data().write(to: inner.appendingPathComponent("Icon\r"))
    var finder = Data(count: 32); finder[8] = 0x04
    _ = finder.withUnsafeBytes { setxattr(inner.path, "com.apple.FinderInfo", $0.baseAddress, 32, 0, XATTR_NOFOLLOW) }
    let fields = ProjectFields(number: "000", format: "Short", title: "Plain")
    let full = try TemplateReader.scan(template, fields: fields)
    let plain = full.withoutIconFiles
    try check(full.entries.contains { $0.metadata } && !plain.entries.contains { $0.metadata } && plain.excluded.contains("01 Documents/Icon\r") && plain.visible.count == full.visible.count, "a plan without icon files keeps every visible item and lists what it left out")
    let out = base.appendingPathComponent("Plain/Out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let created = try CreationEngine.create(plan: plain, destination: out, name: "000 — Short — Plain", icon: nil, finderMetadata: false)
    let docs = created.appendingPathComponent("01 Documents")
    try check(FileManager.default.fileExists(atPath: docs.appendingPathComponent("000 brief.txt").path) && !FileManager.default.fileExists(atPath: docs.appendingPathComponent("Icon\r").path), "plain copy renames files and leaves the Icon file out")
    try check((try IconService.attribute("com.apple.FinderInfo", at: docs)) == nil, "plain copy writes no FinderInfo")
    let withIcons = try CreationEngine.create(plan: full, destination: out, name: "000 — Short — Icons", icon: nil)
    try check(FileManager.default.fileExists(atPath: withIcons.appendingPathComponent("01 Documents/Icon\r").path) && (try IconService.attribute("com.apple.FinderInfo", at: withIcons.appendingPathComponent("01 Documents")))?[8] == 0x04, "default creation still copies icon files and flags")

    // Restoring icons onto the plain copy makes it metadata-identical to the copy made with icons.
    try FileManager.default.createDirectory(at: created.appendingPathComponent("Added by editor"), withIntermediateDirectories: false)
    let restored = try IconService.restore(template: template, fields: fields, onto: created)
    try check(restored.restored == ["01 Documents"] && restored.unmatched.isEmpty && restored.failed.isEmpty, "restore reports the folders it iconed")
    // digestTree keys keep the differing project names in front; compare from the first slash on.
    func inside(_ tree: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: tree.filter { !$0.key.contains("Added by editor") }.map { (String($0.key.drop(while: { $0 != "/" })), $0.value) })
    }
    let plainTree = inside(try digestTree(created)), iconTree = inside(try digestTree(withIcons))
    try check(plainTree == iconTree, "a restored plain copy carries the same files, icon files and Finder metadata as a copy made with icons")
    let again = try IconService.restore(template: template, fields: fields, onto: created)
    try check(again.restored == ["01 Documents"] && inside(try digestTree(created)) == iconTree, "restoring twice changes nothing")
    try FileManager.default.removeItem(at: created.appendingPathComponent("01 Documents"))
    let missing = try IconService.restore(template: template, fields: fields, onto: created)
    try check(missing.unmatched == ["01 Documents"] && missing.restored.isEmpty && !FileManager.default.fileExists(atPath: created.appendingPathComponent("01 Documents").path), "a folder the project no longer has is reported, never created")
    try rejects("restore refuses a missing project") { _ = try IconService.restore(template: template, fields: fields, onto: out.appendingPathComponent("nowhere")) }

    func layoutTemplate(_ folder: String, named name: String, nestedLevels: Int = 0) throws -> URL {
        let root = base.appendingPathComponent(name, isDirectory: true)
        let documents = root.appendingPathComponent("01 Documents", isDirectory: true)
        let anchor = root.appendingPathComponent("02 Project Files/\(folder)", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: true)
        try Data().write(to: documents.appendingPathComponent("Icon\r"))
        try Data().write(to: anchor.appendingPathComponent("Icon\r"))
        var finder = Data(count: 32); finder[8] = 0x04
        _ = finder.withUnsafeBytes { setxattr(documents.path, "com.apple.FinderInfo", $0.baseAddress, 32, 0, XATTR_NOFOLLOW) }
        _ = finder.withUnsafeBytes { setxattr(anchor.path, "com.apple.FinderInfo", $0.baseAddress, 32, 0, XATTR_NOFOLLOW) }
        var nested = anchor
        if nestedLevels > 0 {
            for level in 1...nestedLevels {
                nested = nested.appendingPathComponent("01 Child \(level)", isDirectory: true)
                try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            }
        }
        return root
    }
    func layoutProject(_ folder: String, named name: String) throws -> URL {
        let root = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("01 Documents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("02 Project Files/\(folder)"), withIntermediateDirectories: true)
        return root
    }
    for (templateFolder, projectFolder, label) in [
        ("01 Video", "01 Premiere Pro", "old template on new project"),
        ("01 Premiere Pro", "01 Video", "new template on old project")
    ] {
        let mismatchTemplate = try layoutTemplate(templateFolder, named: "Mismatch Template \(label)", nestedLevels: 8)
        let mismatchProject = try layoutProject(projectFolder, named: "Mismatch Project \(label)")
        var message = ""
        do {
            _ = try IconService.restore(template: mismatchTemplate, fields: fields, onto: mismatchProject)
        } catch { message = error.localizedDescription }
        try check(message.contains("No icons were changed") && message.contains(templateFolder) && message.contains(mismatchProject.appendingPathComponent("02 Project Files/\(projectFolder)").path), "restore preflight reports exact \(label) evidence")
        try rejects("restore preflight rejects \(label) before the first write") {
            try IconService.preflight(template: mismatchTemplate, fields: fields, onto: mismatchProject)
        }
        try check(!FileManager.default.fileExists(atPath: mismatchProject.appendingPathComponent("01 Documents/Icon\r").path), "\(label) leaves earlier icon targets untouched")
    }
    let manyTemplate = base.appendingPathComponent("Many planned", isDirectory: true)
    let manyProject = base.appendingPathComponent("Many existing", isDirectory: true)
    try FileManager.default.createDirectory(at: manyTemplate, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: manyProject, withIntermediateDirectories: true)
    for number in 1...6 {
        let prefix = String(format: "%02d", number)
        let expected = manyTemplate.appendingPathComponent("\(prefix) planned", isDirectory: true)
        let actual = manyProject.appendingPathComponent("\(prefix) actual", isDirectory: true)
        try FileManager.default.createDirectory(at: expected.appendingPathComponent("01 Child/02 Grandchild"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
    }
    var summary = ""
    do { try IconService.preflight(template: manyTemplate, fields: fields, onto: manyProject) }
    catch { summary = error.localizedDescription }
    try check(summary.contains("Showing 4 of 6 conflicts") && summary.contains("+2 more conflicts"), "restore conflict summary caps repeated paths and counts the rest")
    try check(summary.contains(manyProject.appendingPathComponent("01 actual").path) && summary.contains(manyProject.appendingPathComponent("04 actual").path), "restore conflict summary preserves the shown exact paths")
    let ambiguousTemplate = try layoutTemplate("01 Video", named: "Ambiguous Template")
    let ambiguousProject = try layoutProject("01 Video", named: "Ambiguous Project")
    try FileManager.default.createDirectory(at: ambiguousProject.appendingPathComponent("02 Project Files/01 Premiere Pro"), withIntermediateDirectories: true)
    try rejects("restore refuses when both Premiere anchors exist") {
        _ = try IconService.restore(template: ambiguousTemplate, fields: fields, onto: ambiguousProject)
    }
    try check(!FileManager.default.fileExists(atPath: ambiguousProject.appendingPathComponent("01 Documents/Icon\r").path), "ambiguous Premiere anchors leave icons untouched")
    let symlinkTemplate = try layoutTemplate("01 Video", named: "Symlink Template")
    let symlinkProject = try layoutProject("01 Video", named: "Symlink Project")
    let outside = base.appendingPathComponent("Outside project", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let outsideIcon = outside.appendingPathComponent("Icon\r")
    let originalIcon = Data("external icon must survive".utf8)
    try originalIcon.write(to: outsideIcon)
    let linkedDocuments = symlinkProject.appendingPathComponent("01 Documents", isDirectory: true)
    try FileManager.default.removeItem(at: linkedDocuments)
    try FileManager.default.createSymbolicLink(at: linkedDocuments, withDestinationURL: outside)
    try rejects("restore rejects an expected folder occupied by a symlink") {
        _ = try IconService.restore(template: symlinkTemplate, fields: fields, onto: symlinkProject)
    }
    try check(try Data(contentsOf: outsideIcon) == originalIcon, "symlink preflight preserves the external icon file")
    let legacyTemplate = try layoutTemplate("01 Cafe\u{301}", named: "Unicode Template")
    let unicodeProject = try layoutProject("01 Café", named: "Unicode Project")
    let unicodeRestore = try IconService.restore(template: legacyTemplate, fields: fields, onto: unicodeProject)
    try check(unicodeRestore.failed.isEmpty && unicodeRestore.restored.count == 2, "restore matches canonically equivalent numbered folders")
    // Stripping a copy made with icons leaves exactly a plain copy; restoring brings it back.
    let plainAgain = try CreationEngine.create(plan: plain, destination: out, name: "000 — Short — Plain again", icon: nil, finderMetadata: false)
    let stripped = try IconService.strip(project: withIcons)
    try check(stripped.iconFilesRemoved == ["01 Documents/Icon"] && stripped.foldersCleared == ["01 Documents"] && stripped.failed.isEmpty, "strip reports the icon file and folder it cleared")
    try check(inside(try digestTree(withIcons)) == inside(try digestTree(plainAgain)), "a stripped project is identical to one created with plain folders")
    try check(try IconService.strip(project: withIcons).iconFilesRemoved.isEmpty, "stripping twice changes nothing")
    let roundTrip = try IconService.restore(template: template, fields: fields, onto: withIcons)
    try check(roundTrip.restored == ["01 Documents"] && inside(try digestTree(withIcons)) == iconTree, "strip then restore returns the original icons")
    try rejects("strip refuses a missing project") { _ = try IconService.strip(project: out.appendingPathComponent("nowhere")) }
}


/// A later folder such as `06 Media Revised` takes the icon of the template folder whose name it extends (`03 Media`).
func inheritedIconChecks(base: URL) throws {
    let fm = FileManager.default
    let template = base.appendingPathComponent("Inherit/Template"), project = base.appendingPathComponent("Inherit/Project")
    var flagged = Data(count: 32); flagged[8] = 0x04
    func icon(_ folder: URL) throws {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("icon \(folder.lastPathComponent)".utf8).write(to: folder.appendingPathComponent("Icon\r"))
        _ = flagged.withUnsafeBytes { setxattr(folder.path, "com.apple.FinderInfo", $0.baseAddress, 32, 0, XATTR_NOFOLLOW) }
    }
    try icon(template.appendingPathComponent("03 Media"))
    try icon(template.appendingPathComponent("02 Project Files/01 Premiere Pro"))
    try fm.createDirectory(at: template.appendingPathComponent("01 Documents"), withIntermediateDirectories: true)
    for folder in ["03 Media", "06 Media Revised", "07 Unrelated", "08 Mediabox", "Media Extras", "01 Documents", "02 Project Files/01 Premiere Pro", "02 Project Files/05 Premiere Pro Archive"] {
        try fm.createDirectory(at: project.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    try Data("clip".utf8).write(to: project.appendingPathComponent("06 Media Revised/take.mov"))
    let fields = ProjectFields(number: "000", format: "Short", title: "Inherit")
    func hasIcon(_ path: String) -> Bool {
        let folder = project.appendingPathComponent(path)
        return fm.fileExists(atPath: folder.appendingPathComponent("Icon\r").path) && ((try? IconService.attribute("com.apple.FinderInfo", at: folder))??[8] ?? 0) & 0x04 != 0
    }
    let filesBefore = try digestTree(project).filter { !$0.key.contains("::") }
    let preview = try IconService.restorePreview(template: template, fields: fields, onto: project)
    try check(preview.restored == ["02 Project Files/01 Premiere Pro", "03 Media"] && preview.inherited == ["02 Project Files/05 Premiere Pro Archive", "06 Media Revised"] && preview.unmatched.isEmpty,
              "icon restore preview lists exact and inherited folders")
    try check(!hasIcon("03 Media") && !hasIcon("06 Media Revised"), "icon restore preview writes nothing")
    let report = try IconService.restore(template: template, fields: fields, onto: project)
    try check(report.restored == preview.restored && report.inherited == preview.inherited && report.failed.isEmpty, "restore reports inherited folders apart from exact ones")
    try check(hasIcon("03 Media") && hasIcon("06 Media Revised") && hasIcon("02 Project Files/05 Premiere Pro Archive"), "a folder extending a template folder's name inherits its icon, at the root and nested")
    try check(!hasIcon("07 Unrelated") && !hasIcon("08 Mediabox") && !hasIcon("Media Extras"), "unrelated folders and folders that merely start with the same letters get no icon")
    try check(try Data(contentsOf: project.appendingPathComponent("06 Media Revised/take.mov")) == Data("clip".utf8) && (try children(project)).sorted() == ["01 Documents", "02 Project Files", "03 Media", "06 Media Revised", "07 Unrelated", "08 Mediabox", "Media Extras"],
              "inheriting an icon touches no file and creates no folder")
    try check(report.summary.contains("2 more folders inherited"), "restore summary mentions inherited folders")
    let again = try IconService.restore(template: template, fields: fields, onto: project)
    // A folder that already carries an icon (set by hand, or by an earlier restore) is still listed and re-applied, like an exact match.
    try check(again.inherited == preview.inherited && again.restored == preview.restored && again.failed.isEmpty && hasIcon("06 Media Revised"),
              "restoring twice re-applies an inherited icon a folder already has")
    // Re-applying keeps the folder's other Finder info: give 06 Media Revised a colour label (byte 9, bits 1-3) and restore again.
    let revised = project.appendingPathComponent("06 Media Revised")
    var labelled = try IconService.attribute("com.apple.FinderInfo", at: revised) ?? Data(count: 32); labelled[9] |= 0x0C
    _ = labelled.withUnsafeBytes { setxattr(revised.path, "com.apple.FinderInfo", $0.baseAddress, labelled.count, 0, XATTR_NOFOLLOW) }
    _ = try IconService.restore(template: template, fields: fields, onto: project)
    try check(((try IconService.attribute("com.apple.FinderInfo", at: revised))?[9] ?? 0) & 0x0C == 0x0C && hasIcon("06 Media Revised"),
              "re-applying an inherited icon keeps the folder's colour label")
    let againPreview = try IconService.restorePreview(template: template, fields: fields, onto: project)
    try check(againPreview.inherited.contains("06 Media Revised"), "the dry run lists an already-iconed 06 Media Revised under inherited")
    let dry = try IconService.strip(project: project, dryRun: true)
    try check(dry.iconFilesRemoved.count == 4 && hasIcon("06 Media Revised"), "strip dry run lists the icon files and removes none")
    let stripped = try IconService.strip(project: project)
    try check(stripped.iconFilesRemoved.count == 4 && !hasIcon("06 Media Revised") && !hasIcon("03 Media"), "strip clears inherited icons too")
    let restored = try IconService.restore(template: template, fields: fields, onto: project)
    try check(restored.inherited == preview.inherited && hasIcon("06 Media Revised"), "strip then restore brings the inherited icons back")
    try check(try digestTree(project).filter { !$0.key.contains("::") && !$0.key.hasSuffix("Icon\r") } == filesBefore.filter { !$0.key.hasSuffix("Icon\r") }, "regular files are identical after all of it")
    // A stop returns what was already done instead of throwing it away.
    let stop = Cancellation(); stop.cancel()
    let halted = try IconService.strip(project: project, cancellation: stop)
    try check(halted.cancelled && halted.iconFilesRemoved.isEmpty && hasIcon("06 Media Revised") && halted.summary.hasPrefix("Cancelled part way."), "a cancelled strip reports itself and leaves the icons it had not reached")
    try rejects("a restore stopped before it writes anything throws and changes nothing") { _ = try IconService.restore(template: template, fields: fields, onto: project, cancellation: stop) }
    // Two equally long template names that a folder extends: skipped and reported, never guessed.
    try icon(template.appendingPathComponent("04 Media"))
    try fm.createDirectory(at: project.appendingPathComponent("04 Media"), withIntermediateDirectories: true)
    try fm.createDirectory(at: project.appendingPathComponent("09 Media Final"), withIntermediateDirectories: true)
    let tie = try IconService.restorePreview(template: template, fields: fields, onto: project)
    try check(tie.ambiguous == ["06 Media Revised", "09 Media Final"] && !tie.inherited.contains("09 Media Final") && !tie.inherited.contains("06 Media Revised") && tie.restored.contains("04 Media"),
              "a folder extending two equally long template names is reported as ambiguous and skipped")
    // The numbered-prefix conflict rule is unchanged: a different spelling under the template's own prefix still blocks restore.
    try fm.removeItem(at: project.appendingPathComponent("04 Media"))
    try fm.createDirectory(at: project.appendingPathComponent("04 Media Alt"), withIntermediateDirectories: true)
    try rejects("a folder sharing a template folder's number still fails the layout check") { _ = try IconService.restore(template: template, fields: fields, onto: project) }
}


/// Remove Folder Icons takes the icon and nothing else: colour labels, tags and comments stay.
func stripKeepsMetadataChecks(base: URL) throws {
    let fm = FileManager.default
    let template = base.appendingPathComponent("StripKeeps/Template"), project = base.appendingPathComponent("StripKeeps/Project")
    var flagged = Data(count: 32); flagged[8] = 0x04
    let docs = template.appendingPathComponent("01 Documents")
    try fm.createDirectory(at: docs, withIntermediateDirectories: true)
    try Data("icon".utf8).write(to: docs.appendingPathComponent("Icon\r"))
    _ = flagged.withUnsafeBytes { setxattr(docs.path, "com.apple.FinderInfo", $0.baseAddress, 32, 0, XATTR_NOFOLLOW) }
    let fields = ProjectFields(number: "000", format: "Short", title: "Keeps")
    let created = try CreationEngine.create(plan: TemplateReader.scan(template, fields: fields), destination: { try fm.createDirectory(at: project, withIntermediateDirectories: true); return project }(), name: "000 — Short — Keeps")
    let folder = created.appendingPathComponent("01 Documents"), plainFolder = created.appendingPathComponent("02 Plain")
    try fm.createDirectory(at: plainFolder, withIntermediateDirectories: true)
    var labelled = Data(count: 32); labelled[8] = 0x04; labelled[9] = 0x0C
    _ = labelled.withUnsafeBytes { setxattr(folder.path, "com.apple.FinderInfo", $0.baseAddress, 32, 0, XATTR_NOFOLLOW) }
    try FinderTags.write([.init(name: "Client", colour: .red)], to: folder)
    let comment = Data("remember this".utf8)
    _ = comment.withUnsafeBytes { setxattr(folder.path, "com.apple.metadata:kMDItemFinderComment", $0.baseAddress, comment.count, 0, XATTR_NOFOLLOW) }
    var onlyLabel = Data(count: 32); onlyLabel[9] = 0x0C
    _ = onlyLabel.withUnsafeBytes { setxattr(plainFolder.path, "com.apple.FinderInfo", $0.baseAddress, 32, 0, XATTR_NOFOLLOW) }
    let dry = try IconService.strip(project: created, dryRun: true)
    try check(dry.foldersCleared == ["01 Documents"] && (try IconService.attribute("com.apple.FinderInfo", at: folder))?[8] == 0x04, "strip dry run names the folder with an icon flag and changes nothing")
    let report = try IconService.strip(project: created)
    let after = try IconService.attribute("com.apple.FinderInfo", at: folder)
    try check(report.foldersCleared == ["01 Documents"] && report.failed.isEmpty && !fm.fileExists(atPath: folder.appendingPathComponent("Icon\r").path), "strip removes the icon file and clears the folder flag")
    try check(after?[8] == 0 && after?[9] == 0x0C, "strip keeps the colour label bits of FinderInfo")
    try check(try FinderTags.read(folder) == [.init(name: "Client", colour: .red)], "strip keeps Finder tags")
    try check(try IconService.attribute("com.apple.metadata:kMDItemFinderComment", at: folder) == comment, "strip keeps Finder comments")
    try check(try IconService.attribute("com.apple.FinderInfo", at: plainFolder)?[9] == 0x0C, "strip leaves a folder that only has a colour label alone")
    let zeroed = created.appendingPathComponent("03 Only icon")
    try fm.createDirectory(at: zeroed, withIntermediateDirectories: true)
    _ = flagged.withUnsafeBytes { setxattr(zeroed.path, "com.apple.FinderInfo", $0.baseAddress, 32, 0, XATTR_NOFOLLOW) }
    _ = try IconService.strip(project: created)
    try check(try IconService.attribute("com.apple.FinderInfo", at: zeroed) == nil, "FinderInfo that is all zeros once the flag is cleared is removed")
    let restored = try IconService.restore(template: template, fields: fields, onto: created)
    try check(restored.restored == ["01 Documents"] && restored.failed.isEmpty && fm.fileExists(atPath: folder.appendingPathComponent("Icon\r").path) && (try IconService.attribute("com.apple.FinderInfo", at: folder))?[8] == 0x04, "restore still brings the icon back")
    try check(try FinderTags.read(folder) == [.init(name: "Client", colour: .red)], "restore keeps the Finder tags too")
}


/// Arrow keys in the icon view: left and right inside a row, up and down by the real number of columns.
func browserGridChecks() throws {
    try check(BrowserGrid.columns(width: 600, minimum: 96, spacing: 6) == 5 && BrowserGrid.columns(width: 96, minimum: 96, spacing: 6) == 1 && BrowserGrid.columns(width: 30, minimum: 96, spacing: 6) == 1 && BrowserGrid.columns(width: 0, minimum: 96, spacing: 6) == 1, "icon grid column count comes from the width")
    try check(BrowserGrid.columns(width: 1000, minimum: 96, spacing: 6) == 9, "a wide window shows more columns, not four")
    // 10 items in rows of 4: 0-3, 4-7, 8-9.
    try check(BrowserGrid.next(from: 5, count: 10, columns: 4, .right) == 6 && BrowserGrid.next(from: 7, count: 10, columns: 4, .right) == 7, "right moves within a row and stops at its end")
    try check(BrowserGrid.next(from: 5, count: 10, columns: 4, .left) == 4 && BrowserGrid.next(from: 4, count: 10, columns: 4, .left) == 4, "left moves within a row and stops at its start")
    try check(BrowserGrid.next(from: 9, count: 10, columns: 4, .right) == 9, "right stops at the last item")
    try check(BrowserGrid.next(from: 1, count: 10, columns: 4, .down) == 5 && BrowserGrid.next(from: 5, count: 10, columns: 4, .up) == 1, "down and up move by the column count")
    try check(BrowserGrid.next(from: 3, count: 10, columns: 4, .up) == 3 && BrowserGrid.next(from: 9, count: 10, columns: 4, .down) == 9, "up stops in the first row and down in the last")
    try check(BrowserGrid.next(from: 6, count: 10, columns: 4, .down) == 9, "down from a row with nothing below goes to the last item")
    try check(BrowserGrid.next(from: nil, count: 10, columns: 4, .down) == 0 && BrowserGrid.next(from: nil, count: 10, columns: 4, .up) == 9 && BrowserGrid.next(from: nil, count: 0, columns: 4, .down) == nil, "no selection starts at an end; an empty folder selects nothing")
    try check(BrowserGrid.next(from: 2, count: 5, columns: 1, .down) == 3 && BrowserGrid.next(from: 2, count: 5, columns: 1, .right) == 2, "a single column moves by one with up and down only")
}
