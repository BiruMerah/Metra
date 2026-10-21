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
    
    let cameraService: CameraService
    let mathMaterialService: MathMaterialProtocol
    let aiManager: AIServiceProtocol
    
    init(cameraService: CameraService, mathMaterialService: MathMaterialProtocol, aiManager: AIServiceProtocol) {
        self.cameraService = cameraService
        self.mathMaterialService = mathMaterialService
        self.aiManager = aiManager
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
    
    func finishCamera(with data: MathMaterialModel) {
        if !path.isEmpty {
            path.removeLast()
        }
        
        // TODO: Define the params
        path.append(AppRoutes.mathMaterial)
    }
    
    // MARK: - View Factories
    @ViewBuilder
    func buildHome() -> some View {
        let viewModel = HomeViewModel(coordinator: self, mathMaterialService: mathMaterialService, aiManager: aiManager)
        HomeView(coordinator: self, viewModel: viewModel)
    }
    
    @ViewBuilder
    func buildView(route: AppRoutes) -> some View {
        switch route {
        case .home:
            let viewModel = HomeViewModel(coordinator: self, mathMaterialService: mathMaterialService, aiManager: aiManager)
            HomeView(coordinator: self, viewModel: viewModel)
            
        case .camera:
            let viewModel = CameraViewModel(cameraService: cameraService)
            CameraView(
                viewModel: viewModel,
                session: cameraService.previewSession
            )
            
        case .importPhoto:
            ImportPhotoView()
            
        case .savedMaterialList:
            let viewModel = SavedMaterialViewModel(coordinator: self, mathMaterialService: mathMaterialService)
            SavedMaterialView(viewModel: viewModel)
            
        case .mathMaterial:
            EmptyView()
            
        case .mathTopicMaterial:
            EmptyView()
        }
    }
}
