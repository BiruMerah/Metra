import Foundation
import UIKit

private struct TopicPlan: Codable {
    struct Topic: Codable { let title: String; let chunkIDs: [String] }
    let topics: [Topic]
}

enum TopicGroupingError: LocalizedError {
    case missingPrompt, inputBudgetExceeded, invalidPlan(String)
    var errorDescription: String? {
        switch self {
        case .missingPrompt: "Prompt topic-v1 tidak ada di bundle."
        case .inputBudgetExceeded: "Input pengelompokan melampaui budget 6000 token; chunk tetap disimpan."
        case .invalidPlan(let reason): "Plan topik ditolak: \(reason)"
        }
    }
}

@MainActor
enum TopicGroupingService {
    /// No transcription/generation of content: Qwen returns titles and membership only.
    static func run(document: FinalExtractionDocument, modelDirectory: URL?, runtime: QwenDiagramRuntime,
                    paths: RunPaths, onProgress: (String) -> Void) async throws -> ReadyExtractionDocument {
        let repository = RunRepository()
        let attemptID = UUID().uuidString.lowercased()
        let prefix = "topics/attempts/\(attemptID)"
        let directory = paths.root.appendingPathComponent(prefix, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("chunks"), withIntermediateDirectories: true)
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let started = ProcessInfo.processInfo.systemUptime
        let initialThermal = MemorySampler.thermalString(ProcessInfo.processInfo.thermalState)
        let sampler = MemorySampler(outputURL: directory.appendingPathComponent("memory.jsonl"), runID: paths.runID)
        sampler.start(); sampler.sampleNow()
        defer { sampler.stop() }
        let buildStart = ProcessInfo.processInfo.systemUptime
        let candidates = try ReadingChunkBuilder.build(document, artifactPrefix: prefix)
        let chunkingMS = (ProcessInfo.processInfo.systemUptime - buildStart) * 1000
        for candidate in candidates { try repository.writeJSON(candidate, to: paths.root.appendingPathComponent(candidate.chunk.sourceRef)) }
        try repository.writeJSON(document, to: directory.appendingPathComponent("input.final-extraction.json"))
        if let modelDirectory {
            let manifest = modelDirectory.appendingPathComponent("metra-import-manifest.json")
            if let data = try? Data(contentsOf: manifest) { try data.write(to: directory.appendingPathComponent("model-import.snapshot.json"), options: .atomic) }
        }
        let body = candidates.filter { !$0.isAuxiliary }
        let auxiliary = candidates.filter(\.isAuxiliary).map(\.chunk)
        var topics: [ReadyTopic] = [], assigned = Set<String>()
        var failures: [[String: String]] = []
        var requests: [[String: Any]] = []
        var generationResults: [QwenTextResult] = []
        var exportMS = 0.0

        func snapshot(_ groupingStatus: String) throws -> ReadyExtractionDocument {
            let remaining = body.filter { !assigned.contains($0.chunk.id) }.map(\.chunk)
            let review = document.contentQualityStatus == .needsReview || candidates.contains { $0.chunk.status != "ready" } || groupingStatus != "complete"
            let value = ReadyExtractionDocument(schema: "metra-final-ready-v1", id: document.id, groupingAttemptID: attemptID,
                                                status: review ? "needs_review" : "draft", groupingStatus: groupingStatus,
                                                topicQualityStatus: .notAssessed, sourceCoverageStatus: document.sourceCoverageStatus,
                                                contentQualityStatus: review ? .needsReview : document.contentQualityStatus,
                                                createdAt: startedAt, sourceArtifact: "\(prefix)/input.final-extraction.json",
                                                topics: topics, ungroupedChunks: remaining, auxiliaryChunks: auxiliary,
                                                reportArtifact: "\(prefix)/report.json")
            let allIDs = topics.flatMap(\.chunks).map(\.id) + remaining.map(\.id) + auxiliary.map(\.id)
            guard allIDs.count == candidates.count, Set(allIDs) == Set(candidates.map { $0.chunk.id }) else { throw FinalExportError.sourceCoverageChanged }
            let start = ProcessInfo.processInfo.systemUptime
            try repository.writeJSON(value, to: directory.appendingPathComponent("final_ready.json"))
            try repository.writeJSON(value, to: paths.readyExtraction)
            exportMS += (ProcessInfo.processInfo.systemUptime - start) * 1000
            return value
        }

        func writeReport(_ status: String) throws {
            func total(_ values: [Double]) -> Any { values.isEmpty ? NSNull() : values.reduce(0,+) as Any }
            let footprint = (try? String(contentsOf: directory.appendingPathComponent("memory.jsonl"), encoding: .utf8))?.split(separator: "\n").compactMap { line -> UInt64? in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["appPhysFootprintBytes"] as? UInt64
            }.max()
            let report: [String: Any] = [
                "schema": "metra-topic-stage-report-v1", "run_id": paths.runID, "attempt_id": attemptID,
                "status": status, "started_at": startedAt, "updated_at": ISO8601DateFormatter().string(from: Date()),
                "device": ["hardware": DeviceIdentity.hardwareModelIdentifier() as Any? ?? NSNull(), "ios": UIDevice.current.systemVersion],
                "build": BuildIdentity.metadata, "input_mode": "existing_final_extraction_text_only",
                "chunk_policy": ReadingChunkBuilder.version, "input_chunks": candidates.count, "topic_chunks": body.count,
                "auxiliary_chunks": auxiliary.count, "assigned_chunks": assigned.count, "topics": topics.count,
                "topic_quality_status": "not_assessed", "source_coverage_status": document.sourceCoverageStatus.rawValue,
                "model": ["repository": "mlx-community/Qwen3-VL-2B-Instruct-4bit", "revision": "9c4f5209e57b31f4b9dfba735de3fb983739c9cc", "precision": "4-bit affine group_size=64", "runtime": "MLXVLM Swift 3.32.3", "vision_input": false],
                "config": ["max_tokens": 2048, "max_prompt_tokens": 6000, "temperature": 0, "top_p": 1, "seed": 0,
                           "cache_limit_bytes": 268435456, "generation_deadline_seconds": 120, "max_chunks_per_request": 32,
                           "max_characters_per_request": 12000, "max_requests": 32, "retries": 0],
                "spans_ms": ["chunking": chunkingMS, "model_load": total(generationResults.map(\.loadMilliseconds)),
                             "prepare": total(generationResults.map(\.preprocessMilliseconds)),
                             "generation": total(generationResults.map(\.inferenceMilliseconds)),
                             "export": exportMS, "stage_wall": (ProcessInfo.processInfo.systemUptime - started) * 1000],
                "memory": ["sampled_peak_bytes": footprint as Any? ?? NSNull(), "interval_ms": 200, "scope": "app process only; WebContent excluded"],
                "thermal": ["initial": initialThermal, "final": MemorySampler.thermalString(ProcessInfo.processInfo.thermalState)],
                "requests": requests, "failures": failures,
                "limitations": ["Topic validation checks references, complete coverage and source order; topic meaning is not human-approved.", "Requests are bounded per page/window; topics across windows are not automatically unified.", "Chunk content is copied by code. Missing formula speech remains explicit review; no model rewrite."]
            ]
            try repository.writeJSON(report, to: directory.appendingPathComponent("report.json"))
        }

        _ = try snapshot("running")
        try writeReport("running")
        let promptURL = Bundle.main.url(forResource: "topic-v1", withExtension: "txt")
        let instructions = promptURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        if modelDirectory == nil { failures.append(["code": "qwen_weights_not_imported", "message": "Impor checkpoint Qwen yang dipin untuk pengelompokan topik."]) }
        if instructions == nil { failures.append(["code": "topic_prompt_unavailable", "message": "Prompt topic-v1 tidak tersedia."]) }

        var windows: [[ChunkCandidate]] = [], current: [ChunkCandidate] = []
        var characters = 0
        for candidate in body {
            let count = candidate.chunk.sourceText.count
            if !current.isEmpty && (current.count >= 32 || characters + count > 12000 || current.last?.chunk.pageID != candidate.chunk.pageID) {
                windows.append(current); current = []; characters = 0
            }
            current.append(candidate); characters += count
        }
        if !current.isEmpty { windows.append(current) }
        if let modelDirectory, let instructions {
            for (index, window) in windows.enumerated() {
                if Task.isCancelled { failures.append(["code": "cancelled", "message": "Pengelompokan dibatalkan; chunk tersisa disimpan."]); break }
                guard index < 32 else { failures.append(["code": "request_budget", "message": "Budget 32 request tercapai; chunk tersisa disimpan."]); break }
                let requestID = String(format: "request-%04d", index + 1)
                let requestRoot = directory.appendingPathComponent(requestID, isDirectory: true)
                try FileManager.default.createDirectory(at: requestRoot, withIntermediateDirectories: true)
                let aliases = window.indices.map { String(format: "c%03d", $0 + 1) }
                let payload = zip(aliases, window).map { id, candidate in ["id": id, "kind": candidate.chunk.kind, "sourceText": candidate.chunk.sourceText] }
                let inputData = try JSONSerialization.data(withJSONObject: ["chunks": payload], options: [.sortedKeys])
                let prompt = instructions + "\n\nDATA SUMBER JSON:\n" + String(decoding: inputData, as: UTF8.self)
                try prompt.write(to: requestRoot.appendingPathComponent("prompt.txt"), atomically: true, encoding: .utf8)
                try repository.writeJSON(Dictionary(uniqueKeysWithValues: zip(aliases, window.map { $0.chunk.id })), to: requestRoot.appendingPathComponent("chunk-id-map.json"))
                onProgress("Mengelompokkan topik di iPhone: bagian \(index + 1)/\(windows.count), \(window.count) chunk…")
                sampler.sampleNow()
                do {
                    let result = try await runtime.groupTopics(prompt: prompt, modelDirectory: modelDirectory, outputDirectory: requestRoot)
                    generationResults.append(result)
                    try repository.writeJSON(result, to: requestRoot.appendingPathComponent("generation.json"))
                    guard result.stopReason == "stop" else { throw TopicGroupingError.invalidPlan("generation stop: \(result.stopReason)") }
                    let plan = try validate(result.rawText, expectedIDs: aliases)
                    try repository.writeJSON(plan, to: requestRoot.appendingPathComponent("plan.validated.json"))
                    let lookup = Dictionary(uniqueKeysWithValues: zip(aliases, window.map(\.chunk)))
                    for topic in plan.topics {
                        let chunks = topic.chunkIDs.compactMap { lookup[$0] }
                        topics.append(ReadyTopic(id: String(format: "t%04d", topics.count + 1), title: topic.title, titleSource: "qwen_generated",
                                                 status: chunks.allSatisfy { $0.status == "ready" } ? "draft" : "needs_review", chunks: chunks))
                        assigned.formUnion(chunks.map(\.id))
                    }
                    requests.append(["id": requestID, "status": "succeeded", "chunks": window.count, "prompt_hash": result.promptHash])
                    try repository.writeJSON(["status": "succeeded", "validation": "exact_complete_ordered_chunk_membership", "quality": "not_assessed"], to: requestRoot.appendingPathComponent("status.json"))
                } catch {
                    let code = Task.isCancelled ? "cancelled" : "topic_request_failed"
                    failures.append(["request": requestID, "code": code, "message": error.localizedDescription])
                    requests.append(["id": requestID, "status": code, "chunks": window.count])
                    try repository.writeJSON(["status": code, "message": error.localizedDescription], to: requestRoot.appendingPathComponent("status.json"))
                }
                sampler.sampleNow()
                _ = try snapshot("running"); try writeReport("running")
            }
        }
        let status = Task.isCancelled ? "cancelled" : (body.isEmpty ? "not_required" : (assigned.count == body.count ? "complete" : (topics.isEmpty ? (modelDirectory == nil ? "skipped_dependency" : "failed") : "partial")))
        let final = try snapshot(status)
        sampler.sampleNow(); try writeReport(status)
        repository.appendEvent(["stage": "topic_grouping", "kind": "completed", "status": status, "attempt_id": attemptID, "report": final.reportArtifact], to: paths.events)
        return final
    }

    private static func validate(_ raw: String, expectedIDs: [String]) throws -> TopicPlan {
        let data = Data(raw.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == ["topics"],
              let items = object["topics"] as? [[String: Any]], !items.isEmpty, items.count <= expectedIDs.count,
              items.allSatisfy({ Set($0.keys) == ["title", "chunkIDs"] }) else { throw TopicGroupingError.invalidPlan("schema JSON tidak sesuai") }
        let plan = try JSONDecoder().decode(TopicPlan.self, from: data)
        guard plan.topics.allSatisfy({ !$0.chunkIDs.isEmpty && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.count <= 120 && !$0.title.contains("\n") }),
              plan.topics.flatMap(\.chunkIDs) == expectedIDs else { throw TopicGroupingError.invalidPlan("judul atau coverage/urutan ID tidak valid") }
        return plan
    }
}
