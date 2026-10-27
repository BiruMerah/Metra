#if DEBUG
import Foundation
import UIKit

/// One uploaded real image through the production import/extraction service.
/// No synthetic OCR or expected transcription enters the image-model request.
@MainActor
enum UnicodeMathDeviceProbe {
    private struct Request: Decodable { let sourceSHA256: String; let title: String? }
    private static var started: Set<String> = []

    static func run(attemptID:String,coordinator:AppCoordinator,paddleExperiment:Bool = false) async {
        guard let id = UUID(uuidString:attemptID)?.uuidString.lowercased(),started.insert(id).inserted,
              let documents = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else { return }
        let root = documents.appendingPathComponent("verification/\(paddleExperiment ? "paddleocr-v1" : "unicode-math-v1")/\(id)",isDirectory:true)
        let repository = RunRepository()
        var report: [String:Any] = ["schema":paddleExperiment ? "metra-paddleocr-device-v1" : "metra-unicode-math-device-v1","attempt_id":id,
            "build":BuildIdentity.metadata,"status":"running","saved_material_modified":false,
            "device":["hardware_model_identifier":DeviceIdentity.hardwareModelIdentifier() as Any? ?? NSNull(),"system_version":UIDevice.current.systemVersion],
            "policy":UnicodeMathSource.version,"paddleocr_added":true,
            "scope":"One real image through production layout, MFD, Vision plus native PaddleOCR line recognition, Unicode source proposals, UniMERNet, MathJax, MathCAT and normal diagram/topic handling. All inference on iPhone; no generated OCR or answer supplied.",
            "started_at":ISO8601DateFormatter().string(from:Date())]
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            guard !FileManager.default.fileExists(atPath:root.appendingPathComponent("completed.json").path) else { return }
            let request = try JSONDecoder().decode(Request.self,from:Data(contentsOf:root.appendingPathComponent("request.json")))
            let input = try Data(contentsOf:root.appendingPathComponent("input.png"))
            guard ImageIngestor.sha256(input) == request.sourceSHA256 else { throw LayoutRuntimeError.invalid("Unicode pilot source SHA-256 mismatch") }
            try repository.writeJSON(report,to:root.appendingPathComponent("report.json"))
            let material = try await coordinator.extractionService.extract(
                pages:[MaterialImageInput(data:input,fileName:"unicode-math-pilot.png",origin:.photoLibrary)],
                title:request.title ?? "Materi — uji simbol matematika") { progress in
                    appendJSONObjectLine(["progress":progress,"time":ISO8601DateFormatter().string(from:Date())],to:root.appendingPathComponent("progress.jsonl"))
                }
            guard let run = material.extractionRunID else { throw LayoutRuntimeError.invalid("Pilot result has no run ID") }
            report["run_id"] = run
            let pageURL = try coordinator.extractionService.artifactURL(for:"metra-runs/\(run)/pages/p0001/page-result.json")
            let page = try JSONDecoder().decode(PageExtraction.self,from:Data(contentsOf:pageURL))
            report["source_sha256"] = page.source.sourceSHA256
            report["source_hash_matches_request"] = page.source.sourceSHA256 == request.sourceSHA256
            report["runtime_status"] = page.runtimeStatus.rawValue
            report["paddle_selection_artifact"] = "metra-runs/\(run)/pages/p0001/paddleocr/selection.json"
            report["paddle_components"] = page.components.filter { $0.component == "paddleocr_text_recognition" }.map { c -> [String:Any] in
                ["status":c.status,"message":c.message as Any? ?? NSNull(),"metrics":c.metrics.compactMapValues{$0}]
            }
            report["paddle_selected_observations"] = page.rawOCR.filter { $0.selectedTextOverride != nil }.map { o -> [String:Any] in
                ["id":o.id,"vision_text":o.candidates.first?.text as Any? ?? NSNull(),"selected_text":o.selectedText,
                 "selection_artifact":o.selectionArtifact as Any? ?? NSNull()]
            }
            let regions = page.layoutRegions ?? []
            report["unicode_formula_results"] = (page.formulaRegions ?? []).compactMap { formula -> [String:Any]? in
                guard let region = regions.first(where:{$0.id == formula.layoutRegionID}),
                      region.sourceNotationPolicy == UnicodeMathSource.version else { return nil }
                return ["id":formula.id,"region_id":region.id,"source_text":region.proposalText as Any? ?? NSNull(),
                    "source_range_utf16":region.sourceRangeUTF16 as Any? ?? NSNull(),"route":formula.route,
                    "latex":formula.latex as Any? ?? NSNull(),"spoken":formula.spokenText as Any? ?? NSNull(),
                    "merge_allowed":formula.spokenMergeAllowed as Any? ?? NSNull(),"consistency":formula.sourceConsistencyStatus as Any? ?? NSNull(),
                    "status":formula.status,"crop":formula.cropArtifact as Any? ?? NSNull()]
            }
            report["status"] = "completed_runtime; source_accuracy_requires_review"
        } catch {
            report["status"] = "failed";report["error"] = error.localizedDescription
        }
        report["completed_at"] = ISO8601DateFormatter().string(from:Date())
        try? repository.writeJSON(report,to:root.appendingPathComponent("report.json"))
        try? repository.writeJSON(report,to:root.appendingPathComponent("completed.json"))
    }
}
#endif
