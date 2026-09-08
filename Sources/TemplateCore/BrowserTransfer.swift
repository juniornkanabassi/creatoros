import Foundation
import Darwin

public struct BrowserTransferFailure: LocalizedError {
    public let committed: [URL]
    public let cause: Error
    public var errorDescription: String? {
        let result = committed.isEmpty ? "No files were copied." : "Copied: " + committed.map(\.lastPathComponent).joined(separator: ", ") + ". These copies remain."
        return cause.localizedDescription + " " + result + " Original files were not moved or deleted."
    }
}

/// Explicit browser copies only; listing a folder does not read file contents.
public enum BrowserTransfer {
    public static func dragURL(root: URL, relative: String) throws -> URL {
        _ = try ordinaryPath(root, directory: true)
        return try ordinaryPath(Catalogue.safeChild(relative, under: root), directory: false)
    }

    public static func copyFiles(_ sources: [URL], into destination: URL, runtime: AppRuntime,
                                 cancellation: Cancellation = Cancellation(), progress: (Int, Int) -> Void = { _, _ in }) throws -> [URL] {
        var committed: [URL] = []
        do {
            try cancellation.check()
            guard !sources.isEmpty, sources.count <= 100 else { throw AppFailure("Drop between 1 and 100 files at a time.") }
            try runtime.requireWritable(destination)
            let destination = try ordinaryPath(destination, directory: true)
            var names = Set(try FileManager.default.contentsOfDirectory(atPath: destination.path).map(Naming.key))
            // Validate the complete batch before creating any staging files.
            let candidates = try sources.map { source -> URL in
                try cancellation.check()
                let source = try ordinaryPath(source, directory: false)
                guard names.insert(Naming.key(source.lastPathComponent)).inserted else {
                    throw AppFailure("A file named ‘\(source.lastPathComponent)’ already exists or appears twice in this drop (including case or Unicode variants).")
                }
                return source
            }
            for source in candidates {
                try cancellation.check()
                try runtime.requireWritable(destination)
                _ = try ordinaryPath(destination, directory: true)
                let final = destination.appendingPathComponent(source.lastPathComponent)
                let stage = destination.appendingPathComponent(".creatoros-drop-" + UUID().uuidString)
                try copy(source, to: stage, cancellation: cancellation)
                defer { try? FileManager.default.removeItem(at: stage) }
                try cancellation.check()
                try runtime.requireWritable(final)
                // Recheck normalised names too, including on case-sensitive volumes.
                guard !(try FileManager.default.contentsOfDirectory(atPath: destination.path)).contains(where: {
                    Naming.key($0) == Naming.key(final.lastPathComponent)
                }) else { throw AppFailure("A file named ‘\(final.lastPathComponent)’ appeared during the copy.") }
                guard renamex_np(stage.path, final.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw AppFailure("Cannot finish the copy without replacing an existing file: \(String(cString: strerror(errno))).")
                }
                committed.append(final)
                progress(committed.count, candidates.count)
            }
            return committed
        } catch { throw BrowserTransferFailure(committed: committed, cause: error) }
    }

    private static func ordinaryPath(_ url: URL, directory: Bool) throws -> URL {
        guard url.isFileURL else { throw AppFailure("Drop local files from Finder, not web links.") }
        var path = url.standardizedFileURL.path
        if path == "/tmp" || path.hasPrefix("/tmp/") || path == "/var" || path.hasPrefix("/var/") { path = "/private" + path }
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += "/" + component
            var info = stat()
            guard lstat(prefix, &info) == 0, (info.st_mode & mode_t(S_IFMT)) != mode_t(S_IFLNK) else {
                throw AppFailure("A file or folder is missing, unavailable or uses a symbolic link: \(prefix)")
            }
            let part = URL(fileURLWithPath: prefix)
            guard !TemplateReader.packages.contains(part.pathExtension.lowercased()),
                  try part.resourceValues(forKeys: [.isPackageKey]).isPackage != true else {
                throw AppFailure("Folders, packages and their internal files cannot be transferred here.")
            }
        }
        let result = URL(fileURLWithPath: path)
        let values = try result.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isHiddenKey])
        let name = result.lastPathComponent
        guard directory ? values.isDirectory == true : values.isRegularFile == true,
              !name.hasPrefix("."), name != "Icon\r", values.isHidden != true else {
            throw AppFailure(directory ? "Choose an existing ordinary destination folder." : "Only ordinary visible files can be transferred; folders and metadata files are excluded.")
        }
        return result
    }

    private static func copy(_ source: URL, to stage: URL, cancellation: Cancellation) throws {
        _ = try ordinaryPath(source, directory: false)
        let inputFD = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard inputFD >= 0 else { throw AppFailure("Cannot read \(source.lastPathComponent). Download cloud-only files first.") }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat()
        guard fstat(inputFD, &before) == 0, (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw AppFailure("Source is no longer an ordinary file.") }
        guard before.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0 else {
            throw AppFailure("Unlock \(source.lastPathComponent) before copying it here; its locked attributes would prevent staging cleanup.")
        }
        let outputFD = Darwin.open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard outputFD >= 0 else { throw AppFailure("Cannot create the temporary copy. Check space and folder access.") }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close() }
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: stage) } }
        var bytes: Int64 = 0
        while true {
            try cancellation.check()
            guard let data = try input.read(upToCount: 1_048_576), !data.isEmpty else { break }
            try output.write(contentsOf: data)
            bytes += Int64(data.count)
        }
        guard fcopyfile(inputFD, outputFD, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
            throw AppFailure("Cannot preserve file attributes for \(source.lastPathComponent): \(String(cString: strerror(errno))).")
        }
        var after = stat()
        guard fstat(inputFD, &after) == 0, bytes == before.st_size, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw AppFailure("\(source.lastPathComponent) changed while being copied. Retry when it has finished saving.")
        }
        try output.synchronize()
        finished = true
    }
}
