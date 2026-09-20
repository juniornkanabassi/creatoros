import Foundation

/// Resolves browser drop locations without giving UI code unchecked paths.
public enum BrowserDropRoute {
    public static func destination(root: URL, displayed: String, target: String?) throws -> URL {
        let relative = target ?? displayed
        return relative.isEmpty ? root : try Catalogue.safeChild(relative, under: root)
    }

    public static func isNoOp(_ sources: [URL], destination: URL, forceCopy: Bool) -> Bool {
        !forceCopy && !sources.isEmpty && sources.allSatisfy {
            $0.deletingLastPathComponent().standardizedFileURL == destination.standardizedFileURL
        }
    }
}
