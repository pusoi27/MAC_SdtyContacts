import Foundation

/// A phone contact extracted from an appointment card screenshot.
/// Swift port of the Python `PhoneContact` dataclass from contacts_generator.
struct PhoneContact: Equatable {
    var childName: String
    var parentName: String
    var phoneNumber: String
    var email: String
    var notes: String = ""

    /// Contact name in the required format: "child name (parent name)".
    var contactName: String {
        let child = childName.trimmingCharacters(in: .whitespaces)
        let parent = parentName.trimmingCharacters(in: .whitespaces)
        if !child.isEmpty && !parent.isEmpty {
            return "\(child) (\(parent))"
        }
        return child.isEmpty ? parent : child
    }

    /// Sets child/parent names from the combined "child (parent)" format.
    mutating func setContactName(_ combinedName: String) {
        let value = combinedName.trimmingCharacters(in: .whitespaces)
        if let match = value.wholeMatch(of: /^(.*?)\s*\((.*?)\)\s*$/) {
            childName = String(match.1).trimmingCharacters(in: .whitespaces)
            parentName = String(match.2).trimmingCharacters(in: .whitespaces)
        } else {
            childName = value
        }
    }

    /// vCard 3.0 (Apple-compatible). FN holds the display name; N is intentionally
    /// left empty to preserve the exact display format without structured-name parsing.
    var vCard: String {
        // Escape backslashes, newlines, and commas in NOTE per RFC 6350.
        let noteEscaped = notes
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ",", with: "\\,")

        let lines = [
            "BEGIN:VCARD",
            "VERSION:3.0",
            "FN:\(contactName)",
            "N:;;;;",
            "TEL;TYPE=CELL:\(phoneNumber)",
            "EMAIL;TYPE=INTERNET:\(email)",
            "NOTE:\(noteEscaped)",
            "END:VCARD",
        ]
        // vCard spec requires CRLF line endings.
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Filesystem-safe filename stem for the exported .vcf file.
    var safeFilename: String {
        var cleaned = contactName.replacingOccurrences(
            of: "[<>:\"/\\\\|?*\\x00-\\x1F]",
            with: "_",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return cleaned.isEmpty ? "contact" : cleaned
    }
}
