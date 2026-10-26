//
//  MathMaterialEntity.swift
//  Metra
//
//  Created by Fidel Fausta Cavell on 17/10/26.
//

import Foundation
import SwiftData

@Model
final class MathMaterialEntity {
    // TODO: Define list of model properties
    @Attribute(.unique)
    var id: UUID
    
    var title: String
    // Optional additions let existing title-only records remain readable.
    var createdAt: Date?
    var extractionRunID: String?
    var readyJSONPath: String?
    var extractionStatus: String?
    var topicIndexJSON: Data?
    @Relationship(deleteRule: .cascade, inverse: \MathChunkEntity.material)
    var chunks: [MathChunkEntity] = []
    
    init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title
        self.createdAt = Date()
    }
    
    // MARK: - Mapper
    func toDomain() -> MathMaterialModel {
        MathMaterialModel(
            id: self.id,
            title: self.title,
            createdAt: createdAt ?? .distantPast,
            extractionRunID: extractionRunID,
            readyJSONPath: readyJSONPath,
            extractionStatus: extractionStatus,
            chunks: chunks.sorted { $0.order < $1.order }.map { $0.toDomain() },
            topicIndexJSON: topicIndexJSON
        )
    }
    
    static func from(domain: MathMaterialModel) -> MathMaterialEntity {
        let entity = MathMaterialEntity(id: domain.id, title: domain.title)
        entity.createdAt = domain.createdAt
        entity.extractionRunID = domain.extractionRunID
        entity.readyJSONPath = domain.readyJSONPath
        entity.extractionStatus = domain.extractionStatus
        entity.topicIndexJSON = domain.topicIndexJSON
        entity.chunks = domain.chunks.map { MathChunkEntity(materialID: domain.id, chunk: $0) }
        return entity
    }
}
