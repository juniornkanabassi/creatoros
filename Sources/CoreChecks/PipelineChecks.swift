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
    let campaignRecord = try ProjectRecord(url: base.appendingPathComponent("Pipeline/01 Longs/230 — Long — Lille vs PSG | Post-Game Reaction"), format: "Long")
    _ = campaignRecord
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
    // Stripping a copy made with icons leaves exactly a plain copy; restoring brings it back.
    let plainAgain = try CreationEngine.create(plan: plain, destination: out, name: "000 — Short — Plain again", icon: nil, finderMetadata: false)
    let stripped = try IconService.strip(project: withIcons)
    try check(stripped.iconFilesRemoved == ["01 Documents/Icon"] && stripped.foldersCleared == ["01 Documents"] && stripped.failed.isEmpty, "strip reports the icon file and folder it cleared")
    try check(inside(try digestTree(withIcons)) == inside(try digestTree(plainAgain)), "a stripped project is identical to one created with plain folders")
    try check(try IconService.strip(project: withIcons).iconFilesRemoved.isEmpty, "stripping twice changes nothing")
    let roundTrip = try IconService.restore(template: template, fields: fields, onto: withIcons)
    try check(roundTrip.restored == ["01 Documents"] && inside(try digestTree(withIcons)) == iconTree, "strip then restore returns the original icons")
    try rejects("strip refuses a missing project") { _ = try IconService.strip(project: out.appendingPathComponent("nowhere")) }
    _ = iconTree
}
