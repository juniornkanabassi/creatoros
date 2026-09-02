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
    public var isComplete: Bool { missing.isEmpty && issues.isEmpty }
}

public struct ProjectFields: Sendable {
    public static let numberPlaceholder = "[Project Number]"
    public static let titlePlaceholder = "[Project Name]"
    public static let formatPlaceholder = "[Content Format]"
    public var number: String
    public var format: String
    public var campaign: String
    public var title: String
    public init(number: String, format: String, campaign: String = "", title: String) {
        self.number = number; self.format = format; self.campaign = campaign; self.title = title
    }
    public func finalName() throws -> String {
        for (label, value) in [("Project number", number), ("Content format", format), ("Project name", title)] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppFailure("Enter a \(label.lowercased()).")
            }
            try Naming.validate(value)
        }
        if !campaign.isEmpty { try Naming.validate(campaign) }
        let name = [number, format, campaign, title].filter { !$0.isEmpty }.joined(separator: " — ")
        try Naming.validate(name)
        return name
    }
    public var tokens: [String: String] {
        ["Project Number": number, "Content Format": format, "Conent Form": format,
         "Campaign": campaign, "Project Name": title]
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
        let name = [number, format, campaign, title].filter { !$0.isEmpty }.joined(separator: " — ")
        let tokens = ["Project Number": number, "Content Format": format, "Conent Form": format, "Campaign": campaign, "Project Name": title]
        return PreviewName(name: name, missing: missing, issues: issues, tokens: tokens)
    }
}

public enum Naming {
    public static func validate(_ name: String) throws {
        let forbidden = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
        guard !name.isEmpty, name != ".", name != "..", name.rangeOfCharacter(from: forbidden) == nil else {
            throw AppFailure("Invalid name ‘\(name)’. Remove path separators, control characters or <>:\"/\\|?*.")
        }
        guard !name.hasSuffix(" "), !name.hasSuffix("."), name.utf8.count <= 255 else {
            throw AppFailure("Invalid name ‘\(name)’. Remove trailing dots/spaces or shorten it to 255 UTF-8 bytes.")
        }
        let stem = name.split(separator: ".", omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces).uppercased()
        let reserved = ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"] +
            (1...9).flatMap { ["COM\($0)", "LPT\($0)"] } + ["COM¹", "COM²", "COM³", "LPT¹", "LPT²", "LPT³"]
        guard !reserved.contains(stem) else { throw AppFailure("‘\(name)’ is a reserved Windows device name. Choose another name.") }
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
