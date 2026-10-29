#if DEBUG
import Foundation

/// Fresh production import plus comparisons against saved successful speech.
/// Expected answers are test-only; none are supplied to recognition models.
@MainActor
enum FormulaRegressionDeviceProbe {
    private static var started = Set<String>()
    private struct Fixture: Decodable {
        let name:String
        let sourceSHA256:String
        let bbox:PixelBox
        let expectedSpeech:String
    }
    static func run(attemptID:String,coordinator:AppCoordinator) async {
        guard let id = UUID(uuidString:attemptID)?.uuidString.lowercased(),started.insert(id).inserted,
              let documents = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else { return }
        let root = documents.appendingPathComponent("verification/formula-regression-v1/\(id)")
        guard !FileManager.default.fileExists(atPath:root.appendingPathComponent("completed.json").path) else { return }
        let inputs = documents.appendingPathComponent("verification/multipage-clearspeak-v1/\(id)")
        let repository = RunRepository()
        var report:[String:Any] = ["schema":"metra-formula-regression-device-v1","attempt_id":id,
            "build":BuildIdentity.metadata,"status":"running",
            "scope":"Fresh five-page import on iPhone; compare previous successful formulas and persisted reader speech. No expected answers sent to models."]
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            try repository.writeJSON(report,to:root.appendingPathComponent("report.json"))
            let baseline = try JSONDecoder().decode(FinalExtractionDocument.self,from:Data(contentsOf:inputs.appendingPathComponent("baseline.json")))
            let fixtures = try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:inputs.appendingPathComponent("fixtures.json")))
            await ImageOnlyDiagramDeviceProbe.run(attemptID:id,coordinator:coordinator)
            let completion = try JSONSerialization.jsonObject(with:Data(contentsOf:inputs.appendingPathComponent("completed.json"))) as? [String:Any]
            guard let run = completion?["run_id"] as? String,
                  let savedID = completion?["saved_material_id"] as? String,let materialID = UUID(uuidString:savedID),
                  let material = try coordinator.mathMaterialService.fetchSavedMaterial(id:materialID) else {
                throw CheckError.failed("Missing completed run or persisted material")
            }
            let runRoot = try coordinator.extractionService.artifactURL(for:"metra-runs/\(run)")
            let final = try JSONDecoder().decode(FinalExtractionDocument.self,from:Data(contentsOf:runRoot.appendingPathComponent("final-extraction.json")))
            let candidates = try ReadingChunkBuilder.build(final,artifactPrefix:"audit")
            let persisted = Dictionary(uniqueKeysWithValues:material.chunks.map { ($0.id,$0) })
            func clean(_ text:String) -> String { text.components(separatedBy:.whitespacesAndNewlines).filter{!$0.isEmpty}.joined(separator:" ") }
            func readerProjection(_ formula:FinalFormula) -> (text:String,covered:Bool,unresolved:Bool) {
                let chunks = candidates.filter { $0.sourceSlices.contains { $0.formulaID == formula.id } }.compactMap { persisted[$0.chunk.id] }
                return (chunks.map { ReadingPresentation.accessibilityLabel(for:$0) }.joined(separator:" "),
                    !chunks.isEmpty,chunks.contains { $0.unresolvedFormulaIDs.contains(formula.id) })
            }
            var checks:[String:Bool] = [:],comparisons:[[String:Any]] = [],recoveries:[[String:Any]] = []
            var baselineCount = 0
            for page in baseline.pages {
                guard let current = final.pages.first(where:{ $0.sourceSHA256 == page.sourceSHA256 }) else {
                    checks["\(page.id).same_source_page"] = false;continue
                }
                for old in page.formulas where old.spokenText != nil {
                    baselineCount += 1
                    let matched = current.formulas.max { old.bboxPageXYXY.iou($0.bboxPageXYXY) < old.bboxPageXYXY.iou($1.bboxPageXYXY) }
                    let overlap = matched.map { old.bboxPageXYXY.iou($0.bboxPageXYXY) } ?? 0
                    let rendered = matched.map(readerProjection)
                    let expected = clean(old.spokenText!)
                    let sameSpeech = matched?.spokenText.map(clean) == expected
                    let readerPreserved = rendered.map { $0.covered && !$0.unresolved && clean($0.text).contains(expected) } ?? false
                    checks["baseline.\(old.id).speech_preserved"] = overlap >= 0.5 && sameSpeech
                    checks["baseline.\(old.id).reader_preserved"] = overlap >= 0.5 && readerPreserved
                    comparisons.append(["baseline_formula":old.id,"current_formula":matched?.id ?? "missing",
                        "expected_speech":expected,"current_speech":matched?.spokenText ?? "",
                        "iou":overlap,"speech_preserved":sameSpeech,"reader_preserved":readerPreserved])
                }
            }
            for fixture in fixtures {
                let current = final.pages.first { $0.sourceSHA256 == fixture.sourceSHA256 }
                let matched = current?.formulas.max { fixture.bbox.iou($0.bboxPageXYXY) < fixture.bbox.iou($1.bboxPageXYXY) }
                let overlap = matched.map { fixture.bbox.iou($0.bboxPageXYXY) } ?? 0
                let rendered = matched.map(readerProjection)
                let passed = overlap >= 0.5 && matched?.spokenText.map(clean) == clean(fixture.expectedSpeech) &&
                    (rendered.map { $0.covered && !$0.unresolved && clean($0.text).contains(clean(fixture.expectedSpeech)) } ?? false)
                checks["recovery.\(fixture.name)"] = passed
                recoveries.append(["name":fixture.name,"formula_id":matched?.id ?? "missing","expected_speech":fixture.expectedSpeech,
                    "actual_speech":matched?.spokenText ?? "","reader_text":rendered?.text ?? "","passed":passed])
            }
            checks["complete_five_pages"] = final.pages.count == 5
            checks["persisted_reader_chunks_match_export"] = Set(material.chunks.map(\.id)) == Set(candidates.map { $0.chunk.id })
            let visualReportURL = documents.appendingPathComponent("verification/image-only-diagram-v1/\(id)/completed.json")
            let visualReport = try JSONSerialization.jsonObject(with:Data(contentsOf:visualReportURL)) as? [String:Any]
            checks["existing_image_only_checks_preserved"] = (visualReport?["checks"] as? [String:Bool])?.values.allSatisfy({$0}) == true
            report["run_id"] = run;report["saved_material_id"] = savedID
            report["baseline_run_id"] = baseline.id;report["baseline_successful_formulas"] = baselineCount
            report["checks"] = checks;report["baseline_comparisons"] = comparisons;report["recovery_cases"] = recoveries
            report["formula_count"] = final.pages.reduce(0) { $0 + $1.formulas.count }
            report["ready_formula_count"] = final.pages.flatMap(\.formulas).filter { $0.spokenText != nil }.count
            report["wall_ms"] = completion?["wall_ms"]
            report["status"] = checks.values.allSatisfy({$0}) ? "passed_regression_checks; human_listening_not_performed" : "failed_regression_checks"
            let rows = ReadingPresentation.rows(for:material.chunks).map {
                ["chunk_ids":$0.chunks.map(\.id),"text":$0.text,"accessibility_label":$0.accessibilityLabel] as [String:Any]
            }
            try repository.writeJSON(["rows":rows],to:root.appendingPathComponent("persisted-reader-rows.json"))
        } catch { report["status"] = "failed";report["error"] = String(reflecting:error) }
        try? repository.writeJSON(report,to:root.appendingPathComponent("report.json"))
        try? repository.writeJSON(report,to:root.appendingPathComponent("completed.json"))
    }
    private enum CheckError:Error { case failed(String) }
}
#endif
