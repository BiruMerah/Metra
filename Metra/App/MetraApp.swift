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
    @State private var coordinator: AppCoordinator?
    private let modelContainer: ModelContainer?
    private let storageError: String?
    
    init() {
        // MARK: - Data Layer setup
        do {
            let config = ModelConfiguration(schema: DatabaseSchema.schema, isStoredInMemoryOnly: false)
            let container = try ModelContainer(for: DatabaseSchema.schema, configurations: config)
            modelContainer = container
            storageError = nil
            let repository = MathMaterialRepository(modelContext: container.mainContext)
            _coordinator = State(initialValue: AppCoordinator(
                cameraService: CameraService(), mathMaterialService: repository,
                extractionService: OnDeviceExtractionService()
            ))
        } catch {
            // Keep the existing store and run files. An in-memory fallback must
            // not report that material was saved persistently.
            modelContainer = nil
            storageError = error.localizedDescription
            _coordinator = State(initialValue: nil)
        }
    }
    
    var body: some Scene {
        WindowGroup {
            if let coordinator, let modelContainer {
                ContentView(coordinator: coordinator).modelContainer(modelContainer)
                    .task {
                        #if DEBUG
                        // Device experiments run only with an explicit launch flag.
                        let args = ProcessInfo.processInfo.arguments
                        if let position = args.firstIndex(of: "--metra-foundation-probe"), args.indices.contains(position + 1) {
                            await FoundationModelsDeviceProbe.run(attemptID: args[position + 1])
                            return
                        }
                        if let position = args.firstIndex(of: "--metra-mfd-replay"), args.indices.contains(position + 1) {
                            await MFDCropIntegrationDeviceProbe.run(attemptID: args[position + 1], coordinator: coordinator)
                            return
                        }
                        if let position = args.firstIndex(of: "--metra-mfd-only"), args.indices.contains(position + 1) {
                            await LayoutOnlyDeviceProbe.run(attemptID: args[position + 1], mfdOnly: true)
                            return
                        }
                        if let position = args.firstIndex(of: "--metra-layout-only"), args.indices.contains(position + 1) {
                            await LayoutOnlyDeviceProbe.run(attemptID: args[position + 1])
                            return
                        }
                        if let position = args.firstIndex(of: "--metra-unit-replay"), args.indices.contains(position + 1) {
                            await UnitPowerDeviceProbe.run(sourceRunID: args[position + 1], coordinator: coordinator)
                            return
                        }
                        if let position = args.firstIndex(where: { ["--metra-formula-audit", "--metra-formula-replay"].contains($0) }),
                           args.indices.contains(position + 1), UUID(uuidString: args[position + 1]) != nil {
                            await FormulaMergeDeviceProbe.run(sourceRunID: args[position + 1],
                                replay: args[position] == "--metra-formula-replay", coordinator: coordinator)
                            return
                        }
                        if let position = args.firstIndex(of: "--metra-topic-experiment"),
                           args.indices.contains(position + 1), let id = UUID(uuidString: args[position + 1]) {
                            TopicNavigationDeviceProbe.capture(materialID: id, coordinator: coordinator)
                            coordinator.navigate(to: .mathMaterial(id))
                        }
                        #endif
                    }
            } else {
                ContentUnavailableView("Penyimpanan belum dapat dibuka", systemImage: "externaldrive",
                                       description: Text(storageError ?? "Coba buka kembali aplikasi."))
            }
        }
    }
}
