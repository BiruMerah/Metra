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
    @State private var isImportingPhoto = false
    @State private var selectedPhotoURL: URL?
    
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
                title: "Ambil Foto",
                accessibilityLabel: "Ambil foto dari materi atau soal matematika",
                height: 45
            ) {
                coordinator.navigate(to: .camera)
            }
            
            ActionButton(
                title: "Unggah Foto",
                accessibilityLabel: "Unggah foto yang berisi materi atau soal matematika",
                height: 45
            ) {
                isImportingPhoto = true
            }
            
            ActionButton(
                title: "Unggah Dokumen",
                accessibilityLabel: "Unggah dokumen materi atau soal matematika",
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
            isPresented: $isImportingPhoto,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            // MARK: - Getting photo file logic
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                viewModel.handleDocument(at: url)
                
            case .failure(let error):
                print("Failed to pick photo: \(error.localizedDescription)")
            }
        }
        .overlay {
            if viewModel.isLoading {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text("Menganalisis foto...")
                            .foregroundStyle(.white)
                            .font(.headline)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .alert("Error", isPresented: .init(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("Ok", role: .cancel) { }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }
}

#Preview {
    let cameraService = CameraService(cameraManager: CameraManager())
    let mathMaterialService = MathMaterialRepository(
        modelContext: ModelContext(try! ModelContainer(for: DatabaseSchema.schema))
    )
    let aiManager = AIManager()
    let coordinator = AppCoordinator(
        cameraService: cameraService,
        mathMaterialService: mathMaterialService,
        aiManager: aiManager
    )
    
    HomeView(
        coordinator: coordinator,
        viewModel: HomeViewModel(coordinator: coordinator, mathMaterialService: mathMaterialService, aiManager: aiManager)
    )
}
