import Foundation
import Observation

@Observable
@MainActor
final class MathMaterialViewModel {
    // MARK: - Presentation State
    var material: MathMaterialModel?
    var errorMessage: String?
    var topicError: String?
    var isOrganizingTopics = false
    var topics: [MaterialReadingTopic] { material?.readingTopicIndex.topics ?? [] }

    // MARK: - Dependencies
    private let materialID: UUID
    private let materialService: MathMaterialProtocol
    private let extractionService: MaterialExtractionProtocol
    private unowned let coordinator: AppCoordinator
    @ObservationIgnored private var groupingTask: Task<MathMaterialModel, Error>?
    private var didLoad = false

    init(materialID: UUID, materialService: MathMaterialProtocol, extractionService: MaterialExtractionProtocol,
         coordinator: AppCoordinator) {
        self.materialID = materialID
        self.materialService = materialService
        self.extractionService = extractionService
        self.coordinator = coordinator
    }

    func loadAndOrganize() async {
        guard !didLoad else { return }
        didLoad = true
        do {
            material = try materialService.fetchSavedMaterial(id: materialID)
            if material == nil { errorMessage = "Materi tidak ditemukan." }
        } catch { errorMessage = error.localizedDescription }
        // Loading stored material does not run an LM or rewrite saved topics.
    }

    func cancelGrouping() { groupingTask?.cancel() }

    func openTopic(_ topic: MaterialReadingTopic) {
        coordinator.navigate(to: .mathTopicMaterial(materialID: materialID, topicID: topic.id))
    }
}
