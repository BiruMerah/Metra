import Foundation

/// Recognition validity and OCR placement are separate decisions. OCR-only
/// proposals still require corroboration; an image detector owns its crop.
enum FormulaEvidencePolicy {
    static let version = "image_detector_recognition_authority_v1"
    static let detectorSources: Set<String> = ["pp_doclayout_l", "pix2text_mfd_image_proposal_v1"]

    static func imageSource(_ region: LayoutRegion?) -> String? {
        guard let region else { return nil }
        if let source = region.detectionSource, detectorSources.contains(source) { return source }
        // Original DocLayout regions have a native class ID and can predate
        // the optional provenance field. OCR/MFD additions use candidates.
        if region.detectionSource == nil, region.label == "formula", region.classID >= 0 { return "pp_doclayout_l" }
        if let inherited = region.imageDetectionSource, detectorSources.contains(inherited) { return inherited }
        return nil
    }

    struct Structure: Codable, Sendable {
        let allowed: Bool
        let reason: String
    }

    /// Detect incomplete structure without changing symbols, operands or font.
    /// This is not a proof that image recognition is factually correct.
    static func structure(_ mathML: String) -> Structure {
        guard let root = MathMLSourceTree.read(mathML) else {
            return .init(allowed: false, reason: "Invalid or empty MathML")
        }
        var operand = false
        var failure: String?
        func visit(_ node: MathMLSourceTree.Node) {
            if ["annotation", "annotation-xml"].contains(node.name) { return }
            if node.name == "merror" { failure = "MathML contains merror" }
            if ["mi", "mn"].contains(node.name), node.text.contains(where: { $0.isLetter || $0.isNumber }) { operand = true }
            if ["mfrac", "msup", "msub", "msubsup"].contains(node.name) {
                let count = node.name == "msubsup" ? 3 : 2
                if node.children.count != count || node.children.contains(where: { MathMLSourceTree.compact($0.tokens).isEmpty }) {
                    failure = "Fraction, power or subscript has an empty operand"
                }
                if ["msup", "msubsup"].contains(node.name), let base = node.children.first,
                   ["×", "÷", "+", "−", "-", "="].contains(MathMLSourceTree.compact(base.tokens)) {
                    failure = "Power base is a bare arithmetic operator; recognition is ambiguous"
                }
            }
            node.children.forEach(visit)
        }
        visit(root)
        if let failure { return .init(allowed: false, reason: failure) }
        return .init(allowed: operand, reason: operand ? "Nonempty image-recognized structure; source fidelity unassessed" : "No number or identifier; marker-only recognition")
    }
}
