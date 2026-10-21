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
        case .searching:
            return "Arahkan kamera ke lembar. Pastikan tepi kertas terlihat dan cahaya cukup."
            
        case .moveLeft:
            return "Geser kamera sedikit ke kiri."
            
        case .moveRight:
            return "Geser kamera sedikit ke kanan."
            
        case .moveUp:
            return "Arahkan kamera sedikit ke atas."
            
        case .moveDown:
            return "Arahkan kamera sedikit ke bawah."
            
        case .moveCloser:
            return "Dekatkan kamera sedikit."
            
        case .moveFarther:
            return "Jauhkan kamera sedikit."
            
        case .straighten:
            return "Luruskan kamera."
            
        case .holdStill:
            return "Lembar terdeteksi. Tahan kamera tetap diam."
            
        case .ready:
            return "Lembar siap difoto. Ketuk dua kali di layar untuk mengambil foto."
        }
    }
}

enum CameraPreparationResult {
    case ready
    case permissionDenied
    case cameraUnavailable
    case cancelled
}

enum CameraCaptureError: LocalizedError {
    case permissionDenied
    case cameraUnavailable
    case cameraNotReady
    case documentNotReady
    case photoDataUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Akses kamera ditolak. Izinkan kamera melalui Pengaturan."
            
        case .cameraUnavailable:
            return "Kamera belakang tidak tersedia."
            
        case .cameraNotReady:
            return "Kamera belum siap. Coba lagi sebentar."
            
        case .documentNotReady:
            return "Lembar belum siap difoto. Ikuti petunjuk kamera."
            
        case .photoDataUnavailable:
            return "Foto tidak dapat diproses. Coba ambil ulang."
        }
    }
}
