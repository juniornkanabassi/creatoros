import Foundation

// One-time personal setup, kept outside the distributable. Run only while the
// app is closed. Unknown JSON keys and non-empty existing metadata are retained.
func argument(_ key: String) throws -> String {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: key), a.indices.contains(i + 1) else {
        throw NSError(domain: "Setup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(key)"])
    }
    return a[i + 1]
}
let file = URL(fileURLWithPath: try argument("--library"))
let input = try Data(contentsOf: file)
var library = try JSONSerialization.jsonObject(with: input) as! [String: Any]
guard let schema = library["schema"] as? Int, (1...4).contains(schema) else { fatalError("Unsupported library schema") }
let reportURL = URL(fileURLWithPath: try argument("--audit"))
let audit = try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as! [String: Any]
var projects = library["projects"] as! [[String: Any]]
var metadataCount = 0
var preserved = 0
for item in audit["projects"] as! [[String: Any]] where item["outcome"] as? String == "backed_up" {
    guard let path = item["matchedPath"] as? String,
          let candidate = (item["candidates"] as? [[String: Any]])?.first(where: { $0["path"] as? String == path }),
          let id = candidate["id"] as? String,
          let i = projects.firstIndex(where: { $0["id"] as? String == id && $0["path"] as? String == path }),
          let properties = item["properties"] as? [String: String] else { continue }
    var fields: [String: Any] = [:]
    if let stage = properties["Status"], !stage.isEmpty { fields["stage"] = stage }
    if let campaign = properties["Campaign"], !campaign.isEmpty { fields["campaign"] = campaign }
    if let series = properties["Series"], !series.isEmpty { fields["series"] = series.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    fields["notionURL"] = item["notionURL"]
    var changed = false
    for (key, value) in fields {
        if projects[i][key] == nil || projects[i][key] is NSNull {
            projects[i][key] = value; changed = true
        } else { preserved += 1 }
    }
    if changed { metadataCount += 1 }
}
library["projects"] = projects
let root = URL(fileURLWithPath: try argument("--content-root"))
let paths = ["Long": "02 Live Projects/01 Internal Drive/01 Recordings/01 Longs",
             "Short": "02 Live Projects/01 Internal Drive/01 Recordings/02 Shorts",
             "Podcast": "02 Live Projects/01 Internal Drive/01 Recordings/03 Podcasts",
             "Livestream": "02 Live Projects/01 Internal Drive/02 Livestreams"]
var presets = library["presets"] as! [[String: Any]]
var destinations: [String: String] = [:]
for i in presets.indices where (presets[i]["destination"] as? String ?? "").isEmpty {
    guard let format = presets[i]["format"] as? String, let suffix = paths[format] else { continue }
    let url = root.appendingPathComponent(suffix)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw NSError(domain: "Setup", code: 2, userInfo: [NSLocalizedDescriptionKey: "Destination unavailable: \(url.path)"])
    }
    presets[i]["destination"] = url.path
    presets[i]["destinationBookmark"] = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil).base64EncodedString()
    destinations[format] = url.path
}
library["presets"] = presets
let output = try JSONSerialization.data(withJSONObject: library, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
let apply = CommandLine.arguments.contains("--apply")
if apply && (metadataCount > 0 || !destinations.isEmpty) {
    let backup = URL(fileURLWithPath: try argument("--backup"))
    try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
    try input.write(to: backup, options: .withoutOverwriting)
    guard try Data(contentsOf: file) == input else { fatalError("Library changed during setup; no changes saved") }
    try output.write(to: file, options: .atomic)
    guard try Data(contentsOf: file) == output else { fatalError("Readback failed; restore backup") }
}
let summary: [String: Any] = ["applied": apply, "projectsUpdated": metadataCount,
                            "existingFieldsPreserved": preserved, "destinationsSet": destinations,
                            "projectCount": projects.count, "schemaKept": schema]
print(String(data: try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
