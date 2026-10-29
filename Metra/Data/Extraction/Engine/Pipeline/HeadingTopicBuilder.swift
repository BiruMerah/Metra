import Foundation

/// The canonical content remains in chunks[]. Topics only reference that content.
struct ReadyTopicIndex: Codable, Sendable {
    let policy: String
    let membershipStatus: String
    let qualityStatus: ReviewStatus
    let topics: [ReadyTopicReference]
    let auxiliaryChunkIDs: [String]
    let limitations: [String]
}

struct ReadyTopicReference: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let titleSource: String
    let headingChunkIDs: [String]
    let chunkIDs: [String]
    let pageID: String
    let status: String
    let uncertainties: [String]
}

enum HeadingTopicBuilder {
    static let version = "source_heading_paths_per_page_v2"
    static let headingKinds: Set<String> = ["doc_title", "paragraph_title", "heading"]

    private struct Draft {
        let first: ChunkCandidate
        var headings: [ChunkCandidate]
        var members: [ChunkCandidate]
    }

    static func build(_ candidates: [ChunkCandidate]) throws -> ReadyTopicIndex {
        var topics: [ReadyTopicReference] = [], auxiliary: [String] = []
        var draft: Draft?
        func finish() {
            guard let current = draft else { return }
            let rawTitle = SourceHeadingPath.title(current.headings.map(\.chunk.sourceText))
            let sourceTitle = rawTitle != nil
            var warnings: [String] = []
            if current.headings.isEmpty { warnings.append("no_source_heading; generic title is an application label, not an inferred topic") }
            else if !sourceTitle { warnings.append("source_heading_empty_or_long; complete heading retained in its chunk") }
            if current.headings.contains(where:{ !["ready", "generated"].contains($0.chunk.status) }) {
                warnings.append("source_heading_needs_review")
            }
            let incomplete = current.members.contains { !["ready", "generated"].contains($0.chunk.status) }
            topics.append(.init(id:"topic.\(current.first.chunk.id)",
                title:rawTitle ?? "Materi tanpa judul",titleSource:sourceTitle ? (current.headings.count > 1 ? "source_heading_path" : "source_heading") : "application_fallback",
                headingChunkIDs:current.headings.map(\.chunk.id),chunkIDs:current.members.map { $0.chunk.id },
                pageID:current.first.chunk.pageID,status:incomplete || !warnings.isEmpty ? "needs_review" : "draft",
                uncertainties:warnings))
            draft = nil
        }
        for candidate in candidates {
            if draft?.first.chunk.pageID != candidate.chunk.pageID { finish() }
            if candidate.isAuxiliary { auxiliary.append(candidate.chunk.id); continue }
            if headingKinds.contains(candidate.chunk.kind) {
                if let current = draft,current.members.allSatisfy({ headingKinds.contains($0.chunk.kind) }),
                   SourceHeadingPath.title((current.headings+[candidate]).map(\.chunk.sourceText)) != nil {
                    draft?.headings.append(candidate);draft?.members.append(candidate);continue
                }
                finish()
                draft = Draft(first:candidate,headings:[candidate],members:[candidate])
            } else if draft == nil {
                draft = Draft(first:candidate,headings:[],members:[candidate])
            } else { draft?.members.append(candidate) }
        }
        finish()
        let expectedBody = candidates.filter { !$0.isAuxiliary }.map { $0.chunk.id }
        let flattened = topics.flatMap(\.chunkIDs)
        let all = flattened + auxiliary
        guard flattened == expectedBody, Set(all).count == all.count,
              Set(all) == Set(candidates.map { $0.chunk.id }), all.count == candidates.count,
              Set(topics.map(\.id)).count == topics.count,
              topics.allSatisfy({ topic in
                  topic.headingChunkIDs.allSatisfy(topic.chunkIDs.contains) &&
                  topic.chunkIDs.allSatisfy { id in candidates.contains { $0.chunk.id == id && $0.chunk.pageID == topic.pageID } }
              }) else { throw HeadingTopicError.invalidMembership }
        return .init(policy:version,membershipStatus:expectedBody.isEmpty ? "not_required" : "complete",
            qualityStatus:.notAssessed,topics:topics,auxiliaryChunkIDs:auxiliary,
            limitations:["Boundaries follow source headings and reading order. Consecutive headings form one source title path; no semantic LLM grouping.",
                "Page boundaries start a new group; cross-page continuation and heading hierarchy are not inferred.",
                "Generic titles are explicit application fallbacks. Source heading/OCR correctness remains unassessed."])
    }
}

enum HeadingTopicError: LocalizedError {
    case invalidMembership
    var errorDescription: String? { "Indeks topik gagal: referensi chunk hilang, berulang, atau berubah urutan. Ekstraksi sumber tetap tersedia." }
}
