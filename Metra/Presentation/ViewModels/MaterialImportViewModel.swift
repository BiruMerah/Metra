import AVFoundation
import Foundation
import ImageIO
import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@Observable
@MainActor
final class MaterialImportViewModel {
    // MARK: - Presentation State
    var title = ""
    var pages: [MaterialImageInput] = []
    var isLoadingPhotos = false
    var isProcessing = false
    var showCamera = false
    var progressText = ""
    var errorMessage: String?
    var diagramModelIsAvailable = false
    var diagramModelUsesSystem = false
    var diagramModelStatus = ""
    var hasResultToSave: Bool { pendingMaterial != nil }
    var isBusy: Bool { isLoadingPhotos || isProcessing }

    // MARK: - Dependencies
    private unowned let coordinator: AppCoordinator
    private let extractionService: MaterialExtractionProtocol
    private let materialService: MathMaterialProtocol
    @ObservationIgnored private var extractionTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnails: [UUID: UIImage] = [:]
    private var pendingMaterial: MathMaterialModel?

    init(coordinator: AppCoordinator, extractionService: MaterialExtractionProtocol,
         materialService: MathMaterialProtocol) {
        self.coordinator = coordinator
        self.extractionService = extractionService
        self.materialService = materialService
        refreshModelStatus()
    }

    // MARK: - Input Actions
    func addPhotos(_ items: [PhotosPickerItem]) async {
        guard !isBusy, pendingMaterial == nil else { return }
        isLoadingPhotos = true
        defer { isLoadingPhotos = false }
        do {
            // Append only after the whole picker selection was read successfully.
            var selected: [MaterialImageInput] = []
            for item in items {
                try Task.checkCancellation()
                guard let data = try await item.loadTransferable(type: Data.self), !data.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                selected.append(MaterialImageInput(data: data, fileName: "galeri-\(UUID().uuidString.lowercased()).\(ext)", origin: .photoLibrary))
            }
            pages.append(contentsOf: selected)
        } catch { errorMessage = "Halaman belum dapat ditambahkan: \(error.localizedDescription)" }
    }

    func requestCamera() async {
        guard !isBusy, pendingMaterial == nil else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            errorMessage = "Kamera tidak tersedia pada perangkat ini."
            return
        }
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
        default: authorized = false
        }
        if authorized { showCamera = true }
        else { errorMessage = "Izinkan akses kamera untuk Metra melalui Pengaturan iPhone." }
    }

    func addCameraImage(_ image: UIImage) {
        guard !isBusy, pendingMaterial == nil else { return }
        guard let data = image.jpegData(compressionQuality: 0.95) else {
            errorMessage = "Foto belum dapat disimpan. Coba ambil kembali."
            return
        }
        pages.append(MaterialImageInput(data: data, fileName: "kamera-\(UUID().uuidString.lowercased()).jpg", origin: .camera))
    }

    func removePage(id: UUID) {
        guard !isBusy, pendingMaterial == nil else { return }
        pages.removeAll { $0.id == id }
        thumbnails.removeValue(forKey: id)
    }

    func thumbnail(for page: MaterialImageInput) -> UIImage? {
        if let image = thumbnails[page.id] { return image }
        guard let source = CGImageSourceCreateWithData(page.data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 160
              ] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cgImage)
        thumbnails[page.id] = image
        return image
    }

    func movePage(id: UUID, offset: Int) {
        guard !isBusy, pendingMaterial == nil, let index = pages.firstIndex(where: { $0.id == id }),
              pages.indices.contains(index + offset) else { return }
        pages.swapAt(index, index + offset)
    }

    // MARK: - Extraction and Persistence
    func processMaterial() {
        guard !isBusy, !pages.isEmpty else { return }
        errorMessage = nil
        isProcessing = true
        extractionTask = Task { [weak self] in
            guard let self else { return }
            defer { isProcessing = false; extractionTask = nil; refreshModelStatus() }
            do {
                let material: MathMaterialModel
                if let pendingMaterial {
                    material = pendingMaterial
                } else {
                    let requestedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    material = try await extractionService.extract(
                        pages: pages,
                        title: requestedTitle.isEmpty ? "Materi \(pages.count) halaman" : requestedTitle
                    ) { [weak self] progress in self?.progressText = progress }
                    pendingMaterial = material
                }
                try Task.checkCancellation()
                progressText = "Menyimpan materi…"
                try materialService.addSavedMaterial(material: material)
                pendingMaterial = nil
                isProcessing = false
                coordinator.finishExtraction(materialID: material.id)
            } catch is CancellationError {
                progressText = "Pemrosesan dibatalkan."
            } catch {
                errorMessage = pendingMaterial == nil ? error.localizedDescription :
                    "Bacaan sudah dibuat, tetapi belum tersimpan ke daftar materi. Coba simpan ulang. \(error.localizedDescription)"
            }
        }
    }

    func cancel() {
        extractionTask?.cancel()
        extractionService.cancel()
    }

    private func refreshModelStatus() {
        diagramModelIsAvailable = extractionService.diagramModelIsAvailable
        diagramModelUsesSystem = extractionService.diagramModelUsesSystem
        diagramModelStatus = extractionService.diagramModelStatus
    }
}
