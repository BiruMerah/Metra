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
    private let photoOutput = AVCapturePhotoOutput()
    private var photoDelegates: [Int64: PhotoCaptureDelegate] = [:]
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
        guard session.canAddOutput(photoOutput) else {
            session.removeOutput(videoOutput)
            session.removeInput(input)
            videoOutput.setSampleBufferDelegate(nil, queue: nil)
            return false
        }
        session.addOutput(photoOutput)
        isConfigured = true
        return true
    }

    func capturePhoto() async throws -> Data {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw CameraCaptureError.permissionDenied
        }
        guard isConfigured else { throw CameraCaptureError.cameraUnavailable }

        return try await withCheckedThrowingContinuation { continuation in
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.flashMode = .off
            let captureID = settings.uniqueID
            let delegate = PhotoCaptureDelegate { [weak self] result in
                self?.photoDelegates.removeValue(forKey: captureID)
                continuation.resume(with: result)
            }
            photoDelegates[captureID] = delegate

            guard session.isRunning else {
                delegate.finish(with: .failure(CameraCaptureError.cameraNotReady))
                return
            }
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
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

private nonisolated final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let onComplete: @MainActor (Result<Data, Error>) -> Void
    private var photoResult: Result<Data, Error>?
    private var hasFinished = false

    init(onComplete: @escaping @MainActor (Result<Data, Error>) -> Void) {
        self.onComplete = onComplete
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            photoResult = .failure(error)
        } else if let data = photo.fileDataRepresentation() {
            photoResult = .success(data)
        } else {
            photoResult = .failure(CameraCaptureError.photoDataUnavailable)
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        let result = error.map { Result<Data, Error>.failure($0) }
            ?? photoResult
            ?? .failure(CameraCaptureError.photoDataUnavailable)
        Task { @MainActor in
            finish(with: result)
        }
    }

    @MainActor
    func finish(with result: Result<Data, Error>) {
        guard !hasFinished else { return }
        hasFinished = true
        onComplete(result)
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
