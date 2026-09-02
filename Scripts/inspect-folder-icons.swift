import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else { fatalError("Usage: inspect-folder-icons.swift output-directory folder…") }
let output = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (index, path) in args.dropFirst(2).enumerated() {
    let image = NSWorkspace.shared.icon(forFile: path)
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { fatalError("Cannot read icon") }
    let target = output.appendingPathComponent("icon-\(index).png")
    try png.write(to: target)
    print("\(target.path) <- \(path)")
}
