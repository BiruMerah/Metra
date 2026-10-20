//
//  CameraEnum.swift
//  Metra
//
//  Created by Andito Rizkyka Rianto on 20/10/26.
//

import Foundation

enum CameraGuidanceState: Equatable {
    case searching
    case moveLeft
    case moveRight
    case moveUp
    case moveDown
    case moveCloser
    case moveFarther
    case straighten
    case holdStill
    case ready

    var message: String {
        switch self {
        case .searching: "Arahkan kamera ke halaman."
        case .moveLeft: "Geser kamera sedikit ke kiri."
        case .moveRight: "Geser kamera sedikit ke kanan."
        case .moveUp: "Arahkan kamera sedikit ke atas."
        case .moveDown: "Arahkan kamera sedikit ke bawah."
        case .moveCloser: "Dekatkan kamera sedikit."
        case .moveFarther: "Jauhkan kamera sedikit."
        case .straighten: "Luruskan kamera."
        case .holdStill: "Posisi sudah baik. Tahan kamera."
        case .ready: "Halaman siap untuk difoto."
        }
    }
}

enum CameraPreparationResult {
    case ready
    case permissionDenied
    case cameraUnavailable
    case cancelled
}
