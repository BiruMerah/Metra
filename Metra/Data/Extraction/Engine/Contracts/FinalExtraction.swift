import Foundation

/// Import identity is (document.id, local id). Re-importing a run can upsert these
/// identities; page/segment ids are deliberately not regenerated during export.
struct FinalExtractionDocument: Codable, Sendable {
    let schema: String
    let id: String
    let mergePolicyVersion: String
    let profile: RunProfile
    let runtimeStatus: RuntimeStatus
    let sourceCoverageStatus: ReviewStatus
    let contentQualityStatus: ReviewStatus
    let startedAt: String
    let completedAt: String?
    let artifacts: [String: String]
    let pages: [FinalPage]
}

struct FinalPage: Codable, Identifiable, Sendable {
    let id: String
    let sourceID: String
    let sourceSHA256: String
    let imageArtifact: String
    let width: Int
    let height: Int
    let runtimeStatus: RuntimeStatus
    let sourceCoverageStatus: ReviewStatus
    let contentQualityStatus: ReviewStatus
    let readingOrderMethod: String
    let blocks: [FinalBlock]
    let formulas: [FinalFormula]
    var diagrams: [FinalDiagram]? = nil
    var readingNormalization: QuestionReadingNormalizer.Report? = nil
}

struct FinalBlock: Codable, Identifiable, Sendable {
    let id: String
    let kind: String
    let bboxPageXYXY: PixelBox
    let readingOrder: Int
    let status: String
    let segments: [FinalSegment]
    var questionID: String? = nil
    var questionNumber: String? = nil
    var choiceLabel: String? = nil
    var sourceBlockIDs: [String]? = nil
}

struct OCRSourceReference: Codable, Hashable, Sendable {
    let artifact: String
    let observationID: String
    let rangeUTF16: [Int]
}

struct FinalSegment: Codable, Identifiable, Sendable {
    let id: String
    let kind: String
    /// Present on prose only. A math segment resolves its content via formulaID.
    let text: String?
    let formulaID: String?
    let status: String
    let sourceRefs: [OCRSourceReference]
    /// Explicit derived whitespace for line/boundary joins; raw slices stay exact.
    let joinBefore: String?
    let joinReason: String?
    var readingRole: String? = nil
}

struct FinalFormula: Codable, Identifiable, Sendable {
    let id: String
    let segmentID: String
    let sourceText: String
    let latex: String?
    /// Raw MathCAT speech is retained in its artifact when merge is withheld.
    let spokenText: String?
    let status: String
    let recognitionStatus: String
    let sourceConsistencyStatus: String
    let mergeMethods: [String]
    let reviewReasons: [String]
    let bboxPageXYXY: PixelBox
    let artifacts: [String: String]
    var recognitionRoute:[String]? = nil
    var spokenCandidate:String? = nil
    var coveredByFormulaIDs: [String]? = nil
}

enum FinalExtractionBuilder {
    static func build(_ document: ExtractionDocument) throws -> FinalExtractionDocument {
        let pages = try document.pages.map(buildPage)
        try requireUnique(pages.map(\.id))
        return FinalExtractionDocument(
            schema: "metra-final-extraction-v1", id: document.runID,
            mergePolicyVersion: FormulaSpanResolver.version, profile: document.profile,
            runtimeStatus: document.runtimeStatus, sourceCoverageStatus: document.sourceCoverageStatus,
            contentQualityStatus: pages.contains { $0.contentQualityStatus == .needsReview } ? .needsReview : document.contentQualityStatus,
            startedAt: document.startedAt, completedAt: document.completedAt,
            artifacts: ["source": "source-extraction.json", "spoken": "spoken-extraction.json", "report": "report.json", "models": "model-manifest.snapshot.json", "config": "config.snapshot.json"],
            pages: pages
        )
    }

    private static func buildPage(_ page: PageExtraction) throws -> FinalPage {
        // Old persisted page results remain readable. Only the derived final view
        // is remapped; the original results/artifacts are never rewritten here.
        let blocks: [ExtractionBlock]
        if page.mergePolicyVersion != FormulaSpanResolver.version, let regions = page.layoutRegions {
            blocks = LayoutMerge.blocks(pageID: page.id, regions: regions, observations: page.rawOCR, formulas: page.formulaRegions ?? [])
        } else { blocks = page.blocks }
        try validateSourceSlices(page.rawOCR, blocks: blocks)
        try requireUnique(blocks.map(\.id))
        let segments = blocks.flatMap(\.segments)
        try requireUnique(segments.map(\.id))
        let formulas = page.formulaRegions ?? []
        try requireUnique(formulas.map(\.id))
        let formulaByID = Dictionary(uniqueKeysWithValues: formulas.map { ($0.id, $0) })
        let references = Dictionary(grouping: segments.filter { $0.formulaID != nil }, by: { $0.formulaID! })
        guard Set(references.keys).isSubset(of: Set(formulaByID.keys)) else { throw FinalExportError.invalidFormulaReference }
        let ocrByID = Dictionary(uniqueKeysWithValues: page.rawOCR.map { ($0.id, $0) })

        func sourceRefs(_ inputs: [TextSegment]) -> [OCRSourceReference] {
            inputs.compactMap { segment in
                guard let id = segment.sourceObservationID, segment.sourceRangeUTF16.count == 2 else { return nil }
                return OCRSourceReference(artifact: "pages/\(page.id)/ocr.raw.json", observationID: id, rangeUTF16: segment.sourceRangeUTF16)
            }.sorted {
                let a = ocrByID[$0.observationID]?.rawOrder ?? 0, b = ocrByID[$1.observationID]?.rawOrder ?? 0
                if a != b { return a < b }
                if $0.observationID != $1.observationID { return $0.observationID < $1.observationID }
                return $0.rangeUTF16[0] < $1.rangeUTF16[0]
            }
        }
        var ownerByFormula: [String: String] = [:]
        var finalBlocks: [FinalBlock] = []
        var finalFormulas: [FinalFormula] = []
        for block in blocks.sorted(by: { $0.readingOrder == $1.readingOrder ? $0.id < $1.id : $0.readingOrder < $1.readingOrder }) {
            var output: [FinalSegment] = []
            var previousSource: TextSegment?
            var previousRendered = ""
            for segment in block.segments {
                var refs = sourceRefs([segment])
                var rendered = segment.textRaw
                var status = segment.status
                if let formulaID = segment.formulaID {
                    guard ownerByFormula[formulaID] == nil else { continue }
                    guard let formula = formulaByID[formulaID] else { throw FinalExportError.invalidFormulaReference }
                    ownerByFormula[formulaID] = segment.id
                    let inputs = references[formulaID] ?? [segment]
                    refs = sourceRefs(inputs)
                    let coveredBy = segment.coveredByFormulaIDs
                    let needsReview = inputs.contains { ["needs_review", "unresolved"].contains($0.status) } || formula.spokenMergeAllowed == false
                    let speech = needsReview ? nil : inputs.compactMap(\.spokenText).first
                    status = coveredBy != nil ? "duplicate_detection" : (speech == nil ? "needs_review" : "ready")
                    let source = refs.compactMap { ref -> String? in
                        guard let observation = ocrByID[ref.observationID] else { return nil }
                        return (observation.selectedText as NSString).substring(with: NSRange(location: ref.rangeUTF16[0], length: ref.rangeUTF16[1] - ref.rangeUTF16[0]))
                    }.joined(separator: "\n")
                    var artifacts: [String: String] = [:]
                    if let crop = formula.recognitionCropArtifact ?? formula.cropArtifact { artifacts["crop"] = crop }
                    if let raw = formula.recognitionArtifact { artifacts["recognition"] = raw }
                    if formula.mathML != nil { artifacts["mathml"] = "pages/\(page.id)/formulas/\(formula.id)/mathml.xml" }
                    for stage in formula.stageResults ?? [] {
                        if let path = stage.rawArtifact, ["mathjax", "mathcat"].contains(stage.component) { artifacts[stage.component] = path }
                        if let path = stage.rawArtifact, stage.component == "vision_numeric_corroboration" { artifacts["numeric_merge_decision"] = path }
                        if let path = stage.rawArtifact, stage.component == "formula_exponent_consistency" { artifacts["exponent_consistency"] = path }
                        if let path = stage.rawArtifact, stage.component == "formula_degree_expression_consistency" { artifacts["degree_expression_consistency"] = path }
                        if let path = stage.rawArtifact, stage.component == "formula_unit_consistency" { artifacts["unit_consistency"] = path }
                        if let path = stage.rawArtifact, stage.component == "formula_unit_normalization" {
                            artifacts["unit_normalization"] = path
                        }
                        if let path = stage.rawArtifact, stage.component == "mathcat_unit_normalized" {
                            artifacts["normalized_mathcat"] = path
                            artifacts["normalized_mathml"] = "pages/\(page.id)/formulas/\(formula.id)/mathml.unit-normalized.xml"
                        }
                        if let path = stage.rawArtifact, stage.component == "mfd_crop_provenance" { artifacts["crop_merge"] = path }
                    }
                    var reasons = inputs.compactMap(\.mergeNote)
                    if let reason = formula.sourceConsistencyMessage, formula.spokenMergeAllowed == false { reasons.append(reason) }
                    if speech == nil, reasons.isEmpty, coveredBy == nil { reasons.append(formula.failureMessage ?? "Spoken output unavailable or source attachment requires review") }
                    finalFormulas.append(FinalFormula(id: formulaID, segmentID: segment.id, sourceText: source, latex: formula.latex, spokenText: speech, status: status, recognitionStatus: formula.status, sourceConsistencyStatus: formula.sourceConsistencyStatus ?? "not_assessed", mergeMethods: Array(Set(inputs.compactMap(\.mergeMethod))).sorted(), reviewReasons: Array(Set(reasons)).sorted(), bboxPageXYXY: formula.bboxPageXYXY, artifacts: artifacts,recognitionRoute:formula.route,spokenCandidate:speech == nil && formula.route.contains("literal_numeric_mathml_v1") ? formula.spokenText : nil,coveredByFormulaIDs:coveredBy))
                    rendered = speech ?? source
                }
                let lineChanged = previousSource != nil && previousSource?.sourceObservationID != segment.sourceObservationID
                let mathBoundary = previousSource?.formulaID != nil || segment.formulaID != nil
                let needsSpace = !output.isEmpty && (lineChanged || mathBoundary) && shouldInsertSpace(previousRendered, rendered)
                output.append(FinalSegment(id: segment.id, kind: segment.formulaID == nil ? segment.kind : "math", text: segment.formulaID == nil ? segment.textRaw : nil, formulaID: segment.formulaID, status: status, sourceRefs: refs, joinBefore: needsSpace ? " " : nil, joinReason: needsSpace ? (lineChanged ? "ocr_line_boundary" : "text_math_boundary") : nil))
                previousSource = segment
                previousRendered = rendered
            }
            // Retain unsupported visual content explicitly; empty layout containers
            // and formula children have no second reading path in the final view.
            let unsupported = DiagramSpokenService.visualLabels.contains(block.kind) || block.kind == "table"
            guard !output.isEmpty || unsupported else { continue }
            let status = unsupported ? "unsupported" : (output.contains { $0.status == "needs_review" } ? "needs_review" : "ready")
            finalBlocks.append(FinalBlock(id: block.id, kind: block.kind, bboxPageXYXY: block.bboxPageXYXY, readingOrder: block.readingOrder, status: status, segments: output))
        }
        let diagramResults = page.diagrams ?? []
        let finalDiagrams = diagramResults.map { DiagramSpokenService.render($0, formulas: Dictionary(uniqueKeysWithValues: finalFormulas.map { ($0.id,$0) })) }
        let diagramByID = Dictionary(uniqueKeysWithValues:finalDiagrams.map { ($0.layoutRegionID,$0) })
        // Absorb each visual's OCR/formula child into one visual reading block.
        // Source refs and formula segment ids remain unchanged and are checked below.
        var moved: [String:[FinalSegment]] = [:]
        var kept: [FinalBlock] = []
        for block in finalBlocks {
            var remaining: [FinalSegment] = []
            for segment in block.segments {
                let target = diagramResults.first { diagram in
                    if let formulaID = segment.formulaID { return diagram.formulaIDs.contains(formulaID) }
                    return !segment.sourceRefs.isEmpty && segment.sourceRefs.allSatisfy { diagram.sourceObservationIDs.contains($0.observationID) }
                }
                if let target { moved[target.layoutRegionID,default:[]].append(segment) }
                else { remaining.append(segment) }
            }
            kept.append(FinalBlock(id:block.id,kind:block.kind,bboxPageXYXY:block.bboxPageXYXY,readingOrder:block.readingOrder,status:block.status,segments:remaining))
        }
        finalBlocks = kept.compactMap { block in
            let segments = block.segments + (moved[block.id] ?? [])
            let diagram = diagramByID[block.id]
            guard !segments.isEmpty || diagram != nil || block.status == "unsupported" else { return nil }
            return FinalBlock(id:block.id,kind:block.kind,bboxPageXYXY:block.bboxPageXYXY,readingOrder:block.readingOrder,
                              status:diagram?.status ?? block.status,segments:segments)
        }
        guard Set(ownerByFormula.keys) == Set(formulaByID.keys) else { throw FinalExportError.invalidFormulaReference }
        let finalByID = Dictionary(uniqueKeysWithValues: finalFormulas.map { ($0.id, $0) })
        for alias in finalFormulas where alias.coveredByFormulaIDs != nil {
            let coveredBy = alias.coveredByFormulaIDs ?? []
            guard alias.status == "duplicate_detection", alias.spokenText == nil, alias.sourceText.isEmpty,
                  coveredBy.count >= 2, Set(coveredBy).count == coveredBy.count,
                  coveredBy.allSatisfy({ id in
                      guard let child = finalByID[id] else { return false }
                      return child.coveredByFormulaIDs == nil && child.status == "ready" && !child.sourceText.isEmpty
                  }) else { throw FinalExportError.invalidFormulaReference }
        }
        let normalization = try QuestionReadingNormalizer.normalize(pageID: page.id, blocks: finalBlocks,
            formulas: finalFormulas, observations: page.rawOCR, pageWidth: page.source.normalizedWidth)
        finalBlocks = normalization.blocks
        let finalRefs = finalBlocks.flatMap(\.segments).flatMap(\.sourceRefs)
        let originalRefs = sourceRefs(segments)
        guard finalRefs.count == originalRefs.count, Set(finalRefs) == Set(originalRefs) else { throw FinalExportError.sourceCoverageChanged }
        let hasReview = finalBlocks.contains { ["needs_review", "unsupported", "failed", "skipped_dependency", "cancelled"].contains($0.status) }
        return FinalPage(id: page.id, sourceID: page.source.id, sourceSHA256: page.source.sourceSHA256,
                         imageArtifact: "pages/\(page.id)/normalized.png", width: page.source.normalizedWidth, height: page.source.normalizedHeight,
                         runtimeStatus: page.runtimeStatus, sourceCoverageStatus: page.sourceCoverageStatus,
                         contentQualityStatus: hasReview ? .needsReview : page.contentQualityStatus,
                         readingOrderMethod: page.readingOrderMethod + "; " + QuestionReadingNormalizer.version,
                         blocks: finalBlocks, formulas: finalFormulas, diagrams: finalDiagrams, readingNormalization: normalization.report)
    }

    private static func shouldInsertSpace(_ previous: String, _ next: String) -> Bool {
        guard let last = previous.last, let first = next.first, !last.isWhitespace, !first.isWhitespace else { return false }
        return !".,;:!?)]}".contains(first) && last != "(" && last != "[" && last != "{"
    }

    private static func requireUnique(_ ids: [String]) throws {
        guard Set(ids).count == ids.count else { throw FinalExportError.duplicateIdentity }
    }

    private static func validateSourceSlices(_ observations: [OCRObservation], blocks: [ExtractionBlock]) throws {
        try requireUnique(observations.map(\.id))
        let grouped = Dictionary(grouping: blocks.flatMap(\.segments).filter { $0.sourceObservationID != nil }, by: { $0.sourceObservationID! })
        guard Set(grouped.keys).isSubset(of: Set(observations.map(\.id))) else { throw FinalExportError.sourceCoverageChanged }
        for observation in observations {
            let source = observation.selectedText as NSString
            var cursor = 0
            for segment in (grouped[observation.id] ?? []).sorted(by: { ($0.sourceRangeUTF16.first ?? -1) < ($1.sourceRangeUTF16.first ?? -1) }) {
                let range = segment.sourceRangeUTF16
                guard range.count == 2, range[0] == cursor, range[1] >= range[0], range[1] <= source.length,
                      Range(NSRange(location: range[0], length: range[1] - range[0]), in: observation.selectedText) != nil,
                      source.substring(with: NSRange(location: range[0], length: range[1] - range[0])) == segment.textRaw else { throw FinalExportError.sourceCoverageChanged }
                cursor = range[1]
            }
            guard cursor == source.length else { throw FinalExportError.sourceCoverageChanged }
        }
    }
}

enum FinalExportError: LocalizedError {
    case duplicateIdentity, invalidFormulaReference, sourceCoverageChanged
    var errorDescription: String? {
        switch self {
        case .duplicateIdentity: "Ekspor final gagal: identitas konten berulang. Hasil sumber tetap tersimpan."
        case .invalidFormulaReference: "Ekspor final gagal: referensi formula tidak memiliki satu pemilik segmen. Hasil sumber tetap tersimpan."
        case .sourceCoverageChanged: "Ekspor final gagal: rentang OCR hilang, berubah, atau berulang. Hasil sumber tetap tersimpan."
        }
    }
}
