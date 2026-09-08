import Foundation
import TemplateCore

func browserTransferChecks(base: URL) throws {
    let fm = FileManager.default
    let area = base.appendingPathComponent("Browser transfer")
    let external = base.appendingPathComponent("Downloads")
    let destination = area.appendingPathComponent("Project/Media")
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    let runtime = try AppRuntime(root: area)
    let original = external.appendingPathComponent("Template [take 2].mov")
    let bytes = Data("opaque movie bytes\u{0}".utf8)
    try put(bytes, at: original)
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
}
