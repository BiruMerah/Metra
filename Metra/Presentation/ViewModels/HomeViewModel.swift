//
//  HomeViewModel.swift
//  Metra
//
//  Created by Fidel Fausta Cavell on 21/10/26.
//

import Foundation
import Observation

@Observable
@MainActor
final class HomeViewModel {
    // MARK: - Dependencies
    private unowned let coordinator: AppCoordinator
    private let mathMaterialService: MathMaterialProtocol
    
    init(coordinator: AppCoordinator, mathMaterialService: MathMaterialProtocol) {
        self.coordinator = coordinator
        self.mathMaterialService = mathMaterialService
    }
}
