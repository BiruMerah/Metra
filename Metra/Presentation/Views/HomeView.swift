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
            HStack {
                Text("Home")
                    .font(.title)
                    .fontWeight(.bold)
                    .accessibilityLabel("Kamu saat ini berada dihalaman awal, halaman beranda")
                
                Spacer()
            }
            .padding(.bottom, 96)
            
            ActionButton(title: "Ambil Gambar", accessibilityLabel: "Ambil gambar dari materi atau soal matematika", height: 45) {
                coordinator.navigate(to: .camera)
            }
            
            ActionButton(title: "Unggah Dokumen", accessibilityLabel: "Unggah dokumen materi atau soal matematika", height: 45) {
                coordinator.navigate(to: .importDocument)
            }
            
            ActionButton(title: "Unggah Foto", accessibilityLabel: "Unggah foto yang berisi materi atau soal matematika", height: 45) {
                coordinator.navigate(to: .importPhoto)
            }
            
            ActionButton(title: "Buka Materi Tersimpan", accessibilityLabel: "Buka halaman materi matematika yang tersimpan", height: 45) {
                coordinator.navigate(to: .savedMaterialList)
            }
            .padding(.top, 48)
            
            Spacer()
        }
        .padding(.horizontal, 24)
    }
}

#Preview {
    HomeView(coordinator: AppCoordinator(
        cameraService: CameraService(),
        mathMaterialService: MathMaterialRepository(
            modelContext: ModelContext(try! ModelContainer(for: DatabaseSchema.schema))
        )
    ))
}
