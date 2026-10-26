//
//  MathMaterialModel.swift
//  Metra
//
//  Created by Fidel Fausta Cavell on 17/10/26.
//

import Foundation

// Domain model (don't implement pk)
struct MathMaterialModel: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var createdAt: Date
    var extractionRunID: String?
    var readyJSONPath: String?
    var extractionStatus: String?
    var chunks: [MathChunkModel]
    var topicIndexJSON: Data?
    
    init(id: UUID = UUID(), title: String, createdAt: Date = Date(),
         extractionRunID: String? = nil, readyJSONPath: String? = nil,
         extractionStatus: String? = nil, chunks: [MathChunkModel] = [], topicIndexJSON: Data? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.extractionRunID = extractionRunID
        self.readyJSONPath = readyJSONPath
        self.extractionStatus = extractionStatus
        self.chunks = chunks
        self.topicIndexJSON = topicIndexJSON
    }
}
