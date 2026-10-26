import Foundation

/// One canonical reading chunk; source text and review speech are kept separate.
struct MathChunkModel: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let order: Int
    let pageID: String
    let kind: String
    let status: String
    let sourceText: String
    let spokenText: String?
    let spokenPreview: String?
    let sourceReference: String
    let imagePath: String?
    let unresolvedFormulaIDs: [String]
    let uncertainties: [String]

    var needsReview: Bool { !["ready", "generated"].contains(status) }
    var readingText: String { spokenText ?? spokenPreview ?? sourceText }
}
