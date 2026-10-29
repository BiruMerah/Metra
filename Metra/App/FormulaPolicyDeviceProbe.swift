#if DEBUG
import Foundation

@MainActor
enum FormulaPolicyDeviceProbe {
    private static var started = Set<String>()

    static func run(attemptID: String, coordinator: AppCoordinator) async {
        guard let id = UUID(uuidString:attemptID)?.uuidString.lowercased(), started.insert(id).inserted,
              let documents = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else { return }
        let root = documents.appendingPathComponent("verification/formula-policy-v1/\(id)")
        guard !FileManager.default.fileExists(atPath:root.appendingPathComponent("completed.json").path) else { return }
        let repository = RunRepository()
        var report: [String:Any] = ["schema":"metra-formula-policy-device-v1","attempt_id":id,"build":BuildIdentity.metadata,
            "status":"running","scope":"Production policy/placement fixtures, five original pages and persisted reader; no expected answers sent to models"]
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            var checks = fixtureChecks()
            report["fixture_checks"] = checks
            try repository.writeJSON(report,to:root.appendingPathComponent("report.json"))
            guard checks.values.allSatisfy({$0}) else { throw ProbeError.failed("Policy fixture failed") }
            await MultiPageDeviceProbe.run(attemptID:id,coordinator:coordinator)
            let completionURL = documents.appendingPathComponent("verification/multipage-clearspeak-v1/\(id)/completed.json")
            let completion = try JSONSerialization.jsonObject(with:Data(contentsOf:completionURL)) as? [String:Any]
            guard let run = completion?["run_id"] as? String,
                  let savedID = completion?["saved_material_id"] as? String,let materialID = UUID(uuidString:savedID),
                  let persisted = try coordinator.mathMaterialService.fetchSavedMaterial(id:materialID) else {
                throw ProbeError.failed("Fresh import or persisted material unavailable")
            }
            let runRoot = try coordinator.extractionService.artifactURL(for:"metra-runs/\(run)")
            let source = try JSONDecoder().decode(ExtractionDocument.self,from:Data(contentsOf:runRoot.appendingPathComponent("source-extraction.json")))
            let final = try JSONDecoder().decode(FinalExtractionDocument.self,from:Data(contentsOf:runRoot.appendingPathComponent("final-extraction.json")))
            checks["complete_five_pages"] = final.pages.count == 5
            let proposals = source.pages.flatMap { $0.layoutRegions ?? [] }.filter { $0.sourceObservationID != nil }
            checks["no_isolated_letter_candidates"] = !proposals.contains {
                $0.detectionSource == "vision_range_math_proposal_v1" && $0.proposalText?.count == 1
            }
            checks["no_currency_as_unit_candidate"] = !proposals.contains { $0.proposalText?.contains("000,00 maka") == true }
            checks["rupiah_reader_preserved"] = persisted.chunks.contains {
                $0.pageID == "p0005" && ReadingPresentation.text(for:$0).contains("Rp3.000,00 maka") &&
                    ReadingPresentation.text(for:$0).contains("Rp2.000,00") && $0.unresolvedFormulaIDs.isEmpty
            }
            checks["five_equation_reader_preserved"] = persisted.chunks.contains {
                $0.pageID == "p0005" && $0.spokenText?.contains("5 baris") == true &&
                    $0.spokenText?.contains("19000") == true && $0.spokenText?.contains("2000") == true
            }
            let runtimeReport = try JSONSerialization.jsonObject(with:Data(contentsOf:runRoot.appendingPathComponent("report.json"))) as? [String:Any]
            checks["foundation_formula_disabled"] = (runtimeReport?["formula_fallback"] as? [String:Any])?["enabled"] as? Bool == false
            checks["image_geometry_recovery_present"] = final.pages.flatMap(\.formulas).contains {
                $0.spokenText != nil && $0.mergeMethods.contains("image_detector_geometry_range")
            }
            let rows = ReadingPresentation.rows(for:persisted.chunks).map {
                ["chunk_ids":$0.chunks.map(\.id),"text":$0.text,"accessibility_label":$0.accessibilityLabel] as [String:Any]
            }
            try repository.writeJSON(["rows":rows],to:root.appendingPathComponent("persisted-reader-rows.json"))
            report["run_id"] = run;report["saved_material_id"] = savedID;report["wall_ms"] = completion?["wall_ms"]
            report["checks"] = checks
            report["status"] = checks.values.allSatisfy({$0}) ? "passed_policy_and_reader_checks; semantic_audit_required" : "failed_checks"
            coordinator.navigate(to:.mathMaterial(materialID))
        } catch { report["status"] = "failed";report["error"] = String(reflecting:error) }
        try? repository.writeJSON(report,to:root.appendingPathComponent("report.json"))
        try? repository.writeJSON(report,to:root.appendingPathComponent("completed.json"))
    }

    private static func fixtureChecks() -> [String:Bool] {
        var checks: [String:Bool] = [:]
        checks["standalone_bullet_is_text"] = OCRFormulaCandidatePolicy.isStandaloneListMarker("•") && !OCRFormulaCandidatePolicy.isStandaloneListMarker("a · b")
        for text in ["n", "b", "5n", "x2", "x'", "000,00 maka"] {
            checks["no_implicit_expression.\(text)"] = !OCRFormulaCandidatePolicy.expressionHasOperator(text)
        }
        for text in ["a+b", "3m + 5n = 19.000", "x ≤ 5"] {
            checks["explicit_expression.\(text)"] = OCRFormulaCandidatePolicy.expressionHasOperator(text)
        }
        for text in ["Rp3.000,00 maka", "000,00 maka", "300 mabc", "300 ma", "300 m-"] {
            checks["no_word_unit.\(text)"] = (try? LengthUnitSource.matches(in:text).isEmpty) == true
        }
        for text in ["314 cm²", "25 m3", "616 cmг", "770 mr", "25 m^3"] {
            checks["unit_recovery_retained.\(text)"] = LengthUnitSource.parse(text) != nil
        }
        func math(_ body:String) -> String { "<math>\(body)</math>" }
        checks["valid_fraction"] = FormulaEvidencePolicy.structure(math("<mfrac><mn>1</mn><mn>2</mn></mfrac>")).allowed
        checks["empty_denominator_rejected"] = !FormulaEvidencePolicy.structure(math("<mfrac><mn>1</mn><mrow/></mfrac>")).allowed
        checks["operator_power_rejected"] = !FormulaEvidencePolicy.structure(math("<msup><mo>×</mo><mn>2</mn></msup>")).allowed
        checks["bullet_not_formula"] = !FormulaEvidencePolicy.structure(math("<mo>•</mo>")).allowed
        checks["merror_rejected"] = !FormulaEvidencePolicy.structure(math("<merror><mi>x</mi></merror>")).allowed
        let target = PixelBox(xmin:100,ymin:100,xmax:240,ymax:130)
        let innerDetection = PixelBox(xmin:100,ymin:100,xmax:140,ymax:120)
        let enclosingDetection = PixelBox(xmin:100,ymin:100,xmax:170,ymax:120)
        checks["nested_mfd_uses_raw_detection_boxes"] = FormulaCropMerger.sameImageOccurrence(innerDetection,enclosingDetection)
        checks["adjacent_mfd_occurrences_stay_distinct"] = !FormulaCropMerger.sameImageOccurrence(innerDetection,PixelBox(xmin:145,ymin:100,xmax:185,ymax:120))
        let polynomial = math("<mn>5</mn><msup><mi>x</mi><mn>2</mn></msup><mo>+</mo><mn>2</mn><mi>x</mi>")
        func region(_ id:String,_ source:String,inherited:String? = nil) -> LayoutRegion {
            LayoutRegion(id:id,classID:-1,label:"formula",score:0.9,bboxPageXYXY:target,rawIndex:0,
                detectionSource:source,imageDetectionSource:inherited)
        }
        func formula(_ id:String,_ region:LayoutRegion) -> FormulaRegion {
            FormulaRegion(id:id,layoutRegionID:region.id,parentID:nil,bboxPageXYXY:target,score:0.9,cropArtifact:nil,
                sourceObservationIDs:[],route:[],status:"spoken_generated",errorCode:nil,latex:nil,mathML:polynomial,
                spokenText:"5 x kuadrat tambah 2 x",detectionSource:region.detectionSource,spokenMergeAllowed:true)
        }
        func observation(_ text:String,shared:Bool = false) -> OCRObservation {
            let boxes = text.indices.map { index -> OCRRangeBox in
                let lo = index.utf16Offset(in:text), hi = text.index(after:index).utf16Offset(in:text)
                let width = 140.0/Double(text.utf16.count)
                return OCRRangeBox(rangeUTF16:[lo,hi],bboxPageXYXY:shared ?
                    PixelBox(xmin:40,ymin:100,xmax:300,ymax:130) :
                    PixelBox(xmin:100+Double(lo)*width,ymin:100,xmax:100+Double(hi)*width,ymax:130))
            }
            return OCRObservation(id:"o1",rawOrder:1,bboxPageXYXY:target,candidates:[.init(text:text,confidence:0.9)],rangeBoxes:boxes)
        }
        let detected = region("r1","pp_doclayout_l"), recognized = formula("f1",detected)
        let nativeLayout = LayoutRegion(id:"native",classID:7,label:"formula",score:0.9,bboxPageXYXY:target,rawIndex:0)
        checks["native_doclayout_without_optional_source_retains_authority"] = FormulaEvidencePolicy.imageSource(nativeLayout) == "pp_doclayout_l"
        let damaged = observation("5x + 2x")
        let placed = FormulaSpanResolver.resolveOccurrences(observations:[damaged],regions:[detected],formulas:[recognized])
        checks["damaged_ocr_does_not_block_image_formula"] = !placed.spans.isEmpty && placed.spans.allSatisfy(\.allowsSpeech)
        let ocr = region("r2","vision_math_expression_proposal_v1")
        checks["ocr_only_not_promoted_to_detector"] = FormulaEvidencePolicy.imageSource(ocr) == nil &&
            !FormulaSpanResolver.resolve(observations:[damaged],regions:[ocr],formulas:[formula("f2",ocr)]).contains(where:\.allowsSpeech)
        let split = region("r3",CompoundFormulaSplitter.version,inherited:"pp_doclayout_l")
        checks["split_retains_detector_provenance"] = FormulaEvidencePolicy.imageSource(split) == "pp_doclayout_l"
        checks["shared_boundary_stays_review"] = !FormulaSpanResolver.resolve(observations:[observation("5x + 2x",shared:true)],regions:[detected],formulas:[recognized]).contains(where:\.allowsSpeech)
        checks["prose_not_overwritten"] = !FormulaSpanResolver.resolve(observations:[observation("NEW EDITION")],regions:[detected],formulas:[recognized]).contains(where:\.allowsSpeech)
        let second = region("r4","pp_doclayout_l")
        checks["duplicate_range_conflict_stays_review"] = !FormulaSpanResolver.resolve(observations:[damaged],regions:[detected,second],formulas:[recognized,formula("f4",second)]).contains(where:\.allowsSpeech)
        let independent = FormulaSpanResolver.resolveOccurrences(observations:[],regions:[detected],formulas:[recognized])
        checks["detected_formula_without_ocr_can_stand_alone"] = independent.independentFormulaIDs.contains("f1")
        checks["standalone_speech_reaches_merge"] = LayoutMerge.blocks(pageID:"p1",regions:[detected],observations:[],formulas:[recognized]).flatMap(\.segments).contains { $0.spokenText == recognized.spokenText }
        let mfd = region("r5","pix2text_mfd_image_proposal_v1")
        checks["empty_mfd_crop_not_blindly_accepted"] = FormulaSpanResolver.resolveOccurrences(observations:[],regions:[mfd],formulas:[formula("f5",mfd)]).independentFormulaIDs.isEmpty
        return checks
    }

    private enum ProbeError: Error { case failed(String) }
}
#endif
