//
//  MetraApp.swift
//  Metra
//
//  Created by Fidel Fausta Cavell on 18/10/26.
//

import SwiftUI
import SwiftData

@main
struct MetraApp: App {
    @State private var coordinator: AppCoordinator
    private let modelContainer: ModelContainer
    
    init() {
        // MARK: - Data Layer setup
        do {
            let config = ModelConfiguration(schema: DatabaseSchema.schema, isStoredInMemoryOnly: false)
            modelContainer = try ModelContainer(for: DatabaseSchema.schema, configurations: config)
        } catch {
            print("SwiftData migration error: \(error). Falling back to in-memory store.")
            let fallbackConfig = ModelConfiguration(schema: DatabaseSchema.schema, isStoredInMemoryOnly: false)
            modelContainer = try! ModelContainer(for: DatabaseSchema.schema, configurations: fallbackConfig)
        }
        let mathMaterialRepository = MathMaterialRepository(modelContext: modelContainer.mainContext)
        let aiManager = AIManager()
        
        // MARK: - Camera setup
        let cameraManager = CameraManager()
        let cameraService = CameraService(cameraManager: cameraManager)
        
        // MARK: - Presentation Layer setup
        let initialCoordinator = AppCoordinator(
            cameraService: cameraService,
            mathMaterialService: mathMaterialRepository,
            aiManager: aiManager
        )
        _coordinator = State(wrappedValue: initialCoordinator)
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinator)
                .modelContainer(modelContainer)
        }
    }
}
