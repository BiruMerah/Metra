import AVFoundation
import QuartzCore
import Vision

@MainActor
final class VisionDocumentAnalyzer {
    private let visionQueue = DispatchQueue(
        label: "metra.vision.document",
        qos: .userInitiated
    )
    private var lastAnalysisTime: CFTimeInterval = 0
    private var isAnalyzing = false
    private let analysisInterval: CFTimeInterval = 0.15

    func analyze(
        pixelBuffer: CVPixelBuffer,
        completion: @escaping @MainActor (DocumentGeometry?) -> Void
    ) {
        let now = CACurrentMediaTime()
        guard !isAnalyzing, now - lastAnalysisTime >= analysisInterval else { return }

        lastAnalysisTime = now
        isAnalyzing = true

        visionQueue.async { [weak self] in
            let request = VNDetectRectanglesRequest()
            request.minimumConfidence = 0.6
            request.minimumSize = 0.2
            request.maximumObservations = 1

            // Matches the portrait back-camera orientation used by the POC.
            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: .right,
                options: [:]
            )

            let geometry: DocumentGeometry?
            do {
                try handler.perform([request])
                geometry = request.results?.first.map(Self.makeGeometry)
            } catch {
                geometry = nil
            }

            Task { @MainActor [weak self] in
                self?.isAnalyzing = false
                completion(geometry)
            }
        }
    }

    nonisolated private static func makeGeometry(
        from rectangle: VNRectangleObservation
    ) -> DocumentGeometry {
        let corners = [
            rectangle.topLeft,
            rectangle.topRight,
            rectangle.bottomLeft,
            rectangle.bottomRight
        ]
        let center = CGPoint(
            x: corners.map(\.x).reduce(0, +) / 4,
            y: corners.map(\.y).reduce(0, +) / 4
        )
        let width = (
            distance(rectangle.topLeft, rectangle.topRight) +
            distance(rectangle.bottomLeft, rectangle.bottomRight)
        ) / 2
        let height = (
            distance(rectangle.topLeft, rectangle.bottomLeft) +
            distance(rectangle.topRight, rectangle.bottomRight)
        ) / 2
        let angle = atan2(
            rectangle.topRight.y - rectangle.topLeft.y,
            rectangle.topRight.x - rectangle.topLeft.x
        )

        return DocumentGeometry(
            center: center,
            coverage: width * height,
            horizontalOffset: center.x - 0.5,
            verticalOffset: 0.5 - center.y,
            tilt: abs(angle)
        )
    }

    nonisolated private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }
}
