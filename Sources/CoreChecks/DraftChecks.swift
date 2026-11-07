import Foundation
import TemplateCore

func draftChecks() throws {
    var draft = ProjectDraft()
    draft.destination = "/Volumes/Studio/Studio/Projects"
    try check(draft.plainFolders, "a LucidLink destination turns Plain folders on")
    draft.plainFolders = false
    draft.destination = "/Volumes/Studio/Studio/Projects"
    try check(draft.plainFolders, "choosing the LucidLink destination again turns Plain folders back on")
    draft.destination = "/Volumes/Archive/Projects"
    try check(!draft.plainFolders, "an ordinary drive turns Plain folders off")

    draft.number = "007"; draft.numberEdited(suggested: "003")
    try check(draft.number == "007" && !draft.numberIsAutomatic, "a typed number stops following the suggestion")
    draft.followSuggestion("004")
    try check(draft.number == "007", "a typed number survives a library change")
    draft.number = ""; draft.numberEdited(suggested: "004")
    try check(draft.number == "004" && draft.numberIsAutomatic, "an emptied number goes back to the suggestion")
    draft.followSuggestion("005")
    try check(draft.number == "005", "an automatic number follows the next free one")

    let field = CustomField(name: "Sponsor", includeInName: true)
    draft.title = "Title"; draft.campaign = "Spring"; draft.extraValues = [field.id: "Acme"]; draft.startingFrom = UUID()
    let fields = draft.fields(format: "Short", fieldList: [field, CustomField(name: "Unused")])
    try check(fields.number == "005" && fields.title == "Title" && fields.campaign == "Spring" && fields.format == "Short"
              && fields.extras.map(\.value) == ["Acme", ""], "draft fields feed the name in field order")

    let kept = draft
    draft.title = "Changed"; draft.destination = "/Volumes/Studio/Studio/Projects"
    draft = kept
    try check(draft == kept && !draft.plainFolders && draft.title == "Title", "a set-aside draft comes back whole, Plain folders included")

    draft.number = "009"; draft.numberIsAutomatic = false; draft.plainFolders = true
    draft.clearForNext(suggested: "006")
    try check(draft.title.isEmpty && draft.campaign.isEmpty && draft.extraValues.isEmpty && draft.startingFrom == nil
              && draft.number == "006" && draft.numberIsAutomatic, "Next Project clears what was typed and restarts numbering")
    try check(draft.destination == "/Volumes/Archive/Projects" && draft.plainFolders, "Next Project keeps the destination and Plain folders")
}
