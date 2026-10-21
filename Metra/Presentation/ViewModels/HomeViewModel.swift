//
//  HomeViewModel.swift
//  Metra
//
//  Created by Fidel Fausta Cavell on 21/10/26.
//

import Foundation
import Observation
import UniformTypeIdentifiers

// MARK: - Data Payload structure
public enum SelectedFileType: Sendable {
    case pdf
    case image
}
public struct SelectedDocumentPayload: Sendable {
    public let fileName: String
    public let fileType: SelectedFileType
    public let mimeType: String
    public let data: Data
    
    public init(fileName: String, fileType: SelectedFileType, mimeType: String, data: Data) {
        self.fileName = fileName
        self.fileType = fileType
        self.mimeType = mimeType
        self.data = data
    }
}

@Observable
@MainActor
final class HomeViewModel {
    // MARK: - Published variables
    var selectedDocument: SelectedDocumentPayload?
    var isLoading: Bool = false
    var errorMessage: String?
    
    // MARK: - Dependencies
    private unowned let coordinator: AppCoordinator
    private let mathMaterialService: MathMaterialProtocol
    private let aiManager: AIServiceProtocol
    
    init(coordinator: AppCoordinator, mathMaterialService: MathMaterialProtocol, aiManager: AIServiceProtocol) {
        self.coordinator = coordinator
        self.mathMaterialService = mathMaterialService
        self.aiManager = aiManager
    }
    
    // MARK: Functions
    func handleDocument(at url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            self.errorMessage = "Izin mengakses file ditolak oleh sistem"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        do {
            let fileData = try Data(contentsOf: url)
            let fileName = url.lastPathComponent
            let fileExtension = url.pathExtension
            
            guard let utType = UTType(filenameExtension: fileExtension) else {
                self.errorMessage = "Tipe file tidak dikenali."
                return
            }
            
            let fileType: SelectedFileType
            if utType.conforms(to: .pdf) {
                fileType = .pdf
            } else if utType.conforms(to: .image) {
                fileType = .image
            } else {
                self.errorMessage = "Format file tidak didukung. Harap pilih PDF atau Gambar."
                return
            }
            
            let mimeType = utType.preferredMIMEType ?? (fileType == .pdf ? "application/pdf" : "image/jpeg")
            self.selectedDocument = SelectedDocumentPayload(
                fileName: fileName,
                fileType: fileType,
                mimeType: mimeType,
                data: fileData
            )
            print("Berhasil menyimpan dokumen: \(fileName) (\(fileData.count) bytes)")
            
            Task {
                await sendToAI()
            }
            
        } catch {
            self.errorMessage = "Fail to sent file: \(error.localizedDescription)"
        }
    }
    
    func sendToAI() async {
        guard let document = selectedDocument else {
            self.errorMessage = "Tidak ada dokumen yang dipilih."
            return
        }
        
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        
        do {
            print("Sent to AI manager")
            
            try await Task.sleep(for: .seconds(3))
            
            print("Delay finished, processing...")
            
        } catch {
            self.errorMessage = "Gagal memproses dengan AI: \(error.localizedDescription)"
        }
    }
}
