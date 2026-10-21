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
        case .searching: "Arahkan kamera ke lembar. Pastikan tepi kertas terlihat dan cahaya cukup."
        case .moveLeft: "Geser kamera sedikit ke kiri."
        case .moveRight: "Geser kamera sedikit ke kanan."
        case .moveUp: "Arahkan kamera sedikit ke atas."
        case .moveDown: "Arahkan kamera sedikit ke bawah."
        case .moveCloser: "Dekatkan kamera sedikit."
        case .moveFarther: "Jauhkan kamera sedikit."
        case .straighten: "Luruskan kamera."
        case .holdStill: "Lembar terdeteksi. Tahan kamera tetap diam."
        case .ready: "Lembar siap difoto. Ketuk dua kali di layar untuk mengambil foto."
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
            "Akses kamera ditolak. Izinkan kamera melalui Pengaturan."
        case .cameraUnavailable:
            "Kamera belakang tidak tersedia."
        case .cameraNotReady:
            "Kamera belum siap. Coba lagi sebentar."
        case .documentNotReady:
            "Lembar belum siap difoto. Ikuti petunjuk kamera."
        case .photoDataUnavailable:
            "Foto tidak dapat diproses. Coba ambil ulang."
        }
    }
}
