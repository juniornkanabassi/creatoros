import Foundation
import AppKit
import Darwin

public enum ImportMode: String, Codable, CaseIterable, Sendable {
    case full, structure
    public var title: String { self == .full ? "Files and folders" : "Folder structure only" }
}

public final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

public struct Entry: Identifiable, Sendable {
    public var id: String { output }
    public let source: String
    public let output: String
    public let directory: Bool
    /// Finder icon support file. Copied as metadata, never renamed, hidden in browsers.
    public let metadata: Bool
    /// Inside a document package. Copied byte for byte, never renamed.
    public let opaque: Bool
    public let bytes: Int64
    public let modified: Date?
    public init(source: String, output: String, directory: Bool, metadata: Bool, opaque: Bool = false, bytes: Int64, modified: Date?) {
        self.source = source; self.output = output; self.directory = directory; self.metadata = metadata
        self.opaque = opaque; self.bytes = bytes; self.modified = modified
    }
}

public struct CopyPlan: Sendable {
    public let root: URL
    public let entries: [Entry]
    public let excluded: [String]
    public var bytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    public var visible: [Entry] { entries.filter { !$0.metadata } }
}

public enum TemplateReader {
    public static let packages: Set<String> = ["app", "rtfd", "fcpbundle", "bundle", "framework", "photoslibrary", "logicx", "band", "playground"]
    public static func payload(_ selected: URL) throws -> URL {
        let root = selected.pathExtension.lowercased() == "pht" ? selected.appendingPathComponent("Files") : selected
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw AppFailure("Choose an ordinary folder or a .pht containing a Files folder.") }
        return root.resolvingSymlinksInPath()
    }

    public static func scan(_ root: URL, mode: ImportMode = .full, fields: ProjectFields? = nil,
                            excluding: Set<String> = [], cancellation: Cancellation = Cancellation()) throws -> CopyPlan {
        var entries: [Entry] = []; var excluded: [String] = []; var names = Set<String>()
        let canonical = try payload(root)
        func walk(_ folder: URL, relative: String, output: String, opaque: Bool) throws {
            try cancellation.check()
            let children = try FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for child in children {
                try cancellation.check()
                let name = child.lastPathComponent
                let rel = relative.isEmpty ? name : relative + "/" + name
                if excluding.contains(rel) { excluded.append(rel + " (omitted)"); continue }
                if name == ".DS_Store" { continue }
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey])
                guard values.isSymbolicLink != true else {
                    if mode == .structure { excluded.append(rel + " (symbolic link)"); continue }
                    throw AppFailure("Symbolic link is unsupported: \(rel). Remove it from a separate template copy before importing.")
                }
                let directory = values.isDirectory == true
                let package = directory && (values.isPackage == true || packages.contains(child.pathExtension.lowercased()))
                let icon = name == "Icon\r"
                if mode == .structure && (package || (!directory && !icon)) {
                    excluded.append(rel + (package ? " (package)" : " (file)")); continue
                }
                guard directory || values.isRegularFile == true else { throw AppFailure("Unsupported special file: \(rel)") }
                let renamed = try rename(name, metadata: icon, opaque: opaque, fields: fields)
                let out = output.isEmpty ? renamed : output + "/" + renamed
                guard names.insert(Naming.key(out)).inserted else { throw AppFailure("Case or Unicode name collision: \(out)") }
                entries.append(Entry(source: rel, output: out, directory: directory, metadata: icon, opaque: opaque,
                                     bytes: directory ? 0 : Int64(values.fileSize ?? 0), modified: values.contentModificationDate))
                if directory { try walk(child, relative: rel, output: out, opaque: opaque || package) }
            }
        }
        try walk(canonical, relative: "", output: "", opaque: false)
        return CopyPlan(root: canonical, entries: entries, excluded: excluded)
    }

    /// The single rename step. Metadata and package internals keep their names; everything else follows Naming.render.
    public static func rename(_ name: String, metadata: Bool, opaque: Bool, fields: ProjectFields?) throws -> String {
        guard let fields, !metadata, !opaque else { return name }
        return try Naming.render(name, fields: fields)
    }

    /// Derives the executable plan from a structural scan (fields nil) without touching the disk again.
    /// Produces exactly what scan(root, fields:) would, entry for entry, so a cached structure can be reused per keystroke.
    public static func plan(from structure: CopyPlan, fields: ProjectFields) throws -> CopyPlan {
        var entries: [Entry] = []; var names = Set<String>(); var outputs: [String: String] = [:]
        for entry in structure.entries {
            let name = (entry.source as NSString).lastPathComponent
            let parent = (entry.source as NSString).deletingLastPathComponent
            let parentOutput = parent.isEmpty ? "" : (outputs[parent] ?? parent)
            let renamed = try rename(name, metadata: entry.metadata, opaque: entry.opaque, fields: fields)
            let out = parentOutput.isEmpty ? renamed : parentOutput + "/" + renamed
            guard names.insert(Naming.key(out)).inserted else { throw AppFailure("Case or Unicode name collision: \(out)") }
            if entry.directory { outputs[entry.source] = out }
            entries.append(Entry(source: entry.source, output: out, directory: entry.directory, metadata: entry.metadata,
                                 opaque: entry.opaque, bytes: entry.bytes, modified: entry.modified))
        }
        return CopyPlan(root: structure.root, entries: entries, excluded: structure.excluded)
    }
}

public enum IconService {
    public static let attributes = ["com.apple.FinderInfo", "com.apple.ResourceFork"]
    public static func captureFolderIcon(_ folder: URL) throws -> Data {
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true, let finder = try attribute("com.apple.FinderInfo", at: folder),
              finder.count >= 10, finder[8] & 0x04 != 0 else { throw AppFailure("This folder does not have a custom Finder icon.") }
        let image = NSWorkspace.shared.icon(forFile: folder.path)
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw AppFailure("Cannot capture this folder icon.") }
        return png
    }
    public static func attribute(_ name: String, at url: URL) throws -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0 {
            if errno == ENOATTR { return nil }
            throw AppFailure("Cannot read metadata at \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read == size else { throw AppFailure("Metadata changed while reading \(url.lastPathComponent). Retry the operation.") }
        return data
    }
    public static func copyMetadata(from source: URL, to target: URL) throws {
        for name in attributes {
            if let data = try attribute(name, at: source) {
                let result = data.withUnsafeBytes { setxattr(target.path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
                guard result == 0 else { throw AppFailure("Unable to preserve Finder icon metadata for \(target.lastPathComponent).") }
            }
        }
        if target.lastPathComponent == "Icon\r" {
            var flags = stat()
            guard lstat(target.path, &flags) == 0, chflags(target.path, flags.st_flags | UInt32(UF_HIDDEN)) == 0 else {
                throw AppFailure("Cannot hide the copied Finder icon support file.")
            }
        }
    }
    public static func apply(_ data: Data, to folder: URL) throws {
        guard let image = NSImage(data: data), NSWorkspace.shared.setIcon(image, forFile: folder.path, options: []) else {
            throw AppFailure("Finder could not apply the selected project icon. No project was committed. Check the destination and retry.")
        }
    }
}

public enum CreationEngine {
    public typealias Progress = @Sendable (Double, String) -> Void

    /// Makes an independent, allowlisted-metadata copy into a new destination. Never merges.
    public static func create(plan: CopyPlan, destination: URL, name: String, icon: Data? = nil,
                              cancellation: Cancellation = Cancellation(), progress: Progress = { _, _ in }) throws -> URL {
        try Naming.validate(name)
        try cancellation.check()
        let fm = FileManager.default
        let destination = destination.resolvingSymlinksInPath()
        let values = try destination.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw AppFailure("Destination folder is unavailable. Choose a mounted, writable folder.") }
        guard destination != plan.root, !destination.path.hasPrefix(plan.root.path + "/") else {
            throw AppFailure("Destination must be outside the template being copied.")
        }
        let final = destination.appendingPathComponent(name)
        guard !fm.fileExists(atPath: final.path) else { throw AppFailure("A project named ‘\(name)’ already exists. Nothing has been overwritten.") }
        let stage = destination.appendingPathComponent(".project-templates-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? fm.removeItem(at: stage) } }
        var completed: Int64 = 0
        var lastProgress = Date.distantPast
        for entry in plan.entries {
            try cancellation.check()
            let source = plan.root.appendingPathComponent(entry.source)
            let target = stage.appendingPathComponent(entry.output)
            // Plans are internal, but enforce containment again at the writing boundary.
            guard source.standardizedFileURL.path.hasPrefix(plan.root.path + "/"),
                  source.resolvingSymlinksInPath().path == source.standardizedFileURL.path,
                  target.standardizedFileURL.path.hasPrefix(stage.path + "/") else {
                throw AppFailure("Template path changed or escaped its root. Nothing was committed.")
            }
            let current = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            guard current.isSymbolicLink != true, (current.isDirectory == true) == entry.directory,
                  entry.directory || (Int64(current.fileSize ?? 0) == entry.bytes && current.contentModificationDate == entry.modified) else {
                throw AppFailure("Template changed since preview: \(entry.source). Refresh the preview and retry.")
            }
            if entry.directory {
                try fm.createDirectory(at: target, withIntermediateDirectories: false)
            } else {
                let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
                guard descriptor >= 0 else { throw AppFailure("Cannot read \(entry.source). Check access and download any cloud-only files first.") }
                let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? input.close() }
                guard fm.createFile(atPath: target.path, contents: nil) else { throw AppFailure("Cannot create \(entry.output). Check free space and permissions.") }
                let output = try FileHandle(forWritingTo: target)
                defer { try? output.close() }
                while true {
                    try cancellation.check()
                    guard let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
                    try output.write(contentsOf: chunk)
                    completed += Int64(chunk.count)
                    if Date().timeIntervalSince(lastProgress) > 0.08 {
                        progress(Double(completed) / Double(max(plan.bytes, 1)), entry.output)
                        lastProgress = Date()
                    }
                }
                try output.synchronize()
                let copied = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard Int64(copied) == entry.bytes, after.contentModificationDate == entry.modified else {
                    throw AppFailure("File changed during copying: \(entry.source). Nothing was committed.")
                }
                try IconService.copyMetadata(from: source, to: target)
            }
        }
        // Directory metadata follows children, so the custom-icon flag and Icon\r arrive together.
        for entry in plan.entries.reversed() where entry.directory {
            try cancellation.check()
            try IconService.copyMetadata(from: plan.root.appendingPathComponent(entry.source), to: stage.appendingPathComponent(entry.output))
        }
        try IconService.copyMetadata(from: plan.root, to: stage)
        if let icon { try IconService.apply(icon, to: stage) }
        try cancellation.check()
        progress(1, "Finalising")
        // RENAME_EXCL prevents a late destination race from replacing another project's folder.
        guard renamex_np(stage.path, final.path, UInt32(RENAME_EXCL)) == 0 else {
            throw AppFailure("Could not finalise without replacing an existing path: \(String(cString: strerror(errno))). Nothing was overwritten.")
        }
        committed = true
        progress(1, "Complete")
        return final
    }
}
