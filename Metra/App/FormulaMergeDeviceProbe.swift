#if DEBUG
import Foundation

/// Explicit local device verification only. All derived files use a new attempt;
/// the source run, model outputs and existing saved material are never rewritten.
@MainActor
enum FormulaMergeDeviceProbe {
    static func run(sourceRunID: String, replay: Bool, coordinator: AppCoordinator) async {
        guard UUID(uuidString: sourceRunID) != nil else { return }
        let attemptID = UUID().uuidString.lowercased()
        let relative = "verification/formula-merge-v1/\(attemptID)"
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let root = documents.appendingPathComponent(relative, isDirectory: true)
        let repository = RunRepository()
        var report: [String: Any] = ["schema": "metra-formula-merge-probe-v1", "attempt_id": attemptID,
            "source_run": sourceRunID, "build": BuildIdentity.metadata, "fresh_inference_requested": replay,
            "status": "running", "original_run_modified": false]
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try repository.writeJSON(report, to: root.appendingPathComponent("report.json"))
            let sourceURL = try coordinator.extractionService.artifactURL(for: "metra-runs/\(sourceRunID)/spoken-extraction.json")
            let bytes = try Data(contentsOf: sourceURL)
            let source = try JSONDecoder().decode(ExtractionDocument.self, from: bytes)
            let rebuilt = try FinalExtractionBuilder.build(source)
            try repository.writeJSON(rebuilt, to: root.appendingPathComponent("final-extraction.json"))
            let ready = try OrderedChunkExport.run(document: rebuilt, paths: .init(root: root, runID: sourceRunID))
            let page = source.pages[0]
            let regions = page.layoutRegions ?? [], formulas = page.formulaRegions ?? []
            let resolved = FormulaSpanResolver.resolveOccurrences(observations: page.rawOCR, regions: regions, formulas: formulas)
            var checks = try targetChecks(final: rebuilt, ready: ready)

            // Deliberately altered metadata tests the fail-closed conditions.
            // These are safety fixtures, never new image/model evidence.
            var missingParentLink = regions
            if let index = missingParentLink.firstIndex(where: { $0.id == "p0001.layout.0035" }) {
                missingParentLink[index].parentID = nil
            } else { throw ProbeError.missingFixture }
            let unrelated = FormulaSpanResolver.resolveOccurrences(observations: page.rawOCR, regions: missingParentLink, formulas: formulas)
            checks["unproven_nesting_not_aliased"] = unrelated.coveredByFormulaIDs["p0001.formula.0007"] == nil &&
                unrelated.spans.filter { $0.formulaID == "p0001.formula.0006" }.contains { !$0.allowsSpeech }
            var noImageRecognition = formulas
            guard let child = noImageRecognition.firstIndex(where: { $0.id == "p0001.formula.0006" }) else { throw ProbeError.missingFixture }
            noImageRecognition[child].mathML = nil
            let withoutImage = FormulaSpanResolver.resolveOccurrences(observations: page.rawOCR, regions: regions, formulas: noImageRecognition)
            checks["ocr_L_alone_does_not_authorize_angle"] = !withoutImage.spans.contains {
                $0.formulaID == "p0001.formula.0006" && $0.allowsSpeech
            } && withoutImage.coveredByFormulaIDs["p0001.formula.0007"] == nil
            var conflictingImage = formulas
            guard let parent = conflictingImage.firstIndex(where: { $0.id == "p0001.formula.0007" }),
                  let originalML = conflictingImage[parent].mathML else { throw ProbeError.missingFixture }
            let alteredML = originalML.replacingOccurrences(of: ">45<", with: ">46<")
            guard alteredML != originalML else { throw ProbeError.missingFixture }
            conflictingImage[parent].mathML = alteredML
            let inconsistent = FormulaSpanResolver.resolveOccurrences(observations: page.rawOCR, regions: regions, formulas: conflictingImage)
            checks["disagreeing_image_mathml_not_aliased"] = inconsistent.coveredByFormulaIDs["p0001.formula.0007"] == nil

            let oldReadyURL = try coordinator.extractionService.artifactURL(for: "metra-runs/\(sourceRunID)/final_ready.json")
            let oldReady = try JSONDecoder().decode(ReadyExtractionDocument.self, from: Data(contentsOf: oldReadyURL))
            guard let oldEmpty = oldReady.chunks?.first(where: { $0.unresolvedFormulaIDs == ["p0001.formula.0008"] }) else { throw ProbeError.missingFixture }
            let oldModel = domainChunk(oldEmpty, order: 0)
            checks["legacy_internal_id_becomes_neutral_message"] = ReadingPresentation.text(for: oldModel) == "Rumus belum dapat dibaca."
            checks["literal_m_n_preserved"] = ReadingPresentation.removeReviewAnnotations("[perlu review: m] dan [perlu review: n]",
                internalFormulaIDs: ["p0001.formula.0008"]) == "m dan n"
            checks["nested_source_brackets_preserved"] = ReadingPresentation.removeReviewAnnotations("[perlu review: x[n+1]]") == "x[n+1]"
            report["cached_remerge_checks"] = checks
            report["aliases"] = resolved.coveredByFormulaIDs
            report["source_snapshot_sha256"] = ImageIngestor.sha256(bytes)
            report["fixture_scope"] = "cached iPhone artifacts plus deliberately changed metadata; no model execution for safety fixtures"
            try repository.writeJSON(readingSnapshot(ready), to: root.appendingPathComponent("cached-reader.json"))
            try repository.writeJSON(report, to: root.appendingPathComponent("report.json"))
            guard checks.values.allSatisfy({ $0 }) else { throw ProbeError.checkFailed }

            if replay {
                let sourcePages = try RunRepository().sourcePages(forRunID: sourceRunID)
                let inputs = try sourcePages.map { page in
                    MaterialImageInput(data: try Data(contentsOf: ImageIngestor.originalURL(for: page)),
                                       fileName: page.fileName, origin: .photoLibrary)
                }
                let material = try await coordinator.extractionService.extract(pages: inputs, title: "Materi — hasil merge baru") { progress in
                    appendJSONObjectLine(["progress": progress, "time": ISO8601DateFormatter().string(from: Date())],
                                         to: root.appendingPathComponent("progress.jsonl"))
                }
                guard let newRun = material.extractionRunID else { throw ProbeError.checkFailed }
                let freshFinalURL = try coordinator.extractionService.artifactURL(for: "metra-runs/\(newRun)/final-extraction.json")
                let freshReadyURL = try coordinator.extractionService.artifactURL(for: "metra-runs/\(newRun)/final_ready.json")
                let freshFinal = try JSONDecoder().decode(FinalExtractionDocument.self, from: Data(contentsOf: freshFinalURL))
                let freshReady = try JSONDecoder().decode(ReadyExtractionDocument.self, from: Data(contentsOf: freshReadyURL))
                var freshChecks = try targetChecks(final: freshFinal, ready: freshReady)
                freshChecks["same_source_image_hash"] = freshFinal.pages.map(\.sourceSHA256) == rebuilt.pages.map(\.sourceSHA256)
                report["fresh_run"] = newRun
                report["fresh_checks"] = freshChecks
                try repository.writeJSON(readingSnapshot(freshReady), to: root.appendingPathComponent("fresh-reader.json"))
                guard freshChecks.values.allSatisfy({ $0 }) else { throw ProbeError.checkFailed }
                try coordinator.mathMaterialService.addSavedMaterial(material: material)
                report["new_material_id"] = material.id.uuidString
                report["fresh_inference_status"] = "completed; original material and run retained"
                coordinator.navigate(to: .mathMaterial(material.id))
            }
            report["status"] = "passed"
            report["source_snapshot_unchanged"] = ImageIngestor.sha256(try Data(contentsOf: sourceURL)) == ImageIngestor.sha256(bytes)
            try repository.writeJSON(report, to: root.appendingPathComponent("report.json"))
        } catch {
            report["status"] = "failed"
            report["error"] = error.localizedDescription
            try? repository.writeJSON(report, to: root.appendingPathComponent("report.json"))
        }
    }

    private static func targetChecks(final: FinalExtractionDocument, ready: ReadyExtractionDocument) throws -> [String: Bool] {
        let formulas = final.pages.flatMap(\.formulas)
        let byID = Dictionary(uniqueKeysWithValues: formulas.map { ($0.id, $0) })
        guard let a = byID["p0001.formula.0006"], let c = byID["p0001.formula.0008"],
              let enclosing = byID["p0001.formula.0007"] else { throw ProbeError.missingFixture }
        let chunks = ready.chunks ?? []
        let slices = try ReadingChunkBuilder.build(final, artifactPrefix: "audit").flatMap(\.sourceSlices)
        let reader = chunks.enumerated().map { ReadingPresentation.text(for: domainChunk($0.element, order: $0.offset)) }
        return ["angle_AOB_ready": a.status == "ready" && a.spokenText?.contains("45") == true,
                "angle_COD_ready": c.status == "ready" && c.spokenText?.contains("120") == true,
                "source_ocr_preserved": a.sourceText == "LAOB = 45°" && c.sourceText.contains("ZCOD = 120°"),
                "enclosing_detection_retained_as_alias": enclosing.coveredByFormulaIDs == [a.id, c.id] && enclosing.spokenText == nil,
                "AOB_read_once": slices.filter { $0.formulaID == a.id }.count == 1,
                "COD_read_once": slices.filter { $0.formulaID == c.id }.count == 1,
                "enclosing_detection_not_read_twice": !slices.contains { $0.formulaID == enclosing.id },
                "no_internal_formula_id_in_reader": !reader.contains { $0.range(of: #"p\d{4}\.formula\.\d{4}"#, options: .regularExpression) != nil },
                "detected_formula_records_retained": formulas.count == 26]
    }

    private static func readingSnapshot(_ ready: ReadyExtractionDocument) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (ready.chunks ?? []).enumerated().map {
            ($0.element.id, ReadingPresentation.text(for: domainChunk($0.element, order: $0.offset)))
        })
    }

    private static func domainChunk(_ chunk: ReadyChunk, order: Int) -> MathChunkModel {
        .init(id: chunk.id, order: order, pageID: chunk.pageID, kind: chunk.kind, status: chunk.status,
              sourceText: chunk.sourceText, spokenText: chunk.spokenText, spokenPreview: chunk.spokenPreview,
              sourceReference: chunk.sourceRef, imagePath: chunk.imageArtifact,
              unresolvedFormulaIDs: chunk.unresolvedFormulaIDs, uncertainties: chunk.uncertainties ?? [])
    }

    private enum ProbeError: LocalizedError {
        case missingFixture, checkFailed
        var errorDescription: String? { "Formula merge verification failed: \(self). See the preserved attempt report." }
    }
}
#endif
