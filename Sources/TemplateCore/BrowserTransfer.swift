import Foundation
import Darwin

public struct BrowserTransferFailure: LocalizedError {
    public let committed: [URL]
    public let moved: [URL]
    public var copied: [URL] { committed.filter { !moved.contains($0) } }
    public let cause: Error
    public var errorDescription: String? {
        let result = committed.isEmpty ? "No files were transferred." :
            "Completed transfers remain." +
            (copied.isEmpty ? "" : " Copied: " + copied.map(\.lastPathComponent).joined(separator: ", ") + ". Originals remain.") +
            (moved.isEmpty ? "" : " Moved: " + moved.map(\.lastPathComponent).joined(separator: ", ") + ". These files are now in the destination.")
        return cause.localizedDescription + " " + result
    }
}

/// Explicit browser transfers only; listing a folder does not read file contents.
public enum BrowserTransfer {
    public static func dragURL(root: URL, relative: String) throws -> URL {
        _ = try ordinaryPath(root, directory: true)
        return try ordinaryPath(Catalogue.safeChild(relative, under: root), directory: false)
    }

    public static func copyFiles(_ sources: [URL], into destination: URL, runtime: AppRuntime,
                                 cancellation: Cancellation = Cancellation(), progress: (Int, Int) -> Void = { _, _ in }) throws -> [URL] {
        try transferFiles(sources, into: destination, runtime: runtime, forceCopy: true, cancellation: cancellation, progress: progress)
    }

    public static func shouldMove(sourceDevice: dev_t, destinationDevice: dev_t, forceCopy: Bool) -> Bool {
        !forceCopy && sourceDevice == destinationDevice
    }

    public static func transferFiles(_ sources: [URL], into destination: URL, runtime: AppRuntime, forceCopy: Bool = false,
                                     cancellation: Cancellation = Cancellation(), progress: (Int, Int) -> Void = { _, _ in }) throws -> [URL] {
        var committed: [URL] = []
        var moved: [URL] = []
        do {
            try cancellation.check()
            guard !sources.isEmpty, sources.count <= 100 else { throw AppFailure("Drop between 1 and 100 files at a time.") }
            try runtime.requireWritable(destination)
            let destination = try ordinaryPath(destination, directory: true)
            let destinationInfo = try identity(destination)
            var names = Set(try FileManager.default.contentsOfDirectory(atPath: destination.path).map(Naming.key))
            // Validate the complete batch before creating any staging files.
            let candidates = try sources.map { source -> (url: URL, info: stat, parent: stat, move: Bool) in
                try cancellation.check()
                let source = try ordinaryPath(source, directory: false)
                guard names.insert(Naming.key(source.lastPathComponent)).inserted else {
                    throw AppFailure("A file named ‘\(source.lastPathComponent)’ already exists or appears twice in this drop (including case or Unicode variants).")
                }
                let info = try identity(source)
                let parent = try identity(source.deletingLastPathComponent())
                guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                      info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0 else {
                    throw AppFailure("Unlock \(source.lastPathComponent) before transferring this ordinary file.")
                }
                let move = shouldMove(sourceDevice: info.st_dev, destinationDevice: destinationInfo.st_dev, forceCopy: forceCopy)
                if move { try requireMove(source, runtime: runtime) }
                return (source, info, parent, move)
            }
            for candidate in candidates {
                let source = candidate.url
                try cancellation.check()
                try runtime.requireWritable(destination)
                _ = try ordinaryPath(destination, directory: true)
                try verifyIdentity(destination, expected: destinationInfo)
                _ = try ordinaryPath(source, directory: false)
                try verifyIdentity(source, expected: candidate.info)
                try verifyIdentity(source.deletingLastPathComponent(), expected: candidate.parent)
                let final = destination.appendingPathComponent(source.lastPathComponent)
                let stage = destination.appendingPathComponent(".creatoros-drop-" + UUID().uuidString)
                if !candidate.move { try copy(source, to: stage, expected: candidate.info, cancellation: cancellation) }
                defer { if !candidate.move { try? FileManager.default.removeItem(at: stage) } }
                try cancellation.check()
                try runtime.requireWritable(final)
                try verifyIdentity(destination, expected: destinationInfo)
                try verifyIdentity(source, expected: candidate.info)
                try verifyIdentity(source.deletingLastPathComponent(), expected: candidate.parent)
                if candidate.move { try requireMove(source, runtime: runtime) }
                // Recheck normalised names too, including on case-sensitive volumes.
                guard !(try FileManager.default.contentsOfDirectory(atPath: destination.path)).contains(where: {
                    Naming.key($0) == Naming.key(final.lastPathComponent)
                }) else { throw AppFailure("A file named ‘\(final.lastPathComponent)’ appeared during the transfer.") }
                guard renamex_np((candidate.move ? source : stage).path, final.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw AppFailure("Cannot finish the transfer safely: \(String(cString: strerror(errno))).")
                }
                committed.append(final)
                if candidate.move { moved.append(final) }
                progress(committed.count, candidates.count)
            }
            return committed
        } catch { throw BrowserTransferFailure(committed: committed, moved: moved, cause: error) }
    }

    private static func identity(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw AppFailure("Cannot verify \(url.lastPathComponent).") }
        return info
    }

    private static func verifyIdentity(_ url: URL, expected: stat) throws {
        let current = try identity(url)
        guard current.st_dev == expected.st_dev, current.st_ino == expected.st_ino,
              current.st_mode & mode_t(S_IFMT) == expected.st_mode & mode_t(S_IFMT) else {
            throw AppFailure("\(url.lastPathComponent) changed during the transfer. Please retry.")
        }
    }

    private static func requireMove(_ source: URL, runtime: AppRuntime) throws {
        // Only explicit regular-file transfers relax source isolation; all destinations remain guarded.
        let libraryRoots = [runtime.root, AppRuntime.alphaRoot, AppRuntime.stableRoot]
        guard !libraryRoots.contains(where: { root in
            Naming.key(source.deletingLastPathComponent().path) == Naming.key(root.path) ||
            Naming.key(source.path).hasPrefix(Naming.key(root.appendingPathComponent("Templates").path) + "/")
        }) else {
            throw AppFailure("Library files and managed templates cannot be moved. Hold Option while dropping to copy instead.")
        }
        let parent = source.deletingLastPathComponent()
        let info = try identity(parent)
        guard access(parent.path, W_OK | X_OK) == 0,
              info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0 else {
            throw AppFailure("The source folder is read-only or locked. Hold Option while dropping to copy instead.")
        }
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

    private static func copy(_ source: URL, to stage: URL, expected: stat, cancellation: Cancellation) throws {
        _ = try ordinaryPath(source, directory: false)
        let inputFD = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard inputFD >= 0 else { throw AppFailure("Cannot read \(source.lastPathComponent). Download cloud-only files first.") }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat()
        guard fstat(inputFD, &before) == 0, (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_dev == expected.st_dev, before.st_ino == expected.st_ino else { throw AppFailure("Source is no longer the same ordinary file.") }
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
