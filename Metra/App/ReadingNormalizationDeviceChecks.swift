#if DEBUG
import Foundation

/// Guard checks for the single, user-authorized image pilot. Cached source and
/// small MathML fixtures are separate from the subsequent fresh model run.
@MainActor
enum ReadingNormalizationDeviceChecks {
    static func run(root:URL, finalHash:String, pageHash:String) async throws -> [String:Any] {
        let repository = RunRepository()
        let finalURL = root.appendingPathComponent("baseline.final-extraction.json")
        let pageURL = root.appendingPathComponent("baseline.page-result.json")
        let finalData = try Data(contentsOf:finalURL), pageData = try Data(contentsOf:pageURL)
        guard ImageIngestor.sha256(finalData) == finalHash, ImageIngestor.sha256(pageData) == pageHash else {
            throw LayoutRuntimeError.invalid("Cached normalization input checksum mismatch")
        }
        let source = try JSONDecoder().decode(FinalExtractionDocument.self,from:finalData)
        let page = try JSONDecoder().decode(PageExtraction.self,from:pageData)
        var checks: [String:Bool] = [:]
        let pages = try source.pages.map { old -> FinalPage in
            let normalized = try QuestionReadingNormalizer.normalize(pageID:old.id,blocks:old.blocks,formulas:old.formulas,
                observations:page.rawOCR,pageWidth:old.width)
            return FinalPage(id:old.id,sourceID:old.sourceID,sourceSHA256:old.sourceSHA256,imageArtifact:old.imageArtifact,
                width:old.width,height:old.height,runtimeStatus:old.runtimeStatus,sourceCoverageStatus:old.sourceCoverageStatus,
                contentQualityStatus:old.contentQualityStatus,readingOrderMethod:QuestionReadingNormalizer.version,
                blocks:normalized.blocks,formulas:old.formulas,diagrams:old.diagrams,readingNormalization:normalized.report)
        }
        let derived = FinalExtractionDocument(schema:source.schema,id:source.id,mergePolicyVersion:source.mergePolicyVersion,
            profile:source.profile,runtimeStatus:source.runtimeStatus,sourceCoverageStatus:source.sourceCoverageStatus,
            contentQualityStatus:source.contentQualityStatus,startedAt:source.startedAt,completedAt:source.completedAt,
            artifacts:source.artifacts,pages:pages)
        let chunks = try ReadingChunkBuilder.build(derived,artifactPrefix:"cached-reading")
        let groups = pages.flatMap(\.blocks).filter { $0.choiceLabel != nil }
        let byQuestion = Dictionary(grouping:groups,by:{ $0.questionID ?? "" })
        checks["six_source_questions_normalized"] = byQuestion.count == 6
        checks["all_choices_ABCD_in_source_question"] = byQuestion.values.allSatisfy { $0.map(\.choiceLabel) == ["A","B","C","D"] }
        checks["each_choice_one_chunk_with_source_slices"] = groups.allSatisfy { block in
            let matches = chunks.filter { $0.blockID == block.id }
            return matches.count == 1 && matches[0].chunk.kind == "answer_choice" && !matches[0].sourceSlices.isEmpty
        }
        checks["split_C_300_read_label_first"] = chunks.contains { $0.chunk.kind == "answer_choice" && $0.chunk.sourceText == "C. 300" }
        checks["all_source_segments_retained"] = pages.allSatisfy { $0.readingNormalization?.sourceSegmentsPreservedExactlyOnce == true }
        try repository.writeJSON(derived,to:root.appendingPathComponent("cached-normalized.final-extraction.json"))
        try repository.writeJSON(chunks,to:root.appendingPathComponent("cached-normalized.chunks.json"))

        var unitRows: [[String:Any]] = []
        for region in page.layoutRegions ?? [] {
            guard let text = region.proposalText, LengthUnitSource.parse(text) != nil,
                  let formula = page.formulaRegions?.first(where:{ $0.layoutRegionID == region.id }), let raw = formula.mathML else { continue }
            let result = LengthUnitNormalizer.normalize(source:text,mathML:raw)
            var row: [String:Any] = ["source":text,"formula_id":formula.id,"allowed":result.allowed,"raw_mathml":raw]
            if let normalized = result.normalizedMathML {
                let speech = try await MathCATAdapter.shared.speak(mathML:normalized)
                row["normalized_mathml"] = normalized; row["spoken"] = speech.spokenText
                row["has_full_unit_name"] = speech.spokenText.contains("meter") && !speech.spokenText.contains("c m")
            }
            unitRows.append(row)
        }
        checks["all_eight_cached_measurements_normalize"] = unitRows.count == 8 && unitRows.allSatisfy { $0["allowed"] as? Bool == true }
        checks["mathcat_reads_complete_unit_names"] = unitRows.allSatisfy { $0["has_full_unit_name"] as? Bool == true }
        let split = "<math><mn>616</mn><mi>c</mi><msup><mi>m</mi><mn>2</mn></msup></math>"
        checks["corrupt_suffix_needs_image_power"] = LengthUnitNormalizer.normalize(source:"616 cmг",mathML:split).allowed &&
            !LengthUnitNormalizer.normalize(source:"616 cmг",mathML:"<math><mn>616</mn><mi>cm</mi><mn>2</mn></math>").allowed
        checks["explicit_power_conflict_withheld"] = !LengthUnitNormalizer.normalize(source:"616 cm³",mathML:split).allowed
        checks["flattened_power_conflict_withheld"] = !LengthUnitNormalizer.normalize(source:"616 cm3",mathML:split).allowed
        checks["number_change_withheld"] = !LengthUnitNormalizer.normalize(source:"616 cm2",mathML:split.replacingOccurrences(of:">616<",with:">6161<")).allowed
        checks["extra_operator_withheld"] = !LengthUnitNormalizer.normalize(source:"616 cm2",mathML:split.replacingOccurrences(of:"<mn>616",with:"<mo>+</mo><mn>616")).allowed
        checks["wrong_unit_withheld"] = !LengthUnitNormalizer.normalize(source:"616 m2",mathML:split).allowed
        checks["baseline_bytes_unchanged"] = try Data(contentsOf:finalURL) == finalData && Data(contentsOf:pageURL) == pageData
        let report: [String:Any] = ["scope":"Cached real artifacts and explicit MathML guard fixtures, no detector/recognizer inference; not an image accuracy score",
                                  "checks":checks,"unit_rows":unitRows,"all_passed":checks.values.allSatisfy{$0}]
        try repository.writeJSON(report,to:root.appendingPathComponent("cached-checks.json"))
        guard checks.values.allSatisfy({$0}) else {
            throw LayoutRuntimeError.invalid("Cached normalization guards failed: \(checks.filter{!$0.value}.keys.sorted().joined(separator:", ")); fresh image inference not started")
        }
        return report
    }
}
#endif
