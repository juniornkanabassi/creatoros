import Foundation
import Darwin

/// Which board a format belongs to. Recordings move through writing, filming and editing;
/// live streams are only ever scheduled and then streamed, so they get their own stages.
public enum PipelineKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case recordings, live
    public var id: String { rawValue }
    public var title: String { self == .live ? "Live" : "Recordings" }
    public static func of(format: String) -> PipelineKind { format == "Livestream" ? .live : .recordings }
    public func includes(format: String) -> Bool { PipelineKind.of(format: format) == self }
}

/// The seven Finder tag colours plus none, so a stage colour in the app is the same colour on the folder in Finder.
public enum StageColour: String, CaseIterable, Codable, Sendable {
    case none, gray, green, purple, blue, yellow, red, orange
    /// Finder's own numbering inside `_kMDItemUserTags`.
    public var finderIndex: Int {
        switch self { case .none: 0; case .gray: 1; case .green: 2; case .purple: 3; case .blue: 4; case .yellow: 5; case .red: 6; case .orange: 7 }
    }
    public init(finderIndex: Int) { self = StageColour.allCases.first { $0.finderIndex == finderIndex } ?? .none }
    public var title: String { self == .none ? "No colour" : rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// Finder tags on a folder, read and written through the same extended attribute Finder uses.
/// Only tags named after a known stage are ever replaced; every other tag on the folder is kept.
public enum FinderTags {
    public static let attribute = "com.apple.metadata:_kMDItemUserTags"
    public struct Tag: Equatable, Sendable {
        public var name: String
        public var colour: StageColour
        public init(name: String, colour: StageColour) { self.name = name; self.colour = colour }
        var stored: String { colour == .none ? name : name + "\n" + String(colour.finderIndex) }
        init(stored: String) {
            let parts = stored.components(separatedBy: "\n")
            name = parts[0]
            colour = parts.count > 1 ? StageColour(finderIndex: Int(parts[1]) ?? 0) : .none
        }
    }
    public static func read(_ url: URL) throws -> [Tag] {
        let path = url.path
        let size = getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0 {
            if errno == ENOATTR { return [] }
            throw posixError("read tags")
        }
        if size == 0 { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read >= 0 else { throw posixError("read tags") }
        data.count = read
        guard let list = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        return list.map(Tag.init(stored:))
    }
    public static func write(_ tags: [Tag], to url: URL) throws {
        let path = url.path
        if tags.isEmpty {
            if removexattr(path, attribute, XATTR_NOFOLLOW) != 0 && errno != ENOATTR { throw posixError("clear tags") }
            return
        }
        let data = try PropertyListSerialization.data(fromPropertyList: tags.map(\.stored), format: .binary, options: 0)
        let result = data.withUnsafeBytes { setxattr(path, attribute, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        guard result == 0 else { throw posixError("write tags") }
    }
    /// Puts the stage tag on the folder in place of any other stage tag. Returns false when nothing needed changing.
    @discardableResult
    public static func apply(stage: String, colour: StageColour, knownStages: [String], to url: URL) throws -> Bool {
        let known = Set(knownStages.map(Naming.key))
        let existing = try read(url)
        let kept = existing.filter { !known.contains(Naming.key($0.name)) }
        let wanted = kept + [Tag(name: stage, colour: colour)]
        guard wanted != existing else { return false }
        try write(wanted, to: url)
        return true
    }
    /// Removes every stage tag from the folder, keeping the rest.
    public static func clear(knownStages: [String], from url: URL) throws {
        let known = Set(knownStages.map(Naming.key))
        let existing = try read(url)
        let kept = existing.filter { !known.contains(Naming.key($0.name)) }
        if kept != existing { try write(kept, to: url) }
    }
    /// The stage a folder carries in Finder, when one of its tags names a known stage.
    public static func stage(of url: URL, knownStages: [String]) -> String? {
        guard let tags = try? read(url) else { return nil }
        return tags.compactMap { tag in knownStages.first { Naming.key($0) == Naming.key(tag.name) } }.first
    }
    private static func posixError(_ what: String) -> AppFailure {
        AppFailure("Could not \(what): \(String(cString: strerror(errno)))")
    }
}
