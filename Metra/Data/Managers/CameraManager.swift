//
//  CameraManager.swift
//  Metra
//
//  Created by Andito Rizkyka Rianto on 20/10/26.
//

import AVFoundation

@MainActor
final class CameraManager: NSObject {
    let session = AVCaptureSession()
    var onFrame: ((CVPixelBuffer) -> Void)?

    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(
        label: "metra.camera.video",
        qos: .userInitiated
    )
    private var isConfigured = false
    
    private let sessionQueue = DispatchQueue(
        label: "metra.camera.session",
        qos: .userInitiated
    )
    
    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default :
            return false
        }
    }
    
    func configureBackCamera() -> Bool {
        guard !isConfigured else { return true }

        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ), let input = try? AVCaptureDeviceInput(device: camera) else {
            return false
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        guard session.canAddInput(input) else { return false }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)

        guard session.canAddOutput(videoOutput) else {
            session.removeInput(input)
            videoOutput.setSampleBufferDelegate(nil, queue: nil)
            return false
        }
        session.addOutput(videoOutput)
        isConfigured = true
        return true
    }
    
    func startCamera() {
        let cameraSession = session

        sessionQueue.async {
            guard !cameraSession.isRunning else { return }
            cameraSession.startRunning()
        }
    }

    func stopCamera() {
        let cameraSession = session

        sessionQueue.async {
            guard cameraSession.isRunning else { return }
            cameraSession.stopRunning()
        }
    }
    
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        Task { @MainActor [weak self] in
            self?.onFrame?(pixelBuffer)
        }
    }
}
