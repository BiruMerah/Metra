import Foundation
import FoundationModels

/// The OS owns the diagram model; no app checkpoint import or download.
@MainActor
final class ModelAssetManager {
    var isAvailable: Bool {
        let model = SystemLanguageModel.default
        return model.isAvailable && model.capabilities.contains(.vision)
    }
    var status: String {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.capabilities.contains(.vision)
                ? "Deskripsi gambar memakai model Apple di iPhone. Tidak memerlukan impor model tambahan."
                : "Model Apple pada perangkat ini belum mendukung gambar. Teks dan rumus tetap dapat diproses."
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return "Aktifkan Apple Intelligence di Pengaturan iPhone untuk deskripsi gambar."
            case .deviceNotEligible: return "Perangkat ini belum mendukung model Apple untuk deskripsi gambar."
            case .modelNotReady: return "Model Apple belum siap. Tunggu persiapan model oleh iOS; teks dan rumus tetap dapat diproses."
            @unknown default: return "Model Apple belum tersedia. Teks dan rumus tetap dapat diproses."
            }
        }
    }
}
