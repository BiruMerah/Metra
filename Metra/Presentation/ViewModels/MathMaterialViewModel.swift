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
        guard let original = material, !original.chunks.isEmpty,
              original.readingTopicIndex.policy != MaterialTopicIndex.qwenPolicy,
              extractionService.diagramModelIsAvailable else { return }
        isOrganizingTopics = true
        defer { isOrganizingTopics = false; groupingTask = nil }
        let task = Task { try await extractionService.organizeTopics(in: original) { _ in } }
        groupingTask = task
        do {
            let updated = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            try materialService.addSavedMaterial(material: updated)
            material = updated
        } catch is CancellationError {
            // Existing headings and content remain readable after cancellation.
        } catch { topicError = "Bacaan tetap tersedia. \(error.localizedDescription)" }
    }

    func cancelGrouping() { groupingTask?.cancel() }

    func openTopic(_ topic: MaterialReadingTopic) {
        coordinator.navigate(to: .mathTopicMaterial(materialID: materialID, topicID: topic.id))
    }
}
