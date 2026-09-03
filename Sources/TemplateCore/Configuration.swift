import Foundation

public enum Configuration {
    public static func fieldName(_ name: String, others: [String]) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= 80,
              clean.rangeOfCharacter(from: .controlCharacters.union(CharacterSet(charactersIn: "[]"))) == nil else {
            throw AppFailure("Use a field name of 1–80 bytes without brackets or control characters.")
        }
        let reserved = ["template", "Project Number", "Content Format", "Content Form", "Conent Form", "Campaign", "Project Name"]
        guard !(reserved + others).contains(where: { Naming.key($0) == Naming.key(clean) }) else {
            throw AppFailure("‘\(clean)’ is already used or reserved. Choose another field name.")
        }
        return clean
    }
    public static func stages(_ names: [String]) throws -> [String] {
        let clean = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard clean.count >= 2, clean.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 80 && $0.rangeOfCharacter(from: .controlCharacters) == nil }),
              Set(clean.map(Naming.key)).count == clean.count else {
            throw AppFailure("Keep at least two stages with distinct, non-empty names of at most 80 bytes.")
        }
        return clean
    }
}
