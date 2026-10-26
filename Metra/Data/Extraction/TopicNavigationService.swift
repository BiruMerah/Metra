import Foundation
import UIKit

/// A separate experiment over immutable chunks. Never invokes the historical
/// v1 grouping exporter, which embedded chunk payloads inside topics.
@MainActor
enum TopicNavigationService {
    private struct Plan: Codable {
        struct Topic: Codable { let title: String; let chunkIDs: [String] }
        let topics: [Topic]
    }

    static func run(material: MathMaterialModel, modelDirectory: URL?, dependencyError: String?,
                    runtime: QwenDiagramRuntime, onProgress: (String) -> Void) async throws -> MaterialTopicIndex {
        let attempt = UUID().uuidString.lowercased()
        let relative = "topic-navigation/\(material.id.uuidString.lowercased())/\(attempt)"
        let root = try ImageIngestor.documentsURL().appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = RunRepository()
        let ordered = material.chunks.sorted { $0.order < $1.order }
        let baseline = material.readingTopicIndex
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let source = try encoder.encode(ordered)
        try source.write(to: root.appendingPathComponent("chunks.snapshot.json"), options: .atomic)
        try repository.writeJSON(baseline, to: root.appendingPathComponent("source-topic-index.json"))
        if let modelDirectory {
            for name in ["metra-bundle-manifest.json", "metra-import-manifest.json"] {
                if let data = try? Data(contentsOf: modelDirectory.appendingPathComponent(name)) {
                    try data.write(to: root.appendingPathComponent(name), options: .atomic)
                }
            }
        }
        let sampler = MemorySampler(outputURL: root.appendingPathComponent("memory.jsonl"), runID: material.id.uuidString)
        sampler.start(); sampler.sampleNow()
        defer { sampler.stop() }
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let started = ProcessInfo.processInfo.systemUptime
        let initialThermal = MemorySampler.thermalString(ProcessInfo.processInfo.thermalState)
        var requests: [[String: Any]] = []
        var generations: [QwenTextResult] = []
        var topics: [MaterialReadingTopic] = []
        var acceptedWindows = 0
        let instructions = Bundle.main.url(forResource: "topic-navigation-v3", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let body = ordered.filter { !MaterialTopicIndex.auxiliaryKinds.contains($0.kind) }
        var windows: [[MathChunkModel]] = [], window: [MathChunkModel] = []
        var characters = 0
        for chunk in body {
            let sourceHeadingBoundary = isTopicalHeading(chunk) && window.contains {
                !MaterialTopicIndex.headingKinds.contains($0.kind)
            }
            if !window.isEmpty && (sourceHeadingBoundary || window.count >= 32 || characters + chunk.sourceText.count > 10000 || window.last?.pageID != chunk.pageID) {
                windows.append(window); window = []; characters = 0
            }
            window.append(chunk); characters += chunk.sourceText.count
        }
        if !window.isEmpty { windows.append(window) }

        for (offset, chunks) in windows.enumerated() {
            let requestID = String(format: "request-%04d", offset + 1)
            let directory = root.appendingPathComponent(requestID, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var failure: String?
            var proposed: [MaterialReadingTopic]?
            if Task.isCancelled { failure = "cancelled" }
            else if offset >= 8 { failure = "request_budget_exceeded" }
            else if modelDirectory == nil { failure = dependencyError ?? "qwen_model_unavailable" }
            else if instructions == nil { failure = "topic_navigation_prompt_unavailable" }
            else if let modelDirectory, let instructions {
                let aliases = chunks.indices.map { String(format: "c%03d", $0 + 1) }
                let payload = zip(aliases, chunks).map { id, chunk in
                    ["id": id, "kind": chunk.kind, "sourceText": chunk.sourceText]
                }
                let data = try JSONSerialization.data(withJSONObject: ["chunks": payload], options: [.sortedKeys])
                let prompt = instructions + "\n\nDATA SUMBER JSON:\n" + String(decoding: data, as: UTF8.self)
                try prompt.write(to: directory.appendingPathComponent("prompt.txt"), atomically: true, encoding: .utf8)
                try repository.writeJSON(Dictionary(uniqueKeysWithValues: zip(aliases, chunks.map(\.id))),
                                         to: directory.appendingPathComponent("chunk-id-map.json"))
                onProgress("Menyusun topik…")
                do {
                    let result = try await runtime.groupTopics(prompt: prompt, modelDirectory: modelDirectory, outputDirectory: directory)
                    generations.append(result)
                    try repository.writeJSON(result, to: directory.appendingPathComponent("generation.json"))
                    guard result.stopReason == "stop" else { throw TopicGroupingError.invalidPlan("generation stop: \(result.stopReason)") }
                    let plan = try validate(result.rawText, expectedIDs: aliases)
                    try Task.checkCancellation()
                    try repository.writeJSON(plan, to: directory.appendingPathComponent("plan.validated.json"))
                    let lookup = Dictionary(uniqueKeysWithValues: zip(aliases, chunks))
                    proposed = plan.topics.map { item in
                        let members = item.chunkIDs.compactMap { lookup[$0] }
                        return .init(id: "topic.\(members[0].id)", title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                     titleSource: "qwen_generated", headingChunkIDs: members.filter { MaterialTopicIndex.headingKinds.contains($0.kind) }.map(\.id),
                                     chunkIDs: members.map(\.id))
                    }
                    acceptedWindows += 1
                } catch { failure = Task.isCancelled ? "cancelled" : error.localizedDescription }
            }
            let fallback = MaterialTopicIndex.sourceHeadings(chunks: chunks, fallbackTitle: material.title)
            topics += proposed ?? fallback.topics
            let status: [String: Any] = ["id": requestID, "status": proposed == nil ? "source_heading_fallback" : "validated",
                                        "failure": failure as Any? ?? NSNull(), "chunk_count": chunks.count,
                                        "membership_validation": "exact_complete_ordered_ids", "semantic_quality": "not_assessed"]
            requests.append(status)
            try repository.writeJSON(status, to: directory.appendingPathComponent("status.json"))
            sampler.sampleNow()
        }
        let status = Task.isCancelled ? "cancelled" : (body.isEmpty ? "not_required" :
            (acceptedWindows == windows.count ? "complete" : (acceptedWindows > 0 ? "partial" : (modelDirectory == nil ? "skipped_dependency" : "failed"))))
        let index = MaterialTopicIndex(policy: MaterialTopicIndex.qwenPolicy, topics: topics,
                                       auxiliaryChunkIDs: baseline.auxiliaryChunkIDs, attemptID: attempt,
                                       experimentStatus: status, reportPath: "\(relative)/report.json")
        guard index.isValid(for: ordered) else { throw TopicGroupingError.invalidPlan("canonical chunk membership changed") }
        try repository.writeJSON(index, to: root.appendingPathComponent("topic-index.json"))
        sampler.sampleNow()
        let peak = (try? String(contentsOf: root.appendingPathComponent("memory.jsonl"), encoding: .utf8))?
            .split(separator: "\n").compactMap { line -> UInt64? in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["appPhysFootprintBytes"] as? UInt64
            }.max()
        func total(_ values: [Double]) -> Any { values.isEmpty ? NSNull() : values.reduce(0, +) as Any }
        try repository.writeJSON([
            "schema": "metra-topic-navigation-report-v1", "policy": MaterialTopicIndex.qwenPolicy,
            "material_id": material.id.uuidString, "attempt_id": attempt, "status": status,
            "started_at": startedAt, "completed_at": ISO8601DateFormatter().string(from: Date()),
            "device": ["hardware": DeviceIdentity.hardwareModelIdentifier() as Any? ?? NSNull(), "ios": UIDevice.current.systemVersion],
            "build": BuildIdentity.metadata, "input_mode": "existing_canonical_chunks_text_only", "vision_input": false,
            "source_chunks_sha256": ImageIngestor.sha256(source), "canonical_content_changed": false,
            "input_chunks": ordered.count, "body_chunks": body.count, "topic_count": topics.count,
            "model_id": "mlx-community/Qwen3-VL-2B-Instruct-4bit", "revision": "9c4f5209e57b31f4b9dfba735de3fb983739c9cc",
            "runtime": "MLXVLM Swift 3.32.3", "config": ["max_tokens": 2048, "max_prompt_tokens": 6000, "temperature": 0,
                "top_p": 1, "seed": 0, "deadline_seconds_after_load": 120, "max_chunks_per_request": 32,
                "max_characters_per_window": 10000, "max_requests": 8, "retries": 0],
            "source_boundary_policy": "topical_source_heading_fence_v1; generic example/solution headings remain attached; Qwen groups only within fences",
            "spans_ms": ["model_load": total(generations.map(\.loadMilliseconds)), "prepare": total(generations.map(\.preprocessMilliseconds)),
                         "generation": total(generations.map(\.inferenceMilliseconds)), "stage_wall": (ProcessInfo.processInfo.systemUptime - started) * 1000],
            "memory": ["sampled_peak_bytes": peak as Any? ?? NSNull(), "interval_ms": 200, "scope": "app_process_only; WebContent excluded"],
            "thermal": ["initial": initialThermal, "final": MemorySampler.thermalString(ProcessInfo.processInfo.thermalState)],
            "quality_status": "not_assessed", "requests": requests,
            "limitations": ["Reference validation does not prove semantic topic accuracy.", "Windows stop at page boundaries and budget limits; cross-window topics are not merged.",
                            "Failed windows use source headings. Content, unresolved formula status and raw previews are unchanged."]
        ], to: root.appendingPathComponent("report.json"))
        try Task.checkCancellation()
        return index
    }

    private static func isTopicalHeading(_ chunk: MathChunkModel) -> Bool {
        guard MaterialTopicIndex.headingKinds.contains(chunk.kind) else { return false }
        let title = chunk.sourceText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^\d+(?:\.\d+)*\.?\s+"#, with: "", options: .regularExpression)
        guard !title.isEmpty else { return false }
        // Structural labels inside an example should stay with that example.
        let generic = #"^(contoh|alternatif penyelesaian|penyelesaian|jawaban|jawab|solusi|latihan)(\s+[\d.]+)?[.:]?$"#
        return title.range(of: generic, options: .regularExpression) == nil
    }

    private static func validate(_ raw: String, expectedIDs: [String]) throws -> Plan {
        let data = Data(raw.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == ["topics"],
              let items = object["topics"] as? [[String: Any]], !items.isEmpty, items.count <= expectedIDs.count,
              items.allSatisfy({ Set($0.keys) == ["title", "chunkIDs"] }) else { throw TopicGroupingError.invalidPlan("invalid JSON schema") }
        let plan = try JSONDecoder().decode(Plan.self, from: data)
        guard plan.topics.flatMap(\.chunkIDs) == expectedIDs,
              plan.topics.allSatisfy({ !$0.chunkIDs.isEmpty && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  $0.title.count <= 120 && !$0.title.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }) }) else {
            throw TopicGroupingError.invalidPlan("title or exact ordered membership invalid")
        }
        return plan
    }
}
