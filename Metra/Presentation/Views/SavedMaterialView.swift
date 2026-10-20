//
//  SavedMaterialView.swift
//  Metra
//
//  Created by Fidel Fausta Cavell on 18/10/26.
//

import SwiftUI
import SwiftData

struct SavedMaterialView: View {
    // MARK: - Test SwiftData implementation purpose only
    @Environment(\.modelContext) private var modelContext
    @Query private var materials: [MathMaterialEntity]
    
    // MARK: - Dependencies
    @Bindable var viewModel: SavedMaterialViewModel
    
    var body: some View {
        List {
            if viewModel.materials.isEmpty {
                ContentUnavailableView(
                    "No Materials Yet",
                    systemImage: "tray",
                    description: Text("Tap 'Add Test Item' to test SwiftData insertion.")
                )
            } else {
                ForEach(viewModel.materials) { item in
                    VStack(alignment: .leading) {
                        Text(item.title)
                            .font(.headline)
                        Text(item.id.uuidString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    viewModel.deleteMaterial(at: offsets)
                    
                }
            }
        }
        .navigationTitle("Saved Materials")
        .toolbar {
            Button("Add Test Item") {
                viewModel.addSavedMaterial()
            }
        }
        .task {
            viewModel.loadMaterials()
        }
    }
}
