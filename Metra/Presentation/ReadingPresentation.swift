import Foundation

enum ReadingPresentation {
    /// question_start is assigned only from a confirmed source question marker.
    /// The visible text keeps its number; VoiceOver receives an explicit role.
    static func accessibilityLabel(for chunk: MathChunkModel) -> String {
        let reading = text(for: chunk)
        guard chunk.kind == "question_start",
              let regex = try? NSRegularExpression(pattern: #"^([0-9]{1,4})[.)]\s+"#),
              let match = regex.firstMatch(in: reading, range: NSRange(reading.startIndex..., in: reading)) else { return reading }
        let source = reading as NSString
        return "Soal \(source.substring(with: match.range(at: 1))). \(source.substring(from: NSMaxRange(match.range)))"
    }

    /// Hide pipeline annotations only in the reader. Raw previews, status and
    /// unresolved IDs remain unchanged in SwiftData and extraction artifacts.
    static func text(for chunk: MathChunkModel) -> String {
        guard chunk.spokenText == nil, let preview = chunk.spokenPreview else { return chunk.readingText }
        var text = removeReviewAnnotations(preview, internalFormulaIDs: Set(chunk.unresolvedFormulaIDs))
        if chunk.kind == "diagram" {
            for warning in chunk.uncertainties where !warning.isEmpty {
                text = text.replacingOccurrences(of: warning, with: "")
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? chunk.sourceText : text
    }

    static func removeReviewAnnotations(_ text: String, internalFormulaIDs: Set<String> = []) -> String {
        var result = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard text[cursor] == "[" else { result.append(text[cursor]); cursor = text.index(after: cursor); continue }
            var end = text.index(after: cursor), depth = 1
            while end < text.endIndex && depth > 0 {
                if text[end] == "[" { depth += 1 }
                if text[end] == "]" { depth -= 1 }
                end = text.index(after: end)
            }
            guard depth == 0 else { result += text[cursor...]; break }
            let inside = String(text[text.index(after: cursor)..<text.index(before: end)])
            let prefixes = ["perlu review: ", "rumus perlu review: ", "nilai perlu review: "]
            if let prefix = prefixes.first(where: inside.hasPrefix) {
                let payload = String(inside.dropFirst(prefix.count))
                // The legacy preview uses an internal ID when OCR source is
                // empty. That ID is provenance, never a reading substitute.
                result += internalFormulaIDs.contains(payload) ? "Rumus belum dapat dibaca." : payload
            } else if inside.hasPrefix("perlu review") {
                // Review-only metadata, e.g. [perlu review label gabungan; ...].
            } else if inside.hasPrefix("Deskripsi gambar belum tersedia:") {
                result += "Deskripsi gambar belum tersedia."
            } else { result += text[cursor..<end] }
            cursor = end
        }
        return result
    }
}
