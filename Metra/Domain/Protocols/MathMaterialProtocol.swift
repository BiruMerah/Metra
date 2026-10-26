//
//  MathMaterialProtocol.swift
//  Metra
//
//  Created by Fidel Fausta Cavell on 18/10/26.
//

import Foundation

@MainActor
protocol MathMaterialProtocol {
    func fetchSavedMaterials() throws -> [MathMaterialModel]
    func fetchSavedMaterial(id: UUID) throws -> MathMaterialModel?
    
    func addSavedMaterial(material: MathMaterialModel) throws
    
    func deleteSavedMaterial(id: UUID) throws
}
