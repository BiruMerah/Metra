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
    
    init(cameraService: CameraService, mathMaterialService: MathMaterialProtocol) {
        self.cameraService = cameraService
        self.mathMaterialService = mathMaterialService
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
        HomeView(coordinator: self)
    }
    
    @ViewBuilder
    func buildView(route: AppRoutes) -> some View {
        switch route {
        case .home:
            HomeView(coordinator: self)
            
        case .camera:
            let viewModel = CameraViewModel(cameraService: cameraService)
            CameraView(
                viewModel: viewModel,
                session: cameraService.previewSession,
                onClose: { self.navigateBack() }
            )
            
        case .importDocument:
            ImportDocumentView()
            
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
