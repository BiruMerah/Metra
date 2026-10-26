//
//  MathMaterialRepository.swift
//  Metra
//
//  Created by Fidel Fausta Cavell on 18/10/26.
//

import Foundation
import SwiftData

@MainActor
final class MathMaterialRepository: MathMaterialProtocol {
    private let modelContext: ModelContext
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    // MARK: - Protocol implementation
    func fetchSavedMaterials() throws -> [MathMaterialModel] {
        let descriptor = FetchDescriptor<MathMaterialEntity>()
        let entities = try modelContext.fetch(descriptor)
        
        return entities.map { $0.toDomain() }.sorted { $0.createdAt > $1.createdAt }
    }

    func fetchSavedMaterial(id: UUID) throws -> MathMaterialModel? {
        try findEntity(id: id)?.toDomain()
    }
    
    func addSavedMaterial(material: MathMaterialModel) throws {
        do {
            // Retrying a database save for the same run must not duplicate content.
            if let entity = try findEntity(id: material.id) {
                entity.title = material.title
                entity.createdAt = material.createdAt
                entity.extractionRunID = material.extractionRunID
                entity.readyJSONPath = material.readyJSONPath
                entity.extractionStatus = material.extractionStatus
                entity.topicIndexJSON = material.topicIndexJSON
                let incoming = Set(material.chunks.map(\.id))
                for old in entity.chunks where !incoming.contains(old.sourceID) { modelContext.delete(old) }
                let existing = Dictionary(uniqueKeysWithValues: entity.chunks.map { ($0.sourceID, $0) })
                entity.chunks = material.chunks.map { chunk in
                    // A run is immutable: reuse an already persisted source chunk.
                    existing[chunk.id] ?? MathChunkEntity(materialID: material.id, chunk: chunk)
                }
            } else {
                modelContext.insert(MathMaterialEntity.from(domain: material))
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
    
    func deleteSavedMaterial(id: UUID) throws {
        if let entity = try findEntity(id: id) {
            modelContext.delete(entity)
            do { try modelContext.save() }
            catch { modelContext.rollback(); throw error }
        }
    }

    private func findEntity(id: UUID) throws -> MathMaterialEntity? {
        let targetID = id
        var descriptor = FetchDescriptor<MathMaterialEntity>(predicate: #Predicate { $0.id == targetID })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
