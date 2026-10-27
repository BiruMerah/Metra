import Foundation

/// Derive reading structure from explicit question/choice markers and source
/// boxes. Raw page blocks, OCR strings, formulas and every source ref remain.
enum QuestionReadingNormalizer {
    static let version = "question_scoped_choice_reading_v1"
    struct Decision: Codable, Sendable {
        let questionID: String
        let number: String
        let accepted: Bool
        let reason: String
        let labels: [String]
        let sourceBlockIDs: [String]
        let orderedBlockIDs: [String]
    }
    struct Report: Codable, Sendable {
        let version: String
        let decisions: [Decision]
        let sourceSegmentsPreservedExactlyOnce: Bool
        let limitation: String
    }
    private struct Choice {
        let label: String
        var blocks: [FinalBlock]
        var segments: [FinalSegment]
    }
    private static let auxiliary: Set<String> = ["header", "footer", "number"]
    private static let visual = Set(DiagramSpokenService.visualLabels).union(["image", "diagram", "table", "figure", "chart"])
    private static let alphabet = ["A", "B", "C", "D", "E"]
    // Restrict OCR homoglyph interpretation to confirmed choice-marker context.
    private static let labelMap: [String: String] = ["А":"A", "В":"B", "С":"C", "Е":"E"]

    static func normalizedLabel(_ value: String) -> String { labelMap[value] ?? value }

    static func normalize(pageID: String, blocks: [FinalBlock], formulas: [FinalFormula],
                          observations: [OCRObservation], pageWidth: Int) throws -> (blocks: [FinalBlock], report: Report) {
        let byFormula = Dictionary(uniqueKeysWithValues: formulas.map { ($0.id, $0) })
        let byOCR = Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0) })
        let original = blocks.sorted { $0.readingOrder < $1.readingOrder }
        func raw(_ segment: FinalSegment) -> String { segment.formulaID.flatMap { byFormula[$0]?.sourceText } ?? segment.text ?? "" }
        func text(_ block: FinalBlock) -> String { block.segments.map { ($0.joinBefore ?? "") + raw($0) }.joined().trimmingCharacters(in: .whitespacesAndNewlines) }
        func anchor(_ block: FinalBlock) -> String? {
            let source = text(block)
            guard !auxiliary.contains(block.kind), !visual.contains(block.kind),
                  !HeadingTopicBuilder.headingKinds.contains(block.kind),
                  let regex = try? NSRegularExpression(pattern: #"^([0-9]{1,4})[.)]\s+\p{L}"#),
                  let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { return nil }
            return (source as NSString).substring(with: match.range(at: 1))
        }
        func union(_ boxes: [PixelBox]) -> PixelBox? {
            guard let first = boxes.first else { return nil }
            return boxes.dropFirst().reduce(first) { a, b in
                PixelBox(xmin:min(a.xmin,b.xmin),ymin:min(a.ymin,b.ymin),xmax:max(a.xmax,b.xmax),ymax:max(a.ymax,b.ymax))
            }
        }
        func bounds(_ segment: FinalSegment) -> PixelBox? {
            let boxes = segment.sourceRefs.compactMap { ref -> PixelBox? in
                guard let ocr = byOCR[ref.observationID], ref.rangeUTF16.count == 2 else { return nil }
                let chars = (ocr.rangeBoxes ?? []).filter { box in
                    box.rangeUTF16.count == 2 && box.rangeUTF16[0] < ref.rangeUTF16[1] && box.rangeUTF16[1] > ref.rangeUTF16[0]
                }.map(\.bboxPageXYXY)
                return union(chars) ?? ocr.bboxPageXYXY
            }
            return union(boxes)
        }
        func sameLine(_ a: PixelBox, _ b: PixelBox) -> Bool {
            let overlap = min(a.ymax,b.ymax) - max(a.ymin,b.ymin)
            return overlap >= 0.5 * max(1,min(a.ymax-a.ymin,b.ymax-b.ymin))
        }
        func orderedSegments(_ segments: [FinalSegment]) -> [FinalSegment] {
            guard segments.allSatisfy({ bounds($0) != nil }) else { return segments }
            // Group by observation before sorting: segments within one OCR line
            // stay in exact UTF-16 source order; different line fragments use x.
            let groups = Dictionary(grouping: segments) { segment in segment.sourceRefs.first?.observationID ?? segment.id }
            let sorted = groups.values.sorted { a, b in
                guard let boxA = union(a.compactMap(bounds)), let boxB = union(b.compactMap(bounds)) else { return a[0].id < b[0].id }
                if sameLine(boxA,boxB) { return boxA.xmin == boxB.xmin ? a[0].id < b[0].id : boxA.xmin < boxB.xmin }
                return boxA.ymin == boxB.ymin ? a[0].id < b[0].id : boxA.ymin < boxB.ymin
            }.flatMap { group in
                group.sorted {
                    let a = $0.sourceRefs.first?.rangeUTF16.first ?? 0, b = $1.sourceRefs.first?.rangeUTF16.first ?? 0
                    return a == b ? $0.id < $1.id : a < b
                }
            }
            var prior = ""
            return sorted.enumerated().map { index, segment in
                let next = raw(segment)
                let space = index > 0 && needsSpace(prior,next)
                prior = next
                return FinalSegment(id:segment.id,kind:segment.kind,text:segment.text,formulaID:segment.formulaID,status:segment.status,
                    sourceRefs:segment.sourceRefs,joinBefore:space ? " " : nil,joinReason:space ? "choice_source_geometry_join" : nil,
                    readingRole:segment.readingRole)
            }
        }
        func marker(_ segments: [FinalSegment]) -> String? {
            let source = segments.map { ($0.joinBefore ?? "") + raw($0) }.joined().trimmingCharacters(in:.whitespacesAndNewlines)
            guard let regex = try? NSRegularExpression(pattern: #"^([A-EАВСЕ])[.)](?:\s|[0-9(]|$)"#),
                  let match = regex.firstMatch(in:source,range:NSRange(source.startIndex...,in:source)) else { return nil }
            return normalizedLabel((source as NSString).substring(with:match.range(at:1)))
        }
        func markLabel(_ segments: [FinalSegment], label: String) -> [FinalSegment] {
            var prefix = true
            return segments.map { segment in
                let value = raw(segment).trimmingCharacters(in:.whitespacesAndNewlines)
                let isLabel = prefix && segment.formulaID != nil && value.count == 1 && normalizedLabel(value) == label
                if !value.isEmpty && !isLabel && value != "." && value != ")" { prefix = false }
                return FinalSegment(id:segment.id,kind:segment.kind,text:segment.text,formulaID:segment.formulaID,status:segment.status,
                    sourceRefs:segment.sourceRefs,joinBefore:segment.joinBefore,joinReason:segment.joinReason,
                    readingRole:isLabel ? "source_choice_marker" : segment.readingRole)
            }
        }
        let anchors = original.indices.compactMap { i in anchor(original[i]).map { (index:i,number:$0) } }
        var output: [FinalBlock] = [], decisions: [Decision] = []
        let lefts = anchors.map { original[$0.index].bboxPageXYXY.xmin }
        let alignedAnchors = (lefts.max() ?? 0) - (lefts.min() ?? 0) <= max(16,Double(pageWidth)*0.04)
        if let first = anchors.first { output += original[..<first.index] }
        else { output = original }
        for (position, entry) in anchors.enumerated() {
            let end = position+1 < anchors.count ? anchors[position+1].index : original.count
            let group = Array(original[entry.index..<end])
            let questionID = "\(pageID).question.\(entry.number).\(original[entry.index].id)"
            var choices: [Choice] = []
            for block in group.dropFirst() where !auxiliary.contains(block.kind) && !visual.contains(block.kind) && !HeadingTopicBuilder.headingKinds.contains(block.kind) {
                let arranged = orderedSegments(block.segments)
                if let label = marker(arranged) { choices.append(.init(label:label,blocks:[block],segments:arranged)) }
            }
            var consumed = Set(choices.flatMap { $0.blocks.map(\.id) })
            // Attach a split value only to a unique preceding same-line marker.
            for block in group.dropFirst() where !consumed.contains(block.id) && !auxiliary.contains(block.kind) && !visual.contains(block.kind) {
                let value = text(block)
                guard !value.isEmpty, value.count <= 180 else { continue }
                let matches = choices.indices.filter { i in
                    let choice = choices[i]
                    let labelOnly = choice.segments.map(raw).joined().filter { !$0.isWhitespace }
                    guard labelOnly.count == 2, normalizedLabel(String(labelOnly.prefix(1))) == choice.label,
                          let b = choice.blocks.first?.bboxPageXYXY else { return false }
                    return sameLine(b,block.bboxPageXYXY) && block.bboxPageXYXY.xmin >= b.xmax-2 &&
                        block.bboxPageXYXY.xmin-b.xmax <= Double(pageWidth)*0.35
                }.sorted { choices[$0].blocks[0].bboxPageXYXY.xmax > choices[$1].blocks[0].bboxPageXYXY.xmax }
                guard let i = matches.first else { continue }
                if matches.count > 1,
                   abs(choices[i].blocks[0].bboxPageXYXY.xmax-choices[matches[1]].blocks[0].bboxPageXYXY.xmax) < 8 { continue }
                choices[i].blocks.append(block)
                choices[i].segments = orderedSegments(choices[i].segments + block.segments)
                consumed.insert(block.id)
            }
            let labels = choices.map(\.label).sorted()
            let firstChoice = group.firstIndex { consumed.contains($0.id) }
            let unexpectedTail = firstChoice.map { start in group[start...].contains { !consumed.contains($0.id) && !auxiliary.contains($0.kind) } } ?? false
            let nonempty = choices.allSatisfy { choice in
                let source = choice.segments.map(raw).joined().trimmingCharacters(in:.whitespacesAndNewlines)
                return source.count > 2
            }
            let accepted = alignedAnchors && (2...5).contains(labels.count) && labels == Array(alphabet.prefix(labels.count)) &&
                Set(labels).count == labels.count && !unexpectedTail && nonempty
            guard accepted else {
                output += group
                if !choices.isEmpty { decisions.append(.init(questionID:questionID,number:entry.number,accepted:false,
                    reason:!alignedAnchors ? "Ambiguous multi-column question anchors; retain source order" : "Incomplete/duplicate markers, empty choice or unowned body after choices; retain source order",
                    labels:labels,sourceBlockIDs:group.map(\.id),orderedBlockIDs:group.map(\.id))) }
                continue
            }
            let ordered = choices.sorted { $0.label < $1.label }
            let body = group.filter { !consumed.contains($0.id) && !auxiliary.contains($0.kind) }.map { block in
                FinalBlock(id:block.id,kind:block.kind,bboxPageXYXY:block.bboxPageXYXY,readingOrder:block.readingOrder,status:block.status,
                    segments:block.segments,questionID:questionID,questionNumber:entry.number,sourceBlockIDs:block.sourceBlockIDs ?? [block.id])
            }
            let choiceBlocks = ordered.map { choice -> FinalBlock in
                let first = choice.blocks[0]
                return FinalBlock(id:first.id,kind:"answer_choice",bboxPageXYXY:union(choice.blocks.map(\.bboxPageXYXY))!,
                    readingOrder:first.readingOrder,status:choice.blocks.contains { $0.status != "ready" } ? "needs_review" : "ready",
                    segments:markLabel(choice.segments,label:choice.label),questionID:questionID,questionNumber:entry.number,choiceLabel:choice.label,
                    sourceBlockIDs:choice.blocks.flatMap { $0.sourceBlockIDs ?? [$0.id] })
            }
            let result = body + choiceBlocks + group.filter { auxiliary.contains($0.kind) }
            output += result
            decisions.append(.init(questionID:questionID,number:entry.number,accepted:true,
                reason:"Explicit complete A–\(labels.last ?? "B") marker set within one numbered question; labels and values joined by source ranges/boxes; source payload not rewritten",
                labels:labels,sourceBlockIDs:group.map(\.id),orderedBlockIDs:result.map(\.id)))
        }
        let before = original.flatMap(\.segments).map(\.id), after = output.flatMap(\.segments).map(\.id)
        guard before.count == after.count, Set(before) == Set(after), Set(after).count == after.count,
              Set(output.map(\.id)).count == output.count else { throw FinalExportError.sourceCoverageChanged }
        output = output.enumerated().map { i, b in
            FinalBlock(id:b.id,kind:b.kind,bboxPageXYXY:b.bboxPageXYXY,readingOrder:i+1,status:b.status,segments:b.segments,
                questionID:b.questionID,questionNumber:b.questionNumber,choiceLabel:b.choiceLabel,sourceBlockIDs:b.sourceBlockIDs)
        }
        return (output,.init(version:version,decisions:decisions,sourceSegmentsPreservedExactlyOnce:true,
            limitation:"Derived question/choice reading structure only. Missing/ambiguous markers and multi-column question anchors remain unchanged. No OCR correction, solving, cross-page grouping or image-fidelity claim."))
    }

    private static func needsSpace(_ prior: String, _ next: String) -> Bool {
        guard let a = prior.last, let b = next.first, !a.isWhitespace, !b.isWhitespace else { return false }
        return !".,;:!?)]}".contains(b) && !"([{".contains(a)
    }
}
