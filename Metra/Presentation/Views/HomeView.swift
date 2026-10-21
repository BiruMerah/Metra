//
//  HomeView.swift
//  Metra
//
//  Created by Fidel Fausta Cavell on 18/10/26.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct HomeView: View {
    let coordinator: AppCoordinator
    
    // MARK: - Dependencies
    @Bindable var viewModel: HomeViewModel
    
    // MARK: - State variable of document picker
    @State private var isImportingDocument = false
    @State private var selectedDocumentURL: URL?
    
    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Text("Home")
                    .font(.title)
                    .fontWeight(.bold)
                    .accessibilityLabel("Kamu saat ini berada dihalaman awal, halaman beranda")
                
                Spacer()
            }
            .padding(.bottom, 96)
            
            ActionButton(
                title: "Ambil Gambar",
                accessibilityLabel: "Ambil gambar dari materi atau soal matematika",
                height: 45
            ) {
                coordinator.navigate(to: .camera)
            }
            
            ActionButton(
                title: "Unggah Dokumen",
                accessibilityLabel: "Unggah dokumen materi atau soal matematika",
                height: 45
            ) {
                isImportingDocument = true
            }
            
            ActionButton(
                title: "Unggah Foto",
                accessibilityLabel: "Unggah foto yang berisi materi atau soal matematika",
                height: 45
            ) {
                coordinator.navigate(to: .importPhoto)
            }
            
            ActionButton(
                title: "Buka Materi Tersimpan",
                accessibilityLabel: "Buka halaman materi matematika yang tersimpan",
                height: 45
            ) {
                coordinator.navigate(to: .savedMaterialList)
            }
            .padding(.top, 48)
            
            Spacer()
        }
        .padding(.horizontal, 24)
        .fileImporter(
            isPresented: $isImportingDocument,
            allowedContentTypes: [.pdf, .image],
            allowsMultipleSelection: false
        ) { result in
            // MARK: - Getting document logic
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                
                guard url.startAccessingSecurityScopedResource() else {
                    print("Permission to access file is denied")
                    return
                }
                defer { url.stopAccessingSecurityScopedResource() }
                
                self.selectedDocumentURL = url
                print("Picked document at: \(url)")
                
                // TODO - Processing logic code
                
            case .failure(let error):
                print("Failed to pick document: \(error.localizedDescription)")
            }
        }
    }
}

#Preview {
    let cameraService = CameraService(cameraManager: CameraManager())
    let mathMaterialService = MathMaterialRepository(
        modelContext: ModelContext(try! ModelContainer(for: DatabaseSchema.schema))
    )
    let coordinator = AppCoordinator(
        cameraService: cameraService,
        mathMaterialService: mathMaterialService
    )
    
    HomeView(
        coordinator: coordinator,
        viewModel: HomeViewModel(coordinator: coordinator, mathMaterialService: mathMaterialService)
    )
}
