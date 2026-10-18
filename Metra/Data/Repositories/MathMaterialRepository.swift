//
//  MathMaterialRepository.swift
//  Metra
//
//  Created by Fidel Fausta Cavell on 18/10/26.
//

import Foundation
import SwiftData

final class MathMaterialRepository: MathMaterialProtocol {
    private let modelContext: ModelContext
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    // MARK: - Protocol implementation
    func fetchSavedMaterials() throws -> [MathMaterialModel] {
        let descriptor = FetchDescriptor<MathMaterialEntity>()
        let entities = try modelContext.fetch(descriptor)
        
        return entities.map { $0.toDomain() }
    }
    
    func addSavedMaterial(material: MathMaterialModel) throws {
        let entity = MathMaterialEntity.from(domain: material)
        modelContext.insert(entity)
        try modelContext.save()
    }
    
    func deleteSavedMaterial(id: UUID) throws {
        let targetId = id
        let predicate = #Predicate<MathMaterialEntity> { $0.id == targetId }
        let descriptor = FetchDescriptor<MathMaterialEntity>(predicate: predicate)
        
        if let entity = try modelContext.fetch(descriptor).first {
            modelContext.delete(entity)
            try modelContext.save()
        }
    }
}
