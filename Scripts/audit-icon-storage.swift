import Foundation
import Darwin

guard CommandLine.arguments.count == 2 else { fatalError("Usage: audit-icon-storage.swift template-folder") }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let keys: [URLResourceKey] = [.isHiddenKey, .isRegularFileKey, .isSymbolicLinkKey]
guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { fatalError("Cannot enumerate template") }
var count = 0; var hidden = 0; var forks = 0
for case let url as URL in enumerator where url.lastPathComponent == "Icon\r" {
    let values = try url.resourceValues(forKeys: Set(keys))
    guard values.isRegularFile == true, values.isSymbolicLink != true else { fatalError("Unexpected icon payload type") }
    count += 1
    if values.isHidden == true { hidden += 1 }
    let bytes = getxattr(url.path, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW)
    if bytes > 0 { forks += 1 }
    print("\(url.deletingLastPathComponent().path): hidden=\(values.isHidden == true), icon resource=\(bytes) bytes")
}
print("SUMMARY \(count) icon support files; \(hidden) hidden; \(forks) with resource data. Read-only audit.")
