import Foundation
import CoreML
import Vision

enum MathVisualClass: String, Codable, Sendable {
    case graph, diagrams, geometry, others

    var guideline: String {
        switch self {
        case .graph:
            "State the graph subtype. Describe the x- and y-axes and what their labels represent, if these axes exist. Do not invent axes for pie charts. List source data points individually. For coordinate pairs, render the separator as the spoken Indonesian word koma. Do not infer trends or solve the exercise."
        case .diagrams:
            "Describe the visible parts of this math diagram in short bullet points. Spell out abbreviated units for audio. Describe the image, not the concept taught by the surrounding text. Do not solve or explain the exercise."
        case .geometry:
            "Use brief, specific sentences about visible points and lines, organized from left to right. Use bullet points or line breaks. Focus on data not already described in the caption; do not repeat the surrounding explanation. Do not infer unmarked relationships."
        case .others:
            "Skip description generation."
        }
    }
}

struct MathVisualClassification: Codable, Sendable {
    let version: String
    let modelSHA256: String
    let status: String
    let predictedClass: MathVisualClass?
    let probabilities: [String: Double]
    let cropArtifact: String?
    let cropSHA256: String?
    let preprocessing: String
    let requestMilliseconds: Double
    let error: String?
}

/// One model instance per page; discarded before loading the next heavy model.
enum MathVisualClassifier {
    static let version = "math_visual_classifier_v1"
    static let modelSHA256 = "f5a6837fc1649b99172f621b9873f15de139f83e17c6a4ef74b811756adbb062"

    static func classify(regions: [LayoutRegion], pageRoot: URL) throws -> [LayoutRegion] {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard let url = Bundle.main.url(forResource: "MathVisualRepresentationClassifier", withExtension: "mlmodelc") else {
            throw LayoutRuntimeError.invalid("Model classifier gambar belum tersedia.")
        }
        let model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: configuration))
        let runRoot = pageRoot.deletingLastPathComponent().deletingLastPathComponent()
        return regions.map { source in
            guard DiagramSpokenService.visualLabels.contains(source.label) else { return source }
            var region = source
            let start = ProcessInfo.processInfo.systemUptime
            var probabilities: [String: Double] = [:]
            var predicted: MathVisualClass?, failure: String?, hash: String?
            do {
                try Task.checkCancellation()
                guard let crop = source.cropArtifact else { throw DiagramProbeError.invalidObject }
                let imageURL = runRoot.appendingPathComponent(crop)
                hash = ImageIngestor.sha256(try Data(contentsOf: imageURL))
                let request = VNCoreMLRequest(model: model)
                // Keep the complete chart/geometry crop, including edge labels.
                request.imageCropAndScaleOption = .scaleFit
                try VNImageRequestHandler(url: imageURL, options: [:]).perform([request])
                guard let predictions = request.results as? [VNClassificationObservation],
                      let best = predictions.first, let kind = MathVisualClass(rawValue: best.identifier) else {
                    throw LayoutRuntimeError.invalid("Label classifier gambar tidak dikenal.")
                }
                probabilities = Dictionary(uniqueKeysWithValues: predictions.map { ($0.identifier, Double($0.confidence)) })
                predicted = kind
            } catch { failure = error.localizedDescription }
            region.visualClassification = .init(version: version, modelSHA256: modelSHA256,
                status: failure == nil ? "succeeded" : "failed", predictedClass: predicted, probabilities: probabilities,
                cropArtifact: source.cropArtifact, cropSHA256: hash,
                preprocessing: "Vision scaleFit; preserve full crop; model RGB input 360x360; training crop policy unavailable",
                requestMilliseconds: (ProcessInfo.processInfo.systemUptime-start)*1000, error: failure)
            return region
        }
    }
}
