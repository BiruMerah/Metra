#if DEBUG
import Foundation
import UIKit

/// Opt-in measurement of one uploaded image with the production layout adapter.
/// Every attempt has its own directory and leaves saved material untouched.
@MainActor
enum LayoutOnlyDeviceProbe {
    private struct Request: Decodable { let sourceSHA256: String }
    private static var started: Set<String> = []

    static func run(attemptID: String, mfdOnly: Bool = false) async {
        guard let id = UUID(uuidString: attemptID)?.uuidString.lowercased(),
              started.insert((mfdOnly ? "mfd:" : "layout:") + id).inserted,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let root = documents.appendingPathComponent("verification/\(mfdOnly ? "mfd-only-v1" : "layout-only-v1")/\(id)", isDirectory: true)
        let repository = RunRepository()
        let sampler = MemorySampler(outputURL: root.appendingPathComponent("memory.jsonl"), runID: id)
        var report: [String: Any] = [
            "schema": mfdOnly ? "metra-mfd-only-device-v1" : "metra-layout-only-device-v1", "attempt_id": id,
            "build": BuildIdentity.metadata, "status": "running",
            "started_at": ISO8601DateFormatter().string(from: Date()),
            "device": ["hardware_model_identifier": DeviceIdentity.hardwareModelIdentifier() as Any? ?? NSNull(),
                       "system_version": UIDevice.current.systemVersion],
            "scope": mfdOnly ? "One image, Pix2Text-MFD only; no recognizer or other model inference" : "One image, PP-DocLayout-L only; existing production preprocessing and postprocessing. No OCR, supplemental formula proposals, UniMERNet, MathCAT or Qwen.",
            "source_accuracy": "not_assessed", "saved_material_modified": false
        ]
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: root.appendingPathComponent("request.json")))
            let inputURL = root.appendingPathComponent("input.png")
            let input = try Data(contentsOf: inputURL)
            guard ImageIngestor.sha256(input) == request.sourceSHA256 else {
                throw LayoutRuntimeError.invalid("Uploaded layout input SHA-256 does not match request.")
            }
            try repository.writeJSON(report, to: root.appendingPathComponent("report.json"))
            sampler.start(); sampler.sampleNow()
            let source = try ImageIngestor().ingestFile(inputURL)
            let normalizedURL = try ImageIngestor.normalizedURL(for: source)
            try repository.writeJSON(source, to: root.appendingPathComponent("source.json"))
            try Data(contentsOf: normalizedURL).write(to: root.appendingPathComponent("normalized.png"), options: .atomic)
            let pageRoot = root.appendingPathComponent("pages/p0001", isDirectory: true)
            try FileManager.default.createDirectory(at: pageRoot.appendingPathComponent("crops"), withIntermediateDirectories: true)
            if mfdOnly {
                let runtime = Pix2TextMFDRuntime()
                do {
                    let result = try await runtime.detect(imageURL: normalizedURL, pageID: "p0001", pageRoot: pageRoot,
                                                         enqueuedAt: ProcessInfo.processInfo.systemUptime)
                    report["page_size"] = result.pageSize
                    report["raw_box_count"] = result.rawPredictions.count
                    report["region_count"] = result.regions.count
                    report["counts_by_label"] = Dictionary(grouping: result.regions, by: \.classID).map { ["class_id": $0.key,"count": $0.value.count] }
                    report["metrics_ms"] = result.metrics
                    report["model_was_warm"] = result.modelWasWarm
                    report["layout_artifact"] = "pages/p0001/mfd.raw.json"
                    report["overlay_artifact"] = "pages/p0001/mfd-overlay.png"
                } catch { await runtime.unload(); throw error }
                await runtime.unload()
            } else {
                let runtime = PPDocLayoutRuntime()
                do {
                    let result = try await runtime.detect(imageURL: normalizedURL, pageID: "p0001", pageRoot: pageRoot,
                                                         enqueuedAt: ProcessInfo.processInfo.systemUptime)
                    report["page_size"] = result.pageSize
                    report["raw_box_count"] = result.rawBoxes.count
                    report["region_count"] = result.regions.count
                    report["counts_by_label"] = Dictionary(grouping: result.regions, by: \.label).mapValues(\.count)
                    report["metrics_ms"] = result.metrics
                    report["model_was_warm"] = result.modelWasWarm
                    report["layout_artifact"] = "pages/p0001/layout.raw.json"
                    report["overlay_artifact"] = "pages/p0001/layout-overlay.png"
                } catch { await runtime.unload(); throw error }
                await runtime.unload()
            }
            sampler.sampleNow()
            report["source_sha256"] = source.sourceSHA256
            report["normalized_sha256"] = source.normalizedSHA256
            report["status"] = "completed"
        } catch {
            report["status"] = "failed"
            report["error"] = error.localizedDescription
        }
        sampler.stop()
        report["completed_at"] = ISO8601DateFormatter().string(from: Date())
        try? repository.writeJSON(report, to: root.appendingPathComponent("report.json"))
    }
}
#endif
