import SwiftUI
import AppKit
import TemplateCore

/// The three places in the app. New Project is a sheet over any of them, opened with Command-N.
enum Page: String, CaseIterable, Identifiable {
    case projects = "Projects", pipeline = "Pipeline", templates = "Templates"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .pipeline: "rectangle.3.group"
        case .projects: "externaldrive"
        case .templates: "square.stack.3d.up"
        }
    }
    var hint: String {
        switch self {
        case .pipeline: "Move recordings and streams through their stages"
        case .projects: "Browse every project, wherever it lives"
        case .templates: "Template sets and the folders each format copies"
        }
    }
}

/// What the New Project screen creates from: a set resolved by format, or a legacy template used directly.
enum TemplateSelection: Hashable {
    case set(UUID), legacy(UUID)
    var stored: String { switch self { case .set(let id): "set:\(id.uuidString)"; case .legacy(let id): "legacy:\(id.uuidString)" } }
    init?(stored: String) {
        let parts = stored.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] { case "set": self = .set(id); case "legacy": self = .legacy(id); default: return nil }
    }
}

enum VariantState {
    case none
    case missing(setName: String)
    case ready(TemplateRecord, sharedWith: [String])
    case legacy(TemplateRecord)
    var record: TemplateRecord? { switch self { case .ready(let r, _), .legacy(let r): r; default: nil } }
}

/// Which browser receives the View menu shortcuts. Sheets push over pages.
enum BrowserSurface: String, CaseIterable { case projectFiles, managedTemplate, creationPreview }

/// What happened to a Finder tag write, returned to control callers; the GUI ignores it.
enum TagOutcome: String { case applied, skipped, failed }

struct PendingAssignment: Equatable { let setID: UUID; let format: String }
struct IconRestoreCandidate: Identifiable {
    let id: UUID
    let name: String
    let available: Bool
    let reason: String?
}
struct NewSetPrompt: Identifiable { let id = UUID(); let mappingTemplateID: UUID?; var name: String }
struct CachedStructure { let plan: CopyPlan; let rootModified: Date?; let renamingPaths: Set<String>? }

/// What Find Moved Folders concluded about one project whose folder was missing.
struct RelinkOutcome: Identifiable {
    enum Kind: Hashable { case relinked(URL), candidates([URL]), notFound, stillThere }
    let id: UUID
    let name: String
    let previousPath: String
    var kind: Kind
}
struct RelinkReport: Identifiable {
    let id = UUID()
    let checked: Int
    var outcomes: [RelinkOutcome]
    /// Turns a row green once the project has been linked, by the pass itself or by hand while the report is open.
    mutating func markLinked(_ id: UUID, at url: URL) {
        if let index = outcomes.firstIndex(where: { $0.id == id }) { outcomes[index].kind = .relinked(url) }
    }
    var relinked: [RelinkOutcome] { outcomes.filter { if case .relinked = $0.kind { return true }; return false } }
    var unresolved: [RelinkOutcome] { outcomes.filter { switch $0.kind { case .candidates, .notFound: true; default: false } } }
}

enum AppInfo {
    static var name: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "CreatorOS" }
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development" }
    static var channel: String { Bundle.main.object(forInfoDictionaryKey: "CreatorOSChannel") as? String ?? "" }
    static var channelName: String {
        switch channel { case "α": "Alpha"; case "β": "Beta"; case "RC": "Release candidate"; default: channel }
    }
    static var label: String { [name, version, channel].filter { !$0.isEmpty }.joined(separator: " ") }
}

/// Keep the ordinary Greek characters, but give their release marks a distinct handwritten tail.
struct ReleaseVersionLabel: View {
    var includeName = false
    var size: CGFloat = 13

    var body: some View {
        let prefix = "\(includeName ? AppInfo.name + " " : "")\(AppInfo.version)"
        let spacer = AppInfo.channel.isEmpty ? "" : " "
        let greek = AppInfo.channel == "α" || AppInfo.channel == "β"
        let mark = Text(AppInfo.channel).font(greek ? .custom("TimesNewRomanPS-ItalicMT", fixedSize: size + 3) : nil)
        Text("\(prefix)\(spacer)\(mark)")
            .accessibilityLabel([prefix, AppInfo.channelName].filter { !$0.isEmpty }.joined(separator: " "))
    }
}

/// Named colours the user can pick for a location badge.
enum BadgeColour: String, CaseIterable, Identifiable {
    case gray, orange, green, blue, purple, teal, pink, indigo, red, yellow, brown, mint
    var id: String { rawValue }
    var colour: Color {
        switch self {
        case .gray: .gray; case .orange: .orange; case .green: .green; case .blue: .blue; case .purple: .purple; case .teal: .teal
        case .pink: .pink; case .indigo: .indigo; case .red: .red; case .yellow: .yellow; case .brown: .brown; case .mint: .mint
        }
    }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

