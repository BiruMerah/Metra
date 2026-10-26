import Foundation
import Observation

@Observable
@MainActor
final class MathTopicReaderViewModel {
    // MARK: - Presentation State
    var material: MathMaterialModel?
    var selectedIndex = 0
    var errorMessage: String?
    var topics: [MaterialReadingTopic] { material?.readingTopicIndex.topics ?? [] }
    var topic: MaterialReadingTopic? { topics.indices.contains(selectedIndex) ? topics[selectedIndex] : nil }
    var hasPrevious: Bool { selectedIndex > 0 }
    var hasNext: Bool { selectedIndex + 1 < topics.count }
    var chunks: [MathChunkModel] {
        guard let material, let topic else { return [] }
        let lookup = Dictionary(uniqueKeysWithValues: material.chunks.map { ($0.id, $0) })
        return topic.chunkIDs.compactMap { lookup[$0] }
    }

    // MARK: - Dependencies
    private let materialID: UUID
    private let initialTopicID: String
    private let materialService: MathMaterialProtocol
    private let extractionService: MaterialExtractionProtocol
    private var didLoad = false

    init(materialID: UUID, topicID: String, materialService: MathMaterialProtocol,
         extractionService: MaterialExtractionProtocol) {
        self.materialID = materialID
        initialTopicID = topicID
        self.materialService = materialService
        self.extractionService = extractionService
    }

    // MARK: - Public Actions
    func load() {
        guard !didLoad else { return }
        didLoad = true
        do {
            material = try materialService.fetchSavedMaterial(id: materialID)
            guard material != nil, let index = topics.firstIndex(where: { $0.id == initialTopicID }) else {
                errorMessage = "Topik tidak ditemukan. Buka kembali dari daftar topik."
                return
            }
            selectedIndex = index
        } catch { errorMessage = error.localizedDescription }
    }

    func previous() { if hasPrevious { selectedIndex -= 1 } }
    func next() { if hasNext { selectedIndex += 1 } }

    func imageURL(for chunk: MathChunkModel) -> URL? {
        guard let path = chunk.imagePath else { return nil }
        return try? extractionService.artifactURL(for: path)
    }
}
