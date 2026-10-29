import Foundation

/// A separate image-model description, never a replacement for accepted
/// MathCAT speech or evidence that a withheld expression passed validation.
struct FormulaFallbackDescription: Codable, Sendable {
    let policy: String
    let provider: String
    let status: String
    let description: String
    let visibleNotation: String
    let uncertainties: [String]
    let artifacts: [String:String]

    var readerText: String? {
        guard ["described","partial"].contains(status) else { return nil }
        let text = description.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let note = uncertainties.filter { !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }.joined(separator:"; ")
        return "Deskripsi alternatif rumus, belum dipastikan: " + text + (note.isEmpty ? "" : " Bagian yang belum jelas: " + note)
    }
}
