import Foundation

/// One format inside a set, pointing at the managed payload it creates projects from.
public struct TemplateVariant: Codable, Identifiable, Sendable, Hashable {
    public var id: String { format }
    public var format: String
    public var templateID: UUID
    public var assigned: Date
    public init(format: String, templateID: UUID) {
        self.format = format; self.templateID = templateID; assigned = Date()
    }
}

/// A brand, client or campaign asset set. Each format may have its own payload.
public struct TemplateSet: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var created: Date
    public var variants: [TemplateVariant]
    public init(name: String, variants: [TemplateVariant] = []) {
        id = UUID(); self.name = name; created = Date(); self.variants = variants
    }
    public func variant(for format: String) -> TemplateVariant? { variants.first { $0.format == format } }
    /// Other formats in this set that share the given payload.
    public func formatsSharing(_ templateID: UUID, excluding format: String) -> [String] {
        variants.filter { $0.templateID == templateID && $0.format != format }.map(\.format)
    }
}

public extension Library {
    var sets: [TemplateSet] { templateSets ?? [] }
    func set(_ id: UUID?) -> TemplateSet? { id.flatMap { id in sets.first { $0.id == id } } }
    func template(_ id: UUID?) -> TemplateRecord? { id.flatMap { id in templates.first { $0.id == id } } }
    /// The payload for a set and format, or nil when the format is not set up. Never falls back to another format.
    func resolve(setID: UUID, format: String) -> TemplateRecord? {
        guard let variant = set(setID)?.variant(for: format) else { return nil }
        return template(variant.templateID)
    }
    /// Managed templates no set refers to. Still usable directly as legacy templates.
    var unassignedTemplates: [TemplateRecord] {
        let referenced = Set(sets.flatMap { $0.variants.map(\.templateID) })
        return templates.filter { !referenced.contains($0.id) }
    }
    /// Every set and format whose payload record no longer exists.
    func referenceProblems() -> [String] {
        sets.flatMap { set in
            set.variants.compactMap { template($0.templateID) == nil ? "\(set.name) · \($0.format) points at a missing template" : nil }
        }
    }
    static func setName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppFailure("Give the content template a name, for example your channel or a client.") }
        return name
    }
    /// Creates a set. With a template id, all four formats point at that one payload, shown as shared.
    @discardableResult
    mutating func createSet(named raw: String, mappingAll templateID: UUID? = nil) throws -> TemplateSet {
        let name = try Library.setName(raw)
        guard sets.allSatisfy({ $0.name.caseInsensitiveCompare(name) != .orderedSame }) else {
            throw AppFailure("A content template called ‘\(name)’ already exists.")
        }
        var variants: [TemplateVariant] = []
        if let templateID {
            guard template(templateID) != nil else { throw AppFailure("That managed template no longer exists.") }
            variants = Library.formats.map { TemplateVariant(format: $0, templateID: templateID) }
        }
        let set = TemplateSet(name: name, variants: variants)
        templateSets = sets + [set]
        return set
    }
    mutating func renameSet(_ id: UUID, to raw: String) throws {
        let name = try Library.setName(raw)
        guard let index = sets.firstIndex(where: { $0.id == id }) else { throw AppFailure("That content template no longer exists.") }
        var next = sets; next[index].name = name; templateSets = next
    }
    mutating func assign(format: String, templateID: UUID, in setID: UUID) throws {
        guard Library.formats.contains(format) else { throw AppFailure("Unknown format \(format).") }
        guard template(templateID) != nil else { throw AppFailure("That managed template no longer exists.") }
        guard let index = sets.firstIndex(where: { $0.id == setID }) else { throw AppFailure("That content template no longer exists.") }
        var next = sets
        next[index].variants.removeAll { $0.format == format }
        next[index].variants.append(TemplateVariant(format: format, templateID: templateID))
        next[index].variants.sort { (Library.formats.firstIndex(of: $0.format) ?? 9) < (Library.formats.firstIndex(of: $1.format) ?? 9) }
        templateSets = next
    }
    mutating func unassign(format: String, in setID: UUID) {
        guard let index = sets.firstIndex(where: { $0.id == setID }) else { return }
        var next = sets; next[index].variants.removeAll { $0.format == format }; templateSets = next
    }
    /// Removes the set only. Payload folders and template records are untouched.
    mutating func removeSet(_ id: UUID) { templateSets = sets.filter { $0.id != id } }
    /// Sets and formats that would lose their payload if this template were removed.
    func usages(of templateID: UUID) -> [String] {
        sets.flatMap { set in set.variants.filter { $0.templateID == templateID }.map { "\(set.name) · \($0.format)" } }
    }
}
