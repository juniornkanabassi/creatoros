import Foundation

import CoreFoundation
/// The wire contract, CLI help and MCP schemas share this table.
public struct ControlCommand {
    public let action: String, description: String, example: String
    public let strings: [String], booleans: [String], integers: [String], required: [String]
    public var words: String { action.replacingOccurrences(of: ".", with: " ") }
    public var tool: String { action.replacingOccurrences(of: ".", with: "_") }
    public var schema: [String: Any] {
        var properties: [String: Any] = [:]
        for key in strings { properties[key] = ["type": "string"] }
        for key in booleans { properties[key] = ["type": "boolean"] }
        for key in integers { properties[key] = ["type": "integer", "minimum": key == "limit" ? 1 : 0]; if key == "limit" { properties[key] = ["type": "integer", "minimum": 1, "maximum": 200] } }
        return ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
    public static let all: [ControlCommand] = [
        .init(action: "status", description: "Read app and GUI state without launching", example: "creatoros status --json", strings: [], booleans: [], integers: [], required: []),
        .init(action: "library.stats", description: "Count visible library records", example: "creatoros library stats", strings: [], booleans: [], integers: [], required: []),
        .init(action: "project.list", description: "List projects on ticked locations", example: "creatoros project list --format Short --limit 10", strings: ["format", "stage", "search"], booleans: ["includeIdeas"], integers: ["limit", "offset"], required: []),
        .init(action: "project.status", description: "Inspect a project by UUID, name or number", example: "creatoros project status 001 --format Short", strings: ["project", "format"], booleans: [], integers: [], required: ["project"]),
        .init(action: "project.open", description: "Select a project in the GUI", example: "creatoros project open 001 --format Short", strings: ["project", "format"], booleans: ["show"], integers: [], required: ["project"]),
        .init(action: "project.reveal", description: "Open the project folder in Finder", example: "creatoros project reveal 001 --format Short", strings: ["project", "format"], booleans: ["show"], integers: [], required: ["project"]),
        .init(action: "project.create", description: "Create and register a project using the app action", example: "creatoros project create --format Short --title Example --request-id example-1", strings: ["format", "title", "number", "campaign", "template", "requestId"], booleans: ["show"], integers: [], required: ["format", "title"])
    ]
    public func validate(_ params: [String: Any]) throws {
        let allowed = Set(strings + booleans + integers)
        guard Set(params.keys).isSubset(of: allowed), required.allSatisfy({ params[$0] != nil }) else { throw AppFailure("Unknown or missing parameters for \(action).") }
        for (key, value) in params {
            if strings.contains(key) { guard let text = value as? String, !text.isEmpty, text.utf8.count <= 4096 else { throw AppFailure("\(key) must be a non-empty string of at most 4096 bytes.") } }
            if booleans.contains(key) { guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw AppFailure("\(key) must be a boolean.") } }
            if integers.contains(key) { guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.rounded() == n.doubleValue, n.doubleValue >= (key == "limit" ? 1 : 0), n.doubleValue <= (key == "limit" ? 200 : Double(Int.max / 2)) else { throw AppFailure("\(key) is outside its integer range.") } }
        }
    }
}
