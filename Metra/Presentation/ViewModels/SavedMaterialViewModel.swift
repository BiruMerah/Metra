//
//  SavedMaterialViewModel.swift
//  Metra
//
//  Created by Fidel Fausta Cavell on 18/10/26.
//

import Foundation
import Observation

@Observable
@MainActor
final class SavedMaterialViewModel {
    // MARK: - Published variables
    var materials: [MathMaterialModel] = []
    var errorMessage: String?
    var isLoading: Bool = false
    
    // MARK: - Dependencies
    private unowned let coordinator: AppCoordinator
    private let mathMaterialService: MathMaterialProtocol
    
    init(coordinator: AppCoordinator, mathMaterialService: MathMaterialProtocol) {
        self.coordinator = coordinator
        self.mathMaterialService = mathMaterialService
    }
    
    // MARK: - Functions
    func loadMaterials() {
        isLoading = true
        errorMessage = nil
        do {
            self.materials = try mathMaterialService.fetchSavedMaterials()
        } catch {
            self.errorMessage = error.localizedDescription
        }
        isLoading = false
    }
    
    func addSavedMaterial() {
        let newMaterial = MathMaterialModel(title: "Math Topic #\(materials.count + 1)")
        do {
            try mathMaterialService.addSavedMaterial(material: newMaterial)
            loadMaterials() // Refresh list
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
    
    func deleteMaterial(at offsets: IndexSet) {
        for index in offsets {
            let item = materials[index]
            do {
                try mathMaterialService.deleteSavedMaterial(id: item.id)
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
        loadMaterials() // Refresh list
    }
}
