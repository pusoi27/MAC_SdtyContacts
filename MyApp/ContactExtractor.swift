import Foundation
import Vision

/// One recognized line of text with its vertical center in the image (0 = top, 1 = bottom).
struct OCRLine: Sendable {
    let text: String
    let centerY: Double
}

/// Extracts contact information from appointment card screenshots using Vision OCR.
/// Swift port of the Python `ContactExtractor` (Tesseract/OpenCV) from contacts_generator.
struct ContactExtractor {
    private let lines: [OCRLine]
    private let fullText: String

    private static let usPhone = #"\(\d{3}\)\s*\d{3}-\d{4}|\(?\d{3}\)?[\s\-.]?\d{3}[\s\-.]?\d{4}|\b\d{10}\b"#
    private static let childToken = #"(?:Child|Chiid|Chlld|Ch1ld|ChiId)"#
    private static let parentEmailStop = #"Parent\s*(?:Email|Emai1|E\s*[-.]?\s*mail|Em)\s*[:;\-]?"#
    private static let parentPhoneStop = #"Parent\s*Ph(?:one)?\s*[:;\-]?"#
    private static let emailPattern = #"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#

    struct ChildBlock {
        let number: String
        let name: String
        let grade: String
        let subject: String
    }

    // MARK: - OCR

    /// Runs Vision text recognition on the image data and extracts a contact.
    static func extract(from imageData: Data) async throws -> PhoneContact {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = ImageRequestHandler(imageData)
        let observations = try await handler.perform(request)

        var lines: [OCRLine] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // Vision bounding boxes use a lower-left origin; flip so 0 = top of image.
            let box = observation.boundingBox.cgRect
            lines.append(OCRLine(text: text, centerY: 1.0 - box.midY))
        }
        lines.sort { $0.centerY < $1.centerY }
        return ContactExtractor(lines: lines).extractContact()
    }

    init(lines: [OCRLine]) {
        self.lines = lines
        self.fullText = lines.map(\.text).joined(separator: "\n")
    }

    func extractContact() -> PhoneContact {
        PhoneContact(
            childName: extractChildName(),
            parentName: extractParentName(),
            phoneNumber: extractPhone(),
            email: extractEmail(),
            notes: extractNotes()
        )
    }

    // MARK: - Field extraction

    /// Lines whose vertical center falls inside the given band (0 = top, 1 = bottom).
    private func sectionLines(from start: Double, to end: Double) -> [OCRLine] {
        lines.filter { $0.centerY >= start && $0.centerY <= end }
    }

    /// Parent name and phone from the top header area, e.g. "Chris Cooper - (305) 793-2424".
    private func extractTopParentHeader() -> (name: String, phone: String) {
        let pattern = "^(?:[^A-Za-z0-9]+\\s*)?([A-Za-z][A-Za-z'\\-.\\s]+?)\\s*[-\u{2013}\u{2014}]\\s*(\(Self.usPhone))\\b"
        for line in sectionLines(from: 0.0, to: 0.30) {
            guard let groups = firstMatch(of: pattern, in: line.text) else { continue }
            let name = normalizePersonName(groups[1])
            let phone = normalizeUSPhone(groups[2])
            if !name.isEmpty && !phone.isEmpty {
                return (name, phone)
            }
        }
        return ("", "")
    }

    private func extractPhone() -> String {
        let header = extractTopParentHeader()
        if !header.name.isEmpty && !header.phone.isEmpty {
            return header.phone
        }

        // Preferred: explicit Parent Phone label line.
        for line in lines.map(\.text) where isParentPhoneLabel(line) {
            let phone = extractUSPhone(from: line)
            if !phone.isEmpty { return phone }
        }

        // Secondary: phone from a "<name> - phone" line.
        for line in lines.map(\.text) {
            if let groups = firstMatch(of: "[-\u{2013}\u{2014}]\\s*(\(Self.usPhone))\\b", in: line) {
                return normalizeUSPhone(groups[1])
            }
        }

        // Fallback: first valid US phone number anywhere in the text.
        if let groups = firstMatch(of: Self.usPhone, in: fullText) {
            return normalizeUSPhone(groups[0])
        }
        return ""
    }

    private func extractEmail() -> String {
        // Preferred: bottom zone with a Parent Email label.
        for line in sectionLines(from: 0.62, to: 0.95) where isParentEmailLabel(line.text) {
            if let groups = firstMatch(of: Self.emailPattern, in: line.text) {
                return trimEmail(groups[0])
            }
        }

        // Any Parent Email label line.
        for line in lines.map(\.text) where isParentEmailLabel(line) {
            if let groups = firstMatch(of: Self.emailPattern, in: line) {
                return trimEmail(groups[0])
            }
        }

        // Fallback: any email in the OCR text.
        if let groups = firstMatch(of: Self.emailPattern, in: fullText) {
            return trimEmail(groups[0])
        }
        return ""
    }

    private func trimEmail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
    }

    /// Structured child blocks: "Child: 1 Name | Grade: X | Subject: Y".
    private func extractChildBlocks() -> [ChildBlock] {
        let pattern = "\(Self.childToken)\\s*[:;\\-]?\\s*(\\d+)?\\s*(.*?)(?=\(Self.childToken)\\s*[:;\\-]?\\s*\\d+|\(Self.parentEmailStop)|\(Self.parentPhoneStop)|Appointment|(?:My\\s+)?Notes\\s*[:;\\-]?|$)"
        var blocks: [ChildBlock] = []
        var autoIndex = 1

        for match in allMatches(of: pattern, in: fullText, dotAll: true) {
            var number = match[1].trimmingCharacters(in: .whitespaces)
            if number.isEmpty {
                number = String(autoIndex)
            }
            autoIndex += 1

            var blockText = match[2].replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            blockText = blockText.trimmingCharacters(in: CharacterSet(charactersIn: " -|:\n\t"))

            // Child name is expected immediately after "Child: #" and before Grade/Subject tokens.
            var name = ""
            if let groups = firstMatch(
                of: "^([A-Za-z][A-Za-z'\\-\\s]+?)(?=\\s*(?:\\|\\s*)?(?:Grade\\s*[:;\\-]?|Subject\\s*[:;\\-]?)|$)",
                in: blockText
            ) {
                name = normalizePersonName(groups[1])
            }

            var grade = ""
            if let groups = firstMatch(of: "Grade\\s*[:;\\-]?\\s*([A-Za-z0-9]+)", in: blockText) {
                grade = groups[1]
            }

            var subject = ""
            if let groups = firstMatch(
                of: "Subject\\s*[:;\\-]?\\s*([A-Za-z0-9&,/\\-\\s]+?)(?=\\s*(?:\(Self.parentEmailStop)|\(Self.parentPhoneStop)|Appointment|Center|Created|$))",
                in: blockText
            ) {
                subject = groups[1].replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                // Trim trailing noise such as day names or footer labels.
                if let range = subject.range(
                    of: #"\b(?:Parent|Appointment|Center|Created|Saturday|Sunday|Monday|Tuesday|Wednesday|Thursday|Friday)\b"#,
                    options: [.regularExpression, .caseInsensitive]
                ) {
                    subject = String(subject[..<range.lowerBound])
                }
                subject = subject.trimmingCharacters(in: CharacterSet(charactersIn: " ,;|-"))
            }

            if !name.isEmpty || !grade.isEmpty || !subject.isEmpty {
                blocks.append(ChildBlock(number: number, name: name, grade: grade, subject: subject))
            }
        }
        return blocks
    }

    private func extractChildNames() -> [String] {
        var unique: [String] = []
        var seen = Set<String>()
        for block in extractChildBlocks() where !block.name.isEmpty {
            let key = block.name.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(block.name)
            }
        }

        // Collapse prefix duplicates (e.g. "Trenton" vs "Trenton Liggins"), keeping the longer name.
        return unique.filter { name in
            !unique.contains { other in
                other.lowercased() != name.lowercased()
                    && other.lowercased().hasPrefix(name.lowercased() + " ")
            }
        }
    }

    /// One or multiple child names as a single string. Siblings sharing a last name
    /// become "Given1 & Given2 Last"; otherwise names are joined with "; ".
    private func extractChildName() -> String {
        let names = extractChildNames()
        guard names.count > 1 else { return names.first ?? "" }

        let split = names.map(splitChildName)
        let lastNames = split.map {
            $0.last.replacingOccurrences(of: #"[^A-Za-z'\-]"#, with: "", options: .regularExpression).lowercased()
        }
        if !lastNames.contains(""), Set(lastNames).count == 1 {
            let givens = split.map(\.given).filter { !$0.isEmpty }
            let sharedLast = split[0].last
            if !givens.isEmpty && !sharedLast.isEmpty {
                return "\(givens.joined(separator: " & ")) \(sharedLast)"
            }
        }
        return names.joined(separator: "; ")
    }

    private func extractParentName() -> String {
        let header = extractTopParentHeader()
        if !header.name.isEmpty && !header.phone.isEmpty {
            return header.name
        }

        let skipPrefixes = ["parent phone", "parent ph", "phone", "time", "date", "where", "parent email"]

        // Preferred: marker/square + parent name + dash + US phone anywhere in the text.
        let parentLinePattern = "^(?:[^A-Za-z0-9]+\\s*)?([A-Za-z][A-Za-z'\\-.\\s]+?)\\s*[-\u{2013}\u{2014}]\\s*(?:\(Self.usPhone))\\b"
        for line in lines.map(\.text) {
            guard let groups = firstMatch(of: parentLinePattern, in: line) else { continue }
            let name = normalizePersonName(groups[1])
            let lowered = name.lowercased()
            if !name.isEmpty && !skipPrefixes.contains(where: { lowered.hasPrefix($0) }) {
                return name
            }
        }

        // "Parent Phone" line that includes "Name - phone".
        for line in lines.map(\.text) where isParentPhoneLabel(line) {
            guard line.rangeOfCharacter(from: CharacterSet(charactersIn: "-\u{2013}\u{2014}")) != nil else { continue }
            var left = line.components(separatedBy: CharacterSet(charactersIn: "-\u{2013}\u{2014}")).first ?? ""
            left = left.replacingOccurrences(
                of: #"Parent\s*Ph(?:one)?\s*[:\-]?\s*"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            left = normalizePersonName(left)
            if left.rangeOfCharacter(from: .letters) != nil {
                return left
            }
        }

        // Explicit "Parent Name:" label.
        if let groups = firstMatch(of: #"Parent\s*Name\s*[:\-]?\s*([A-Za-z][A-Za-z'\-\s.]{2,})"#, in: fullText) {
            return normalizePersonName(groups[1])
        }

        // Fallback heuristic: first likely name line, skipping labels and metadata.
        let skipKeywords = [
            "time", "date", "where", "created", "grade", "subject",
            "parent phone", "parent ph", "parent email", "parent em", "appointment", "my notes",
            "description", "contact", "eastern time", "new york", "am", "pm", "email",
        ]
        for line in lines.map(\.text) {
            let clean = line.trimmingCharacters(in: .whitespaces)
            // Drop obvious labels like "Email:".
            if clean.range(of: #"^[A-Za-z\s]+:\s*$"#, options: .regularExpression) != nil { continue }
            guard clean.count > 3,
                  clean.range(of: #"\d{3}.*\d{4}"#, options: .regularExpression) == nil else { continue }
            let lowered = clean.lowercased()
            if !skipKeywords.contains(where: { lowered.contains($0) }) {
                let name = normalizePersonName(clean)
                if name.count > 2 { return name }
            }
        }
        return ""
    }

    /// Notes: each child's grade/subject info plus any explicit "Notes:" text.
    private func extractNotes() -> String {
        var childNotes: [String] = []
        for block in extractChildBlocks() {
            var parts: [String] = []
            if !block.grade.isEmpty { parts.append("Grade: \(block.grade)") }
            if !block.subject.isEmpty { parts.append("Subject: \(block.subject)") }
            guard !parts.isEmpty else { continue }
            let noteText = parts.joined(separator: ", ")
            childNotes.append(block.name.isEmpty ? noteText : "\(block.name): \(noteText)")
        }

        // De-duplicate child notes, keeping the richest variant.
        var dedupedChildNotes: [String] = []
        for note in childNotes {
            let key = note.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).lowercased()
            var replaced = false
            for (idx, existing) in dedupedChildNotes.enumerated() {
                let existingKey = existing.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).lowercased()
                if key.contains(existingKey) || existingKey.contains(key) {
                    if key.count > existingKey.count { dedupedChildNotes[idx] = note }
                    replaced = true
                    break
                }
            }
            if !replaced { dedupedChildNotes.append(note) }
        }

        // Explicit "Notes:" / "My Notes:" sections.
        let notesPattern = "(?:^|\\n)\\s*(?:My\\s+)?Notes\\s*[:;\\-]?\\s*(.+?)(?=\\n\\s*(?:\(Self.childToken)|\(Self.parentEmailStop)|\(Self.parentPhoneStop)|Appointment|$)|\\z)"
        var explicitNotes: [String] = []
        var seenNotes = Set<String>()
        for match in allMatches(of: notesPattern, in: fullText, dotAll: true) {
            let note = match[1]
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard note.rangeOfCharacter(from: .alphanumerics) != nil else { continue }
            if seenNotes.insert(note.lowercased()).inserted {
                explicitNotes.append(note)
            }
        }

        var combined: [String] = []
        if !dedupedChildNotes.isEmpty {
            combined.append(dedupedChildNotes.joined(separator: "\n"))
        }
        if !explicitNotes.isEmpty {
            combined.append(explicitNotes.map { "Notes: \($0)" }.joined(separator: "\n"))
        }
        return combined.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Normalization helpers

    /// Removes non-name symbols (e.g. "**") and collapses whitespace.
    private func normalizePersonName(_ value: String) -> String {
        var text = value.replacingOccurrences(of: #"[^A-Za-z'\-\s]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Normalizes a US phone number to the canonical format: (555) 555-5555.
    private func normalizeUSPhone(_ value: String) -> String {
        let raw = value.trimmingCharacters(in: .whitespaces)
        let digits = raw.replacingOccurrences(of: #"\D"#, with: "", options: .regularExpression)
        guard digits.count == 10 else { return raw }
        let area = digits.prefix(3)
        let exchange = digits.dropFirst(3).prefix(3)
        let number = digits.suffix(4)
        return "(\(area)) \(exchange)-\(number)"
    }

    /// Extracts and normalizes a US phone number from arbitrary text.
    private func extractUSPhone(from text: String) -> String {
        let patterns = [
            #"\(\d{3}\)\s*\d{3}-\d{4}"#,
            #"\(?\d{3}\)?[\s\-.]?\d{3}[\s\-.]?\d{4}"#,
            #"\b\d{10}\b"#,
        ]
        for pattern in patterns {
            if let groups = firstMatch(of: pattern, in: text) {
                return normalizeUSPhone(groups[0])
            }
        }
        return ""
    }

    /// Detects Parent Email label lines, including common OCR variants.
    private func isParentEmailLabel(_ line: String) -> Bool {
        let patterns = [
            #"Parent\s*E\s*[-.]?\s*mail\s*[:\-]?"#,
            #"Parent\s*Email\s*[:\-]?"#,
            #"Parent\s*Emai1\s*[:\-]?"#,
            #"Parent\s*Em\s*[:\-]?"#,
        ]
        return patterns.contains { firstMatch(of: $0, in: line) != nil }
    }

    /// Detects Parent Phone label lines, including common OCR variants.
    private func isParentPhoneLabel(_ line: String) -> Bool {
        firstMatch(of: #"Parent\s*Ph(?:one)?\s*[:\-]?"#, in: line) != nil
    }

    /// Splits a child full name into (given names, last name).
    private func splitChildName(_ value: String) -> (given: String, last: String) {
        let clean = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return ("", "") }
        let parts = clean.split(separator: " ").map(String.init)
        guard parts.count > 1 else { return (parts[0], "") }
        return (parts.dropLast().joined(separator: " "), parts.last ?? "")
    }

    // MARK: - Regex helpers

    /// First match of a pattern; returns the full match followed by capture groups
    /// (empty string for unmatched optional groups), or nil when there is no match.
    private func firstMatch(of pattern: String, in text: String, dotAll: Bool = false) -> [String]? {
        var options: NSRegularExpression.Options = [.caseInsensitive]
        if dotAll { options.insert(.dotMatchesLineSeparators) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return groups(from: match, in: text)
    }

    /// All matches of a pattern; each entry is the full match followed by capture groups.
    private func allMatches(of pattern: String, in text: String, dotAll: Bool = false) -> [[String]] {
        var options: NSRegularExpression.Options = [.caseInsensitive]
        if dotAll { options.insert(.dotMatchesLineSeparators) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { groups(from: $0, in: text) }
    }

    private func groups(from match: NSTextCheckingResult, in text: String) -> [String] {
        (0..<match.numberOfRanges).map { idx in
            guard let range = Range(match.range(at: idx), in: text) else { return "" }
            return String(text[range])
        }
    }
}
