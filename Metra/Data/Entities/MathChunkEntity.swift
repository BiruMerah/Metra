import Foundation
import SwiftData

@Model
final class MathChunkEntity {
    @Attribute(.unique) var storageID: String
    var sourceID: String
    var order: Int
    var pageID: String
    var kind: String
    var status: String
    var sourceText: String
    var spokenText: String?
    var spokenPreview: String?
    var sourceReference: String
    var imagePath: String?
    var unresolvedFormulaIDs: [String]
    var uncertainties: [String]
    var material: MathMaterialEntity?

    init(materialID: UUID, chunk: MathChunkModel) {
        // Engine IDs are page-relative and repeat in different extraction runs.
        storageID = materialID.uuidString.lowercased() + ":" + chunk.id
        sourceID = chunk.id
        order = chunk.order
        pageID = chunk.pageID
        kind = chunk.kind
        status = chunk.status
        sourceText = chunk.sourceText
        spokenText = chunk.spokenText
        spokenPreview = chunk.spokenPreview
        sourceReference = chunk.sourceReference
        imagePath = chunk.imagePath
        unresolvedFormulaIDs = chunk.unresolvedFormulaIDs
        uncertainties = chunk.uncertainties
    }

    func toDomain() -> MathChunkModel {
        MathChunkModel(id: sourceID, order: order, pageID: pageID, kind: kind, status: status,
                       sourceText: sourceText, spokenText: spokenText, spokenPreview: spokenPreview,
                       sourceReference: sourceReference, imagePath: imagePath,
                       unresolvedFormulaIDs: unresolvedFormulaIDs, uncertainties: uncertainties)
    }
}
