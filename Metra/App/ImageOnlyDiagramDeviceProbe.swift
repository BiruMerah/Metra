#if DEBUG
import Foundation

@MainActor
enum ImageOnlyDiagramDeviceProbe {
    private static var started = Set<String>()
    static func run(attemptID:String,coordinator:AppCoordinator) async {
        guard let id = UUID(uuidString:attemptID)?.uuidString.lowercased(),started.insert(id).inserted,
              let documents = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else { return }
        let root = documents.appendingPathComponent("verification/image-only-diagram-v1/\(id)")
        guard !FileManager.default.fileExists(atPath:root.appendingPathComponent("completed.json").path) else { return }
        let repository = RunRepository()
        var report:[String:Any] = ["schema":"metra-image-only-diagram-v1","attempt_id":id,"build":BuildIdentity.metadata,
            "policy":FoundationDiagramRuntime.version,"status":"running","scope":"Five original pages through the production on-device pipeline; no visual OCR evidence or visual formula recognition."]
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            try repository.writeJSON(report,to:root.appendingPathComponent("report.json"))
            await MultiPageDeviceProbe.run(attemptID:id,coordinator:coordinator)
            let completion = try JSONSerialization.jsonObject(with:Data(contentsOf:documents.appendingPathComponent("verification/multipage-clearspeak-v1/\(id)/completed.json"))) as? [String:Any]
            guard let run = completion?["run_id"] as? String,(completion?["status"] as? String)?.hasPrefix("completed_runtime") == true else { throw CheckError.failed("Fresh image run did not complete.") }
            let runRoot = try coordinator.extractionService.artifactURL(for:"metra-runs/\(run)")
            let final = try JSONDecoder().decode(FinalExtractionDocument.self,from:Data(contentsOf:runRoot.appendingPathComponent("final-extraction.json")))
            let ready = try JSONDecoder().decode(ReadyExtractionDocument.self,from:Data(contentsOf:runRoot.appendingPathComponent("final_ready.json")))
            var checks:[String:Bool] = [:],visuals:[[String:Any]] = []
            var visualRequests = 0,containerRequests = 0,visualFormulas = 0,visualOCR = 0
            for page in final.pages {
                let extracted = try JSONDecoder().decode(PageExtraction.self,from:Data(contentsOf:runRoot.appendingPathComponent("pages/\(page.id)/page-result.json")))
                let regions = extracted.layoutRegions ?? []
                for component in extracted.components {
                    if ["visual_crop_vision_ocr","visual_numeric_vision_ocr"].contains(component.component) {
                        visualRequests += Int((component.metrics["requests"] ?? nil) ?? 0)
                        checks["\(page.id).\(component.component).disabled"] = component.status == "skipped_image_only"
                    }
                    if component.component == "document_container_routing" { containerRequests += Int((component.metrics["container_routing_ocr_requests"] ?? nil) ?? 0) }
                }
                visualFormulas += (extracted.formulaRegions ?? []).filter { VisualImageRoute.owner(of:$0.bboxPageXYXY,regions:regions) != nil }.count
                visualOCR += extracted.rawOCR.filter { VisualImageRoute.owner(of:$0.bboxPageXYXY,regions:regions) != nil }.count
                for diagram in extracted.diagrams ?? [] {
                    var item:[String:Any] = ["id":diagram.id,"page_id":page.id,"status":diagram.status,"class":diagram.visualClassification?.predictedClass?.rawValue ?? "unknown"]
                    if diagram.status == "skipped_others" {
                        checks["\(diagram.id).others_not_generated"] = diagram.foundationDescription == nil && diagram.artifacts["generation"] == nil
                    } else {
                        let inputPath = diagram.artifacts["input"] ?? ""
                        let input = try JSONSerialization.jsonObject(with:Data(contentsOf:runRoot.appendingPathComponent(inputPath))) as? [String:Any]
                        let imageOnly = input?["input_mode"] as? String == "image_only" && input?["ocr_input"] as? Bool == false && input?["mathcat_input"] as? Bool == false
                        checks["\(diagram.id).image_only_input"] = imageOnly
                        checks["\(diagram.id).no_ocr_evidence"] = diagram.input == nil && diagram.sourceObservationIDs.isEmpty && diagram.formulaIDs.isEmpty
                        let projection = page.diagrams?.first { $0.id == diagram.id }
                        checks["\(diagram.id).description_available"] = diagram.foundationDescription?.inputMode == "image_only" && projection?.spokenText?.isEmpty == false
                        item["description"] = projection?.spokenText
                        item["model_reported_uncertainties"] = diagram.foundationDescription?.uncertainties ?? []
                        item["input_mode"] = input?["input_mode"]
                    }
                    visuals.append(item)
                }
            }
            checks["zero_visual_ocr_requests"] = visualRequests == 0
            checks["zero_visual_formula_recognitions"] = visualFormulas == 0
            checks["zero_visual_working_ocr_observations"] = visualOCR == 0
            checks["no_orphan_A_G_formula_chunks"] = !(ready.chunks ?? []).contains { $0.id.contains("p0003.mfd.04342") || $0.id.contains("p0003.mfd.04384") }
            checks["complete_five_pages"] = final.pages.count == 5
            let candidates = try ReadingChunkBuilder.build(final,artifactPrefix:"audit")
            checks["deterministic_chunk_export"] = candidates.map(\.chunk.id) == ready.chunks?.map(\.id)
            checks["no_detached_markers"] = !(ready.chunks ?? []).contains { !MaterialTopicIndex.auxiliaryKinds.contains($0.kind) && ReadingBoundaryPolicy.isMarker($0.sourceText) }
            report["run_id"] = run;report["saved_material_id"] = completion?["saved_material_id"]
            report["input_pages"] = completion?["input_pages"];report["wall_ms"] = completion?["wall_ms"]
            report["checks"] = checks;report["visuals"] = visuals
            report["visual_ocr_requests"] = visualRequests;report["visual_formula_recognitions"] = visualFormulas
            report["container_routing_ocr_requests"] = containerRequests
            report["chunks"] = ready.chunks?.count ?? 0
            report["status"] = checks.values.allSatisfy({ $0 }) ? "passed_routing_checks; direct_model_content_requires_source_review" : "failed_checks"
        } catch { report["status"] = "failed";report["error"] = String(reflecting:error) }
        try? repository.writeJSON(report,to:root.appendingPathComponent("report.json"))
        try? repository.writeJSON(report,to:root.appendingPathComponent("completed.json"))
    }
    private enum CheckError: Error { case failed(String) }
}
#endif
