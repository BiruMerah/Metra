//
//  SavedMaterialView.swift
//  Metra
//
//  Created by Fidel Fausta Cavell on 18/10/26.
//

import SwiftUI

struct SavedMaterialView: View {
    // MARK: - Dependencies
    @Bindable var viewModel: SavedMaterialViewModel
    
    var body: some View {
        List {
            if viewModel.materials.isEmpty {
                ContentUnavailableView(
                    "Belum ada materi",
                    systemImage: "tray",
                    description: Text("Tambahkan halaman dari galeri atau kamera.")
                )
            } else {
                ForEach(viewModel.materials) { item in
                    Button { viewModel.openMaterial(item) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title).font(.headline)
                        }.foregroundStyle(.primary)
                    }
                }
                .onDelete { offsets in
                    viewModel.deleteMaterial(at: offsets)
                    
                }
            }
        }
        .navigationTitle("Materi tersimpan")
        .toolbar {
            Button("Tambah materi") {
                viewModel.addMaterial()
            }
        }
        .task {
            viewModel.loadMaterials()
        }
        .alert("Materi belum dapat dibuka", isPresented: Binding(
            get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(viewModel.errorMessage ?? "") }
    }
}

//#Preview {
//    let config = ModelConfiguration(isStoredInMemoryOnly: false)
//    let container = try! ModelContainer(for: DatabaseSchema.schema, configurations: config)
//    
//    return SavedMaterialView()
//        .modelContainer(container)
//}
