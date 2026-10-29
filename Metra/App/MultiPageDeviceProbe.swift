#if DEBUG
import Foundation
import UIKit

/// Explicit multi-page experiment through the normal gallery import service.
@MainActor
enum MultiPageDeviceProbe {
    private struct InputPage: Codable {
        let fileName: String
        let sourceSHA256: String
        let pdfPage: Int
        let printedPage: Int
        let topic: String
    }
    private struct Request: Decodable {
        let title: String
        let pages: [InputPage]
    }
    private static var started: Set<String> = []

    static func run(attemptID: String, coordinator: AppCoordinator) async {
        guard let id = UUID(uuidString: attemptID)?.uuidString.lowercased(),
              started.insert(id).inserted,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let root = documents.appendingPathComponent("verification/multipage-clearspeak-v1/\(id)", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("completed.json").path) else { return }
        let repository = RunRepository()
        let start = ProcessInfo.processInfo.systemUptime
        var report: [String: Any] = [
            "schema": "metra-multipage-device-v1", "attempt_id": id,
            "build": BuildIdentity.metadata, "status": "running",
            "device": ["hardware_model_identifier": DeviceIdentity.hardwareModelIdentifier() as Any? ?? NSNull(),
                       "system_version": UIDevice.current.systemVersion],
            "scope": "One 4–5 page import through the production on-device extraction service; original full-page PNGs, no synthetic content or Mac inference",
            "started_at": ISO8601DateFormatter().string(from: Date())
        ]
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: root.appendingPathComponent("request.json")))
            guard (4...5).contains(request.pages.count),
                  Set(request.pages.map(\.fileName)).count == request.pages.count else {
                throw LayoutRuntimeError.invalid("Expected 4–5 distinct input pages.")
            }
            let inputs = try request.pages.map { page -> MaterialImageInput in
                guard !page.fileName.isEmpty, page.fileName == (page.fileName as NSString).lastPathComponent,
                      page.fileName != ".", page.fileName != ".." else {
                    throw LayoutRuntimeError.invalid("Invalid input filename.")
                }
                let data = try Data(contentsOf: root.appendingPathComponent("inputs/\(page.fileName)"))
                guard ImageIngestor.sha256(data) == page.sourceSHA256 else {
                    throw LayoutRuntimeError.invalid("Input SHA-256 mismatch: \(page.fileName)")
                }
                return MaterialImageInput(data: data, fileName: page.fileName, origin: .photoLibrary)
            }
            report["input_pages"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request.pages))
            report["input_hashes_verified"] = true
            report["diagram_model_status_before_run"] = coordinator.extractionService.diagramModelStatus
            try repository.writeJSON(report, to: root.appendingPathComponent("report.json"))
            let material = try await coordinator.extractionService.extract(pages: inputs, title: request.title) { progress in
                appendJSONObjectLine(["progress": progress, "time": ISO8601DateFormatter().string(from: Date())],
                                     to: root.appendingPathComponent("progress.jsonl"))
            }
            guard let run = material.extractionRunID else { throw LayoutRuntimeError.invalid("Missing extraction run ID.") }
            report["run_id"] = run
            report["ready_json_path"] = material.readyJSONPath
            report["material_status"] = material.extractionStatus
            report["chunk_count"] = material.chunks.count
            report["output_page_ids"] = Array(Set(material.chunks.compactMap(\.pageID))).sorted()
            try coordinator.mathMaterialService.addSavedMaterial(material: material)
            report["saved_material_id"] = material.id.uuidString
            report["status"] = "completed_runtime; source_accuracy_requires_review"
            coordinator.navigate(to: .mathMaterial(material.id))
        } catch {
            report["status"] = "failed"
            report["error"] = error.localizedDescription
        }
        report["wall_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
        report["completed_at"] = ISO8601DateFormatter().string(from: Date())
        try? repository.writeJSON(report, to: root.appendingPathComponent("report.json"))
        try? repository.writeJSON(report, to: root.appendingPathComponent("completed.json"))
    }
}
#endif
