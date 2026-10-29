#if DEBUG
import Foundation
import ImageIO

/// Explicit classifier-only experiment. Uses the production adapter on the
/// supplied image without page detection, OCR, formula inference or generation.
@MainActor
enum VisualClassifierDeviceProbe {
    private static var started = Set<String>()

    static func run(attemptID: String) async {
        guard let id = UUID(uuidString: attemptID)?.uuidString.lowercased(),
              started.insert(id).inserted,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let root = documents.appendingPathComponent("verification/visual-classifier-v1/\(id)")
        let completed = root.appendingPathComponent("completed.json")
        guard !FileManager.default.fileExists(atPath: completed.path) else { return }
        let repository = RunRepository()
        var report: [String: Any] = ["schema": "metra-visual-classifier-probe-v1",
            "attempt_id": id, "build": BuildIdentity.metadata,
            "scope": "Attached image passed unchanged to production MathVisualClassifier; iPhone inference only",
            "status": "running", "ocr_requests": 0, "foundation_requests": 0]
        do {
            let imageURL = root.appendingPathComponent("input.jpg")
            let data = try Data(contentsOf: imageURL)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw DiagramProbeError.invalidObject }
            report["input_sha256"] = ImageIngestor.sha256(data)
            report["input_size"] = [image.width, image.height]
            let pageRoot = root.appendingPathComponent("pages/p0001")
            try FileManager.default.createDirectory(at: pageRoot, withIntermediateDirectories: true)
            let region = LayoutRegion(id: "p0001.attached-image", classID: -1, label: "image", score: 1,
                bboxPageXYXY: PixelBox(xmin: 0, ymin: 0, xmax: Double(image.width), ymax: Double(image.height)),
                rawIndex: 0, cropArtifact: "input.jpg")
            guard let result = try MathVisualClassifier.classify(regions: [region], pageRoot: pageRoot).first?.visualClassification else {
                throw DiagramProbeError.invalidObject
            }
            try repository.writeJSON(result, to: root.appendingPathComponent("classification.json"))
            report["status"] = result.status
            report["predicted_class"] = result.predictedClass?.rawValue
            report["probabilities"] = result.probabilities
            report["classifier_version"] = result.version
            report["model_sha256"] = result.modelSHA256
            report["input_matches_classified_crop"] = result.cropSHA256 == ImageIngestor.sha256(data)
            report["request_ms"] = result.requestMilliseconds
            if let error = result.error { report["error"] = error }
        } catch {
            report["status"] = "failed"
            report["error"] = String(reflecting: error)
        }
        try? repository.writeJSON(report, to: completed)
    }
}
#endif
