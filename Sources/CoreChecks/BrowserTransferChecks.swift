import Foundation
import TemplateCore

func browserTransferChecks(base: URL) throws {
    let fm = FileManager.default
    let area = base.appendingPathComponent("Browser transfer")
    let external = base.appendingPathComponent("Downloads")
    let destination = area.appendingPathComponent("Project/Media")
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    let runtime = try AppRuntime(root: area)
    try check(try BrowserDropRoute.destination(root: area, displayed: "Project", target: "Project/Media").resolvingSymlinksInPath() == destination.resolvingSymlinksInPath(), "folder-row drop targets that folder")
    try check(try BrowserDropRoute.destination(root: area, displayed: "Project/Media", target: nil).resolvingSymlinksInPath() == destination.resolvingSymlinksInPath(), "blank drop targets displayed folder")
    try check(try BrowserDropRoute.destination(root: area, displayed: "Project/Media", target: "").resolvingSymlinksInPath() == area.resolvingSymlinksInPath(), "ancestor root-column blank drop targets that column")
    try rejects("folder-row target traversal") { _ = try BrowserDropRoute.destination(root: area, displayed: "Project", target: "../Downloads") }
    // A local row drag whose target is a file, not a folder, must never move anything.
    let fileTarget = destination.appendingPathComponent("notes.txt")
    try put(Data("notes".utf8), at: fileTarget)
    let stray = external.appendingPathComponent("stray.txt")
    try put(Data("stray".utf8), at: stray)
    let fileRoute = try BrowserDropRoute.destination(root: area, displayed: "Project", target: "Project/Media/notes.txt")
    try rejects("file-row target is refused as a destination") { _ = try BrowserTransfer.transferFiles([stray], into: fileRoute, runtime: runtime) }
    try check(Data(contentsOf: stray) == Data("stray".utf8) && Data(contentsOf: fileTarget) == Data("notes".utf8), "refused file-row drop leaves source and target untouched")
    try fm.removeItem(at: fileTarget)
    try fm.removeItem(at: stray)
    // Folder moves: same-volume rename after every guard; nothing else.
    let folder = area.appendingPathComponent("Project/Raw")
    let inner = folder.appendingPathComponent("clip.txt")
    try put(Data("clip".utf8), at: inner)
    try rejects("folder move into itself") { _ = try BrowserTransfer.moveFolder(folder, into: folder, runtime: runtime) }
    try rejects("folder move into own descendant") { _ = try BrowserTransfer.moveFolder(folder, into: inner.deletingLastPathComponent(), runtime: runtime) }
    try fm.createDirectory(at: destination.appendingPathComponent("raw"), withIntermediateDirectories: true)
    try rejects("folder move case-folded name collision") { _ = try BrowserTransfer.moveFolder(folder, into: destination, runtime: runtime) }
    try fm.removeItem(at: destination.appendingPathComponent("raw"))
    try rejects("folder move outside the writable root") { _ = try BrowserTransfer.moveFolder(folder, into: fm.temporaryDirectory, runtime: runtime) }
    let movedFolder = try BrowserTransfer.moveFolder(folder, into: destination, runtime: runtime)
    try check(movedFolder.lastPathComponent == "Raw" && fm.fileExists(atPath: destination.appendingPathComponent("Raw").path) && !fm.fileExists(atPath: folder.path)
              && Data(contentsOf: movedFolder.appendingPathComponent("clip.txt")) == Data("clip".utf8), "folder move renames within the volume and keeps contents")
    // Dropped folder row: the shared transfer entry moves it as a folder, drags resolve folder rows, Option is refused.
    try check(try BrowserTransfer.dragURL(root: area, relative: "Project/Media/Raw").lastPathComponent == "Raw", "outbound drag resolves a folder row")
    try rejects("dropped folder with Option is refused") { _ = try BrowserTransfer.transfer([movedFolder], into: area, runtime: runtime, forceCopy: true) }
    let back = try BrowserTransfer.transfer([movedFolder], into: folder.deletingLastPathComponent(), runtime: runtime)
    try check(back.count == 1 && fm.fileExists(atPath: folder.appendingPathComponent("clip.txt").path) && !fm.fileExists(atPath: movedFolder.path), "dropped folder row moves through the shared transfer entry")
    // Several folders in one drop: one refusal leaves every folder where it was.
    let audio = area.appendingPathComponent("Project/Audio")
    try fm.createDirectory(at: audio, withIntermediateDirectories: true)
    try fm.createDirectory(at: destination.appendingPathComponent("audio"), withIntermediateDirectories: true)
    try rejects("multi-folder drop refuses the batch on one collision") { _ = try BrowserTransfer.transfer([folder, audio], into: destination, runtime: runtime) }
    try check(fm.fileExists(atPath: folder.path) && fm.fileExists(atPath: audio.path) && !fm.fileExists(atPath: destination.appendingPathComponent("Raw").path), "refused multi-folder drop moves nothing")
    try fm.removeItem(at: destination.appendingPathComponent("audio"))
    let both = try BrowserTransfer.transfer([folder, audio], into: destination, runtime: runtime)
    try check(both.count == 2 && fm.fileExists(atPath: destination.appendingPathComponent("Audio").path) && fm.fileExists(atPath: destination.appendingPathComponent("Raw/clip.txt").path), "multi-folder drop moves every folder")
    for url in both { try fm.removeItem(at: url) }
    let mixedFolder = area.appendingPathComponent("Inbox/Mixed")
    try put(Data("keep".utf8), at: mixedFolder.appendingPathComponent("inside.txt"))
    let mixedFile = area.appendingPathComponent("Inbox/collision.txt")
    try put(Data("keep".utf8), at: mixedFile)
    try put(Data("existing".utf8), at: destination.appendingPathComponent("collision.txt"))
    try rejects("mixed drop preflights files before moving folders") { _ = try BrowserTransfer.transfer([mixedFolder, mixedFile], into: destination, runtime: runtime) }
    try check(fm.fileExists(atPath: mixedFolder.path) && Data(contentsOf: mixedFile) == Data("keep".utf8), "mixed refusal preserves every source")
    try fm.removeItem(at: destination.appendingPathComponent("collision.txt"))
    let cancelledMixed = Cancellation()
    do {
        _ = try BrowserTransfer.transfer([mixedFolder, mixedFile], into: destination, runtime: runtime, cancellation: cancelledMixed, progress: { _, _ in cancelledMixed.cancel() })
    } catch { throw AppFailure("Unexpected completed mixed batch failure: " + error.localizedDescription) }
    try check(fm.fileExists(atPath: destination.appendingPathComponent("Mixed/inside.txt").path), "valid mixed batch moves folder and file")
    try rejects("library root cannot move") { _ = try BrowserTransfer.moveFolder(area, into: destination, runtime: runtime) }
    let protectedRuntime = try AppRuntime(root: area.appendingPathComponent("Library"))
    try fm.createDirectory(at: protectedRuntime.root, withIntermediateDirectories: true)
    try rejects("library ancestor cannot move") { _ = try BrowserTransfer.moveFolder(area, into: base.appendingPathComponent("Downloads"), runtime: protectedRuntime) }
    let rollbackFolder = area.appendingPathComponent("Inbox/Rollback")
    let rollbackFirst = area.appendingPathComponent("Inbox/rollback-first.txt")
    let rollbackSecond = area.appendingPathComponent("Inbox/rollback-second.txt")
    try put(Data("keep".utf8), at: rollbackFolder.appendingPathComponent("inside.txt"))
    try put(Data("first".utf8), at: rollbackFirst); try put(Data("second".utf8), at: rollbackSecond)
    let rollbackCancel = Cancellation()
    do {
        _ = try BrowserTransfer.transfer([rollbackFolder, rollbackFirst, rollbackSecond], into: destination, runtime: runtime,
                                        cancellation: rollbackCancel, progress: { _, _ in rollbackCancel.cancel() })
        throw AppFailure("FAILED: mixed cancellation")
    } catch let failure as BrowserTransferFailure {
        try check(failure.committed.count == 1 && failure.moved.count == 1 && fm.fileExists(atPath: rollbackFolder.path), "mixed later failure restores folders and honestly reports committed file")
        try check(Data(contentsOf: rollbackSecond) == Data("second".utf8), "mixed cancellation retains uncommitted file")
    }
    let original = external.appendingPathComponent("Template [take 2].mov")
    let bytes = Data("opaque movie bytes\u{0}".utf8)
    try put(bytes, at: original)
    try check(BrowserDropRoute.isNoOp([original], destination: external, forceCopy: false), "same-folder move is a no-op")
    try check(!BrowserDropRoute.isNoOp([original], destination: external, forceCopy: true), "same-folder Option copy still reaches no-overwrite checks")
    let modified = Date(timeIntervalSince1970: 1_700_000_000)
    try fm.setAttributes([.modificationDate: modified, .posixPermissions: 0o640], ofItemAtPath: original.path)
    let copied = try BrowserTransfer.copyFiles([original], into: destination, runtime: runtime)
    try check(copied.count == 1 && copied[0].lastPathComponent == original.lastPathComponent, "drop keeps literal Template and bracket names")
    try check(Data(contentsOf: copied[0]) == bytes && Data(contentsOf: original) == bytes, "drop copies bytes and retains external source")
    try check(fm.attributesOfItem(atPath: copied[0].path)[.posixPermissions] as? Int == 0o640, "drop retains source permissions")
    try check(fm.attributesOfItem(atPath: copied[0].path)[.modificationDate] as? Date == modified, "drop retains modification date")
    try check(BrowserTransfer.dragURL(root: area, relative: "Project/Media/" + original.lastPathComponent) == copied[0], "outbound drag resolves regular file")
    try rejects("drop existing file collision") { _ = try BrowserTransfer.copyFiles([original], into: destination, runtime: runtime) }
    let fresh = external.appendingPathComponent("fresh.txt")
    try put(Data("fresh".utf8), at: fresh)
    try rejects("drop preflights whole batch before copying") { _ = try BrowserTransfer.copyFiles([fresh, original], into: destination, runtime: runtime) }
    try check(!fm.fileExists(atPath: destination.appendingPathComponent("fresh.txt").path), "preflight collision leaves earlier candidate absent")
    try rejects("drop duplicate batch name") { _ = try BrowserTransfer.copyFiles([fresh, fresh], into: destination, runtime: runtime) }
    let caseVariant = external.appendingPathComponent("FRESH.TXT")
    try put(Data(), at: caseVariant)
    try rejects("drop case-folded batch collision") { _ = try BrowserTransfer.copyFiles([fresh, caseVariant], into: destination, runtime: runtime) }
    let unicode = external.appendingPathComponent("cafe\u{301}.txt")
    try put(Data(), at: unicode)
    try put(Data(), at: destination.appendingPathComponent("CAFÉ.txt"))
    try rejects("drop Unicode destination collision") { _ = try BrowserTransfer.copyFiles([unicode], into: destination, runtime: runtime) }
    try rejects("drop missing destination") { _ = try BrowserTransfer.copyFiles([fresh], into: area.appendingPathComponent("missing"), runtime: runtime) }
    try rejects("drop outside runtime") { _ = try BrowserTransfer.copyFiles([fresh], into: external, runtime: runtime) }
    let link = external.appendingPathComponent("link.txt")
    try fm.createSymbolicLink(at: link, withDestinationURL: fresh)
    try rejects("drop symlink source") { _ = try BrowserTransfer.copyFiles([link], into: destination, runtime: runtime) }
    let folderLink = area.appendingPathComponent("linked")
    try fm.createSymbolicLink(at: folderLink, withDestinationURL: external)
    try rejects("drop symlink source ancestor") { _ = try BrowserTransfer.copyFiles([folderLink.appendingPathComponent("fresh.txt")], into: destination, runtime: runtime) }
    try rejects("drop symlink destination") { _ = try BrowserTransfer.copyFiles([fresh], into: folderLink, runtime: runtime) }
    try rejects("outbound traversal") { _ = try BrowserTransfer.dragURL(root: area, relative: "../Downloads/fresh.txt") }
    try rejects("outbound symlink") { _ = try BrowserTransfer.dragURL(root: area, relative: "linked/fresh.txt") }
    let packageFile = area.appendingPathComponent("Example.rtfd/text.txt")
    try put(Data(), at: packageFile)
    try rejects("outbound package internals") { _ = try BrowserTransfer.dragURL(root: area, relative: "Example.rtfd/text.txt") }
    try rejects("drop package internals") { _ = try BrowserTransfer.copyFiles([packageFile], into: destination, runtime: runtime) }
    try rejects("drop folders") { _ = try BrowserTransfer.copyFiles([external], into: destination, runtime: runtime) }
    let metadata = external.appendingPathComponent("._hidden.txt")
    try put(Data(), at: metadata)
    try rejects("drop metadata") { _ = try BrowserTransfer.copyFiles([metadata], into: destination, runtime: runtime) }
    var finderHidden = external.appendingPathComponent("Finder hidden.txt")
    try put(Data(), at: finderHidden)
    var hiddenValues = URLResourceValues(); hiddenValues.isHidden = true
    try finderHidden.setResourceValues(hiddenValues)
    try rejects("drop Finder-hidden file") { _ = try BrowserTransfer.copyFiles([finderHidden], into: destination, runtime: runtime) }
    try rejects("drop bounded count") { _ = try BrowserTransfer.copyFiles(Array(repeating: fresh, count: 101), into: destination, runtime: runtime) }
    let cancellation = Cancellation(); cancellation.cancel()
    do {
        _ = try BrowserTransfer.copyFiles([fresh], into: destination, runtime: runtime, cancellation: cancellation)
        throw AppFailure("FAILED: drop cancellation")
    } catch let error as BrowserTransferFailure {
        try check(error.committed.isEmpty && error.cause is CancellationError, "drop cancellation reports exact committed list")
    }
    let first = external.appendingPathComponent("first.txt"), second = external.appendingPathComponent("second.txt")
    let firstBytes = Data("retained first copy".utf8)
    try put(firstBytes, at: first); try put(Data("second".utf8), at: second)
    let midCancel = Cancellation()
    do {
        _ = try BrowserTransfer.copyFiles([first, second], into: destination, runtime: runtime, cancellation: midCancel,
                                         progress: { completed, _ in if completed == 1 { midCancel.cancel() } })
        throw AppFailure("FAILED: mid-batch cancellation")
    } catch let error as BrowserTransferFailure {
        try check(error.committed == [runtime.root.appendingPathComponent("Project/Media/first.txt")] && error.cause is CancellationError,
                  "mid-batch cancellation reports exactly the published copy")
        try check(Data(contentsOf: error.committed[0]) == firstBytes && Data(contentsOf: first) == firstBytes,
                  "mid-batch cancellation preserves committed bytes and source")
        try check(!fm.fileExists(atPath: destination.appendingPathComponent("second.txt").path), "mid-batch cancellation leaves next output absent")
    }
    try check(!children(destination).contains(where: { $0.hasPrefix(".creatoros-drop-") }), "drop leaves no staging files")
    try check(BrowserTransfer.shouldMove(sourceDevice: 1, destinationDevice: 1, forceCopy: false), "same device selects move")
    try check(!BrowserTransfer.shouldMove(sourceDevice: 1, destinationDevice: 2, forceCopy: false), "different device selects copy")
    try check(!BrowserTransfer.shouldMove(sourceDevice: 1, destinationDevice: 1, forceCopy: true), "Option selects copy on same device")
    let moveSource = area.appendingPathComponent("Inbox/move.txt")
    try put(bytes, at: moveSource)
    let moved = try BrowserTransfer.transferFiles([moveSource], into: destination, runtime: runtime)
    try check(!fm.fileExists(atPath: moveSource.path) && Data(contentsOf: moved[0]) == bytes, "same-volume transfer moves original bytes")
    let optionSource = external.appendingPathComponent("option.txt")
    try put(bytes, at: optionSource)
    let optionCopy = try BrowserTransfer.transferFiles([optionSource], into: destination, runtime: runtime, forceCopy: true)
    try check(Data(contentsOf: optionSource) == bytes && Data(contentsOf: optionCopy[0]) == bytes, "Option copy retains original bytes")
    let externalBytes = try Data(contentsOf: fresh)
    let externalMove = try BrowserTransfer.transferFiles([fresh], into: destination, runtime: runtime)
    try check(!fm.fileExists(atPath: fresh.path) && Data(contentsOf: externalMove[0]) == externalBytes, "explicit external same-volume drop moves source")
    let managed = area.appendingPathComponent("Templates/payload/managed.txt")
    try put(bytes, at: managed)
    try rejects("managed template source cannot move") { _ = try BrowserTransfer.transferFiles([managed], into: destination, runtime: runtime) }
    let libraryFile = area.appendingPathComponent("library.json")
    try put(bytes, at: libraryFile)
    try rejects("library metadata cannot move") { _ = try BrowserTransfer.transferFiles([libraryFile], into: destination, runtime: runtime) }
    let moveFirst = external.appendingPathComponent("move-first.txt")
    let moveSecond = external.appendingPathComponent("move-second.txt")
    try put(bytes, at: moveFirst); try put(bytes, at: moveSecond)
    try rejects("move preflights complete batch") {
        _ = try BrowserTransfer.transferFiles([moveFirst, optionSource], into: destination, runtime: runtime)
    }
    try check(Data(contentsOf: moveFirst) == bytes && Data(contentsOf: optionSource) == bytes, "move collision preserves every source")
    let moveCancel = Cancellation()
    do {
        _ = try BrowserTransfer.transferFiles([moveFirst, moveSecond], into: destination, runtime: runtime, cancellation: moveCancel,
                                              progress: { completed, _ in if completed == 1 { moveCancel.cancel() } })
        throw AppFailure("FAILED: partial move cancellation")
    } catch let error as BrowserTransferFailure {
        try check(error.committed == error.moved && error.moved.count == 1 && error.copied.isEmpty && error.cause is CancellationError,
                  "partial move cancellation distinguishes moved files")
        try check(!fm.fileExists(atPath: moveFirst.path) && Data(contentsOf: moveSecond) == bytes && Data(contentsOf: error.moved[0]) == bytes,
                  "partial move cancellation leaves committed move and untouched next source")
    }
    let replaced = area.appendingPathComponent("Inbox/replaced.txt")
    let trigger = area.appendingPathComponent("Inbox/trigger.txt")
    try put(bytes, at: replaced); try put(bytes, at: trigger)
    do {
        _ = try BrowserTransfer.transferFiles([trigger, replaced], into: destination, runtime: runtime, progress: { completed, _ in
            if completed == 1 {
                try! fm.moveItem(at: replaced, to: replaced.appendingPathExtension("old"))
                try! put(Data("replacement".utf8), at: replaced)
            }
        })
        throw AppFailure("FAILED: replaced source identity")
    } catch let error as BrowserTransferFailure {
        try check(error.moved.count == 1 && Data(contentsOf: replaced) == Data("replacement".utf8), "source replacement fails without moving replacement")
    }
}
