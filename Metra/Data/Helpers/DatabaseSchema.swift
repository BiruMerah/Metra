//
//  DatabaseSchema.swift
//  Metra
//
//  Created by Fidel Fausta Cavell on 18/10/26.
//

import Foundation
import SwiftData

struct DatabaseSchema {
    static let schema = Schema([
        MathMaterialEntity.self,
        MathTopicEntity.self
    ])
}
