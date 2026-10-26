import Foundation

/// Navigation references only. Canonical content continues to live in chunks.
struct MaterialReadingTopic: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let titleSource: String
    let headingChunkIDs: [String]
    let chunkIDs: [String]
}

struct MaterialTopicIndex: Codable, Hashable, Sendable {
    let policy: String
    let topics: [MaterialReadingTopic]
    let auxiliaryChunkIDs: [String]
    var attemptID: String? = nil
    var experimentStatus: String? = nil
    var reportPath: String? = nil
    var failureReason: String? = nil

    static let qwenPolicy = "qwen_topic_navigation_v3"
    static let headingKinds: Set<String> = ["heading", "doc_title", "paragraph_title"]
    static let auxiliaryKinds: Set<String> = ["header", "footer", "number"]

    func isValid(for chunks: [MathChunkModel]) -> Bool {
        let ordered = chunks.sorted { $0.order < $1.order }
        let auxiliary = ordered.filter { Self.auxiliaryKinds.contains($0.kind) }.map(\.id)
        let body = ordered.filter { !Self.auxiliaryKinds.contains($0.kind) }.map(\.id)
        return Set(ordered.map(\.id)).count == ordered.count &&
            topics.flatMap(\.chunkIDs) == body && auxiliaryChunkIDs == auxiliary &&
            Set(topics.map(\.id)).count == topics.count && topics.allSatisfy {
                !$0.chunkIDs.isEmpty && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                $0.title.count <= 160 && !$0.title.contains("\n") &&
                $0.headingChunkIDs.allSatisfy($0.chunkIDs.contains)
            }
    }

    static func sourceHeadings(chunks: [MathChunkModel], fallbackTitle: String) -> Self {
        let cleanFallback = fallbackTitle.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = cleanFallback.isEmpty ? "Materi" : String(cleanFallback.prefix(160))
        var topics: [MaterialReadingTopic] = []
        var members: [MathChunkModel] = []
        func finish() {
            guard let first = members.first else { return }
            let heading = headingKinds.contains(first.kind) ? first : nil
            let text = heading?.sourceText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let useHeading = !text.isEmpty && text.count <= 160 && !text.contains("\n")
            topics.append(.init(id: "topic.\(first.id)", title: useHeading ? text : fallback,
                                titleSource: useHeading ? "source_heading" : "application_fallback",
                                headingChunkIDs: heading.map { [$0.id] } ?? [], chunkIDs: members.map(\.id)))
            members = []
        }
        let ordered = chunks.sorted { $0.order < $1.order }
        for chunk in ordered where !auxiliaryKinds.contains(chunk.kind) {
            if members.last?.pageID != chunk.pageID || headingKinds.contains(chunk.kind) { finish() }
            members.append(chunk)
        }
        finish()
        return .init(policy: "source_headings_navigation_v1", topics: topics,
                     auxiliaryChunkIDs: ordered.filter { auxiliaryKinds.contains($0.kind) }.map(\.id))
    }
}

extension MathMaterialModel {
    var readingTopicIndex: MaterialTopicIndex {
        if let data = topicIndexJSON, let value = try? JSONDecoder().decode(MaterialTopicIndex.self, from: data),
           value.isValid(for: chunks) { return value }
        return .sourceHeadings(chunks: chunks, fallbackTitle: title)
    }
}
