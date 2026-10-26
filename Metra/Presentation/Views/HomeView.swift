//
//  HomeView.swift
//  Metra
//
//  Created by Fidel Fausta Cavell on 18/10/26.
//

import SwiftUI
import SwiftData

struct HomeView: View {
    let coordinator: AppCoordinator
    
    var body: some View {
        VStack(spacing: 24) {
            Text("Belajar dari materi matematika Anda")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("Tambahkan foto halaman untuk menyusun bacaan matematika di iPhone.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)

            Button { coordinator.navigate(to: .camera) } label: {
                Label("Tambah materi", systemImage: "camera")
            }.buttonStyle(.glassProminent)
            
            Button("Materi tersimpan") {
                coordinator.navigate(to: .savedMaterialList)
            }
            .buttonStyle(.glassProminent)
        }.padding().navigationTitle("Metra")
    }
}

#Preview {
    HomeView(coordinator: AppCoordinator(
        cameraService: CameraService(),
        mathMaterialService: MathMaterialRepository(
            modelContext: ModelContext(try! ModelContainer(for: DatabaseSchema.schema))
        ),
        extractionService: OnDeviceExtractionService()
    ))
}
