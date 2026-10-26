//
//  AppCoordinator.swift
//  Metra
//
//  Created by Fidel Fausta Cavell on 18/10/26.
//

import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class AppCoordinator {
    var path = NavigationPath()
    
    let cameraService: CameraProtocol
    let mathMaterialService: MathMaterialProtocol
    let extractionService: MaterialExtractionProtocol
    
    init(cameraService: CameraProtocol, mathMaterialService: MathMaterialProtocol,
         extractionService: MaterialExtractionProtocol) {
        self.cameraService = cameraService
        self.mathMaterialService = mathMaterialService
        self.extractionService = extractionService
    }
    
    func navigate(to route: AppRoutes) {
        path.append(route)
    }
    
    func navigateBack() {
        if !path.isEmpty {
            path.removeLast()
        }
    }
    
    func popToRoot() {
        path.removeLast(path.count)
    }
    
    func finishExtraction(materialID: UUID) {
        if !path.isEmpty {
            path.removeLast()
        }
        
        path.append(AppRoutes.mathMaterial(materialID))
    }
    
    // MARK: - View Factories
    @ViewBuilder
    func buildHome() -> some View {
        HomeView(coordinator: self)
    }
    
    @ViewBuilder
    func buildView(route: AppRoutes) -> some View {
        switch route {
        case .camera:
            let viewModel = MaterialImportViewModel(coordinator: self, extractionService: extractionService,
                                                    materialService: mathMaterialService)
            MaterialImportView(viewModel: viewModel)
            
        case .home:
            buildHome()
            
        case .savedMaterialList:
            let viewModel = SavedMaterialViewModel(coordinator: self, mathMaterialService: mathMaterialService)
            SavedMaterialView(viewModel: viewModel)
            
        case .mathMaterial(let id):
            let viewModel = MathMaterialViewModel(materialID: id, materialService: mathMaterialService,
                                                  extractionService: extractionService, coordinator: self)
            MathMaterialView(viewModel: viewModel)
            
        case .mathTopicMaterial(let materialID, let topicID):
            let viewModel = MathTopicReaderViewModel(materialID: materialID, topicID: topicID,
                materialService: mathMaterialService, extractionService: extractionService)
            MathTopicReaderView(viewModel: viewModel)
        }
    }
}
