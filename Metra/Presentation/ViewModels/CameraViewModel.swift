

import Foundation
import Observation

@Observable
@MainActor
final class CameraViewModel {
    var statusText = "Arahkan kamera ke halaman"
    var isReady = false
    var isCapturing = false

    private let cameraService: CameraProtocol
    @ObservationIgnored private let guidanceAnnouncer = CameraGuidanceAnnouncer()

    init(cameraService: CameraProtocol) {
        self.cameraService = cameraService
        cameraService.setGuidanceHandler { [weak self] state in
            self?.statusText = state.message
            self?.isReady = state == .ready
            self?.guidanceAnnouncer.announce(state.message)
        }
    }

    func prepareCamera() async {
        statusText = "Memeriksa izin kamera..."

        let result = await cameraService.prepareCamera()
        guard !Task.isCancelled else { return }

        switch result {
        case .ready:
            break // The guidance handler supplies the live status.
        case .permissionDenied:
            statusText = "Akses kamera ditolak. Izinkan kamera melalui Pengaturan."
            guidanceAnnouncer.announce(statusText)
        case .cameraUnavailable:
            statusText = "Kamera belakang tidak tersedia."
            guidanceAnnouncer.announce(statusText)
        case .cancelled:
            break
        }
    }

    func stopCamera() {
        guidanceAnnouncer.stop()
        cameraService.stopCamera()
    }
}
