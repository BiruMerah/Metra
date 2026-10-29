import Foundation
import NaturalLanguage

struct ReadyExtractionDocument: Codable, Sendable {
    let schema: String
    let id: String
    let groupingAttemptID: String
    let status: String
    let groupingStatus: String
    let topicQualityStatus: ReviewStatus
    let sourceCoverageStatus: ReviewStatus
    let contentQualityStatus: ReviewStatus
    let createdAt: String
    let sourceArtifact: String
    let topics: [ReadyTopic]
    let ungroupedChunks: [ReadyChunk]
    let auxiliaryChunks: [ReadyChunk]
    let reportArtifact: String
    var chunks: [ReadyChunk]? = nil
    var topicIndex: ReadyTopicIndex? = nil
    var questions: [ReadyQuestionReference]? = nil
}

struct ReadyQuestionReference: Codable, Sendable {
    struct Choice: Codable, Sendable { let label: String; let chunkID: String }
    let id: String
    let number: String
    let pageID: String
    let stemChunkIDs: [String]
    let choices: [Choice]
}

struct ReadyTopic: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let titleSource: String
    let status: String
    let chunks: [ReadyChunk]
}

struct ReadyChunk: Codable, Identifiable, Sendable {
    let id: String
    var kind: String
    let pageID: String
    var status: String
    var sourceText: String
    /// Complete merged speech only. Never silently skip an unresolved formula.
    var spokenText: String?
    /// Present for incomplete speech; review markers are explicitly presentation text.
    var spokenPreview: String?
    var unresolvedFormulaIDs: [String]
    let sourceRef: String
    var diagramID: String? = nil
    var imageArtifact: String? = nil
    var uncertainties: [String]? = nil
    var diagramPairs: [DiagramRenderedPair]? = nil
    var questionID: String? = nil
    var choiceLabel: String? = nil
    var sourceBlockIDs: [String]? = nil
    var sourceChunkIDs: [String]? = nil
    var formulaFallbackIDs: [String]? = nil
}

struct ChunkSourceSlice: Codable, Equatable, Sendable {
    let segmentID: String
    /// Relative to FinalSegment.text, not to the whole OCR observation.
    let textRangeUTF16: [Int]?
    let formulaID: String?
}

struct ChunkCandidate: Codable, Sendable {
    var chunk: ReadyChunk
    let blockID: String
    let readingOrder: Int
    let sourceSlices: [ChunkSourceSlice]
    let isAuxiliary: Bool
    let derivation: String
}

enum ReadingChunkBuilder {
    static let version = ReadingBoundaryPolicy.version

    private struct Atom {
        let mask: String
        let source: String
        let speech: String?
        let preview: String
        let slice: ChunkSourceSlice?
        let unresolvedFormulaID: String?
        var sourceLineStart: Bool = false
        var fallbackID: String? = nil
    }

    static func build(_ document: FinalExtractionDocument, artifactPrefix: String) throws -> [ChunkCandidate] {
        var candidates: [ChunkCandidate] = []
        for page in document.pages {
            var startedQuestions: Set<String> = []
            let formulas = Dictionary(uniqueKeysWithValues: page.formulas.map { ($0.id, $0) })
            for block in page.blocks.sorted(by: { $0.readingOrder < $1.readingOrder }) {
                let readingSegments = block.segments.filter { segment in
                    segment.formulaID.flatMap { formulas[$0]?.coveredByFormulaIDs } == nil
                }
                if readingSegments.isEmpty && !block.segments.isEmpty { continue }
                if let diagram = page.diagrams?.first(where: { $0.layoutRegionID == block.id }) {
                    let id = "\(block.id).c0001"
                    let source = readingSegments.map { segment -> String in
                        let content = segment.formulaID.flatMap { formulas[$0]?.sourceText } ?? segment.text ?? ""
                        return (segment.joinBefore ?? "") + content
                    }.joined().trimmingCharacters(in:.whitespacesAndNewlines)
                    let slices = readingSegments.map { ChunkSourceSlice(segmentID:$0.id,textRangeUTF16:$0.formulaID == nil ? [0,($0.text ?? "").utf16.count] : nil,formulaID:$0.formulaID) }
                    let chunk = ReadyChunk(id:id,kind:diagram.status == "skipped_others" ? "ignored_visual" : "diagram",pageID:page.id,status:diagram.status,sourceText:source,
                        spokenText:diagram.spokenText,spokenPreview:diagram.spokenPreview,
                        unresolvedFormulaIDs:diagram.unresolvedFormulaIDs,sourceRef:"\(artifactPrefix)/chunks/\(id).json",
                        diagramID:diagram.id,imageArtifact:diagram.artifacts["crop"],uncertainties:diagram.uncertainties,diagramPairs:diagram.pairs,
                        questionID:block.questionID,sourceBlockIDs:block.sourceBlockIDs)
                    candidates.append(ChunkCandidate(chunk:chunk,blockID:block.id,readingOrder:block.readingOrder,sourceSlices:slices,isAuxiliary:diagram.status == "skipped_others",
                        derivation:"visual_chunk_projection_v2: copy the existing FinalDiagram speech, pairs and status into one visual chunk; no diagram inference during reading export; source slices retained"))
                    continue
                }
                var atoms: [Atom] = []
                for segment in readingSegments {
                    if let join = segment.joinBefore, !join.isEmpty {
                        atoms.append(Atom(mask: join, source: join, speech: join, preview: join, slice: nil, unresolvedFormulaID: nil))
                    }
                    if let id = segment.formulaID {
                        guard let formula = formulas[id] else { throw FinalExportError.invalidFormulaReference }
                        if segment.readingRole == "source_choice_marker", let label = block.choiceLabel,
                           formula.sourceText.count == 1, QuestionReadingNormalizer.normalizedLabel(formula.sourceText) == label {
                            atoms.append(Atom(mask:formula.sourceText,source:formula.sourceText,speech:label,preview:label,
                                slice:ChunkSourceSlice(segmentID:segment.id,textRangeUTF16:nil,formulaID:id),unresolvedFormulaID:nil))
                            continue
                        }
                        let fallback = formula.spokenText == nil ? document.formulaFallbacks?[id]?.readerText : nil
                        atoms.append(Atom(mask: "\u{FFFC}", source: formula.sourceText, speech: formula.spokenText,
                                          preview: formula.spokenText ?? fallback ?? (formula.sourceText.count == 1 && formula.sourceText.allSatisfy { $0.isASCII && $0.isLetter } ? "[perlu review: \(formula.sourceText)]" : "Rumus belum dapat dibaca."),
                                          slice: ChunkSourceSlice(segmentID: segment.id, textRangeUTF16: nil, formulaID: id),
                                          unresolvedFormulaID: formula.spokenText == nil ? id : nil,fallbackID:fallback == nil ? nil : id))
                    } else {
                        let text = segment.text ?? ""
                        for start in text.indices {
                            let end = text.index(after: start), part = String(text[start..<end])
                            atoms.append(Atom(mask: part, source: part, speech: part, preview: part,
                                              slice: ChunkSourceSlice(segmentID: segment.id, textRangeUTF16: [start.utf16Offset(in: text), end.utf16Offset(in: text)], formulaID: nil), unresolvedFormulaID: nil,
                                              sourceLineStart:start == text.startIndex && segment.sourceRefs.first?.rangeUTF16.first == 0))
                        }
                    }
                }
                let masked = atoms.map(\.mask).joined()
                let preserveBlock = ["doc_title", "paragraph_title", "heading", "header", "footer", "number", "formula", "table", "image", "diagram", "answer_choice"].contains(block.kind)
                var groups = preserveBlock ? [atoms] : paragraphGroups(atoms,masked:masked)
                // A confirmed question marker is part of its initial sentence.
                // Join atoms before projecting speech/slices so source coverage
                // and unresolved-formula status follow the existing machinery.
                let questionNumber = block.questionID.map { !startedQuestions.contains($0) } == true && block.choiceLabel == nil ? block.questionNumber : nil
                if !preserveBlock, let number = questionNumber, groups.count >= 2,
                   groups[0].allSatisfy({ $0.slice?.formulaID == nil }),
                   ["\(number).", "\(number))"].contains(groups[0].map(\.source).joined().trimmingCharacters(in: .whitespacesAndNewlines)),
                   !groups[1].map(\.source).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let initialSentence = groups.remove(at: 1)
                    groups[0].append(contentsOf: initialSentence)
                }
                let firstSource = groups[0].map(\.source).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                let hasQuestionStart = !preserveBlock && questionNumber.map { number in
                    firstSource.range(of: "^" + NSRegularExpression.escapedPattern(for: number) + #"[.)]\s+\S"#,
                                      options: .regularExpression) != nil
                } == true
                if hasQuestionStart, let questionID = block.questionID { startedQuestions.insert(questionID) }
                for (index, items) in groups.enumerated() {
                    let id = "\(block.id).c\(String(format: "%04d", index + 1))"
                    let source = items.map(\.source).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    let preview = choicePrefix(items.map(\.preview).joined().trimmingCharacters(in: .whitespacesAndNewlines), label:block.choiceLabel)
                    let unsupported = block.status == "unsupported"
                    let missing = Array(Set(items.compactMap(\.unresolvedFormulaID))).sorted()
                    let complete = !unsupported && items.allSatisfy { $0.speech != nil }
                    let speech = complete ? choicePrefix(items.compactMap(\.speech).joined().trimmingCharacters(in: .whitespacesAndNewlines), label:block.choiceLabel) : nil
                    let mathOnly = !items.compactMap(\.slice).isEmpty && items.compactMap(\.slice).allSatisfy { $0.formulaID != nil }
                    let kind = hasQuestionStart && index == 0 ? "question_start" : (preserveBlock ? block.kind :
                        (ReadingBoundaryPolicy.beginsListItem(source) ? "list_item" : (mathOnly ? "formula" : "paragraph")))
                    let chunk = ReadyChunk(id: id, kind: kind, pageID: page.id,
                                           status: unsupported ? "unsupported" : (complete ? "ready" : "needs_review"),
                                           sourceText: source, spokenText: speech,
                                           spokenPreview: complete ? nil : (unsupported && preview.isEmpty ? "[isi \(block.kind) belum tersedia]" : preview),
                                           unresolvedFormulaIDs: missing, sourceRef: "\(artifactPrefix)/chunks/\(id).json",
                                           questionID:block.questionID,choiceLabel:block.choiceLabel,sourceBlockIDs:block.sourceBlockIDs ?? [block.id],
                                           formulaFallbackIDs:items.compactMap(\.fallbackID).isEmpty ? nil : Array(Set(items.compactMap(\.fallbackID))).sorted())
                    var slices: [ChunkSourceSlice] = []
                    for slice in items.compactMap(\.slice) {
                        if let last = slices.last, last.segmentID == slice.segmentID,
                           let a = last.textRangeUTF16, let b = slice.textRangeUTF16, a[1] == b[0] {
                            slices[slices.count - 1] = ChunkSourceSlice(segmentID: last.segmentID, textRangeUTF16: [a[0], b[1]], formulaID: nil)
                        } else { slices.append(slice) }
                    }
                    candidates.append(ChunkCandidate(chunk: chunk, blockID: block.id, readingOrder: block.readingOrder, sourceSlices: slices,
                                                     isAuxiliary: ["footer", "header", "number"].contains(block.kind),
                                                     derivation: "\(version): bounded source paragraphs; explicit list boundaries; attached enumerators; atomic formula occurrences; confirmed question and choice boundaries; original source slices and review state retained"))
                }
            }
        }
        let grouped = ReadingContextGrouper.group(candidates,document:document)
        try validateCoverage(document, candidates: grouped)
        return grouped
    }

    private static func paragraphGroups(_ atoms:[Atom],masked:String) -> [[Atom]] {
        guard !atoms.isEmpty else { return [[]] }
        let proposed = ReadingBoundaryPolicy.sentenceEnds(masked)
        var soft = Set<Int>(),forced = Set<Int>(),offset = 0,depth = 0,clause = ""
        let long = ReadingBoundaryPolicy.wordCount(atoms.map { $0.speech ?? $0.source }.joined()) > ReadingBoundaryPolicy.preferredWords
        for (i,atom) in atoms.enumerated() {
            if atom.sourceLineStart,i > 0,
               ReadingBoundaryPolicy.beginsListItem(atoms[i..<min(atoms.count,i+20)].map(\.source).joined()) {
                forced.insert(offset)
            }
            if atom.mask == "(" || atom.mask == "[" || atom.mask == "{" { depth += 1 }
            if atom.mask == ")" || atom.mask == "]" || atom.mask == "}" { depth = max(0,depth-1) }
            clause += atom.speech ?? atom.source
            offset += atom.mask.utf16.count
            if depth == 0,proposed.contains(offset) { soft.insert(offset);clause = "" }
            if long,depth == 0,[",",";"].contains(atom.mask),ReadingBoundaryPolicy.wordCount(clause) >= 35 {
                soft.insert(offset);clause = ""
            }
        }
        let cuts = soft.union(forced).sorted()
        var units:[(items:[Atom],forced:Bool)] = [],unit:[Atom] = [],unitForced = false
        var cutIndex = 0,pending = false,pendingForced = false
        offset = 0
        for atom in atoms {
            while cutIndex < cuts.count,offset >= cuts[cutIndex] {
                pending = true;pendingForced = pendingForced || forced.contains(cuts[cutIndex]);cutIndex += 1
            }
            if pending,!atom.mask.allSatisfy(\.isWhitespace),!unit.isEmpty {
                units.append((unit,unitForced));unit = [];unitForced = pendingForced;pending = false;pendingForced = false
            }
            unit.append(atom);offset += atom.mask.utf16.count
        }
        if !unit.isEmpty { units.append((unit,unitForced)) }
        var groups:[[Atom]] = [],group:[Atom] = []
        for unit in units {
            let words = ReadingBoundaryPolicy.wordCount((group+unit.items).map { $0.speech ?? $0.source }.joined())
            let marker = ReadingBoundaryPolicy.isMarker(group.map(\.source).joined())
            if !group.isEmpty,(unit.forced || (words > ReadingBoundaryPolicy.preferredWords && !marker)) {
                groups.append(group);group = []
            }
            group += unit.items
        }
        if !group.isEmpty { groups.append(group) }
        return groups.isEmpty ? [[]] : groups
    }

    private static func validateCoverage(_ document: FinalExtractionDocument, candidates: [ChunkCandidate]) throws {
        guard Set(candidates.map { $0.chunk.id }).count == candidates.count else { throw FinalExportError.duplicateIdentity }
        let refs = Dictionary(grouping: candidates.flatMap(\.sourceSlices), by: \.segmentID)
        let formulas = Dictionary(uniqueKeysWithValues: document.pages.flatMap(\.formulas).map { ($0.id, $0) })
        for segment in document.pages.flatMap(\.blocks).flatMap(\.segments) {
            let slices = refs[segment.id] ?? []
            if let formulaID = segment.formulaID {
                if let coveredBy = formulas[formulaID]?.coveredByFormulaIDs {
                    guard slices.isEmpty, segment.sourceRefs.isEmpty, coveredBy.count >= 2,
                          coveredBy.allSatisfy({ id in
                              guard let child = formulas[id], child.coveredByFormulaIDs == nil else { return false }
                              return refs[child.segmentID]?.count == 1 && refs[child.segmentID]?.first?.formulaID == id
                          }) else { throw FinalExportError.sourceCoverageChanged }
                    continue
                }
                guard slices.count == 1, slices[0].formulaID == formulaID else { throw FinalExportError.sourceCoverageChanged }
            } else {
                var cursor = 0
                for slice in slices.sorted(by:{ ($0.textRangeUTF16?.first ?? -1) < ($1.textRangeUTF16?.first ?? -1) }) {
                    guard let range = slice.textRangeUTF16, range[0] == cursor, range[1] >= cursor else { throw FinalExportError.sourceCoverageChanged }
                    cursor = range[1]
                }
                guard cursor == (segment.text ?? "").utf16.count else { throw FinalExportError.sourceCoverageChanged }
            }
        }
    }

    private static func choicePrefix(_ text: String, label: String?) -> String {
        guard let label, text.count >= 2, let first = text.first,
              QuestionReadingNormalizer.normalizedLabel(String(first)) == label,
              ".)".contains(text[text.index(after:text.startIndex)]) else { return text }
        return label + ". " + text.dropFirst(2).trimmingCharacters(in:.whitespacesAndNewlines)
    }
}

// v1 topic artifacts remain decodable; new exports have one top-level chunks array.
extension ReadyExtractionDocument {
    private enum CodingKeys: String, CodingKey {
        case schema,id,groupingAttemptID,exportID,status,groupingStatus,topicQualityStatus,sourceCoverageStatus,contentQualityStatus,createdAt,sourceArtifact,topics,ungroupedChunks,auxiliaryChunks,reportArtifact,chunks,topicIndex,questions
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        schema = try c.decode(String.self,forKey:.schema)
        id = try c.decode(String.self,forKey:.id)
        groupingAttemptID = try c.decodeIfPresent(String.self,forKey:.exportID) ?? c.decodeIfPresent(String.self,forKey:.groupingAttemptID) ?? "legacy"
        status = try c.decode(String.self,forKey:.status)
        groupingStatus = try c.decode(String.self,forKey:.groupingStatus)
        topicQualityStatus = try c.decodeIfPresent(ReviewStatus.self,forKey:.topicQualityStatus) ?? .notAssessed
        sourceCoverageStatus = try c.decode(ReviewStatus.self,forKey:.sourceCoverageStatus)
        contentQualityStatus = try c.decode(ReviewStatus.self,forKey:.contentQualityStatus)
        createdAt = try c.decode(String.self,forKey:.createdAt)
        sourceArtifact = try c.decode(String.self,forKey:.sourceArtifact)
        topics = try c.decodeIfPresent([ReadyTopic].self,forKey:.topics) ?? []
        ungroupedChunks = try c.decodeIfPresent([ReadyChunk].self,forKey:.ungroupedChunks) ?? []
        auxiliaryChunks = try c.decodeIfPresent([ReadyChunk].self,forKey:.auxiliaryChunks) ?? []
        reportArtifact = try c.decode(String.self,forKey:.reportArtifact)
        chunks = try c.decodeIfPresent([ReadyChunk].self,forKey:.chunks)
        topicIndex = try c.decodeIfPresent(ReadyTopicIndex.self,forKey:.topicIndex)
        questions = try c.decodeIfPresent([ReadyQuestionReference].self,forKey:.questions)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy:CodingKeys.self)
        try c.encode(schema,forKey:.schema); try c.encode(id,forKey:.id)
        try c.encode(status,forKey:.status); try c.encode(groupingStatus,forKey:.groupingStatus)
        try c.encode(sourceCoverageStatus,forKey:.sourceCoverageStatus); try c.encode(contentQualityStatus,forKey:.contentQualityStatus)
        try c.encode(createdAt,forKey:.createdAt); try c.encode(sourceArtifact,forKey:.sourceArtifact)
        try c.encode(reportArtifact,forKey:.reportArtifact)
        if let chunks {
            try c.encode(groupingAttemptID,forKey:.exportID)
            try c.encode(chunks,forKey:.chunks)
            try c.encodeIfPresent(topicIndex,forKey:.topicIndex)
            try c.encodeIfPresent(questions,forKey:.questions)
            if topicIndex != nil { try c.encode(topicQualityStatus,forKey:.topicQualityStatus) }
        } else {
            try c.encode(groupingAttemptID,forKey:.groupingAttemptID)
            try c.encode(topicQualityStatus,forKey:.topicQualityStatus)
            try c.encode(topics,forKey:.topics); try c.encode(ungroupedChunks,forKey:.ungroupedChunks)
            try c.encode(auxiliaryChunks,forKey:.auxiliaryChunks)
        }
    }
}

@MainActor
enum OrderedChunkExport {
    static func run(document: FinalExtractionDocument, paths: RunPaths) throws -> ReadyExtractionDocument {
        let started = ProcessInfo.processInfo.systemUptime
        let exportID = UUID().uuidString.lowercased()
        let prefix = "reading/exports/\(exportID)"
        let directory = paths.root.appendingPathComponent(prefix,isDirectory:true)
        try FileManager.default.createDirectory(at:directory.appendingPathComponent("chunks"),withIntermediateDirectories:true)
        let candidates = try ReadingChunkBuilder.build(document,artifactPrefix:prefix)
        let topicIndex = try HeadingTopicBuilder.build(candidates)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        for candidate in candidates { try encoder.encode(candidate).write(to:paths.root.appendingPathComponent(candidate.chunk.sourceRef),options:.atomic) }
        var result = ReadyExtractionDocument(schema:"metra-ready-chunks-v4",id:document.id,groupingAttemptID:exportID,
            status:candidates.contains { !["ready","generated"].contains($0.chunk.status) } || topicIndex.topics.contains { $0.status == "needs_review" } ? "needs_review" : "draft",
            groupingStatus:topicIndex.membershipStatus,topicQualityStatus:.notAssessed,sourceCoverageStatus:document.sourceCoverageStatus,
            contentQualityStatus:document.contentQualityStatus,createdAt:ISO8601DateFormatter().string(from:Date()),
            sourceArtifact:"\(prefix)/input.final-extraction.json",topics:[],ungroupedChunks:[],auxiliaryChunks:[],reportArtifact:"\(prefix)/report.json",
            chunks:candidates.map(\.chunk),topicIndex:topicIndex)
        var seenQuestions: Set<String> = []
        result.questions = candidates.compactMap { candidate -> ReadyQuestionReference? in
            guard let id = candidate.chunk.questionID, seenQuestions.insert(id).inserted,
                  let block = document.pages.flatMap(\.blocks).first(where:{ $0.questionID == id }),
                  let number = block.questionNumber else { return nil }
            let members = candidates.filter { $0.chunk.questionID == id }
            return ReadyQuestionReference(id:id,number:number,pageID:candidate.chunk.pageID,
                stemChunkIDs:members.filter { $0.chunk.choiceLabel == nil }.map { $0.chunk.id },
                choices:members.compactMap { member in member.chunk.choiceLabel.map { .init(label:$0,chunkID:member.chunk.id) } })
        }
        try encoder.encode(document).write(to:directory.appendingPathComponent("input.final-extraction.json"),options:.atomic)
        let data = try encoder.encode(result)
        try data.write(to:directory.appendingPathComponent("final_ready.json"),options:.atomic)
        let report: [String:Any] = ["schema":"metra-chunk-export-report-v4","run_id":document.id,"export_id":exportID,
            "chunk_builder":ReadingChunkBuilder.version,"grouping_status":topicIndex.membershipStatus,"qwen_topic_requests":0,
            "topic_policy":topicIndex.policy,"topics":topicIndex.topics.count,"topic_quality_status":"not_assessed",
            "build":BuildIdentity.metadata,"input_mode":"existing_final_extraction_no_inference",
            "diagram_inference_requests":0,"source_snapshot":result.sourceArtifact,
            "generic_topics":topicIndex.topics.filter { $0.titleSource == "application_fallback" }.count,
            "chunks":candidates.count,"diagram_chunks":candidates.filter { $0.chunk.diagramID != nil }.count,
            "question_starts":candidates.filter { $0.chunk.kind == "question_start" }.count,
            "reading_normalization":QuestionReadingNormalizer.version,"questions":result.questions?.count ?? 0,
            "answer_choices":candidates.filter { $0.chunk.kind == "answer_choice" }.count,
            "wall_ms":(ProcessInfo.processInfo.systemUptime-started)*1000,
            "source_coverage_status":"not_assessed","human_approved":false,"tts_approved":false,
            "redundant_detection_aliases":document.pages.flatMap(\.formulas).filter { $0.coveredByFormulaIDs != nil }.count,
            "preservation":"Every OCR source slice and non-aliased formula occurrence is covered once; proven enclosing duplicates remain as coveredByFormulaIDs provenance, without a second reading. This does not establish photo recall or recognition accuracy."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:paths.root.appendingPathComponent(result.reportArtifact),options:.atomic)
        // Publish the latest view only after its immutable snapshot and report exist.
        try data.write(to:paths.readyExtraction,options:.atomic)
        return result
    }
}
