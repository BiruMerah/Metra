import Foundation

enum OCRFormulaCandidatePolicy {
    static let version = "explicit_ocr_formula_candidates_v2"

    static func isStandaloneListMarker(_ text: String) -> Bool {
        ["•", "●", "▪", "·"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Ordinary letters and coefficient/letter fragments remain OCR text.
    /// Complete Unicode notation and measured powers have separate routes.
    static func expressionHasOperator(_ text: String) -> Bool {
        text.count > 1 && text.count <= 160 && text.contains(where: \.isLetter) &&
            text.range(of: #"[=+−\-×÷≤≥<>]"#, options: .regularExpression) != nil
    }
}
