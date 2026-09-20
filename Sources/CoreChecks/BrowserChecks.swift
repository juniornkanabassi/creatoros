import Foundation
import TemplateCore

func browserChecks(base: URL) throws {
    let fm = FileManager.default
    let root = base.appendingPathComponent("Browser project")
    try put(Data("opaque project".utf8), at: root.appendingPathComponent("02 Project Files/Premiere/template.prproj"))
    try put(Data("alternate".utf8), at: root.appendingPathComponent("02 Project Files/Premiere/alternate.prproj"))
    try put(Data("after effects".utf8), at: root.appendingPathComponent("02 Project Files/After Effects/project.aep"))
    try fm.createDirectory(at: root.appendingPathComponent("02 Project Files/not-a-file.prproj"), withIntermediateDirectories: true)
    try put(Data("notes".utf8), at: root.appendingPathComponent("01 Documents/Readme.txt"))
    try put(Data(), at: root.appendingPathComponent("Icon\r"))
    try put(Data(), at: root.appendingPathComponent("._support"))
    try put(Data(), at: root.appendingPathComponent(".DS_Store"))
    try put(Data(), at: root.appendingPathComponent(".secret"))
    try put(Data(), at: root.appendingPathComponent("Library.rtfd/hidden.prproj"))
    try put(Data(), at: root.appendingPathComponent("03 Media/unrelated.prproj"))
    try put(Data(), at: root.appendingPathComponent("04 Exports/unrelated.prproj"))
    try put(Data(), at: root.appendingPathComponent("launch.command"))
    try put(Data(), at: root.appendingPathComponent("Application.app/Contents/file"))
    try fm.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: base)
    let items = try ProjectBrowser.list(root: root)
    try check(!items.contains(where: { $0.name == "Icon\r" || $0.name.hasPrefix(".") || $0.name == "outside" }), "browser hides metadata and excludes symbolic links")
    try check(items.contains(where: { $0.name == "Library.rtfd" && $0.package }), "browser treats document packages as single items")
    let projectFiles = try ProjectBrowser.projectFiles(root: root)
    try check(projectFiles.map(\.name) == ["project.aep", "not-a-file.prproj", "alternate.prproj", "template.prproj"], "project document shortcut excludes media, exports and package internals")
    let premiere = try ProjectBrowser.premiereFiles(root: root)
    try check(premiere.map(\.name) == ["alternate.prproj", "template.prproj"], "Premiere shortcut lists only safe Premiere documents")
    try check(ProjectBrowser.openable(premiere[1], root: root).lastPathComponent == "template.prproj", "browser resolves Premiere document directly")
    try rejects("browser refuses package traversal") { _ = try ProjectBrowser.list(root: root, relative: "Library.rtfd") }
    try rejects("browser refuses escaping folder") { _ = try ProjectBrowser.list(root: root, relative: "../") }
    try rejects("browser refuses symbolic-link navigation") { _ = try ProjectBrowser.list(root: root, relative: "outside") }
    for item in items where item.name == "launch.command" || item.name == "Application.app" {
        try rejects("browser refuses executable \(item.name)") { _ = try ProjectBrowser.openable(item, root: root) }
    }
    let cancel = Cancellation(); cancel.cancel()
    try rejects("browser supports cancellation") { _ = try ProjectBrowser.projectFiles(root: root, cancellation: cancel) }
    var wrongDrive = try ProjectRecord(url: root, format: "Short"); wrongDrive.volumeID = "different-volume-identity"
    try rejects("browser validates drive identity") { _ = try ProjectBrowser.root(wrongDrive) }
    let fields = ProjectFields(number: "009", format: "Short", title: "Sample")
    try check(Naming.render("template.prproj", fields: fields) == fields.finalName() + ".prproj", "lowercase template project is renamed")
    try check(Naming.render("TEMPLATE Description.rtf", fields: fields) == fields.finalName() + " Description.rtf", "uppercase template prefix preserves suffix")
    try check(Naming.render("[Template].psd", fields: fields) == fields.finalName() + ".psd", "template token tolerates capitalisation")
    try check(Naming.render("My template.prproj", fields: fields) == "My template.prproj", "embedded word template remains literal")
    let iconSource = base.appendingPathComponent("Visible metadata fixture")
    try put(Data(), at: iconSource.appendingPathComponent("Icon\r"))
    let dest = base.appendingPathComponent("Metadata destination")
    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    let output = try CreationEngine.create(plan: TemplateReader.scan(iconSource), destination: dest, name: "Hidden support")
    let icon = output.appendingPathComponent("Icon\r")
    try check(icon.resourceValues(forKeys: [.isHiddenKey]).isHidden == true, "generated Finder support file is hidden even when source flag was missing")
    try check(ProjectBrowser.list(root: output).isEmpty, "metadata-only folder displays as empty in browser")
}
