//
//  MathMaterialModel.swift
//  Metra
//
//  Created by Fidel Fausta Cavell on 17/10/26.
//

import Foundation

// Domain model (don't implement pk)
struct MathMaterialModel: Identifiable, Hashable, Sendable {
    // TODO: Define list of model properties
    let id: UUID
    var title: String
    
    init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title
    }
}
