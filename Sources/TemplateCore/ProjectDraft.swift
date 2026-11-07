import Foundation

/// What someone has typed into New Project, plus the rules between those values. The app and the command line share it,
/// so a command can set the form aside and put it back as one value. Not saved anywhere: the form starts fresh each launch.
public struct ProjectDraft: Equatable, Sendable {
    public var number = ""
    /// The number follows the next free one until someone types a different one.
    public var numberIsAutomatic = true
    public var campaign = ""
    public var title = ""
    public var extraValues: [UUID: String] = [:]
    /// Choosing a LucidLink folder turns Plain folders on, because LucidLink refuses folder icons; any other folder turns it off.
    public var destination = "" { didSet { plainFolders = Self.needsPlainFolders(destination) } }
    /// Copy without folder icons.
    public var plainFolders = false
    /// The planned idea this project is being started from.
    public var startingFrom: UUID?

    public init() {}

    public static func needsPlainFolders(_ destination: String) -> Bool { ProjectLocation(path: destination).label == "LucidLink" }

    public func fields(format: String, fieldList: [CustomField]) -> ProjectFields {
        ProjectFields(number: number, format: format, campaign: campaign, title: title,
                      extras: fieldList.map { ExtraValue(name: $0.name, value: extraValues[$0.id] ?? "", includeInName: $0.includeInName) })
    }
    /// The library changed: an automatic number moves on to the next free one.
    public mutating func followSuggestion(_ suggested: String) { if numberIsAutomatic { number = suggested } }
    /// Typing: an emptied number goes back to the suggestion, and typing the suggestion makes it automatic again.
    public mutating func numberEdited(suggested: String) {
        if number.isEmpty { number = suggested }
        numberIsAutomatic = number == suggested
    }
    /// Each format has its own sequence, so a typed number applies to one format only.
    public mutating func restartNumbering(suggested: String) { numberIsAutomatic = true; number = suggested }
    /// Clears what was typed for the next project. Where it goes, and Plain folders, stay.
    public mutating func clearForNext(suggested: String) {
        title = ""; campaign = ""; extraValues = [:]; startingFrom = nil
        restartNumbering(suggested: suggested)
    }
}
