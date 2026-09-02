import Foundation

/// One line of the live preview. The id is the source path so selection and expansion survive keystrokes.
public struct PreviewEntry: Identifiable, Sendable, Hashable {
    public var id: String { source }
    public let source: String
    public let output: String
    public let directory: Bool
    public let package: Bool
    public let metadata: Bool
    public let bytes: Int64
    public var renamed: Bool { source != output }
    /// The output still contains a placeholder because a required field is empty.
    public let placeholder: Bool
    public let issue: String?
    public var name: String { (output as NSString).lastPathComponent }
    public var sourceName: String { (source as NSString).lastPathComponent }
    public var parent: String { (source as NSString).deletingLastPathComponent }
}

/// What the user sees before and while typing. Deliberately has no way to become a CopyPlan.
public struct PreviewRendering: Sendable {
    public let root: URL
    public let outerFolderName: String
    public let entries: [PreviewEntry]
    public let missingFields: [String]
    public let issues: [String]
    public var isExecutable: Bool { missingFields.isEmpty && issues.isEmpty }
    public var visible: [PreviewEntry] { entries.filter { !$0.metadata } }
    public var renamedEntries: [PreviewEntry] { visible.filter { $0.renamed } }
    public var bytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    /// Direct children of a source folder path, folders first, in scan order.
    public func children(of parent: String) -> [PreviewEntry] {
        let items = visible.filter { $0.parent == parent }
        return items.filter(\.directory) + items.filter { !$0.directory }
    }
}

public enum PreviewRenderer {
    static let placeholders = [ProjectFields.numberPlaceholder, ProjectFields.titlePlaceholder, ProjectFields.formatPlaceholder]

    /// Renders names in memory from a structural scan. Never reads the disk, never throws, never writes.
    public static func render(structure: CopyPlan, fields: ProjectFields) -> PreviewRendering {
        let named = fields.previewName()
        var entries: [PreviewEntry] = []; var issues = named.issues
        var outputs: [String: String] = [:]; var seen = Set<String>()
        for entry in structure.entries {
            let name = (entry.source as NSString).lastPathComponent
            let parent = (entry.source as NSString).deletingLastPathComponent
            let parentOutput = parent.isEmpty ? "" : (outputs[parent] ?? parent)
            var renamed = name; var issue: String?
            if !entry.metadata && !entry.opaque {
                do { renamed = try Naming.substitute(name, tokens: named.tokens, final: named.name) }
                catch { issue = error.localizedDescription }
            }
            let placeholder = placeholders.contains { renamed.contains($0) }
            if issue == nil, renamed != name, !placeholder {
                do { try Naming.validate(renamed) } catch { issue = error.localizedDescription }
            }
            let out = parentOutput.isEmpty ? renamed : parentOutput + "/" + renamed
            if issue == nil, !seen.insert(Naming.key(out)).inserted { issue = "Case or Unicode name collision: \(out)" }
            if let issue { issues.append(issue) }
            if entry.directory { outputs[entry.source] = out }
            let package = entry.directory && !entry.opaque && TemplateReader.packages.contains((name as NSString).pathExtension.lowercased())
            entries.append(PreviewEntry(source: entry.source, output: out, directory: entry.directory, package: package,
                                        metadata: entry.metadata, bytes: entry.bytes, placeholder: placeholder, issue: issue))
        }
        var unique = Set<String>()
        return PreviewRendering(root: structure.root, outerFolderName: named.name, entries: entries,
                                missingFields: named.missing, issues: issues.filter { unique.insert($0).inserted })
    }
}
