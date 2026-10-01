import Foundation

public struct AppFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The outcome of naming with whatever the user has typed so far.
public struct PreviewName: Sendable {
    public let name: String
    public let missing: [String]
    public let issues: [String]
    public let tokens: [String: String]
}

/// A value for a user-defined naming parameter. Included in the folder name only when the field says so.
public struct ExtraValue: Sendable, Hashable {
    public let name: String
    public let value: String
    public let includeInName: Bool
    public init(name: String, value: String, includeInName: Bool) { self.name = name; self.value = value; self.includeInName = includeInName }
}

public struct ProjectFields: Sendable {
    public static let numberPlaceholder = "[Project Number]"
    public static let titlePlaceholder = "[Project Name]"
    public static let formatPlaceholder = "[Content Format]"
    public var number: String
    public var format: String
    public var campaign: String
    public var title: String
    public var extras: [ExtraValue]
    public init(number: String, format: String, campaign: String = "", title: String, extras: [ExtraValue] = []) {
        self.number = number; self.format = format; self.campaign = campaign; self.title = title; self.extras = extras
    }
    /// Segments between the format and the title: campaign first, then named extras, blanks dropped.
    var middle: [String] { ([campaign] + extras.filter { $0.includeInName }.map(\.value)).filter { !$0.isEmpty } }
    public func finalName() throws -> String {
        for (label, value) in [("Project number", number), ("Content format", format), ("Project name", title)] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppFailure("Enter a \(label.lowercased()).")
            }
            try Naming.validate(value)
        }
        for segment in middle { try Naming.validate(segment) }
        for extra in extras where !extra.value.isEmpty { try Naming.validate(extra.value) }
        let name = ([number, format] + middle + [title]).joined(separator: " — ")
        try Naming.validate(name)
        return name
    }
    public var tokens: [String: String] {
        var map = ["Project Number": number, "Content Format": format, "Conent Form": format,
                   "Campaign": campaign, "Project Name": title]
        for extra in extras { map[extra.name] = extra.value }
        return map
    }
    /// Never throws. Missing required values become visible placeholders; invalid values become issues.
    public func previewName() -> PreviewName {
        var missing: [String] = []; var issues: [String] = []
        func part(_ label: String, _ value: String, placeholder: String) -> String {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append(label); return placeholder }
            do { try Naming.validate(value) } catch { issues.append("\(label): \(error.localizedDescription)") }
            return value
        }
        let number = part("Project Number", self.number, placeholder: Self.numberPlaceholder)
        let format = part("Content Format", self.format, placeholder: Self.formatPlaceholder)
        let title = part("Project Name", self.title, placeholder: Self.titlePlaceholder)
        if !campaign.isEmpty { do { try Naming.validate(campaign) } catch { issues.append("Campaign: \(error.localizedDescription)") } }
        for extra in extras where !extra.value.isEmpty { do { try Naming.validate(extra.value) } catch { issues.append("\(extra.name): \(error.localizedDescription)") } }
        let name = ([number, format] + middle + [title]).joined(separator: " — ")
        var tokens = ["Project Number": number, "Content Format": format, "Conent Form": format, "Campaign": campaign, "Project Name": title]
        for extra in extras { tokens[extra.name] = extra.value }
        return PreviewName(name: name, missing: missing, issues: issues, tokens: tokens)
    }
}

public enum Naming {
    private static let forbidden = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
    private static let reserved = Set(["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"] +
        (1...9).flatMap { ["COM\($0)", "LPT\($0)"] } + ["COM¹", "COM²", "COM³", "LPT¹", "LPT²", "LPT³"])
    private static func reservedName(_ name: String) -> Bool {
        let stem = name.split(separator: ".", omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces).uppercased()
        return reserved.contains(stem)
    }
    /// One component validator for generated names and audits of existing names. Unicode punctuation is valid.
    public static func problems(_ name: String) -> [String] {
        var issues: [String] = []
        if name.isEmpty || name == "." || name == ".." { issues.append("empty or relative path component") }
        if name.rangeOfCharacter(from: forbidden) != nil { issues.append("path separator, control character or Windows-invalid <>:\"/\\|?*") }
        if name.hasSuffix(" ") || name.hasSuffix(".") { issues.append("trailing space or dot") }
        if name.utf8.count > 255 { issues.append("longer than 255 UTF-8 bytes") }
        if !name.isEmpty && reservedName(name) { issues.append("reserved Windows device name") }
        return issues
    }
    public static func validate(_ name: String) throws {
        let issues = problems(name)
        guard issues.isEmpty else { throw AppFailure("Invalid name ‘\(name)’: \(issues.joined(separator: "; ")).") }
    }
    public static func corrected(_ name: String) -> String {
        var clean = String(name.unicodeScalars.map { forbidden.contains($0) ? "-" : Character($0) })
        while clean.hasSuffix(" ") || clean.hasSuffix(".") { clean.removeLast() }
        if clean.isEmpty { clean = "_" }
        if reservedName(clean) { clean = "_" + clean }
        while clean.utf8.count > 255 { clean.removeLast() }
        while clean.hasSuffix(" ") || clean.hasSuffix(".") { clean.removeLast() }
        return clean.isEmpty ? "_" : clean
    }

    public static func key(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// The one substitution rule shared by the preview and the copy plan.
    /// Bracket tokens are replaced in a single pass over the source name; user values are never re-expanded.
    /// A leading `Template` (any case, whole name or followed by `.` or a space) takes the full name.
    public static func substitute(_ name: String, tokens: [String: String], final: String) throws -> String {
        let regex = try NSRegularExpression(pattern: #"\[([^\]]+)\]"#)
        let ns = name as NSString
        let matches = regex.matches(in: name, range: NSRange(location: 0, length: ns.length))
        var result = name
        for match in matches.reversed() {
            let token = ns.substring(with: match.range(at: 1))
            guard let value = token.lowercased() == "template" ? final : tokens[token] else {
                throw AppFailure("Unknown token [\(token)] in ‘\(name)’. Supported tokens are [template] and the four named fields.")
            }
            if let range = Range(match.range, in: result) { result.replaceSubrange(range, with: value) }
        }
        let lower = name.lowercased()
        if lower == "template" || lower.hasPrefix("template.") || lower.hasPrefix("template ") {
            result = final + String(result.dropFirst("Template".count))
        }
        return result
    }

    public static func render(_ name: String, fields: ProjectFields) throws -> String {
        let final = try fields.finalName()
        let result = try substitute(name, tokens: fields.tokens, final: final)
        try validate(result)
        return result
    }
}
