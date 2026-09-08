import Foundation
import TemplateCore
import Darwin

func compatibilityChecks(base: URL) throws {
    let fm = FileManager.default
    let source = base.appendingPathComponent("Compatibility source.")
    let destination = base.appendingPathComponent("Compatibility output")
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    let opaque = Data([0, 10, 255, 42, 0])
    try put(opaque, at: source.appendingPathComponent("Bad?/A-roll [take 2].mov"))
    try put(opaque, at: source.appendingPathComponent("[Campaign].txt"))
    try put(opaque, at: source.appendingPathComponent("Café ‘quotes’.txt"))
    try put(Data(), at: source.appendingPathComponent("Icon\r"))
    let audit = try Compatibility.scan(source)
    try check(audit.isComplete && audit.canCopy, "compatibility scan provides an executable complete report")
    try check(audit.findings.contains { $0.path == source.lastPathComponent }, "compatibility includes invalid root name")
    try check(audit.iconFiles.count == 1, "compatibility identifies Finder icon support separately")
    let proposal = try Compatibility.proposal(audit)
    let output = try Compatibility.copy(proposal, destination: destination)
    try check(output.lastPathComponent == "Compatibility source", "corrected copy repairs root")
    try check(Data(contentsOf: output.appendingPathComponent("Bad-/A-roll [take 2].mov")) == opaque, "media bracket names and bytes remain opaque")
    try check(Data(contentsOf: output.appendingPathComponent("[Campaign].txt")) == opaque, "existing token-shaped name remains literal")
    try check(Data(contentsOf: output.appendingPathComponent("Café ‘quotes’.txt")) == opaque, "valid Unicode quotes and accents are preserved")
    try check(fm.fileExists(atPath: source.appendingPathComponent("Bad?/A-roll [take 2].mov").path), "repair preserves original names")
    try check(!fm.fileExists(atPath: output.appendingPathComponent("Icon\r").path), "plain corrected copy omits icon support")
    let manifestData = try Data(contentsOf: output.appendingPathComponent(Compatibility.manifestName))
    let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
    try check((manifest?["renames"] as? [[String: String]])?.isEmpty == false, "corrected copy retains a readable rename manifest")
    try rejects("corrected copy never overwrites") { _ = try Compatibility.copy(proposal, destination: destination) }
    try rejects("corrected destination cannot be inside source") { _ = try Compatibility.copy(proposal, destination: source, name: "Nested") }
    let cancellation = Cancellation(); cancellation.cancel()
    try rejects("compatibility scan cancellation") { _ = try Compatibility.scan(source, cancellation: cancellation) }
    try rejects("corrected copy cancellation") { _ = try Compatibility.copy(proposal, destination: destination, name: "Cancelled", cancellation: cancellation) }
    let limited = try Compatibility.scan(source, maxEntries: 2)
    try check(!limited.isComplete && !limited.canCopy && !limited.skipped.isEmpty, "enumeration limit explicitly blocks repair")
    let shallow = try Compatibility.scan(source, maxDepth: 1)
    try check(!shallow.isComplete, "depth limit is explicit")
    let absent = try Compatibility.scan(base.appendingPathComponent("Missing compatibility root"))
    try check(!absent.isComplete && !absent.errors.isEmpty, "unavailable source is not a clean audit")
    let collision = base.appendingPathComponent("Compatibility collisions")
    for name in ["one?.txt", "one*.txt", "two?.txt", "two*.txt"] { try put(Data(), at: collision.appendingPathComponent(name)) }
    let collisions = try Compatibility.scan(collision)
    try check(collisions.collisions.count == 2 && !collisions.canCopy, "audit collects every corrected sibling collision")
    try rejects("collisions reject proposal before writing") { _ = try Compatibility.proposal(collisions) }
    let linked = base.appendingPathComponent("Compatibility symlink")
    try fm.createSymbolicLink(at: linked, withDestinationURL: source)
    try check(!Compatibility.scan(linked).isComplete, "symbolic-link source rejected")
    try fm.createSymbolicLink(at: collision.appendingPathComponent("outside"), withDestinationURL: destination)
    try check(!Compatibility.scan(collision).isComplete, "nested symbolic link explicitly makes audit incomplete")
    let package = base.appendingPathComponent("Compatibility package")
    try put(opaque, at: package.appendingPathComponent("Notes.rtfd/Text.txt"))
    let packageAudit = try Compatibility.scan(package)
    try check(!packageAudit.packages.isEmpty && packageAudit.canCopy, "safe package internals are audited without renaming")
    let packageOutput = try Compatibility.copy(Compatibility.proposal(packageAudit), destination: destination)
    try check(Data(contentsOf: packageOutput.appendingPathComponent("Notes.rtfd/Text.txt")) == opaque, "package data copies byte for byte")
    try put(opaque, at: package.appendingPathComponent("Notes.rtfd/Bad?.txt"))
    try check(!Compatibility.scan(package).canCopy, "package-internal repair is refused")
    let changed = base.appendingPathComponent("Compatibility changed")
    try put(opaque, at: changed.appendingPathComponent("original.txt"))
    let stale = try Compatibility.proposal(Compatibility.scan(changed))
    try put(opaque, at: changed.appendingPathComponent("new.txt"))
    try rejects("added entries invalidate the preview inventory") { _ = try Compatibility.copy(stale, destination: destination) }
    let fresh = try Compatibility.proposal(Compatibility.scan(changed))
    try rejects("source mutation before commit rejects and cleans stage") {
        _ = try Compatibility.copy(fresh, destination: destination, progress: { _, phase in
            if phase == "Finalising" { try? Data([7]).write(to: changed.appendingPathComponent("original.txt")) }
        })
    }
    try check(!fm.fileExists(atPath: destination.appendingPathComponent(changed.lastPathComponent).path), "failed repair leaves no committed destination")
    try check(fm.contentsOfDirectory(atPath: destination.path).allSatisfy { !$0.hasPrefix(".project-templates-") }, "failed repair cleans owned staging directory")
    let verifyPlan = try Compatibility.proposal(Compatibility.scan(changed))
    try rejects("same-length corruption of staged file rejects commit") {
        _ = try Compatibility.copy(verifyPlan, destination: destination, name: "Corrupt staged output", progress: { _, phase in
            guard phase == "Finalising",
                  let names = try? FileManager.default.contentsOfDirectory(atPath: destination.path),
                  let stage = names.first(where: { $0.hasPrefix(".project-templates-") }) else { return }
            try? Data([9]).write(to: destination.appendingPathComponent(stage).appendingPathComponent("original.txt"))
        })
    }
    try check(!fm.fileExists(atPath: destination.appendingPathComponent("Corrupt staged output").path), "hash mismatch leaves no output")
    try fm.createDirectory(at: changed.appendingPathComponent("Empty"), withIntermediateDirectories: false)
    let inventoryPlan = try Compatibility.proposal(Compatibility.scan(changed))
    for mutation in ["Extra file", "Missing empty directory"] {
        try rejects("staging inventory rejects \(mutation)") {
            _ = try Compatibility.copy(inventoryPlan, destination: destination, name: mutation, progress: { _, phase in
                guard phase == "Finalising",
                      let names = try? FileManager.default.contentsOfDirectory(atPath: destination.path),
                      let stage = names.first(where: { $0.hasPrefix(".project-templates-") }) else { return }
                let folder = destination.appendingPathComponent(stage)
                if mutation == "Extra file" { try? Data([1]).write(to: folder.appendingPathComponent("unexpected.txt")) }
                else { try? FileManager.default.removeItem(at: folder.appendingPathComponent("Empty")) }
            })
        }
        try check(!fm.fileExists(atPath: destination.appendingPathComponent(mutation).path), "inventory mismatch leaves no \(mutation) output")
    }
    try fm.removeItem(at: changed.appendingPathComponent("Empty"))
    let customNamePlan = try Compatibility.proposal(Compatibility.scan(changed))
    let renamed = try Compatibility.copy(customNamePlan, destination: destination, name: "Chosen root")
    let renamedManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: renamed.appendingPathComponent(Compatibility.manifestName))) as? [String: Any]
    let rootRenames = renamedManifest?["renames"] as? [[String: String]]
    try check(rootRenames?.contains(where: { $0["from"] == changed.lastPathComponent && $0["to"] == "Chosen root" }) == true, "manifest records custom root choice")
    let fakeIcon = base.appendingPathComponent("Compatibility icon directory")
    try put(opaque, at: fakeIcon.appendingPathComponent("Icon\r/Important.mov"))
    try check(!Compatibility.scan(fakeIcon).canCopy, "an Icon CR directory is never discarded as metadata")
    for name in ["", ".", "..", "COM¹.txt", "LPT³", "Bad\"name", "bad\n"] {
        try check(!Naming.problems(name).isEmpty, "shared validator rejects \(name.debugDescription)")
        try Naming.validate(Naming.corrected(name))
    }
    try check(Naming.corrected("Café ‘quotes’ [take 2]") == "Café ‘quotes’ [take 2]", "suggestions retain valid Unicode and brackets")
    try Naming.validate(Naming.corrected(String(repeating: "é", count: 200) + ".mov"))
    let prospective = Compatibility.scan(plan: proposal.plan, outerName: "CON")
    try check(prospective.findings.contains { $0.path == "CON" } && !prospective.canCopy, "prospective output audit checks root without claiming executable source snapshot")
    let forked = base.appendingPathComponent("Compatibility resource fork")
    try put(opaque, at: forked.appendingPathComponent("opaque.dat"))
    let forkPath = forked.appendingPathComponent("opaque.dat").path
    let forkResult = opaque.withUnsafeBytes { setxattr(forkPath, "com.apple.ResourceFork", $0.baseAddress, opaque.count, 0, XATTR_NOFOLLOW) }
    try check(forkResult == 0 && !Compatibility.scan(forked).canCopy, "repair refuses to discard opaque resource-fork content")
}
