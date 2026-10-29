import Foundation
import NaturalLanguage

/// Reading units follow source paragraphs and explicit lists. Tokenization only
/// supplies candidate sentence/clause cuts; it never rewrites source content.
enum ReadingBoundaryPolicy {
    static let version = "paragraph_list_context_v6"
    static let preferredWords = 70

    static func isMarker(_ text:String) -> Bool {
        text.trimmingCharacters(in:.whitespacesAndNewlines)
            .range(of:#"^(?:[0-9]{1,4}[.)]|[a-zA-Z][.)]|[①-⑳]|[•●▪])$"#,options:.regularExpression) != nil
    }

    static func beginsListItem(_ text:String) -> Bool {
        text.range(of:#"^\s*(?:(?:[0-9]{1,4}[.)]|[a-zA-Z][.)])\s+\S|[①-⑳•●▪]\s*\S)"#,options:.regularExpression) != nil
    }

    static func isExampleLabel(_ text:String) -> Bool {
        text.trimmingCharacters(in:.whitespacesAndNewlines)
            .range(of:#"(?i)^(?:contoh|misalnya)(?:\s+[0-9]+(?:\.[0-9]+)*)?\s*:?$"#,options:.regularExpression) != nil
    }

    static func wordCount(_ text:String) -> Int { text.split(whereSeparator: { $0.isWhitespace }).count }

    static func sentenceEnds(_ text:String) -> Set<Int> {
        let tokenizer = NLTokenizer(unit:.sentence)
        tokenizer.setLanguage(NLLanguage(rawValue:"id"))
        tokenizer.string = text
        var ends = Set<Int>()
        tokenizer.enumerateTokens(in:text.startIndex..<text.endIndex) { range,_ in
            let prefix = String(text[..<range.upperBound]).trimmingCharacters(in:.whitespacesAndNewlines)
            let previous = prefix.split(whereSeparator:\.isWhitespace).last.map(String.init) ?? ""
            // Do not turn a list prefix, abbreviation or decimal into a unit.
            let abbreviation = previous.range(of:#"(?i)^(?:dsb|dll|dst|mis|hlm|no|dr|rp)\.$"#,options:.regularExpression) != nil
            if !isMarker(previous),!abbreviation { ends.insert(range.upperBound.utf16Offset(in:text)) }
            return true
        }
        return ends
    }
}

/// Joins only adjacent, spatially compatible source blocks with an explicit
/// reading dependency. Ordinary complete paragraphs remain separate units.
enum ReadingContextGrouper {
    static func group(_ input:[ChunkCandidate],document:FinalExtractionDocument) -> [ChunkCandidate] {
        let blocks = Dictionary(uniqueKeysWithValues:document.pages.flatMap(\.blocks).map { ($0.id,$0) })
        var output:[ChunkCandidate] = []
        func box(_ candidate:ChunkCandidate) -> PixelBox? {
            let sources = candidate.chunk.sourceBlockIDs ?? [candidate.blockID]
            let boxes = sources.compactMap { blocks[$0]?.bboxPageXYXY }
            guard let first = boxes.first else { return nil }
            return boxes.dropFirst().reduce(first) { a,b in
                PixelBox(xmin:min(a.xmin,b.xmin),ymin:min(a.ymin,b.ymin),xmax:max(a.xmax,b.xmax),ymax:max(a.ymax,b.ymax))
            }
        }
        func near(_ a:ChunkCandidate,_ b:ChunkCandidate) -> Bool {
            guard let x = box(a),let y = box(b) else { return false }
            let overlap = max(0,min(x.xmax,y.xmax)-max(x.xmin,y.xmin))
            let horizontal = overlap / max(1,min(x.xmax-x.xmin,y.xmax-y.xmin))
            let gap = y.ymin-x.ymax
            let height = min(x.ymax-x.ymin,y.ymax-y.ymin)
            return horizontal >= 0.35 && gap >= -max(8,height) && gap <= max(24,height*2)
        }
        for original in input {
            var next = original
            if ReadingBoundaryPolicy.isExampleLabel(next.chunk.sourceText),!next.isAuxiliary,next.chunk.diagramID == nil {
                next.chunk.kind = "example_label"
            }
            guard let previous = output.last,previous.chunk.pageID == next.chunk.pageID,
                  !previous.isAuxiliary,!next.isAuxiliary,
                  previous.chunk.diagramID == nil,next.chunk.diagramID == nil,
                  !["table","answer_choice","question_start"].contains(previous.chunk.kind),
                  !["table","answer_choice","question_start"].contains(next.chunk.kind),
                  !HeadingTopicBuilder.headingKinds.contains(previous.chunk.kind),
                  !HeadingTopicBuilder.headingKinds.contains(next.chunk.kind),
                  previous.chunk.questionID == next.chunk.questionID,near(previous,next),
                  ReadingBoundaryPolicy.wordCount((previous.chunk.spokenText ?? previous.chunk.sourceText)+" "+(next.chunk.spokenText ?? next.chunk.sourceText)) <= 90 else {
                output.append(next);continue
            }
            let prior = previous.chunk.sourceText.trimmingCharacters(in:.whitespacesAndNewlines)
            let following = next.chunk.sourceText.trimmingCharacters(in:.whitespacesAndNewlines)
            let hasMath = next.sourceSlices.contains { $0.formulaID != nil }
            let shortIntro = ReadingBoundaryPolicy.wordCount(prior) <= 12 &&
                (prior.hasSuffix(":") || prior.range(of:#"\([A-Za-z]\)\s*$"#,options:.regularExpression) != nil)
            let continuation = prior.hasSuffix(",") && following.range(of:#"(?i)^(?:jadi|sehingga|maka|yaitu|adalah)\b"#,options:.regularExpression) != nil
            let exampleDefinition = previous.chunk.kind == "example" && !ReadingBoundaryPolicy.beginsListItem(following) &&
                following.range(of:#"(?i)^.{1,35}:\s*disebut\b"#,options:.regularExpression) != nil
            let reason:String?
            if previous.chunk.kind == "example_label" { reason = "explicit_example_label" }
            else if shortIntro,hasMath { reason = "formula_introduction" }
            else if continuation { reason = "explicit_clause_continuation" }
            else if exampleDefinition { reason = "example_source_definition" }
            else { reason = nil }
            guard let reason else { output.append(next);continue }
            output.removeLast()
            let complete = previous.chunk.spokenText != nil && next.chunk.spokenText != nil
            var chunk = previous.chunk
            chunk.kind = previous.chunk.kind == "example_label" || previous.chunk.kind == "example" ? "example" : "formula_context"
            chunk.sourceText = prior + " " + following
            chunk.spokenText = complete ? [previous.chunk.spokenText!,next.chunk.spokenText!].joined(separator:" ") : nil
            chunk.spokenPreview = complete ? nil : [previous.chunk.spokenText ?? previous.chunk.spokenPreview ?? prior,next.chunk.spokenText ?? next.chunk.spokenPreview ?? following].joined(separator:" ")
            chunk.status = complete && ["ready","generated"].contains(previous.chunk.status) && ["ready","generated"].contains(next.chunk.status) ? "ready" : "needs_review"
            chunk.unresolvedFormulaIDs = Array(Set(previous.chunk.unresolvedFormulaIDs+next.chunk.unresolvedFormulaIDs)).sorted()
            let fallbackIDs = Array(Set((previous.chunk.formulaFallbackIDs ?? []) + (next.chunk.formulaFallbackIDs ?? []))).sorted()
            chunk.formulaFallbackIDs = fallbackIDs.isEmpty ? nil : fallbackIDs
            chunk.sourceBlockIDs = unique((previous.chunk.sourceBlockIDs ?? [previous.blockID]) + (next.chunk.sourceBlockIDs ?? [next.blockID]))
            chunk.sourceChunkIDs = (previous.chunk.sourceChunkIDs ?? [previous.chunk.id]) + (next.chunk.sourceChunkIDs ?? [next.chunk.id])
            output.append(ChunkCandidate(chunk:chunk,blockID:previous.blockID,readingOrder:previous.readingOrder,
                sourceSlices:previous.sourceSlices+next.sourceSlices,isAuxiliary:false,
                derivation:previous.derivation+"; "+reason+"; "+next.derivation))
        }
        return output
    }
    private static func unique(_ ids:[String]) -> [String] {
        var seen = Set<String>();return ids.filter { seen.insert($0).inserted }
    }
}
