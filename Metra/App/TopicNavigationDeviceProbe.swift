#if DEBUG
import Foundation

/// Opt-in evidence for --metra-topic-experiment. Reads existing persisted data;
/// does not synthesize content, run models on Mac, or claim VoiceOver UI testing.
@MainActor
enum TopicNavigationDeviceProbe {
    private struct Snapshot: Encodable {
        let materialID: UUID
        let capturedAt: Date
        let index: MaterialTopicIndex
        let chunks: [MathChunkModel]
        let readerText: [String: String]
        let forwardTopicIDs: [String]
        let backwardTopicIDs: [String]
        let coverageValid: Bool
        let forwardNavigationValid: Bool
        let backwardNavigationValid: Bool
        let endpointButtonsValid: Bool
        let voiceOverInteractionTested = false
    }

    static func capture(materialID: UUID, coordinator: AppCoordinator) {
        do {
            guard let material = try coordinator.mathMaterialService.fetchSavedMaterial(id: materialID) else { return }
            let index = material.readingTopicIndex
            var forward: [String] = [], backward: [String] = []
            var endpoints = true
            if let first = index.topics.first {
                let reader = MathTopicReaderViewModel(materialID: materialID, topicID: first.id,
                    materialService: coordinator.mathMaterialService, extractionService: coordinator.extractionService)
                reader.load()
                endpoints = !reader.hasPrevious
                for _ in index.topics.indices {
                    if let topic = reader.topic { forward.append(topic.id) }
                    if reader.hasNext { reader.next() }
                }
                endpoints = endpoints && !reader.hasNext
                for _ in index.topics.indices {
                    if let topic = reader.topic { backward.append(topic.id) }
                    if reader.hasPrevious { reader.previous() }
                }
                endpoints = endpoints && !reader.hasPrevious
            }
            let snapshot = Snapshot(materialID: materialID, capturedAt: Date(), index: index, chunks: material.chunks,
                readerText: Dictionary(uniqueKeysWithValues: material.chunks.map { ($0.id, ReadingPresentation.text(for: $0)) }),
                forwardTopicIDs: forward, backwardTopicIDs: backward, coverageValid: index.isValid(for: material.chunks),
                forwardNavigationValid: forward == index.topics.map(\.id),
                backwardNavigationValid: backward == Array(index.topics.reversed().map(\.id)), endpointButtonsValid: endpoints)
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let directory = documents.appendingPathComponent("topic-navigation/probes", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: directory.appendingPathComponent("\(UUID().uuidString.lowercased()).json"), options: .atomic)
        } catch { NSLog("Topic navigation evidence unavailable: %@", error.localizedDescription) }
    }
}
#endif
