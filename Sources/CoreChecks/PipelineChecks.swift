import Foundation
import TemplateCore

func pipelineChecks(base: URL) throws {
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
    var twin = record; twin.id = UUID(); twin.path = "/Volumes/Naruto Uzumaki/01 Video Project Archive/01 Recordings/01 Longs/" + record.name
    try check(Numbering.siblings(of: record, in: [record, twin]).count == 1, "same number and format on another drive is a sibling")

    let external = ProjectLocation(path: "/Volumes/Naruto Uzumaki/01 Video Project Archive/01 Recordings/01 Longs/230 — Long — X", volumeName: "Naruto Uzumaki")
    try check(external.kind == .external && external.label == "Naruto Uzumaki" && external.defaultColour == "orange" && external.mountPath == "/Volumes/Naruto Uzumaki", "external drive classified with its default colour")
    let cloud = ProjectLocation(path: "/Users/j/Library/CloudStorage/GoogleDrive-jnb@example.com/Shared drives/Shared Content Creation/Short — X")
    try check(cloud.kind == .cloud && cloud.label == "Google Drive" && cloud.account == "jnb@example.com" && cloud.defaultColour == "green", "cloud folder classified by provider and account")
    let local = ProjectLocation(path: "/Users/j/Content Creation/02 Live Projects/x", volumeName: "Macintosh HD")
    try check(local.kind == .local && local.label == "Macintosh HD" && local.defaultColour == "gray" && local.isMounted, "boot drive classified as local")
    try check(!ProjectLocation(path: "/Volumes/ContentTemplate-Not-Mounted/x").isMounted, "unmounted volume reports not mounted")

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
    try check(back.schema == 4 && back.projects[1].stage == "Editing" && back.projects[1].editor == "Freelancer" && back.projects[0].isPlanned && back.fieldList.first?.name == "Sponsor" && back.stageList == ["Idea", "Scripting", "Done"], "pipeline fields, custom fields and stages persist")
    try check(Library().stageList == Library.defaultStages, "default stages apply when none are saved")
}
