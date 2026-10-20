//
//  CameraProtocol.swift
//  Metra
//
//  Created by Fidel Fausta Cavell on 18/10/26.
//

@MainActor
protocol CameraProtocol {
    func prepareCamera() async -> CameraPreparationResult
    func stopCamera()
    func setGuidanceHandler(_ handler: @escaping @MainActor (CameraGuidanceState) -> Void)
}
