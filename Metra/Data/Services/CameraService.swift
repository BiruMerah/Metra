import AVFoundation

@MainActor
final class CameraService: CameraProtocol {
    private let cameraManager: CameraManager
    private let documentAnalyzer = VisionDocumentAnalyzer()
    private let guidanceService = CameraGuidanceService()
    private var guidanceHandler: (@MainActor (CameraGuidanceState) -> Void)?
    private var lastGuidanceState: CameraGuidanceState?
    private var isActive = false
    private var generation = 0

    // The coordinator supplies this session to the SwiftUI preview.
    var previewSession: AVCaptureSession {
        cameraManager.session
    }

    init(cameraManager: CameraManager) {
        self.cameraManager = cameraManager
        cameraManager.onFrame = { [weak self] pixelBuffer in
            self?.process(pixelBuffer)
        }
    }

    func setGuidanceHandler(
        _ handler: @escaping @MainActor (CameraGuidanceState) -> Void
    ) {
        guidanceHandler = handler
    }

    func prepareCamera() async -> CameraPreparationResult {
        guard await cameraManager.requestPermission() else {
            return Task.isCancelled ? .cancelled : .permissionDenied
        }

        guard !Task.isCancelled else { return .cancelled }
        guard cameraManager.configureBackCamera() else { return .cameraUnavailable }

        generation += 1
        guidanceService.reset()
        lastGuidanceState = .searching
        isActive = true
        guidanceHandler?(.searching)
        cameraManager.startCamera()
        return .ready
    }

    func stopCamera() {
        isActive = false
        generation += 1
        guidanceService.reset()
        lastGuidanceState = nil
        cameraManager.stopCamera()
    }

    private func process(_ pixelBuffer: CVPixelBuffer) {
        guard isActive else { return }
        let currentGeneration = generation

        documentAnalyzer.analyze(pixelBuffer: pixelBuffer) { [weak self] geometry in
            guard let self, self.isActive, self.generation == currentGeneration else { return }

            let state = self.guidanceService.evaluate(geometry)
            guard state != self.lastGuidanceState else { return }
            self.lastGuidanceState = state
            self.guidanceHandler?(state)
        }
    }
}
