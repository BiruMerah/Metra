#if DEBUG
import Foundation

/// Uses the exact production tokenizer, coverage validator and topic builders on
/// iPhone. Cached exports and fresh image inference are reported separately.
@MainActor
enum ChunkingDeviceProbe {
    struct Fixture: Decodable {
        let title:String
        let fileName:String
        let sourceSHA256:String
        let baselineFileName:String
    }
    struct Request: Decodable { let fixtures:[Fixture] }
    private static var started = Set<String>()

    static func run(attemptID:String,coordinator:AppCoordinator) async {
        guard let id = UUID(uuidString:attemptID)?.uuidString.lowercased(),started.insert(id).inserted,
              let documents = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else { return }
        let root = documents.appendingPathComponent("verification/chunking-v6/\(id)")
        guard !FileManager.default.fileExists(atPath:root.appendingPathComponent("completed.json").path) else { return }
        let repository = RunRepository()
        var report:[String:Any] = ["schema":"metra-chunking-device-v6","attempt_id":id,"build":BuildIdentity.metadata,
            "status":"running","chunk_policy":ReadingChunkBuilder.version,"human_student_testing":false,
            "scope":"Several student materials/pages, as clarified by user. Cached structural replay and fresh on-device inference."]
        do {
            let request = try JSONDecoder().decode(Request.self,from:Data(contentsOf:root.appendingPathComponent("request.json")))
            var cached:[[String:Any]] = []
            let checks = try boundaryChecks()
            report["boundary_checks"] = checks
            guard checks.values.allSatisfy({ $0 }) else { throw ProbeError.failed("Boundary regression check failed.") }
            for (i,fixture) in request.fixtures.enumerated() {
                guard fixture.fileName == (fixture.fileName as NSString).lastPathComponent,
                      fixture.baselineFileName == (fixture.baselineFileName as NSString).lastPathComponent else { throw ProbeError.failed("Invalid fixture filename.") }
                let url = root.appendingPathComponent("fixtures/\(fixture.fileName)")
                let bytes = try Data(contentsOf:url)
                guard ImageIngestor.sha256(bytes) == fixture.sourceSHA256 else { throw ProbeError.failed("Fixture hash mismatch.") }
                let final = try JSONDecoder().decode(FinalExtractionDocument.self,from:bytes)
                let baseline = try JSONDecoder().decode(ReadyExtractionDocument.self,from:Data(contentsOf:root.appendingPathComponent("fixtures/\(fixture.baselineFileName)")))
                let directory = root.appendingPathComponent("cached/fixture-\(i+1)")
                let ready = try OrderedChunkExport.run(document:final,paths:.init(root:directory,runID:final.id))
                var audit = try metrics(final:final,ready:ready)
                audit["title"] = fixture.title;audit["before"] = summary(baseline.chunks ?? [])
                audit["source_snapshot_unchanged"] = ImageIngestor.sha256(try Data(contentsOf:url)) == fixture.sourceSHA256
                audit["source_sha256"] = fixture.sourceSHA256
                let oldMissing = Set((baseline.chunks ?? []).flatMap(\.unresolvedFormulaIDs))
                audit["unresolved_ids_preserved"] = oldMissing == Set((ready.chunks ?? []).flatMap(\.unresolvedFormulaIDs))
                guard audit["source_snapshot_unchanged"] as? Bool == true,audit["unresolved_ids_preserved"] as? Bool == true else { throw ProbeError.failed("Cached source/review preservation failed.") }
                cached.append(audit)
            }
            report["cached_exports"] = cached
            try repository.writeJSON(report,to:root.appendingPathComponent("report.json"))
            await MultiPageDeviceProbe.run(attemptID:id,coordinator:coordinator)
            let freshReport = try JSONSerialization.jsonObject(with:Data(contentsOf:documents.appendingPathComponent("verification/multipage-clearspeak-v1/\(id)/completed.json"))) as? [String:Any]
            guard let run = freshReport?["run_id"] as? String,(freshReport?["status"] as? String)?.hasPrefix("completed_runtime") == true else { throw ProbeError.failed("Fresh page run did not complete.") }
            let finalURL = try coordinator.extractionService.artifactURL(for:"metra-runs/\(run)/final-extraction.json")
            let readyURL = try coordinator.extractionService.artifactURL(for:"metra-runs/\(run)/final_ready.json")
            let final = try JSONDecoder().decode(FinalExtractionDocument.self,from:Data(contentsOf:finalURL))
            let ready = try JSONDecoder().decode(ReadyExtractionDocument.self,from:Data(contentsOf:readyURL))
            report["fresh"] = try metrics(final:final,ready:ready)
            report["fresh_run_id"] = run;report["fresh_material_id"] = freshReport?["saved_material_id"]
            report["fresh_input_pages"] = freshReport?["input_pages"]
            report["status"] = "passed_structural_checks; source_recognition_and_listening_quality_require_review"
        } catch {
            report["status"] = "failed";report["error"] = String(reflecting:error)
        }
        try? repository.writeJSON(report,to:root.appendingPathComponent("report.json"))
        try? repository.writeJSON(report,to:root.appendingPathComponent("completed.json"))
    }

    private static func summary(_ chunks:[ReadyChunk]) -> [String:Any] {
        let body = chunks.filter { !MaterialTopicIndex.auxiliaryKinds.contains($0.kind) }
        return ["chunks":chunks.count,"body_chunks":body.count,
            "orphan_markers":body.filter { ReadingBoundaryPolicy.isMarker($0.sourceText) }.count,
            "standalone_example_labels":body.filter { ReadingBoundaryPolicy.isExampleLabel($0.sourceText) }.count,
            "context_chunks":body.filter { ["example","formula_context"].contains($0.kind) }.count,
            "list_items":body.filter { $0.kind == "list_item" }.count,
            "long_nonformula_chunks":body.filter { !["formula","diagram","table"].contains($0.kind) && ReadingBoundaryPolicy.wordCount($0.spokenText ?? $0.sourceText) > 90 }.count]
    }
    private static func domain(_ chunks:[ReadyChunk]) -> [MathChunkModel] {
        chunks.enumerated().map { i,c in
            MathChunkModel(id:c.id,order:i,pageID:c.pageID,kind:c.kind,status:c.status,sourceText:c.sourceText,spokenText:c.spokenText,
                spokenPreview:c.spokenPreview,sourceReference:c.sourceRef,imagePath:c.imageArtifact,unresolvedFormulaIDs:c.unresolvedFormulaIDs,uncertainties:c.uncertainties ?? [])
        }
    }
    private static func metrics(final:FinalExtractionDocument,ready:ReadyExtractionDocument) throws -> [String:Any] {
        let candidates = try ReadingChunkBuilder.build(final,artifactPrefix:"audit")
        let chunks = ready.chunks ?? []
        guard candidates.map(\.chunk.id) == chunks.map(\.id) else { throw ProbeError.failed("Nondeterministic chunk IDs.") }
        let actual = candidates.flatMap(\.sourceSlices).compactMap(\.formulaID)
        let expected = final.pages.flatMap(\.formulas).filter { $0.coveredByFormulaIDs == nil }.map(\.id)
        guard actual.count == expected.count,Set(actual) == Set(expected),Set(actual).count == actual.count else { throw ProbeError.failed("Formula occurrence coverage changed.") }
        let models = domain(chunks)
        let index = MaterialTopicIndex.sourceHeadings(chunks:models,fallbackTitle:"Materi tanpa judul")
        guard index.isValid(for:models),index.topics.map(\.chunkIDs) == ready.topicIndex?.topics.map(\.chunkIDs) else { throw ProbeError.failed("Stored and reader topic memberships disagree.") }
        let markerFormulas = Set(final.pages.flatMap(\.blocks).flatMap(\.segments).filter { $0.readingRole == "source_choice_marker" }.compactMap(\.formulaID))
        let speechPreserved = final.pages.flatMap(\.formulas).filter { $0.spokenText != nil && !markerFormulas.contains($0.id) }.allSatisfy { formula in
            candidates.contains { candidate in
                guard candidate.sourceSlices.contains(where:{ $0.formulaID == formula.id }) else { return false }
                if let id = candidate.chunk.diagramID,let diagram = final.pages.flatMap({ $0.diagrams ?? [] }).first(where:{ $0.id == id }) {
                    return candidate.chunk.spokenText == diagram.spokenText && candidate.chunk.spokenPreview == diagram.spokenPreview
                }
                return (candidate.chunk.spokenText ?? candidate.chunk.spokenPreview ?? "").contains(formula.spokenText!)
            }
        }
        guard speechPreserved else { throw ProbeError.failed("Validated formula speech lost during grouping.") }
        var result = summary(chunks)
        result["page_count"] = final.pages.count;result["formula_occurrences"] = actual.count
        result["source_slice_coverage"] = "passed production validator"
        result["formula_speech_preserved"] = speechPreserved;result["reader_topic_membership_valid"] = true
        result["topics"] = ready.topicIndex?.topics.count
        result["question_count"] = ready.questions?.count
        result["choice_count"] = chunks.filter { $0.kind == "answer_choice" }.count
        result["pages"] = final.pages.map { page in ["id":page.id,"source_sha256":page.sourceSHA256,"chunks":summary(chunks.filter { $0.pageID == page.id })] as [String:Any] }
        return result
    }

    private static func boundaryChecks() throws -> [String:Bool] {
        func block(_ id:String,_ text:String,kind:String = "text",x:Double = 0,y:Double = 0,question:String? = nil) -> FinalBlock {
            FinalBlock(id:id,kind:kind,bboxPageXYXY:.init(xmin:x,ymin:y,xmax:x+300,ymax:y+30),readingOrder:Int(y),status:"ready",
                segments:[FinalSegment(id:id+".s1",kind:"text",text:text,formulaID:nil,status:"ready",sourceRefs:[.init(artifact:"fixture",observationID:id,rangeUTF16:[0,text.utf16.count])],joinBefore:nil,joinReason:nil)],questionID:question)
        }
        func document(_ blocks:[FinalBlock],formulas:[FinalFormula] = []) -> FinalExtractionDocument {
            FinalExtractionDocument(schema:"metra-final-extraction-v1",id:"boundary-fixture",mergePolicyVersion:"fixture",profile:.serialBaseline,
                runtimeStatus:.complete,sourceCoverageStatus:.notAssessed,contentQualityStatus:.notAssessed,startedAt:"fixture",completedAt:nil,artifacts:[:],
                pages:[FinalPage(id:"p1",sourceID:"fixture",sourceSHA256:"fixture",imageArtifact:"fixture",width:1000,height:1000,
                    runtimeStatus:.complete,sourceCoverageStatus:.notAssessed,contentQualityStatus:.notAssessed,readingOrderMethod:"fixture",blocks:blocks,formulas:formulas)])
        }
        func build(_ blocks:[FinalBlock]) throws -> [ChunkCandidate] { try ReadingChunkBuilder.build(document(blocks),artifactPrefix:"fixture") }
        var checks:[String:Bool] = [:]
        checks["short_paragraph_keeps_related_sentences"] = try build([block("a","Pecahan senilai memiliki nilai sama. Pembilang dan penyebut dapat dikalikan bilangan yang sama.")]).count == 1
        let list = try build([block("a","1. Kerjakan tanda kurung terlebih dahulu.")])
        checks["enumerator_attached_to_body"] = list.count == 1 && list[0].chunk.kind == "list_item" && list[0].chunk.sourceText.hasPrefix("1. Kerjakan")
        checks["decimal_is_not_list_item"] = !ReadingBoundaryPolicy.beginsListItem("1.5 meter")
        var multiline = block("a","1. Kalimat pertama.")
        multiline = FinalBlock(id:multiline.id,kind:multiline.kind,bboxPageXYXY:multiline.bboxPageXYXY,readingOrder:0,status:"ready",
            segments:multiline.segments + block("b","2. Kalimat kedua.").segments)
        checks["separate_source_list_lines_remain_separate"] = try build([multiline]).count == 2
        let example = try build([block("a","Contoh:",kind:"paragraph_title"),block("b","Satu contoh penerapan aturan.",y:40)])
        checks["example_label_attached"] = example.count == 1 && example[0].chunk.kind == "example" && example[0].sourceSlices.count == 2
        checks["different_columns_not_joined"] = try build([block("a","Contoh:"),block("b","Isi kolom lain.",x:500,y:40)]).count == 2
        checks["different_questions_not_joined"] = try build([block("a","Contoh:",question:"q1"),block("b","Isi soal berikut.",y:40,question:"q2")]).count == 2
        checks["choices_remain_individual"] = try build([block("a","A. Jawaban pertama.",kind:"answer_choice"),block("b","B. Jawaban kedua.",kind:"answer_choice",y:40)]).count == 2
        checks["heading_is_boundary"] = try build([block("a","Contoh:"),block("b","Bagian berikut",kind:"paragraph_title",y:40),block("c","Isi berikut.",y:80)]).count == 3
        let long = (1...8).map { _ in "Kalimat ini menjelaskan langkah yang masih berhubungan dengan paragraf pembelajaran matematika untuk membantu siswa mengikuti uraian dengan jelas." }.joined(separator:" ")
        let packed = try build([block("a",long)])
        checks["long_paragraph_split_at_sentences"] = packed.count > 1 && packed.allSatisfy { ReadingBoundaryPolicy.wordCount($0.chunk.spokenText ?? "") <= 70 }
        let headers = try build([block("a","B. PECAHAN",kind:"paragraph_title"),block("b","a. Jenis Pecahan",kind:"paragraph_title",y:40),block("c","Isi pembelajaran.",y:80)])
        let topics = try HeadingTopicBuilder.build(headers)
        checks["heading_path_avoids_empty_parent_topic"] = topics.topics.count == 1 && topics.topics[0].headingChunkIDs.count == 2
        let row = ReadingPresentation.rows(for:domain(list.map(\.chunk)))[0]
        checks["canonical_list_keeps_aligned_marker_and_body"] = row.listMarker == "1." && row.bodyText == "Kerjakan tanda kurung terlebih dahulu."
        // Explicit math source remains one occurrence even when speech exceeds
        // the paragraph budget or recognition is unresolved.
        let formula = FinalFormula(id:"f1",segmentID:"m.s1",sourceText:"L-_xaxt",latex:nil,spokenText:nil,status:"needs_review",recognitionStatus:"failed",sourceConsistencyStatus:"needs_review",mergeMethods:[],reviewReasons:[],bboxPageXYXY:.init(xmin:0,ymin:40,xmax:300,ymax:70),artifacts:[:])
        let math = FinalBlock(id:"m",kind:"formula",bboxPageXYXY:formula.bboxPageXYXY,readingOrder:40,status:"needs_review",
            segments:[FinalSegment(id:"m.s1",kind:"math",text:nil,formulaID:"f1",status:"needs_review",sourceRefs:[],joinBefore:nil,joinReason:nil)])
        let unresolved = try ReadingChunkBuilder.build(document([block("a","Luas segitiga (L)"),math],formulas:[formula]),artifactPrefix:"fixture")
        checks["formula_intro_and_source_kept_together"] = unresolved.count == 1 && unresolved[0].chunk.sourceText == "Luas segitiga (L) L-_xaxt"
        checks["unresolved_formula_stays_under_review"] = unresolved[0].chunk.spokenText == nil && unresolved[0].chunk.unresolvedFormulaIDs == ["f1"] && unresolved[0].chunk.status == "needs_review"
        checks["damaged_formula_not_exposed_in_reading_preview"] = unresolved[0].chunk.spokenPreview?.contains("L-_") == false && unresolved[0].chunk.spokenPreview?.contains("Rumus belum dapat dibaca.") == true
        return checks
    }
    private enum ProbeError: Error { case failed(String) }
}
#endif
