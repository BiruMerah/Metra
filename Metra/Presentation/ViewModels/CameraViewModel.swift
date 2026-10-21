

import Foundation
import Observation

@Observable
@MainActor
final class CameraViewModel {
    var statusText = "Arahkan kamera ke halaman"
    var guidanceState: CameraGuidanceState = .searching
    var isReady = false
    var isCapturing = false
    var isCameraReady = false
    var capturedPhotoURL: URL?
    var cameraPermissionDenied = false

    private let cameraService: CameraProtocol
    @ObservationIgnored private let guidanceAnnouncer = CameraGuidanceAnnouncer()

    init(cameraService: CameraProtocol) {
        self.cameraService = cameraService
        cameraService.setGuidanceHandler { [weak self] state in
            guard let self, self.capturedPhotoURL == nil, !self.isCapturing else { return }
            let previousState = self.guidanceState
            self.guidanceState = state
            self.statusText = state.message
            self.isReady = state == .ready
            if state != previousState {
                self.guidanceAnnouncer.announce(state.message)
            }
        }
    }

    func prepareCamera() async {
        statusText = "Memeriksa izin kamera..."

        let result = await cameraService.prepareCamera()
        guard !Task.isCancelled else { return }

        switch result {
        case .ready:
            isCameraReady = true
            cameraPermissionDenied = false
          
        case .permissionDenied:
            isCameraReady = false
            isReady = false
            cameraPermissionDenied = true
            statusText = "Akses kamera ditolak. Izinkan kamera melalui Pengaturan."
            guidanceAnnouncer.announce(statusText)
          
        case .cameraUnavailable:
            isCameraReady = false
            isReady = false
            statusText = "Kamera belakang tidak tersedia."
            guidanceAnnouncer.announce(statusText)
          
        case .cancelled:
            break
        }
    }

    func capturePhoto() async {
        guard !isCapturing, capturedPhotoURL == nil else { return }
        
        guard isCameraReady else {
            guidanceAnnouncer.announce(statusText, force: true)
            return
        }
        
        guard isReady else {
            guidanceAnnouncer.announce("Lembar belum siap difoto. \(statusText)", force: true)
            return
        }
        
        isCapturing = true
        statusText = "Mengambil foto..."
        defer { isCapturing = false }

        do {
            capturedPhotoURL = try await cameraService.capturePhoto()
            statusText = "Foto tersimpan di aplikasi. Gunakan tombol Kembali untuk keluar."
            guidanceAnnouncer.announce(statusText)
          
        } catch CameraCaptureError.permissionDenied {
            cameraPermissionDenied = true
            isCameraReady = false
            isReady = false
            statusText = CameraCaptureError.permissionDenied.localizedDescription
            guidanceAnnouncer.announce(statusText)
          
        } catch CameraCaptureError.documentNotReady {
            isReady = false
            guidanceState = .searching
            statusText = CameraCaptureError.documentNotReady.localizedDescription
            guidanceAnnouncer.announce(statusText)
          
        } catch {
            statusText = "Gagal mengambil foto: \(error.localizedDescription)"
            guidanceAnnouncer.announce(statusText)
        }
    }

    func stopCamera() {
        isCameraReady = false
        isReady = false
        guidanceAnnouncer.stop()
        cameraService.stopCamera()
    }
}
