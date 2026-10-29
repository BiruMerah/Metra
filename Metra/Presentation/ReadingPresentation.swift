import Foundation

enum ReadingPresentation {
    struct Row: Identifiable {
        let chunks: [MathChunkModel]

        var id: String { chunks[0].id }
        var contentChunk: MathChunkModel { chunks[chunks.count - 1] }
        var listMarker: String? {
            if chunks.count == 2 { return ReadingPresentation.text(for: chunks[0]) }
            guard ["list_item","question_start"].contains(contentChunk.kind),
                  let prefix = ReadingPresentation.text(for:contentChunk).range(of:#"^(?:[0-9]{1,4}[.)]|[a-zA-Z][.)]|[①-⑳•●▪])\s+"#,options:.regularExpression) else { return nil }
            return String(ReadingPresentation.text(for:contentChunk)[prefix]).trimmingCharacters(in:.whitespacesAndNewlines)
        }
        var bodyText: String {
            let text = ReadingPresentation.text(for:contentChunk)
            guard chunks.count == 1,let marker = listMarker else { return text }
            return String(text.dropFirst(marker.count)).trimmingCharacters(in:.whitespacesAndNewlines)
        }
        var text: String { chunks.map { ReadingPresentation.text(for: $0) }.joined(separator: " ") }
        var accessibilityLabel: String {
            chunks.map { ReadingPresentation.accessibilityLabel(for: $0) }.joined(separator: " ")
        }
    }

    /// Rejoin an enumerator split by sentence tokenization only when the saved
    /// IDs confirm both adjacent chunks came from the same source block.
    /// This projection also works on existing material without rewriting it.
    static func rows(for chunks: [MathChunkModel]) -> [Row] {
        var rows: [Row] = []
        var index = 0
        while index < chunks.count {
            let marker = chunks[index]
            if index + 1 < chunks.count, canJoinListMarker(marker, to: chunks[index + 1]) {
                rows.append(Row(chunks: [marker, chunks[index + 1]]))
                index += 2
            } else {
                rows.append(Row(chunks: [marker]))
                index += 1
            }
        }
        return rows
    }

    private static func canJoinListMarker(_ marker: MathChunkModel, to body: MathChunkModel) -> Bool {
        let source = marker.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard marker.kind == "sentence", body.kind == "sentence",
              marker.imagePath == nil, body.imagePath == nil,
              marker.pageID == body.pageID, body.order == marker.order + 1,
              source.range(of: #"^[0-9]{1,4}[.)]$"#, options: .regularExpression) != nil,
              text(for: marker) == source,
              !body.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
                .range(of: #"^[0-9]{1,4}[.)]$"#, options: .regularExpression) == nil,
              let block = sourceBlockID(marker.id), block == sourceBlockID(body.id) else { return false }
        return true
    }

    private static func sourceBlockID(_ chunkID: String) -> String? {
        guard let suffix = chunkID.range(of: #"\.c[0-9]{4}$"#, options: .regularExpression) else { return nil }
        return String(chunkID[..<suffix.lowerBound])
    }

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
        if chunk.kind == "ignored_visual" { return "" }
        if chunk.kind == "formula", chunk.spokenText == nil {
            if chunk.formulaFallbackIDs?.isEmpty == false,let preview = chunk.spokenPreview,
               !preview.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                return removeReviewAnnotations(markFormulaFallbacks(preview),internalFormulaIDs:Set(chunk.unresolvedFormulaIDs))
            }
            // A formula-only OCR fallback is not validated mathematical speech.
            // Preserve a leading list number, but never present its damaged OCR
            // as though it were a successfully read expression.
            if let prefix = chunk.sourceText.range(of: #"^[0-9]{1,4}[.)]\s+"#, options: .regularExpression) {
                return String(chunk.sourceText[prefix]).trimmingCharacters(in: .whitespacesAndNewlines) + " Rumus belum dapat dibaca."
            }
            return "Rumus belum dapat dibaca."
        }
        guard chunk.spokenText == nil, let preview = chunk.spokenPreview else { return chunk.readingText }
        let visiblePreview = chunk.formulaFallbackIDs?.isEmpty == false ? markFormulaFallbacks(preview) : preview
        var text = removeReviewAnnotations(visiblePreview, internalFormulaIDs: Set(chunk.unresolvedFormulaIDs))
        if chunk.kind == "diagram" {
            for warning in chunk.uncertainties where !warning.isEmpty {
                text = text.replacingOccurrences(of: warning, with: "")
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? chunk.sourceText : text
    }

    private static func markFormulaFallbacks(_ preview:String) -> String {
        // Existing saved fallback previews gain the same explicit qualification
        // at presentation time; source, raw output and saved previews stay intact.
        preview.replacingOccurrences(of:"Deskripsi alternatif rumus: ",with:"Deskripsi alternatif rumus, belum dipastikan: ")
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
