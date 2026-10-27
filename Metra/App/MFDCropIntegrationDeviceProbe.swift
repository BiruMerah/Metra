#if DEBUG
import Foundation

/// Explicit end-to-end pilot through the same service as gallery/camera imports.
@MainActor
enum MFDCropIntegrationDeviceProbe {
    private struct Request: Decodable {
        let sourceSHA256: String
        var title: String? = nil
        var finalSHA256: String? = nil
        var pageSHA256: String? = nil
    }
    private static var started: Set<String> = []

    static func run(attemptID: String, coordinator: AppCoordinator) async {
        guard let id = UUID(uuidString:attemptID)?.uuidString.lowercased(),started.insert(id).inserted,
              let documents = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else { return }
        let root = documents.appendingPathComponent("verification/mfd-integration-v1/\(id)",isDirectory:true)
        let repository = RunRepository()
        var report:[String:Any] = ["schema":"metra-mfd-crop-integration-device-v1","attempt_id":id,
            "build":BuildIdentity.metadata,"status":"running","saved_old_material_modified":false,
            "scope":"One uploaded real image through normal on-device extraction service, MFD crop merge, UniMERNet, MathJax, MathCAT and normal diagram/topic handling; no synthetic content or Mac inference",
            "started_at":ISO8601DateFormatter().string(from:Date())]
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let request = try JSONDecoder().decode(Request.self,from:Data(contentsOf:root.appendingPathComponent("request.json")))
            let input = try Data(contentsOf:root.appendingPathComponent("input.png"))
            guard ImageIngestor.sha256(input) == request.sourceSHA256 else { throw LayoutRuntimeError.invalid("Pilot source SHA-256 mismatch.") }
            try repository.writeJSON(report,to:root.appendingPathComponent("report.json"))
            if let finalHash = request.finalSHA256, let pageHash = request.pageSHA256 {
                report["cached_normalization_checks"] = try await ReadingNormalizationDeviceChecks.run(root:root,finalHash:finalHash,pageHash:pageHash)
                try repository.writeJSON(report,to:root.appendingPathComponent("report.json"))
            }
            let material = try await coordinator.extractionService.extract(
                pages:[MaterialImageInput(data:input,fileName:"mfd-crop-pilot.png",origin:.photoLibrary)],
                title:request.title ?? "Materi — uji crop gabungan") { progress in
                    appendJSONObjectLine(["progress":progress,"time":ISO8601DateFormatter().string(from:Date())],to:root.appendingPathComponent("progress.jsonl"))
                }
            guard let run = material.extractionRunID else { throw LayoutRuntimeError.invalid("Pilot result has no extraction run.") }
            report["run_id"] = run
            let pageURL = try coordinator.extractionService.artifactURL(for:"metra-runs/\(run)/pages/p0001/page-result.json")
            let page = try JSONDecoder().decode(PageExtraction.self,from:Data(contentsOf:pageURL))
            let regions = page.layoutRegions ?? []
            report["source_sha256"] = page.source.sourceSHA256
            report["source_hash_matches_request"] = page.source.sourceSHA256 == request.sourceSHA256
            report["raw_mfd_artifact"] = "metra-runs/\(run)/pages/p0001/mfd.raw.json"
            report["merge_artifact"] = "metra-runs/\(run)/pages/p0001/mfd-crop-merge.json"
            report["active_mfd_regions"] = regions.filter { $0.detectionSource == Pix2TextMFDRuntime.proposalVersion }.count
            report["formula_results"] = (page.formulaRegions ?? []).map { f -> [String:Any] in
                let region = regions.first { $0.id == f.layoutRegionID }
                return ["id":f.id,"region_id":f.layoutRegionID,"route":f.route,"source_text":region?.proposalText as Any? ?? NSNull(),
                        "latex":f.latex as Any? ?? NSNull(),"spoken":f.spokenText as Any? ?? NSNull(),
                        "status":f.status,"merge_allowed":f.spokenMergeAllowed as Any? ?? NSNull(),
                        "consistency":f.sourceConsistencyStatus as Any? ?? NSNull(),"crop":f.cropArtifact as Any? ?? NSNull()]
            }
            try repository.writeJSON(page.components,to:root.appendingPathComponent("components.json"))
            try coordinator.mathMaterialService.addSavedMaterial(material:material)
            report["saved_material_id"] = material.id.uuidString
            report["status"] = "completed_runtime; source_accuracy_requires_review"
            coordinator.navigate(to:.mathMaterial(material.id))
        } catch {
            report["status"] = "failed"
            report["error"] = error.localizedDescription
        }
        report["completed_at"] = ISO8601DateFormatter().string(from:Date())
        try? repository.writeJSON(report,to:root.appendingPathComponent("report.json"))
    }
}
#endif
