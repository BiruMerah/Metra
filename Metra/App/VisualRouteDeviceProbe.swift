#if DEBUG
import Foundation

/// Same-page regression through the production import, Foundation generation,
/// SwiftData persistence and the reader's visible/accessibility projections.
@MainActor
enum VisualRouteDeviceProbe {
    private static var started = Set<String>()

    static func run(attemptID: String, coordinator: AppCoordinator) async {
        guard let id = UUID(uuidString: attemptID)?.uuidString.lowercased(), started.insert(id).inserted,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let root = documents.appendingPathComponent("verification/visual-route-v1/\(id)")
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("completed.json").path) else { return }
        let repository = RunRepository()
        let start = ProcessInfo.processInfo.systemUptime
        var report: [String: Any] = ["schema": "metra-visual-route-device-v1", "attempt_id": id,
            "build": BuildIdentity.metadata, "status": "running",
            "scope": "One original user page through the production pipeline and persisted reader; no expected description supplied to models"]
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try Data(contentsOf: root.appendingPathComponent("input.png"))
            report["input_sha256"] = ImageIngestor.sha256(data)
            try repository.writeJSON(report, to: root.appendingPathComponent("report.json"))
            let material = try await coordinator.extractionService.extract(
                pages: [MaterialImageInput(data: data, fileName: "input.png", origin: .photoLibrary)],
                title: "Uji perbaikan deskripsi geometri — build 48") { progress in
                    appendJSONObjectLine(["progress": progress, "time": ISO8601DateFormatter().string(from: Date())],
                        to: root.appendingPathComponent("progress.jsonl"))
                }
            guard let run = material.extractionRunID else { throw DiagramProbeError.invalidObject }
            report["run_id"] = run
            try coordinator.mathMaterialService.addSavedMaterial(material: material)
            guard let persisted = try coordinator.mathMaterialService.fetchSavedMaterial(id: material.id) else {
                throw DiagramProbeError.invalidObject
            }
            report["saved_material_id"] = persisted.id.uuidString
            let runRoot = try coordinator.extractionService.artifactURL(for: "metra-runs/\(run)")
            let final = try JSONDecoder().decode(FinalExtractionDocument.self,
                from: Data(contentsOf: runRoot.appendingPathComponent("final-extraction.json")))
            var checks: [String: Bool] = [:]
            var visuals: [[String: Any]] = []
            for page in final.pages {
                let extracted = try JSONDecoder().decode(PageExtraction.self,
                    from: Data(contentsOf: runRoot.appendingPathComponent("pages/\(page.id)/page-result.json")))
                let regions = extracted.layoutRegions ?? []
                for component in extracted.components where ["visual_crop_vision_ocr", "visual_numeric_vision_ocr"].contains(component.component) {
                    checks["\(page.id).\(component.component).disabled"] = component.status == "skipped_image_only"
                }
                checks["\(page.id).no_visual_working_ocr"] = extracted.rawOCR.allSatisfy {
                    VisualImageRoute.owner(of: $0.bboxPageXYXY, regions: regions) == nil
                }
                for diagram in extracted.diagrams ?? [] where diagram.status != "skipped_others" {
                    let kind = diagram.visualClassification?.predictedClass
                    let finalDiagram = page.diagrams?.first { $0.id == diagram.id }
                    let chunks = persisted.chunks.filter { $0.kind == "diagram" && $0.id.hasPrefix(diagram.id + ".c") }
                    let region = regions.first { $0.id == diagram.id }
                    checks["\(diagram.id).classification_retained"] = kind != nil && region?.visualClassification?.predictedClass == kind
                    checks["\(diagram.id).classified_crop_retained"] = region?.cropArtifact == diagram.visualClassification?.cropArtifact
                    checks["\(diagram.id).foundation_completed"] = diagram.artifacts["generation"] != nil && diagram.foundationDescription != nil
                    checks["\(diagram.id).final_speech"] = finalDiagram?.spokenText?.isEmpty == false
                    checks["\(diagram.id).persisted_reader_speech"] = !chunks.isEmpty && chunks.allSatisfy {
                        $0.spokenText?.isEmpty == false && ReadingPresentation.text(for: $0) == $0.spokenText &&
                            ReadingPresentation.accessibilityLabel(for: $0) == $0.spokenText
                    }
                    let fingerprintURL = runRoot.appendingPathComponent("pages/\(page.id)/diagrams/\(diagram.id)/generation/request.fingerprint.json")
                    let fingerprint = try JSONSerialization.jsonObject(with: Data(contentsOf: fingerprintURL)) as? [String: Any]
                    checks["\(diagram.id).same_classifier_foundation_image"] =
                        fingerprint?["image_sha256"] as? String == diagram.visualClassification?.cropSHA256 &&
                        diagram.visualClassification?.cropSHA256 != nil
                    checks["\(diagram.id).foundation_image_only"] = fingerprint?["ocr_input"] as? Bool == false && fingerprint?["mathcat_input"] as? Bool == false
                    visuals.append(["id": diagram.id, "class": kind?.rawValue ?? "missing", "status": diagram.status,
                        "speech": finalDiagram?.spokenText ?? "", "uncertainties": finalDiagram?.uncertainties ?? []])
                }
            }
            checks["at_least_one_described_visual"] = !visuals.isEmpty
            report["checks"] = checks
            report["visuals"] = visuals
            let rows = ReadingPresentation.rows(for: persisted.chunks).map {
                ["chunk_ids": $0.chunks.map(\.id), "text": $0.text, "accessibility_label": $0.accessibilityLabel] as [String: Any]
            }
            try repository.writeJSON(["rows": rows], to: root.appendingPathComponent("persisted-reader-rows.json"))
            report["status"] = checks.values.allSatisfy { $0 } ? "passed_routing_and_reader_checks; semantic_review_required" : "failed_checks"
            coordinator.navigate(to: .mathMaterial(persisted.id))
        } catch {
            report["status"] = "failed"
            report["error"] = String(reflecting: error)
        }
        report["wall_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
        try? repository.writeJSON(report, to: root.appendingPathComponent("report.json"))
        try? repository.writeJSON(report, to: root.appendingPathComponent("completed.json"))
    }
}
#endif
