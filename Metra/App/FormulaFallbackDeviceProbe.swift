#if DEBUG
import Foundation

@MainActor
enum FormulaFallbackDeviceProbe {
    private static var started = Set<String>()
    static func run(attemptID:String,coordinator:AppCoordinator,reuseCompleted:Bool = false) async {
        guard let id = UUID(uuidString:attemptID)?.uuidString.lowercased(),started.insert(id).inserted,
              let documents = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else { return }
        let root = documents.appendingPathComponent("verification/\(reuseCompleted ? "formula-fallback-review-v1" : "formula-fallback-v1")/\(id)")
        guard !FileManager.default.fileExists(atPath:root.appendingPathComponent("completed.json").path) else { return }
        let repository = RunRepository()
        var report:[String:Any] = ["schema":"metra-formula-fallback-device-v1","attempt_id":id,"build":BuildIdentity.metadata,
            "policy":FoundationFormulaRuntime.version,"status":"running","scope":"Five-page production import; fallback only for withheld formulas; compare accepted MathCAT results and persisted reader metadata; no expected answers supplied to Foundation."]
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            try repository.writeJSON(report,to:root.appendingPathComponent("report.json"))
            if !reuseCompleted { await FormulaRegressionDeviceProbe.run(attemptID:id,coordinator:coordinator) }
            let regressionURL = documents.appendingPathComponent("verification/formula-regression-v1/\(id)/completed.json")
            let regression = try JSONSerialization.jsonObject(with:Data(contentsOf:regressionURL)) as? [String:Any]
            guard let run = regression?["run_id"] as? String,let savedID = regression?["saved_material_id"] as? String,
                  let uuid = UUID(uuidString:savedID),let material = try coordinator.mathMaterialService.fetchSavedMaterial(id:uuid) else {
                throw ProbeError.failed("Missing persisted completed import")
            }
            let runRoot = try coordinator.extractionService.artifactURL(for:"metra-runs/\(run)")
            let primary = try JSONDecoder().decode(FinalExtractionDocument.self,from:Data(contentsOf:runRoot.appendingPathComponent("final-extraction.primary.json")))
            let final = try JSONDecoder().decode(FinalExtractionDocument.self,from:Data(contentsOf:runRoot.appendingPathComponent("final-extraction.json")))
            let fallback = final.formulaFallbacks ?? [:]
            let held = Set(primary.pages.flatMap(\.formulas).filter { $0.spokenText == nil && $0.coveredByFormulaIDs == nil }.map(\.id))
            let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
            var checks:[String:Bool] = [:],rows:[[String:Any]] = []
            checks["primary_formula_pages_unchanged"] = try encoder.encode(primary.pages) == encoder.encode(final.pages)
            checks["only_withheld_formulas_requested"] = Set(fallback.keys) == held
            checks["primary_regression_checks_passed"] = (regression?["checks"] as? [String:Bool])?.values.allSatisfy({$0}) == true
            let candidates = try ReadingChunkBuilder.build(final,artifactPrefix:"audit")
            let persisted = Dictionary(uniqueKeysWithValues:material.chunks.map { ($0.id,$0) })
            func clean(_ text:String) -> String { text.components(separatedBy:.whitespacesAndNewlines).filter{!$0.isEmpty}.joined(separator:" ") }
            for (formulaID,description) in fallback.sorted(by:{$0.key<$1.key}) {
                var row:[String:Any] = ["formula_id":formulaID,"status":description.status,"visible_notation":description.visibleNotation,
                    "description":description.description,"uncertainties":description.uncertainties]
                if let requestPath = description.artifacts["request"],let crop = description.artifacts["crop"],
                   let requestData = try? Data(contentsOf:runRoot.appendingPathComponent(requestPath)),
                   let request = try JSONSerialization.jsonObject(with:requestData) as? [String:Any] {
                    checks["\(formulaID).image_only_request"] = request["ocr_input"] as? Bool == false && request["failed_candidate_input"] as? Bool == false
                    checks["\(formulaID).image_hash_matches"] = request["image_sha256"] as? String == ImageIngestor.sha256(try Data(contentsOf:runRoot.appendingPathComponent(crop)))
                } else { checks["\(formulaID).request_artifact_available"] = false }
                if let text = description.readerText {
                    let chunks = candidates.filter { $0.sourceSlices.contains { $0.formulaID == formulaID } }.compactMap { persisted[$0.chunk.id] }
                    let visible = chunks.map { ReadingPresentation.accessibilityLabel(for:$0) }.joined(separator:" ")
                    checks["\(formulaID).persisted_fallback_visible"] = !chunks.isEmpty && clean(visible).contains(clean(text))
                    checks["\(formulaID).review_and_fallback_metadata_retained"] = chunks.contains {
                        $0.unresolvedFormulaIDs.contains(formulaID) && $0.formulaFallbackIDs?.contains(formulaID) == true && $0.needsReview
                    }
                    row["reader_text"] = visible
                }
                rows.append(row)
            }
            let baselineURL = documents.appendingPathComponent("verification/multipage-clearspeak-v1/\(id)/baseline.json")
            let baseline = try JSONDecoder().decode(FinalExtractionDocument.self,from:Data(contentsOf:baselineURL))
            if let oldID = UUID(uuidString:baseline.id),let oldMaterial = try coordinator.mathMaterialService.fetchSavedMaterial(id:oldID) {
                let baselineCandidates = try ReadingChunkBuilder.build(baseline,artifactPrefix:"audit")
                checks["old_saved_material_survives_schema_addition"] = Set(oldMaterial.chunks.map(\.id)) == Set(baselineCandidates.map { $0.chunk.id }) &&
                    oldMaterial.chunks.allSatisfy { $0.formulaFallbackIDs == nil }
            } else { checks["old_saved_material_survives_schema_addition"] = false }
            let usable = fallback.values.filter { $0.readerText != nil }.count
            checks["at_least_one_useful_alternative"] = usable > 0
            report["run_id"] = run;report["saved_material_id"] = savedID;report["checks"] = checks
            report["primary_ready_formulas"] = final.pages.flatMap(\.formulas).filter { $0.spokenText != nil }.count
            report["primary_withheld_formulas"] = held.count;report["fallbacks_attempted"] = fallback.count
            report["fallbacks_available"] = usable;report["fallbacks"] = rows;report["wall_ms"] = regression?["wall_ms"]
            report["cached_model_outputs_reused"] = reuseCompleted
            report["status"] = checks.values.allSatisfy({$0}) ? "passed_routing_persistence_and_regression_checks; model_content_requires_source_review" : "failed_checks"
            if reuseCompleted { coordinator.navigate(to:.mathMaterial(material.id)) }
        } catch { report["status"] = "failed";report["error"] = String(reflecting:error) }
        try? repository.writeJSON(report,to:root.appendingPathComponent("report.json"))
        try? repository.writeJSON(report,to:root.appendingPathComponent("completed.json"))
    }
    private enum ProbeError:Error { case failed(String) }
}
#endif
