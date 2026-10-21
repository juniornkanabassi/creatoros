import Foundation

import CoreFoundation
/// The wire contract, CLI help and MCP schemas share this table.
/// Value kinds: `strings`, `booleans` (CLI `--x` sends true, `--no-x` sends false), `integers`, `arrays` (JSON array of
/// strings; the CLI takes a JSON array text) and `objects` (JSON object of string values).
public struct ControlCommand {
    public let action: String, description: String, example: String
    public var strings: [String], booleans: [String], integers: [String], arrays: [String], objects: [String]
    public var required: [String]
    /// The one parameter the CLI also accepts as a bare word after the command (`project set-stage 001`).
    public var positional: String?
    /// Changes library, disk or GUI selection state: takes the one mutation lock.
    public var mutates: Bool
    /// Long running: the CLI waits up to 600 s instead of 30 s.
    public var slow: Bool
    /// At least one of these groups must be fully present, for commands whose required parameters depend on each other.
    public var anyOf: [[String]]
    public init(action: String, description: String, example: String, strings: [String] = [], booleans: [String] = [], integers: [String] = [],
                arrays: [String] = [], objects: [String] = [], required: [String] = [], positional: String? = nil, mutates: Bool = false, slow: Bool = false, anyOf: [[String]] = []) {
        self.action = action; self.description = description; self.example = example
        self.strings = strings; self.booleans = booleans; self.integers = integers; self.arrays = arrays; self.objects = objects
        self.required = required; self.positional = positional; self.mutates = mutates; self.slow = slow; self.anyOf = anyOf
    }
    /// Strings that may be empty, because an empty value clears a field.
    public static let emptyAllowed: Set<String> = ["campaign", "editor", "notes", "series"]
    public var words: String { action.replacingOccurrences(of: ".", with: " ") }
    /// Exact CLI words, for routing; tool names lose the difference between `.` and `-`.
    public var cliWords: [String] { action == "status" ? ["status"] : action.split(separator: ".").map(String.init) }
    public var tool: String { action.replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: "-", with: "_") }
    public var seconds: Int { slow ? 600 : 30 }
    public var schema: [String: Any] {
        var properties: [String: Any] = [:]
        for key in strings { properties[key] = ["type": "string", "maxLength": 4096] as [String: Any]; if !Self.emptyAllowed.contains(key) { properties[key] = ["type": "string", "minLength": 1, "maxLength": 4096] } }
        for key in booleans { properties[key] = ["type": "boolean"] }
        for key in integers { properties[key] = ["type": "integer", "minimum": key == "limit" ? 1 : 0]; if key == "limit" { properties[key] = ["type": "integer", "minimum": 1, "maximum": 200] } }
        for key in arrays { properties[key] = ["type": "array", "items": ["type": "string", "minLength": 1, "maxLength": 4096], "maxItems": 1000] as [String: Any] }
        for key in objects { properties[key] = ["type": "object", "additionalProperties": ["type": "string", "maxLength": 4096]] as [String: Any] }
        var result: [String: Any] = ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
        if !anyOf.isEmpty { result["anyOf"] = anyOf.map { ["required": $0] } }
        return result
    }
    /// What the generated MCP manifest carries for one tool; the shim routes by `_meta`, never by the tool name.
    public var manifest: [String: Any] {
        ["name": tool, "description": description, "inputSchema": schema,
         "_meta": ["creatoros": ["action": action, "words": cliWords, "positional": positional as Any? ?? NSNull()] as [String: Any]]]
    }
    public func validate(_ params: [String: Any]) throws {
        let allowed = Set(strings + booleans + integers + arrays + objects)
        guard Set(params.keys).isSubset(of: allowed), required.allSatisfy({ params[$0] != nil }) else { throw AppFailure("Unknown or missing parameters for \(action).") }
        if !anyOf.isEmpty, !anyOf.contains(where: { $0.allSatisfy { params[$0] != nil } }) {
            throw AppFailure("\(action) needs " + anyOf.map { $0.map { "--" + Self.flag($0) }.joined(separator: " and ") }.joined(separator: ", or ") + ".")
        }
        for (key, value) in params {
            if strings.contains(key) { guard let text = value as? String, (Self.emptyAllowed.contains(key) || !text.isEmpty), text.utf8.count <= 4096 else { throw AppFailure("\(key) must be a non-empty string of at most 4096 bytes.") } }
            if booleans.contains(key) { guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw AppFailure("\(key) must be a boolean.") } }
            if integers.contains(key) { guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.rounded() == n.doubleValue, n.doubleValue >= (key == "limit" ? 1 : 0), n.doubleValue <= (key == "limit" ? 200 : Double(Int.max / 2)) else { throw AppFailure("\(key) is outside its integer range.") } }
            if arrays.contains(key) { guard let list = value as? [Any], list.count <= 1000, list.allSatisfy({ ($0 as? String).map { !$0.isEmpty && $0.utf8.count <= 4096 } ?? false }) else { throw AppFailure("\(key) must be an array of non-empty strings.") } }
            if objects.contains(key) { guard let map = value as? [String: Any], map.values.allSatisfy({ ($0 as? String).map { $0.utf8.count <= 4096 } ?? false }) else { throw AppFailure("\(key) must be an object with string values.") } }
        }
    }
    public static func flag(_ key: String) -> String { key.reduce("") { $0 + ($1.isUppercase ? "-" + $1.lowercased() : String($1)) } }

    public static let all: [ControlCommand] = [
        .init(action: "status", description: "Read app and GUI state without launching", example: "creatoros status --json"),
        .init(action: "library.stats", description: "Count visible library records", example: "creatoros library stats"),
        .init(action: "project.list", description: "List projects on ticked locations; --deep also matches text inside documents", example: "creatoros project list --format Short --limit 10", strings: ["format", "stage", "search"], booleans: ["includeIdeas", "deep"], integers: ["limit", "offset"]),
        .init(action: "project.status", description: "Inspect a project or idea: stage, pin, campaign, editor, series, notes, workspace, previous paths, availability", example: "creatoros project status 001 --format Short", strings: ["project", "format"], required: ["project"], positional: "project"),
        .init(action: "project.open", description: "Select a project in the GUI (--page pipeline shows it on the board)", example: "creatoros project open 001 --format Short --page pipeline", strings: ["project", "format", "page"], booleans: ["show"], required: ["project"], positional: "project", mutates: true),
        .init(action: "project.refresh", description: "Re-read a project's folder state, as the Refresh Project menu does, and try to relink it if missing", example: "creatoros project refresh 001 --format Short", strings: ["project", "format"], required: ["project"], positional: "project", mutates: true),
        .init(action: "project.reveal", description: "Open the project folder in Finder", example: "creatoros project reveal 001 --format Short", strings: ["project", "format"], booleans: ["show"], required: ["project"], positional: "project"),
        .init(action: "project.create", description: "Create and register a project, or start one from an idea; --dry-run previews name, plan and compatibility", example: "creatoros project create --format Short --title Example --extra '{\"Sponsor\":\"Acme\"}' --request-id example-1", strings: ["format", "title", "number", "campaign", "template", "requestId", "fromIdea", "destination"], booleans: ["show", "plainFolders", "dryRun"], objects: ["extra"], mutates: true, slow: true, anyOf: [["format", "title"], ["fromIdea"]]),
        .init(action: "project.rename", description: "Preview or apply the app's reviewed project rename", example: "creatoros project rename 001 --format Short --title Updated --dry-run", strings: ["project", "format", "title", "number", "campaign", "requestId"], booleans: ["dryRun", "updateHeadings", "ignoreOpenApps", "show"], required: ["project"], positional: "project", mutates: true, slow: true),
        .init(action: "project.pin", description: "Pin a project to the top of the list (idempotent)", example: "creatoros project pin 001 --format Short", strings: ["project", "format"], required: ["project"], positional: "project", mutates: true),
        .init(action: "project.unpin", description: "Unpin a project (idempotent)", example: "creatoros project unpin 001 --format Short", strings: ["project", "format"], required: ["project"], positional: "project", mutates: true),
        .init(action: "project.set-stage", description: "Move a project or idea to a stage on its own board; the Finder tag is written before replying", example: "creatoros project set-stage 001 --format Short --stage Editing", strings: ["project", "format", "stage"], required: ["project", "stage"], positional: "project", mutates: true),
        .init(action: "project.update", description: "Edit pipeline details; an empty value clears. Series is comma separated", example: "creatoros project update 001 --format Short --editor Jon --series \"Euro 2026, Finals\"", strings: ["project", "format", "campaign", "editor", "notes", "series"], required: ["project"], positional: "project", mutates: true),
        .init(action: "project.relocate", description: "Point a record at a folder you name (Locate Folder); the record takes the folder's name", example: "creatoros project relocate 001 --format Short --path /Volumes/Drive/001 --dry-run", strings: ["project", "format", "path"], booleans: ["dryRun"], required: ["project", "path"], positional: "project", mutates: true, slow: true),
        .init(action: "project.find-moved", description: "Search the ticked drives for a moved folder; relinks only when exactly one safe match exists", example: "creatoros project find-moved 001 --format Short --dry-run", strings: ["project", "format"], booleans: ["dryRun"], required: ["project"], positional: "project", mutates: true, slow: true),
        .init(action: "project.icons-strip", description: "Remove folder icons so the project can go to LucidLink (the template keeps them)", example: "creatoros project icons-strip 001 --format Short --dry-run", strings: ["project", "format"], booleans: ["dryRun"], required: ["project"], positional: "project", mutates: true, slow: true),
        .init(action: "project.icons-restore", description: "Put a template set's folder icons back; later folders such as 06 Media Revised inherit the icon of the folder their name extends", example: "creatoros project icons-restore 001 --format Short --set Main --dry-run", strings: ["project", "format", "set", "formatAs"], booleans: ["dryRun"], required: ["project"], positional: "project", mutates: true, slow: true),
        .init(action: "project.remove", description: "Remove a project from the list; its folder is never touched", example: "creatoros project remove 001 --format Short --dry-run", strings: ["project", "format"], booleans: ["dryRun"], required: ["project"], positional: "project", mutates: true),
        .init(action: "project.workspace-detach", description: "Keep a started idea's old workspace folder and stop linking it", example: "creatoros project workspace-detach 001 --format Short", strings: ["project", "format"], required: ["project"], positional: "project", mutates: true),
        .init(action: "project.workspace-bin", description: "Move a started idea's old workspace to the Bin (needs --confirm)", example: "creatoros project workspace-bin 001 --format Short --confirm", strings: ["project", "format"], booleans: ["confirm", "dryRun"], required: ["project"], positional: "project", mutates: true, slow: true),
        .init(action: "project.register", description: "Add one existing project folder to the list (Add Existing Project)", example: "creatoros project register --path /Volumes/Drive/005 --format Short --request-id reg-1", strings: ["path", "format", "requestId"], required: ["path"], mutates: true, slow: true),
        .init(action: "project.files", description: "List a project's files and folders (bounded; no symlinks or package contents)", example: "creatoros project files 001 --format Short --path \"02 Project Files\"", strings: ["project", "format", "path"], integers: ["limit", "offset"], required: ["project"], positional: "project"),
        .init(action: "project.open-file", description: "Open a project document in its default app with the browser's safety checks", example: "creatoros project open-file 001 --format Short --path \"01 Documents/Script.md\"", strings: ["project", "format", "path"], required: ["project", "path"], positional: "project"),
        .init(action: "project.add-files", description: "Move or copy a file or folder into a project as a browser drop does; never overwrites", example: "creatoros project add-files 001 --format Short --from /Users/me/clip.mov --to \"03 Media\" --copy", strings: ["project", "format", "from", "to"], booleans: ["copy", "dryRun"], required: ["project", "from"], positional: "project", mutates: true, slow: true),
        .init(action: "project.open-premiere", description: "List a project's Premiere documents, or open one with --file", example: "creatoros project open-premiere 001 --format Short --file \"02 Project Files/001.prproj\"", strings: ["project", "format", "file"], required: ["project"], positional: "project"),
        .init(action: "idea.add", description: "Add an idea to the first column (recordings only)", example: "creatoros idea add --title \"Ref bias\" --format Short --request-id idea-1", strings: ["title", "format", "campaign", "notes", "requestId"], required: ["title", "format"], mutates: true),
        .init(action: "idea.remove", description: "Bin an idea; one with a workspace needs --trash-workspace", example: "creatoros idea remove \"Ref bias\" --format Short --dry-run", strings: ["project", "format"], booleans: ["trashWorkspace", "dryRun"], required: ["project"], positional: "project", mutates: true, slow: true),
        .init(action: "idea.create-workspace", description: "Create a draft workspace folder for an idea", example: "creatoros idea create-workspace \"Ref bias\" --format Short --template Main --request-id ws-1", strings: ["project", "format", "template", "root", "requestId"], required: ["project"], positional: "project", mutates: true, slow: true),
        .init(action: "idea.merge", description: "Fold an idea's empty-field metadata and notes into a project, then remove the idea (control only)", example: "creatoros idea merge \"Ref bias\" --into 001 --into-format Short --dry-run", strings: ["project", "format", "into", "intoFormat"], booleans: ["dryRun"], required: ["project", "into"], positional: "project", mutates: true),
        .init(action: "stage.list", description: "List both boards' stages with colours and record counts", example: "creatoros stage list"),
        .init(action: "stage.set", description: "Replace a board's stage list (JSON array, at least two); reports records left on orphaned stages", example: "creatoros stage set --board recordings --stages '[\"Idea\",\"Writing\",\"Editing\",\"Published\",\"Abandoned\"]'", strings: ["board"], booleans: ["dryRun"], arrays: ["stages"], required: ["board", "stages"], mutates: true),
        .init(action: "stage.set-colour", description: "Set a stage's colour (none, gray, green, purple, blue, yellow, red, orange)", example: "creatoros stage set-colour --stage Editing --colour purple", strings: ["stage", "colour"], required: ["stage", "colour"], mutates: true),
        .init(action: "stage.move-all", description: "Move every record in one stage to another on the same board, ignoring GUI filters", example: "creatoros stage move-all --from Editing --to Published --board recordings --dry-run", strings: ["from", "to", "board"], booleans: ["dryRun"], required: ["from", "to"], mutates: true, slow: true),
        .init(action: "settings.finder-tags", description: "Turn stage Finder tags on or off (--enabled / --no-enabled)", example: "creatoros settings finder-tags --no-enabled", booleans: ["enabled"], required: ["enabled"], mutates: true),
        .init(action: "library.tag-folders", description: "Write stage tags onto every staged folder on a connected, ticked drive", example: "creatoros library tag-folders --dry-run", booleans: ["dryRun"], mutates: true, slow: true),
        .init(action: "field.list", description: "List custom naming fields", example: "creatoros field list"),
        .init(action: "field.add", description: "Add a custom naming field", example: "creatoros field add --name Sponsor --exclude-from-name --request-id field-1", strings: ["name", "requestId"], booleans: ["excludeFromName"], required: ["name"], mutates: true),
        .init(action: "field.update", description: "Rename a field or change whether it goes in the folder name", example: "creatoros field update Sponsor --name Client --no-include-in-name", strings: ["field", "name"], booleans: ["includeInName", "excludeFromName"], required: ["field"], positional: "field", mutates: true),
        .init(action: "field.remove", description: "Remove a custom field; --dry-run reports the creation form value it would drop", example: "creatoros field remove Sponsor --dry-run", strings: ["field"], booleans: ["dryRun"], required: ["field"], positional: "field", mutates: true),
        .init(action: "format.list", description: "List formats with destination, icon and readiness", example: "creatoros format list"),
        .init(action: "format.set-destination", description: "Set where a format's projects are created (saved)", example: "creatoros format set-destination --format Short --path /Volumes/Drive/Short", strings: ["format", "path"], required: ["format", "path"], mutates: true),
        .init(action: "format.set-icon", description: "Set a format's folder icon from an image or from another folder's icon", example: "creatoros format set-icon --format Short --image /Users/me/icon.png", strings: ["format", "image", "fromFolder"], required: ["format"], mutates: true, anyOf: [["image"], ["fromFolder"]]),
        .init(action: "template.list", description: "List template sets, variants and managed templates", example: "creatoros template list"),
        .init(action: "template.files", description: "List a managed template's files (read-only; opening or editing templates stays in the GUI)", example: "creatoros template files Main --path \"01 Documents\"", strings: ["template", "path"], integers: ["limit", "offset"], required: ["template"], positional: "template"),
        .init(action: "template.import", description: "Import a template folder or .pht; --dry-run returns the scan", example: "creatoros template import --path /Users/me/Template --name Main --mode full --set Main --format Short", strings: ["path", "name", "mode", "set", "format", "requestId"], booleans: ["dryRun"], required: ["path", "name", "mode"], mutates: true, slow: true),
        .init(action: "template.remove", description: "Delete a managed template (its copy goes to the Bin) and drop its assignments", example: "creatoros template remove Old --dry-run", strings: ["template"], booleans: ["dryRun"], required: ["template"], positional: "template", mutates: true),
        .init(action: "set.create", description: "Create a template set, optionally mapping all formats to one template", example: "creatoros set create --name Main --from-template Fixture --request-id set-1", strings: ["name", "fromTemplate", "requestId"], required: ["name"], mutates: true),
        .init(action: "set.rename", description: "Rename a template set", example: "creatoros set rename Main --name Channel", strings: ["set", "name"], required: ["set", "name"], positional: "set", mutates: true),
        .init(action: "set.assign", description: "Use a template for one format in a set", example: "creatoros set assign Main --format Short --template Fixture", strings: ["set", "format", "template"], required: ["set", "format", "template"], positional: "set", mutates: true),
        .init(action: "set.unassign", description: "Stop using a template for one format in a set", example: "creatoros set unassign Main --format Short", strings: ["set", "format"], required: ["set", "format"], positional: "set", mutates: true),
        .init(action: "set.remove", description: "Delete a template set (templates stay)", example: "creatoros set remove Main --dry-run", strings: ["set"], booleans: ["dryRun"], required: ["set"], positional: "set", mutates: true),
        .init(action: "library.find-missing", description: "Find Missing Projects: relink the certain ones, report the rest", example: "creatoros library find-missing --dry-run", booleans: ["dryRun"], mutates: true, slow: true),
        .init(action: "library.duplicates", description: "Group projects registered under the same name", example: "creatoros library duplicates"),
        .init(action: "location.list", description: "List locations (key, mounted, hidden, colour, count) and saved scan locations", example: "creatoros location list"),
        .init(action: "location.set", description: "Hide, show or recolour a location in the GUI; hidden locations disappear for every caller", example: "creatoros location set volume:Drive --hidden --colour orange", strings: ["key", "colour"], booleans: ["hidden", "visible"], required: ["key"], positional: "key", mutates: true),
        .init(action: "location.scan", description: "Scan a folder or saved location for projects; --dry-run lists them, --only registers a subset", example: "creatoros location scan --path /Volumes/Drive/Projects --dry-run", strings: ["path", "location"], booleans: ["dryRun"], arrays: ["only"], mutates: true, slow: true, anyOf: [["path"], ["location"]]),
        .init(action: "location.remove", description: "Forget a saved scan location (registered projects stay)", example: "creatoros location remove Projects --dry-run", strings: ["location"], booleans: ["dryRun"], required: ["location"], positional: "location", mutates: true),
        .init(action: "compat.check", description: "Check names for LucidLink; --copy-to makes a corrected copy (--dry-run returns the rename proposal)", example: "creatoros compat check --project 001 --format Short --copy-to /Volumes/Drive/Out", strings: ["project", "format", "path", "copyTo", "requestId"], booleans: ["dryRun"], positional: "project", slow: true, anyOf: [["project"], ["path"]]),
        .init(action: "app.cancel", description: "Cancel the running long operation, only if this request id started it", example: "creatoros app cancel --request-id create-1", strings: ["requestId"], required: ["requestId"])
    ]
}
