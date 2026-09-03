import Foundation

/// Where a project lives, derived from its path: the boot drive, an external volume, or a cloud provider folder.
public struct ProjectLocation: Hashable, Sendable {
    public enum Kind: String, Sendable { case local, external, cloud }
    public let key: String
    public let label: String
    public let kind: Kind
    public let mountPath: String

    public static let bootDrive = "Macintosh HD"

    public init(path: String, volumeName: String? = nil) {
        let parts = path.split(separator: "/").map(String.init)
        if path.hasPrefix("/Volumes/"), parts.count >= 3, parts[1] == parts[2] {
            // A LucidLink filespace mounts as /Volumes/<filespace>/<filespace>: a cloud drive that looks like a volume.
            key = "lucid:" + parts[1]; label = "LucidLink"; kind = .cloud; mountPath = "/Volumes/" + parts[1] + "/" + parts[2]
        } else if path.hasPrefix("/Volumes/") {
            let volume = parts.dropFirst().first ?? "External"
            key = "volume:" + volume; label = volumeName ?? volume; kind = .external; mountPath = "/Volumes/" + volume
        } else if let range = path.range(of: "/Library/CloudStorage/") {
            let folder = path[range.upperBound...].split(separator: "/").first.map(String.init) ?? "Cloud"
            let provider = folder.split(separator: "-").first.map(String.init) ?? folder
            key = "cloud:" + folder
            switch provider {
            case "GoogleDrive": label = "Google Drive"
            case "OneDrive": label = "OneDrive"
            case "iCloudDrive": label = "iCloud Drive"
            case "Dropbox": label = "Dropbox"
            default: label = provider
            }
            kind = .cloud; mountPath = String(path[..<range.upperBound]) + folder
        } else if path.isEmpty {
            key = "planned"; label = "Not created yet"; kind = .local; mountPath = ""
        } else {
            key = "local"; label = volumeName ?? ProjectLocation.bootDrive; kind = .local; mountPath = "/"
        }
    }
    /// The account for a cloud folder, for example jnb@juniornkanabassi.com, when the folder name carries one.
    public var account: String? {
        if key.hasPrefix("lucid:") { return String(key.dropFirst(6)) }
        guard kind == .cloud, let dash = key.firstIndex(of: "-") else { return nil }
        return String(key[key.index(after: dash)...]).split(separator: " ").first.map(String.init)
    }
    /// Cheap presence check that never hydrates cloud files: a stat on the mount folder only.
    public var isMounted: Bool {
        guard !mountPath.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: mountPath)
    }
    /// Colour name suggestions. Junior's archive drive is orange, the boot drive grey, cloud folders green.
    public var defaultColour: String {
        if kind == .local { return "gray" }
        if label.localizedCaseInsensitiveContains("naruto") { return "orange" }
        if label == "LucidLink" { return "indigo" }
        if kind == .cloud { return "green" }
        return "purple"
    }
}

public extension ProjectRecord {
    var location: ProjectLocation { ProjectLocation(path: path, volumeName: volumeName) }
}

/// Next project number per format, from the numbers already used in the library.
public enum Numbering {
    public static func next(for format: String, in projects: [ProjectRecord]) -> String {
        let used = projects.filter { $0.format == format && !$0.isPlanned }.compactMap(\.number)
        let width = max(3, used.map(\.count).max() ?? 3)
        // Increment decimal strings rather than overflowing Int (or truncating through C %d).
        let digits = used.filter { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }
            .map { String($0.drop(while: { $0 == "0" })) }.map { $0.isEmpty ? "0" : $0 }
        let highest = digits.max { $0.count == $1.count ? $0 < $1 : $0.count < $1.count } ?? "0"
        var next = Array(highest.utf8); var carry = true
        for i in next.indices.reversed() where carry {
            if next[i] == 57 { next[i] = 48 } else { next[i] += 1; carry = false }
        }
        if carry { next.insert(49, at: 0) }
        return String(repeating: "0", count: max(0, min(width, 255) - next.count)) + String(decoding: next, as: UTF8.self)
    }
    /// Other records with the same number and format, for example the same project on a second drive.
    public static func siblings(of record: ProjectRecord, in projects: [ProjectRecord]) -> [ProjectRecord] {
        guard let number = record.number else { return [] }
        return projects.filter { $0.id != record.id && $0.format == record.format && $0.number == number && Naming.key($0.name) == Naming.key(record.name) }
    }
}
