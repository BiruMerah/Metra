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
    let kind: String
    let pageID: String
    let status: String
    let sourceText: String
    /// Complete merged speech only. Never silently skip an unresolved formula.
    let spokenText: String?
    /// Present for incomplete speech; review markers are explicitly presentation text.
    let spokenPreview: String?
    let unresolvedFormulaIDs: [String]
    let sourceRef: String
    var diagramID: String? = nil
    var imageArtifact: String? = nil
    var uncertainties: [String]? = nil
    var diagramPairs: [DiagramRenderedPair]? = nil
}

struct ChunkSourceSlice: Codable, Equatable, Sendable {
    let segmentID: String
    /// Relative to FinalSegment.text, not to the whole OCR observation.
    let textRangeUTF16: [Int]?
    let formulaID: String?
}

struct ChunkCandidate: Codable, Sendable {
    let chunk: ReadyChunk
    let blockID: String
    let readingOrder: Int
    let sourceSlices: [ChunkSourceSlice]
    let isAuxiliary: Bool
    let derivation: String
}

enum ReadingChunkBuilder {
    static let version = "sentence_atomic_math_headings_v3"

    private struct Atom {
        let mask: String
        let source: String
        let speech: String?
        let preview: String
        let slice: ChunkSourceSlice?
        let unresolvedFormulaID: String?
    }

    static func build(_ document: FinalExtractionDocument, artifactPrefix: String) throws -> [ChunkCandidate] {
        var candidates: [ChunkCandidate] = []
        for page in document.pages {
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
                    let chunk = ReadyChunk(id:id,kind:"diagram",pageID:page.id,status:diagram.status,sourceText:source,
                        spokenText:diagram.spokenText,spokenPreview:diagram.spokenPreview,
                        unresolvedFormulaIDs:diagram.unresolvedFormulaIDs,sourceRef:"\(artifactPrefix)/chunks/\(id).json",
                        diagramID:diagram.id,imageArtifact:diagram.artifacts["crop"],uncertainties:diagram.uncertainties,diagramPairs:diagram.pairs)
                    candidates.append(ChunkCandidate(chunk:chunk,blockID:block.id,readingOrder:block.readingOrder,sourceSlices:slices,isAuxiliary:false,
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
                        atoms.append(Atom(mask: "\u{FFFC}", source: formula.sourceText, speech: formula.spokenText,
                                          preview: formula.spokenText ?? "[perlu review: \(formula.sourceText.isEmpty ? id : formula.sourceText)]",
                                          slice: ChunkSourceSlice(segmentID: segment.id, textRangeUTF16: nil, formulaID: id),
                                          unresolvedFormulaID: formula.spokenText == nil ? id : nil))
                    } else {
                        let text = segment.text ?? ""
                        for start in text.indices {
                            let end = text.index(after: start), part = String(text[start..<end])
                            atoms.append(Atom(mask: part, source: part, speech: part, preview: part,
                                              slice: ChunkSourceSlice(segmentID: segment.id, textRangeUTF16: [start.utf16Offset(in: text), end.utf16Offset(in: text)], formulaID: nil), unresolvedFormulaID: nil))
                        }
                    }
                }
                let masked = atoms.map(\.mask).joined()
                let preserveBlock = ["doc_title", "paragraph_title", "heading", "header", "footer", "number", "formula", "table", "image", "diagram"].contains(block.kind)
                var sentenceEnds: [Int] = []
                if !preserveBlock, !masked.isEmpty {
                    let tokenizer = NLTokenizer(unit: .sentence)
                    tokenizer.string = masked
                    tokenizer.enumerateTokens(in: masked.startIndex..<masked.endIndex) { range, _ in
                        sentenceEnds.append(range.upperBound.utf16Offset(in: masked)); return true
                    }
                }
                var groups: [[Atom]] = [], group: [Atom] = []
                var offset = 0, sentenceIndex = 0
                for atom in atoms {
                    if sentenceIndex < sentenceEnds.count, offset >= sentenceEnds[sentenceIndex],
                       !atom.mask.allSatisfy(\.isWhitespace), !group.isEmpty {
                        groups.append(group); group = []
                        while sentenceIndex < sentenceEnds.count && offset >= sentenceEnds[sentenceIndex] { sentenceIndex += 1 }
                    }
                    group.append(atom); offset += atom.mask.utf16.count
                }
                if !group.isEmpty { groups.append(group) }
                if groups.isEmpty { groups = [[]] }
                for (index, items) in groups.enumerated() {
                    let id = "\(block.id).c\(String(format: "%04d", index + 1))"
                    let source = items.map(\.source).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    let preview = items.map(\.preview).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    let unsupported = block.status == "unsupported"
                    let missing = Array(Set(items.compactMap(\.unresolvedFormulaID))).sorted()
                    let complete = !unsupported && items.allSatisfy { $0.speech != nil }
                    let speech = complete ? items.compactMap(\.speech).joined().trimmingCharacters(in: .whitespacesAndNewlines) : nil
                    let chunk = ReadyChunk(id: id, kind: preserveBlock ? block.kind : "sentence", pageID: page.id,
                                           status: unsupported ? "unsupported" : (complete ? "ready" : "needs_review"),
                                           sourceText: source, spokenText: speech,
                                           spokenPreview: complete ? nil : (unsupported && preview.isEmpty ? "[isi \(block.kind) belum tersedia]" : preview),
                                           unresolvedFormulaIDs: missing, sourceRef: "\(artifactPrefix)/chunks/\(id).json")
                    var slices: [ChunkSourceSlice] = []
                    for slice in items.compactMap(\.slice) {
                        if let last = slices.last, last.segmentID == slice.segmentID,
                           let a = last.textRangeUTF16, let b = slice.textRangeUTF16, a[1] == b[0] {
                            slices[slices.count - 1] = ChunkSourceSlice(segmentID: last.segmentID, textRangeUTF16: [a[0], b[1]], formulaID: nil)
                        } else { slices.append(slice) }
                    }
                    candidates.append(ChunkCandidate(chunk: chunk, blockID: block.id, readingOrder: block.readingOrder, sourceSlices: slices,
                                                     isAuxiliary: ["footer", "header", "number"].contains(block.kind),
                                                     derivation: "\(version): NLTokenizer sentence boundaries on prose; each formula occurrence is atomic; existing joins retained; outer chunk whitespace trimmed in reading view only"))
                }
            }
        }
        try validateCoverage(document, candidates: candidates)
        return candidates
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
                for slice in slices {
                    guard let range = slice.textRangeUTF16, range[0] == cursor, range[1] >= cursor else { throw FinalExportError.sourceCoverageChanged }
                    cursor = range[1]
                }
                guard cursor == (segment.text ?? "").utf16.count else { throw FinalExportError.sourceCoverageChanged }
            }
        }
    }
}

// v1 topic artifacts remain decodable; new exports have one top-level chunks array.
extension ReadyExtractionDocument {
    private enum CodingKeys: String, CodingKey {
        case schema,id,groupingAttemptID,exportID,status,groupingStatus,topicQualityStatus,sourceCoverageStatus,contentQualityStatus,createdAt,sourceArtifact,topics,ungroupedChunks,auxiliaryChunks,reportArtifact,chunks,topicIndex
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
        let result = ReadyExtractionDocument(schema:"metra-ready-chunks-v3",id:document.id,groupingAttemptID:exportID,
            status:candidates.contains { !["ready","generated"].contains($0.chunk.status) } || topicIndex.topics.contains { $0.status == "needs_review" } ? "needs_review" : "draft",
            groupingStatus:topicIndex.membershipStatus,topicQualityStatus:.notAssessed,sourceCoverageStatus:document.sourceCoverageStatus,
            contentQualityStatus:document.contentQualityStatus,createdAt:ISO8601DateFormatter().string(from:Date()),
            sourceArtifact:"\(prefix)/input.final-extraction.json",topics:[],ungroupedChunks:[],auxiliaryChunks:[],reportArtifact:"\(prefix)/report.json",
            chunks:candidates.map(\.chunk),topicIndex:topicIndex)
        try encoder.encode(document).write(to:directory.appendingPathComponent("input.final-extraction.json"),options:.atomic)
        let data = try encoder.encode(result)
        try data.write(to:directory.appendingPathComponent("final_ready.json"),options:.atomic)
        let report: [String:Any] = ["schema":"metra-chunk-export-report-v3","run_id":document.id,"export_id":exportID,
            "chunk_builder":ReadingChunkBuilder.version,"grouping_status":topicIndex.membershipStatus,"qwen_topic_requests":0,
            "topic_policy":topicIndex.policy,"topics":topicIndex.topics.count,"topic_quality_status":"not_assessed",
            "build":BuildIdentity.metadata,"input_mode":"existing_final_extraction_no_inference",
            "diagram_inference_requests":0,"source_snapshot":result.sourceArtifact,
            "generic_topics":topicIndex.topics.filter { $0.titleSource == "application_fallback" }.count,
            "chunks":candidates.count,"diagram_chunks":candidates.filter { $0.chunk.diagramID != nil }.count,
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
