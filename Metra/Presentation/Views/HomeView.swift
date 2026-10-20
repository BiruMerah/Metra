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
            Text("Hello, This is HomeView!")
                .font(.title2)
            
            Button("Take Photos") {
                coordinator.navigate(to: .camera)
            }
            
            Button("Go to Saved Materials") {
                coordinator.navigate(to: .savedMaterialList)
            }
            .buttonStyle(.glassProminent)
        }
    }
}

#Preview {
    HomeView(coordinator: AppCoordinator(
        cameraService: CameraService(cameraManager: CameraManager()),
        mathMaterialService: MathMaterialRepository(
            modelContext: ModelContext(try! ModelContainer(for: DatabaseSchema.schema))
        )
    ))
}
