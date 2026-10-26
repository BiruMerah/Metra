//
//  AppRoutes.swift
//  Metra
//
//  Created by Fidel Fausta Cavell on 18/10/26.
//

import Foundation

enum AppRoutes: Hashable {
    case home
    case camera
    case savedMaterialList
    case mathMaterial(UUID)
    case mathTopicMaterial(materialID: UUID, topicID: String)
}
