//
//  MathTopicEntity.swift
//  Metra
//
//  Created by Fidel Fausta Cavell on 17/10/26.
//

import Foundation
import SwiftData

@Model
final class MathTopicEntity {
    // TODO: Define list of model properties
    @Attribute(.unique)
    var id: UUID
    
    var title: String
    
    init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title
    }
}
