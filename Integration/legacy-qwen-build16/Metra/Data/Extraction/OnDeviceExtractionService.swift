import Combine
import Foundation
import UIKit

/// Adapts the preserved PoC engine to domain models. UI never receives engine or
/// SwiftData entities; all source/raw artifacts remain in the application's run.
@MainActor
final class OnDeviceExtractionService: MaterialExtractionProtocol {
    // MARK: - Dependencies
    private let coordinator = RunCoordinator()
    private let models = ModelAssetManager()
    private let topicRuntime = QwenDiagramRuntime()
    private var busy = false

    var diagramModelIsAvailable: Bool { models.modelDirectory != nil }
    var diagramModelIsBundled: Bool { models.isBundledModel }
    var diagramModelStatus: String { models.status }

    // MARK: - Public Actions
    func importDiagramModel(from folder: URL) async throws {
        guard !busy, !coordinator.isRunning else { throw ExtractionServiceError.busy }
        busy = true
        defer { busy = false }
        try await models.importVerifiedFolder(folder)
    }

    func extract(pages: [MaterialImageInput], title: String,
                 onProgress: @escaping @MainActor (String) -> Void) async throws -> MathMaterialModel {
        guard !busy, !coordinator.isRunning else { throw ExtractionServiceError.busy }
        guard !pages.isEmpty else { throw ExtractionServiceError.noPages }
        busy = true
        defer { busy = false }
        try Task.checkCancellation()
        onProgress("Menyiapkan halaman…")
        let sources = try await Task.detached(priority: .userInitiated) {
            try pages.map { page in
                try Task.checkCancellation()
                switch page.origin {
                case .photoLibrary:
                    return try ImageIngestor().ingestPhotoData(page.data, fileName: page.fileName)
                case .camera:
                    return try ImageIngestor().ingestCameraData(page.data, fileName: page.fileName)
                }
            }
        }.value
        try Task.checkCancellation()
        if models.modelDirectory != nil {
            onProgress("Menyiapkan model diagram…")
            do { try await models.prepareForInference() }
            catch is CancellationError { throw CancellationError() }
            catch {
                // Preserve the independent OCR/formula path. The manager records
                // verification failure and disables Qwen for this run.
                onProgress("Model diagram belum siap; melanjutkan teks dan rumus…")
            }
        }
        try Task.checkCancellation()
        var completion: AnyCancellable?
        let progress = coordinator.$progressText.sink { raw in onProgress(Self.userProgress(raw)) }
        defer { progress.cancel(); completion?.cancel() }

        try await withTaskCancellationHandler {
            coordinator.start(sources: sources, profile: .serialBaseline, modelDirectory: models.modelDirectory)
            // Await the engine's terminal state, including its safe cancellation save.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                completion = coordinator.$isRunning.filter { !$0 }.prefix(1).sink { _ in continuation.resume() }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [weak self] in self?.coordinator.cancel() }
        }

        guard let document = coordinator.latestReadyDocument,
              ["metra-ready-chunks-v3", "metra-ready-chunks-v4"].contains(document.schema),
              let id = UUID(uuidString: document.id),
              let chunks = document.chunks, !chunks.isEmpty,
              Set(chunks.map(\.id)).count == chunks.count else {
            throw ExtractionServiceError.noReadableResult
        }
        let relativeRun = "metra-runs/\(document.id)"
        let mapped = chunks.enumerated().map { order, chunk in
            MathChunkModel(id: chunk.id, order: order, pageID: chunk.pageID, kind: chunk.kind,
                           status: chunk.status, sourceText: chunk.sourceText,
                           spokenText: chunk.spokenText, spokenPreview: chunk.spokenPreview,
                           sourceReference: chunk.sourceRef,
                           imagePath: chunk.imageArtifact.map { "\(relativeRun)/\($0)" },
                           unresolvedFormulaIDs: chunk.unresolvedFormulaIDs,
                           uncertainties: chunk.uncertainties ?? [])
        }
        let topicIndex = try document.topicIndex.map { try JSONEncoder().encode($0) }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let material = MathMaterialModel(id: id, title: cleanTitle.isEmpty ? "Materi baru" : cleanTitle,
                                 extractionRunID: document.id,
                                 readyJSONPath: "\(relativeRun)/final_ready.json",
                                 extractionStatus: document.status, chunks: mapped, topicIndexJSON: topicIndex)
        // Formula/diagram stages have drained before this separate, serial request.
        return try await buildTopics(in: material, onProgress: onProgress)
    }

    func organizeTopics(in material: MathMaterialModel,
                        onProgress: @escaping @MainActor (String) -> Void) async throws -> MathMaterialModel {
        guard !busy, !coordinator.isRunning else { throw ExtractionServiceError.busy }
        busy = true
        defer { busy = false }
        return try await buildTopics(in: material, onProgress: onProgress)
    }

    private func buildTopics(in material: MathMaterialModel,
                             onProgress: @escaping @MainActor (String) -> Void) async throws -> MathMaterialModel {
        try Task.checkCancellation()
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        var dependencyError: String?
        do { try await models.prepareForInference() }
        catch is CancellationError { throw CancellationError() }
        catch { dependencyError = error.localizedDescription }
        do {
            let index = try await TopicNavigationService.run(material: material, modelDirectory: models.modelDirectory,
                dependencyError: dependencyError, runtime: topicRuntime, onProgress: onProgress)
            await topicRuntime.unload()
            var result = material
            result.topicIndexJSON = try JSONEncoder().encode(index)
            return result
        } catch {
            await topicRuntime.unload()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            // A topic-stage/export failure must not discard independently
            // completed OCR/formula content or make the user rerun extraction.
            let baseline = MaterialTopicIndex.sourceHeadings(chunks: material.chunks, fallbackTitle: material.title)
            let fallback = MaterialTopicIndex(policy: MaterialTopicIndex.qwenPolicy, topics: baseline.topics,
                auxiliaryChunkIDs: baseline.auxiliaryChunkIDs, experimentStatus: "failed",
                failureReason: error.localizedDescription)
            var result = material
            result.topicIndexJSON = try JSONEncoder().encode(fallback)
            return result
        }
    }

    func cancel() { coordinator.cancel() }

    func artifactURL(for relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let url = try ImageIngestor.documentsURL().appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
        return url
    }

    // MARK: - Presentation Mapping
    private static func userProgress(_ raw: String) -> String {
        if raw.contains("formula "), let range = raw.range(of: "formula ") {
            let number = raw[range.upperBound...].prefix { $0.isNumber || $0 == "/" }
            return "Membaca bagian matematika \(number)…"
        }
        if raw.localizedCaseInsensitiveContains("diagram") { return "Membaca gambar dan diagram…" }
        if raw.localizedCaseInsensitiveContains("pembatalan") { return "Menyelesaikan pembatalan…" }
        if raw.localizedCaseInsensitiveContains("layout") { return "Mengenali bagian halaman…" }
        return "Menyusun bacaan dari halaman…"
    }
}

private enum ExtractionServiceError: LocalizedError {
    case busy, noPages, noReadableResult
    var errorDescription: String? {
        switch self {
        case .busy: "Pemrosesan lain masih berjalan. Tunggu hingga selesai."
        case .noPages: "Pilih setidaknya satu halaman."
        case .noReadableResult: "Bacaan belum berhasil disusun. Hasil parsial dan laporan tetap disimpan di perangkat."
        }
    }
}
