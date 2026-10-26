import Foundation
import Combine
import UIKit

private struct PageWorkInput: Sendable {
    let pageID: String
    let source: ImportedSourcePage
    let normalizedURL: URL
}

private struct PageWorkResult: Sendable {
    let pageID: String
    let source: ImportedSourcePage
    let ocr: VisionOCRResult?
    let layout: LayoutResult?
    let formulaPage: FormulaPageResult?
    let effectiveRegions: [LayoutRegion]?
    let diagrams: [DiagramRegionResult]
    let components: [ComponentResult]
    let visionMilliseconds: Double?
    let queueWaitMilliseconds: Double
    let error: String?

    func extractionBlock() -> [ExtractionBlock] {
        if let layout { return LayoutMerge.blocks(pageID: pageID, regions: effectiveRegions ?? layout.regions, observations: ocr?.observations ?? [], formulas: formulaPage?.formulas ?? []) }
        guard let ocr else { return [] }
        return ocr.observations.enumerated().compactMap { index, observation in
            guard !observation.selectedText.isEmpty else { return nil }
            let blockID = "\(pageID).b\(String(format: "%04d", index + 1))"
            let segment = TextSegment(
                id: "\(blockID).s0001",
                kind: "text",
                textRaw: observation.selectedText,
                sourceObservationID: observation.id,
                sourceRangeUTF16: [0, observation.selectedText.utf16.count],
                status: "succeeded",
                spokenText: observation.selectedText
            )
            return ExtractionBlock(
                id: blockID,
                pageID: pageID,
                kind: "unclassified_vision_line",
                bboxPageXYXY: observation.bboxPageXYXY,
                readingOrder: index + 1,
                parentID: nil,
                sourceRegionIDs: [observation.id],
                segments: [segment],
                children: [],
                status: "partial",
                uncertainties: ["layout_unavailable; Vision observation is preserved as a line and is not classified as a paragraph or heading"]
            )
        }
    }

    func pageExtraction() -> PageExtraction {
        let formulas = formulaPage?.formulas ?? layout.map { LayoutMerge.formulas(pageID: pageID, regions: $0.regions, observations: ocr?.observations ?? []) }
        let wasCancelled = components.contains { $0.status == "cancelled" }
        let runtime: RuntimeStatus = wasCancelled ? .cancelled : (ocr == nil && layout == nil ? .failed : .partial)
        let blocks = extractionBlock()
        return PageExtraction(
            id: pageID,
            source: source,
            runtimeStatus: runtime,
            sourceCoverageStatus: .notAssessed,
            contentQualityStatus: formulas?.contains { $0.sourceConsistencyStatus == "needs_review" } == true || blocks.flatMap(\.segments).contains { ["needs_review", "unresolved"].contains($0.status) } ? .needsReview : .notAssessed,
            readingOrderMethod: layout == nil ? "Vision raw observation order; layout unavailable" : "PP-DocLayout-L regions sorted by ymin,xmin; nested regions retained; reading order requires review",
            rawOCR: ocr?.observations ?? [],
            components: components,
            blocks: blocks,
            formulaCounts: FormulaCounts(detected: formulas?.count, recognized: formulas?.filter { $0.stageResults?.contains { ["unimernet","vision_numeric_mathml"].contains($0.component) && $0.status == "succeeded" } == true }.count ?? 0, spoken: formulas?.filter { $0.spokenText != nil }.count ?? 0, unresolved: formulas.map { $0.filter { $0.spokenText == nil }.count }, missedOnReviewedPages: nil),
            layoutRegions: effectiveRegions ?? layout?.regions,
            formulaRegions: formulas,
            mergePolicyVersion: FormulaSpanResolver.version,
            diagrams: diagrams
        )
    }
}

@MainActor
final class RunCoordinator: ObservableObject {
    @Published private(set) var isRunning = false {
        didSet { UIApplication.shared.isIdleTimerDisabled = isRunning }
    }
    @Published private(set) var progressText = "Siap. Pilih halaman dari galeri atau kamera."
    @Published private(set) var latestFormulas: [FormulaRegion] = []
    @Published private(set) var latestLayoutOverlays: [URL] = []
    @Published private(set) var latestRunRoot: URL?
    @Published private(set) var latestReportURL: URL?
    @Published private(set) var latestSourceURL: URL?
    @Published private(set) var latestSpokenURL: URL?
    @Published private(set) var latestFinalURL: URL?
    @Published private(set) var latestFinalDocument: FinalExtractionDocument?
    @Published private(set) var latestReadyURL: URL?
    @Published private(set) var latestReadyDocument: ReadyExtractionDocument?
    @Published private(set) var latestTopicReportURL: URL?
    @Published private(set) var runtimeStatus: RuntimeStatus?
    @Published private(set) var recoverableRun: RecoverableRun?

    private let repository = RunRepository()
    private let qwenRuntime = QwenDiagramRuntime()
    private let layoutRuntime = PPDocLayoutRuntime()
    private let formulaPipeline = FormulaPipeline()
    private let heavyGate = HeavyInferenceGate()
    private var workTask: Task<Void, Never>?
    private var memorySampler: MemorySampler?

    init() {
        recoverableRun = repository.discoverRecoverableRun()
        formulaPipeline.onProgress = { [weak self] text in self?.progressText=text }
        if let stored = repository.latestFinalRun() { showStoredFinal(stored) }
    }

    func start(sources: [ImportedSourcePage], profile: RunProfile, reusingInputs: Bool = false, modelDirectory: URL? = nil) {
        guard !isRunning, !sources.isEmpty else { return }
        isRunning = true
        runtimeStatus = .running
        progressText = "Menyiapkan run dan menyimpan sumber..."
        workTask = Task { [weak self] in
            guard let self else { return }
            await self.execute(sources: sources, profile: profile, reusingInputs: reusingInputs, modelDirectory: modelDirectory)
        }
    }

    func cancel() {
        workTask?.cancel()
        progressText = "Pembatalan diminta; menunggu tahap aktif menyimpan status aman."
    }

    func resumeLatestRun(modelDirectory: URL? = nil) {
        guard !isRunning, let recoverableRun else { return }
        isRunning = true
        runtimeStatus = .running
        progressText = "Run \(recoverableRun.paths.runID) dilanjutkan; halaman yang sudah tersimpan dilewati."
        let sources = recoverableRun.manifest.pages.map(\.source)
        let profile = recoverableRun.manifest.profile
        workTask = Task { [weak self] in
            guard let self else { return }
            await self.execute(sources: sources, profile: profile, resuming: recoverableRun, modelDirectory: modelDirectory)
        }
    }

    private func showStoredFinal(_ stored: StoredFinalRun) {
        latestFinalDocument = stored.document
        latestFinalURL = stored.paths.finalExtraction
        latestRunRoot = stored.paths.root
        latestSourceURL = stored.paths.sourceExtraction
        latestSpokenURL = stored.paths.spokenExtraction
        latestReportURL = stored.paths.report
        runtimeStatus = stored.document.runtimeStatus
        latestReadyDocument = repository.readyDocument(at: stored.paths)
        latestReadyURL = latestReadyDocument == nil ? nil : stored.paths.readyExtraction
        latestTopicReportURL = latestReadyDocument.map { stored.paths.root.appendingPathComponent($0.reportArtifact) }
    }

    func startChunkExport(modelDirectory: URL?, runID: String? = nil) {
        guard !isRunning else { return }
        do {
            let stored: StoredFinalRun
            if let id = runID ?? latestFinalDocument?.id { stored = try repository.finalRun(id: id) }
            else if let latest = repository.latestFinalRun() { stored = latest }
            else { progressText = "Belum ada final-extraction.json tersimpan untuk dibentuk menjadi chunk."; return }
            showStoredFinal(stored)
            isRunning = true
            workTask = Task { [weak self] in
                guard let self else { return }
                await self.createReady(document: stored.document, paths: stored.paths, modelDirectory: modelDirectory)
                self.isRunning = false; self.workTask = nil
            }
        } catch { progressText = "Run sumber tidak dapat dibaca: \(error.localizedDescription)" }
    }

    private func createReady(document: FinalExtractionDocument, paths: RunPaths, modelDirectory: URL?) async {
        latestReadyDocument = nil; latestReadyURL = nil; latestTopicReportURL = nil
        progressText = "Membentuk chunk dan topik dari judul sumber…"
        do {
            let ready = try OrderedChunkExport.run(document: document, paths: paths)
            latestReadyDocument = ready; latestReadyURL = paths.readyExtraction
            latestTopicReportURL = paths.root.appendingPathComponent(ready.reportArtifact)
            progressText = "final_ready tersimpan: \(ready.chunks?.count ?? 0) chunk, \(ready.topicIndex?.topics.count ?? 0) topik mengikuti judul sumber. Ketepatan topik belum dinilai."
        } catch { progressText = "Ekstraksi tersimpan; penyusunan final_ready gagal: \(error.localizedDescription)" }
    }

    func startDiagramCropProbe(source: ImportedSourcePage, modelDirectory: URL) {
        guard !isRunning else { return }
        isRunning = true
        runtimeStatus = .running
        progressText = "Menjalankan OCR label lalu observasi Qwen pada crop yang dipilih..."
        workTask = Task { [weak self] in
            guard let self else { return }
            await self.executeDiagramCropProbe(source: source, modelDirectory: modelDirectory)
        }
    }

    private func executeDiagramCropProbe(source: ImportedSourcePage, modelDirectory: URL) async {
        latestFinalURL = nil
        latestFinalDocument = nil
        latestReadyDocument = nil; latestReadyURL = nil; latestTopicReportURL = nil
        let runStart = ProcessInfo.processInfo.systemUptime
        let startedAt = ISO8601DateFormatter().string(from: Date())
        var paths: RunPaths?
        var sampler: MemorySampler?
        do {
            let (createdPaths, manifest) = try repository.createRun(profile: .serialBaseline, sources: [source], mode: "diagram_crop_component_probe")
            paths = createdPaths
            latestRunRoot = createdPaths.root
            latestReportURL = createdPaths.report
            latestSourceURL = createdPaths.sourceExtraction
            latestSpokenURL = createdPaths.spokenExtraction
            sampler = MemorySampler(outputURL: createdPaths.memorySamples, runID: createdPaths.runID)
            sampler?.start()
            sampler?.sampleNow()

            let pageEntry = manifest.pages[0]
            let pageRoot = createdPaths.pages.appendingPathComponent(pageEntry.pageID, isDirectory: true)
            let normalizedURL = pageRoot.appendingPathComponent("normalized.png")
            progressText = "OCR Vision pada crop terpilih..."
            let ocrStart = ProcessInfo.processInfo.systemUptime
            let ocr = try await VisionOCRAdapter.recognize(imageURL: normalizedURL, pageID: pageEntry.pageID)
            let ocrMilliseconds = (ProcessInfo.processInfo.systemUptime - ocrStart) * 1000
            try repository.writeJSON(ocr, to: pageRoot.appendingPathComponent("ocr.raw.json"))

            let modelInputDirectory = pageRoot.appendingPathComponent("diagram-model-input", isDirectory: true)
            let boundedInput = try QwenDiagramRuntime.makeBoundedPNG(from: normalizedURL, outputDirectory: modelInputDirectory, maxSide: 1008)
            let preparedPrompt = try DiagramProbeService.prompt(
                pageID: pageEntry.pageID,
                sourceSize: [source.normalizedWidth, source.normalizedHeight],
                modelInputSize: boundedInput.size,
                observations: ocr.observations
            )
            try preparedPrompt.text.write(to: pageRoot.appendingPathComponent("diagram-prompt.txt"), atomically: true, encoding: .utf8)
            try repository.writeJSON(preparedPrompt.metadata, to: pageRoot.appendingPathComponent("diagram-input-metadata.json"))

            progressText = "Qwen3-VL memuat/menjalankan satu generation pada gambar diagram 1008 px..."
            let qwen = try await qwenRuntime.observe(
                imageURL: normalizedURL,
                modelDirectory: modelDirectory,
                prompt: preparedPrompt.text,
                outputDirectory: pageRoot.appendingPathComponent("diagram-attempt-001", isDirectory: true)
            )
            let rawURL = pageRoot.appendingPathComponent("diagram.raw.txt")
            try qwen.rawText.write(to: rawURL, atomically: true, encoding: .utf8)

            let validation = DiagramProbeService.validate(raw: qwen.rawText, labelIDs: preparedPrompt.labelIDs)
            var diagramStatus = "needs_review"
            var diagramError: String?
            switch validation {
            case .success(let output):
                diagramStatus = "succeeded"
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.keyEncodingStrategy = .convertToSnakeCase
                try encoder.encode(output).write(to: pageRoot.appendingPathComponent("diagram.validated.json"), options: .atomic)
                try DiagramProbeService.render(output, observations: ocr.observations)
                    .write(to: pageRoot.appendingPathComponent("diagram-rendered.txt"), atomically: true, encoding: .utf8)
            case .failure(let error):
                diagramError = error.localizedDescription
            }

            let components = [
                ComponentResult(component: "apple_vision_ocr", status: "succeeded", errorCode: nil, message: nil, rawArtifact: "pages/\(pageEntry.pageID)/ocr.raw.json", metrics: ["request_wall_ms": ocrMilliseconds]),
                ComponentResult(component: "qwen3_vl_diagram", status: diagramStatus, errorCode: diagramError == nil ? nil : "diagram_response_validation_failed", message: diagramError, rawArtifact: "pages/\(pageEntry.pageID)/diagram.raw.txt", metrics: ["model_load_ms": qwen.loadMilliseconds, "preprocess_ms": qwen.preprocessMilliseconds, "inference_ms": qwen.inferenceMilliseconds, "time_to_first_text_ms": qwen.timeToFirstTextMilliseconds])
            ]
            let blocks = ocr.observations.enumerated().compactMap { index, observation -> ExtractionBlock? in
                guard !observation.selectedText.isEmpty else { return nil }
                let blockID = "\(pageEntry.pageID).b\(String(format: "%04d", index + 1))"
                let segment = TextSegment(id: "\(blockID).s0001", kind: "text", textRaw: observation.selectedText, sourceObservationID: observation.id, sourceRangeUTF16: [0, observation.selectedText.utf16.count], status: "succeeded", spokenText: observation.selectedText)
                return ExtractionBlock(id: blockID, pageID: pageEntry.pageID, kind: "unclassified_vision_line", bboxPageXYXY: observation.bboxPageXYXY, readingOrder: index + 1, parentID: nil, sourceRegionIDs: [observation.id], segments: [segment], children: [], status: "partial", uncertainties: ["diagram crop probe input; source completeness not assessed"])
            }
            let page = PageExtraction(id: pageEntry.pageID, source: source, runtimeStatus: .partial, sourceCoverageStatus: .notAssessed, contentQualityStatus: .notAssessed, readingOrderMethod: "Vision raw observation order; diagram probe does not classify page layout", rawOCR: ocr.observations, components: components, blocks: blocks, formulaCounts: FormulaCounts(detected: nil, recognized: 0, spoken: 0, unresolved: nil, missedOnReviewedPages: nil))
            try repository.writePage(page, to: createdPaths)

            sampler?.sampleNow()
            let completedAt = ISO8601DateFormatter().string(from: Date())
            let report: [String: Any] = [
                "schema": "metra-device-report-v1",
                "run_id": createdPaths.runID,
                "mode": "diagram_crop_component_probe",
                "status": "partial",
                "started_at": startedAt,
                "completed_at": completedAt,
                "device": ["model": UIDevice.current.model, "hardware_model_identifier": DeviceIdentity.hardwareModelIdentifier() as Any? ?? NSNull(), "system_name": UIDevice.current.systemName, "system_version": UIDevice.current.systemVersion, "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory],
                "build": BuildIdentity.metadata,
                "input": ["source_sha256": source.sourceSHA256, "normalized_sha256": source.normalizedSHA256, "page_size_px": [source.normalizedWidth, source.normalizedHeight], "qwen_input_size_px": qwen.inputSize],
                "model": ["id": "mlx-community/Qwen3-VL-2B-Instruct-4bit", "revision": "9c4f5209e57b31f4b9dfba735de3fb983739c9cc", "runtime": "MLXVLM Swift", "vision_input": qwen.boundedImageURL.lastPathComponent, "model_was_warm": qwen.modelWasWarm, "cache_limit_bytes": qwen.cacheLimitBytes, "output_tokens": qwen.outputTokenCount as Any? ?? NSNull()],
                "prompt_sha256": qwen.promptHash,
                "spans_ms": ["apple_vision_request": ocrMilliseconds, "qwen_model_load": qwen.loadMilliseconds, "qwen_preprocess": qwen.preprocessMilliseconds, "qwen_inference_total": qwen.inferenceMilliseconds, "qwen_time_to_first_text": qwen.timeToFirstTextMilliseconds as Any? ?? NSNull(), "end_to_end": (ProcessInfo.processInfo.systemUptime - runStart) * 1000],
                "memory": ["sampled_peak_bytes": Self.sampledPeak(in: createdPaths.memorySamples) as Any? ?? NSNull(), "interval_ms": 200, "scope": "app process only; WebContent/runtime-internal memory excluded"],
                "thermal": ["final": MemorySampler.thermalString(ProcessInfo.processInfo.thermalState)],
                "component_runtime_status": diagramStatus,
                "source_coverage_status": "not_assessed",
                "content_quality_status": "not_assessed",
                "formula_regions": "not_available; diagram prompt received an empty math_regions list",
                "artifacts": ["pages/\(pageEntry.pageID)/diagram.raw.txt", "pages/\(pageEntry.pageID)/diagram.validated.json", "pages/\(pageEntry.pageID)/diagram-rendered.txt"]
            ]
            let document = ExtractionDocument(schema: "metra-source-extraction-v1", runID: createdPaths.runID, profile: .serialBaseline, runtimeStatus: .partial, sourceCoverageStatus: .notAssessed, contentQualityStatus: .notAssessed, startedAt: startedAt, completedAt: completedAt, pages: [page])
            let spokenDocument = ExtractionDocument(schema: "metra-spoken-extraction-v1", runID: createdPaths.runID, profile: .serialBaseline, runtimeStatus: .partial, sourceCoverageStatus: .notAssessed, contentQualityStatus: .notAssessed, startedAt: startedAt, completedAt: completedAt, pages: [page])
            latestFinalDocument = try repository.writeDocuments(document, spoken: spokenDocument, report: report, to: createdPaths)
            latestFinalURL = createdPaths.finalExtraction
            repository.appendEvent(["run_id": createdPaths.runID, "stage": "qwen3_vl_diagram", "kind": "completed", "status": diagramStatus, "inference_ms": qwen.inferenceMilliseconds, "model_load_ms": qwen.loadMilliseconds], to: createdPaths.events)
            latestRunRoot = createdPaths.root
            latestReportURL = createdPaths.report
            latestSourceURL = createdPaths.sourceExtraction
            latestSpokenURL = createdPaths.spokenExtraction
            runtimeStatus = .partial
            progressText = diagramStatus == "succeeded"
                ? "Generation diagram selesai dan JSON lolos validasi mekanik. Kesesuaian terhadap crop tetap belum dinilai."
                : "Raw Qwen tersimpan; validasi gagal dan hasil ditandai perlu ditinjau."
            sampler?.stop()
        } catch {
            sampler?.stop()
            runtimeStatus = .failed
            progressText = "Probe diagram gagal: \(error.localizedDescription)"
            if let paths {
                let failed = ["schema": "metra-device-report-v1", "run_id": paths.runID, "mode": "diagram_crop_component_probe", "status": "failed", "error": ["code": "diagram_probe_failed", "message": error.localizedDescription], "source_coverage_status": "not_assessed", "content_quality_status": "not_assessed"] as [String: Any]
                try? repository.writeJSON(failed, to: paths.report)
            }
        }
        await qwenRuntime.unload()
        isRunning = false
        workTask = nil
    }

    private func execute(sources: [ImportedSourcePage], profile: RunProfile, resuming: RecoverableRun? = nil, reusingInputs: Bool = false, modelDirectory: URL? = nil) async {
        latestFinalURL = nil
        latestFinalDocument = nil
        latestReadyDocument = nil; latestReadyURL = nil; latestTopicReportURL = nil
        let runStart = ProcessInfo.processInfo.systemUptime
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let initialThermal = MemorySampler.thermalString(ProcessInfo.processInfo.thermalState)
        latestLayoutOverlays = []
        latestFormulas = []
        await layoutRuntime.unload()
        await qwenRuntime.unload()
        do {
            let paths: RunPaths
            let manifest: RunManifest
            if let resuming {
                try repository.markRunResuming(resuming)
                paths = resuming.paths
                manifest = resuming.manifest
            } else {
                (paths, manifest) = try repository.createRun(profile: profile, sources: sources)
            }
            latestRunRoot = paths.root
            latestReportURL = paths.report
            latestSourceURL = paths.sourceExtraction
            latestSpokenURL = paths.spokenExtraction
            memorySampler = MemorySampler(outputURL: paths.memorySamples, runID: paths.runID)
            memorySampler?.start()
            memorySampler?.sampleNow()

            repository.appendEvent([
                "run_id": paths.runID,
                "stage": "input_ingest",
                "kind": "completed",
                "duration_ms": sources.map(\.sandboxCopyMilliseconds).reduce(0, +),
                "source": reusingInputs ? "historical importer timing; persisted input reused" : "input importer sandbox copies"
            ], to: paths.events)
            repository.appendEvent([
                "run_id": paths.runID,
                "stage": "normalization",
                "kind": "completed",
                "duration_ms": sources.map(\.normalizationMilliseconds).reduce(0, +),
                "source": reusingInputs ? "historical normalization timing; normalized PNG reused" : "ImageIO decode/orientation/PNG normalization"
            ], to: paths.events)

            let inputs = manifest.pages.map { entry in
                PageWorkInput(
                    pageID: entry.pageID,
                    source: entry.source,
                    normalizedURL: paths.pages.appendingPathComponent(entry.pageID, isDirectory: true).appendingPathComponent("normalized.png")
                )
            }
            let completedPages = resuming?.completedPages ?? [:]
            let pendingInputs = inputs.filter { completedPages[$0.pageID] == nil }
            let results = await process(pendingInputs, profile: profile, paths: paths, modelDirectory: modelDirectory)
            let mergeStart = ProcessInfo.processInfo.systemUptime
            let resumedPages = results.mapValues { $0.pageExtraction() }
            let pageMap = completedPages.merging(resumedPages) { _, latest in latest }
            let orderedPages = manifest.pages.compactMap { pageMap[$0.pageID] }
            let quality:ReviewStatus=orderedPages.contains{$0.contentQualityStatus == .needsReview} ? .needsReview : .notAssessed
            for page in orderedPages { try repository.writePage(page, to: paths) }
            latestFormulas = orderedPages.flatMap { $0.formulaRegions ?? [] }
            let mergeMS = (ProcessInfo.processInfo.systemUptime - mergeStart) * 1000
            latestLayoutOverlays = orderedPages.compactMap { page in
                let url = paths.pages.appendingPathComponent(page.id).appendingPathComponent("layout-overlay.png")
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }

            let terminal: RuntimeStatus = Task.isCancelled ? .cancelled : .partial
            let completedAt = ISO8601DateFormatter().string(from: Date())
            let batchWall = (ProcessInfo.processInfo.systemUptime - runStart) * 1000
            memorySampler?.sampleNow()
            let resumeAttempt: Int
            if resuming != nil,
               let previousReportData = try? Data(contentsOf: paths.report),
               let previousReport = (try? JSONSerialization.jsonObject(with: previousReportData)) as? [String: Any] {
                resumeAttempt = previousReport["resume_attempt"] as? Int ?? 1
            } else {
                resumeAttempt = 0
            }
            let totalVision = orderedPages.flatMap(\.components)
                .filter { $0.component == "apple_vision_ocr" }
                .compactMap { $0.metrics["request_wall_ms"] ?? nil }
                .reduce(0, +)
            let layoutComponents = orderedPages.flatMap(\.components).filter { $0.component == "layout" && $0.status == "succeeded" }
            func formulaMetric(_ component: String, _ name: String) -> Any {
                let values = orderedPages.flatMap(\.components).filter { $0.component == component }.compactMap { $0.metrics[name] ?? nil }
                return values.isEmpty ? NSNull() : values.reduce(0,+) as Any
            }
            func layoutMetric(_ name: String) -> Any {
                let values = layoutComponents.compactMap { $0.metrics[name] ?? nil }
                return values.isEmpty ? NSNull() : values.reduce(0, +) as Any
            }
            let allLayoutSucceeded = orderedPages.count == manifest.pages.count && orderedPages.allSatisfy { $0.layoutRegions != nil }
            let knownFormulaCount = orderedPages.compactMap { $0.formulaCounts.detected }.reduce(0, +)
            let totalQueue = results.values.map(\.queueWaitMilliseconds).reduce(0, +)
            let allRegions:[LayoutRegion]=orderedPages.flatMap { $0.layoutRegions ?? [] }
            let recognizedCount:Int=orderedPages.map { $0.formulaCounts.recognized }.reduce(0,+)
            let spokenCount:Int=orderedPages.map { $0.formulaCounts.spoken }.reduce(0,+)
            let unresolvedCount:Int=orderedPages.compactMap { $0.formulaCounts.unresolved }.reduce(0,+)
            let formulaSummary:[String:Any]=[
                "detected":allLayoutSucceeded ? knownFormulaCount as Any : NSNull(),
                "detected_in_successful_pages":knownFormulaCount,
                "recognized":recognizedCount,"spoken":spokenCount,
                "recognized_count_scope":"successful UniMERNet or literal Vision numeric parsing, not source correctness",
                "unimernet_recognized":orderedPages.flatMap{$0.formulaRegions ?? []}.filter{$0.stageResults?.contains{ $0.component == "unimernet" && $0.status == "succeeded" } == true}.count,
                "literal_numeric_parsed":orderedPages.flatMap{$0.formulaRegions ?? []}.filter{$0.stageResults?.contains{ $0.component == "vision_numeric_mathml" && $0.status == "succeeded" } == true}.count,
                "spoken_merge_allowed":orderedPages.flatMap{$0.formulaRegions ?? []}.filter{$0.spokenText != nil && $0.spokenMergeAllowed != false}.count,
                "source_consistency_flags":orderedPages.flatMap{$0.formulaRegions ?? []}.filter{$0.sourceConsistencyStatus=="needs_review"}.count,
                "unresolved":allLayoutSucceeded ? unresolvedCount as Any : NSNull(),
                "missed_on_reviewed_pages":NSNull(),
                "pp_doclayout_formula_regions":allRegions.filter{$0.label=="formula"}.count,
                "vision_math_roi_proposals":allRegions.filter{$0.label=="formula_candidate"}.count,
                "count_scope":"PP-DocLayout-L regions plus unconfirmed Vision math ROI proposals; multiline/nested units differ from source reference spans"
            ]
            let report: [String: Any] = [
                "schema": "metra-device-report-v1",
                "run_id": paths.runID,
                "status": terminal.rawValue,
                "profile": profile.rawValue,
                "started_at": startedAt,
                "completed_at": completedAt,
                "device": ["model": UIDevice.current.model, "hardware_model_identifier": DeviceIdentity.hardwareModelIdentifier() as Any? ?? NSNull(), "system_name": UIDevice.current.systemName, "system_version": UIDevice.current.systemVersion, "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory],
                "build": BuildIdentity.metadata,
                "input_page_count": manifest.pages.count,
                "input_mode": reusingInputs ? "persisted_input_replay" : (resuming == nil ? "freshly_imported" : "resumed"),
                "input_preparation_history_ms": ["input_ingest": sources.map(\.sandboxCopyMilliseconds).reduce(0, +), "normalization": sources.map(\.normalizationMilliseconds).reduce(0, +)],
                "batch_timing_scope": "run source copy, layout/OCR/formula/Qwen vision, merge and per-page save; excludes picker/initial normalization and final document/report writes",
                "page_count_attempted": completedPages.count + results.count,
                "runtime_completed_page_count": orderedPages.filter { $0.runtimeStatus == .partial || $0.runtimeStatus == .complete }.count,
                "components": Self.aggregateComponents(orderedPages),
                "spans_ms": [
                    "input_ingest": resuming == nil && !reusingInputs ? sources.map(\.sandboxCopyMilliseconds).reduce(0, +) : 0,
                    "normalization": resuming == nil && !reusingInputs ? sources.map(\.normalizationMilliseconds).reduce(0, +) : 0,
                    "queue_wait": totalQueue,
                    "model_load": ["layout_ms": layoutMetric("model_load_ms"),"unimernet_ms":formulaMetric("unimernet","model_load_ms"), "qwen_ms":formulaMetric("qwen3_vl_diagram","model_load_ms")],
                    "preprocess": ["layout_ms": layoutMetric("preprocess_ms"), "qwen_ms":formulaMetric("qwen3_vl_diagram","preprocess_ms")],
                    "inference": ["apple_vision_request_wall_ms": totalVision, "qwen_diagram_ms": formulaMetric("qwen3_vl_diagram","inference_ms"), "layout_ms": layoutMetric("inference_ms"), "formula_detector_ms": NSNull(), "unimernet_ms": formulaMetric("unimernet","inference_ms")],
                    "postprocess": ["layout_ms": layoutMetric("postprocess_ms"), "layout_artifact_write_ms": layoutMetric("artifact_write_ms")],
                    "qwen_grammar_prepare": formulaMetric("qwen3_vl_diagram","grammar_compile_ms"),
                    "math_parsing": formulaMetric("mathjax","parse_ms"),
                    "mathcat": formulaMetric("mathcat","inference_ms"),
                    "merge": mergeMS,
                    "export_packaging": NSNull(),
                    "end_to_end_batch": batchWall
                ],
                "memory": ["sampler": "task_info(TASK_VM_INFO).phys_footprint", "interval_ms": 200, "sampled_peak_bytes": Self.sampledPeak(in: paths.memorySamples) as Any? ?? NSNull(), "scope": "app process only; WebContent excluded"],
                "thermal": ["initial": initialThermal, "final": MemorySampler.thermalString(ProcessInfo.processInfo.thermalState)],
                "concurrency": ["max_active_pages": profile.pageConcurrency, "max_heavy_inference": 1, "max_vision_requests": profile.visionConcurrency, "model_residency": "staged"],
                "source_coverage_status": "not_assessed",
                "content_quality_status": quality.rawValue,
                "formula_counts": formulaSummary,
                "resume_attempt": resumeAttempt,
                "resumed_page_count": completedPages.count,
                "warnings": ["PP-DocLayout-L and UniMERNet source fidelity require review. MathCAT id SimpleSpeak speech is runtime output, not human approval. Contradictory one-letter proposal outputs are retained but withheld from merged speech. Numerical resize parity, complete formula recall and table structure have not been established."]
            ]
            let document = ExtractionDocument(
                schema: "metra-source-extraction-v1",
                runID: paths.runID,
                profile: profile,
                runtimeStatus: terminal,
                sourceCoverageStatus: .notAssessed,
                contentQualityStatus: quality,
                startedAt: startedAt,
                completedAt: completedAt,
                pages: orderedPages
            )
            let spokenDocument = ExtractionDocument(
                schema: "metra-spoken-extraction-v1",
                runID: paths.runID,
                profile: profile,
                runtimeStatus: terminal,
                sourceCoverageStatus: .notAssessed,
                contentQualityStatus: quality,
                startedAt: startedAt,
                completedAt: completedAt,
                pages: orderedPages
            )
            latestFinalDocument = try repository.writeDocuments(document, spoken: spokenDocument, report: report, to: paths)
            latestFinalURL = paths.finalExtraction
            memorySampler?.stop()
            repository.appendEvent([
                "run_id": paths.runID,
                "stage": "merge",
                "kind": "completed",
                "duration_ms": mergeMS,
                "ordering": "manifest page order; PP-DocLayout-L geometry when available; raw Vision observation order retained"
            ], to: paths.events)
            runtimeStatus = terminal
            progressText = "Run partial tersimpan: \(layoutComponents.count)/\(manifest.pages.count) halaman layout berhasil, \(knownFormulaCount) region formula. Lihat status LaTeX/MathML/spoken per formula; kualitas sumber tetap perlu ditinjau."
            if let final = latestFinalDocument { await createReady(document: final, paths: paths, modelDirectory: modelDirectory) }
            recoverableRun = repository.discoverRecoverableRun()
        } catch {
            memorySampler?.stop()
            runtimeStatus = .failed
            progressText = "Run gagal: \(error.localizedDescription)"
            if let root = latestRunRoot {
                let reportURL = root.appendingPathComponent("report.json")
                if let old = try? Data(contentsOf: reportURL),
                   var report = (try? JSONSerialization.jsonObject(with: old)) as? [String: Any] {
                    report["status"] = RuntimeStatus.failed.rawValue
                    report["error"] = ["code": "run_coordinator_failed", "message": error.localizedDescription]
                    try? repository.writeJSON(report, to: reportURL)
                }
            }
            recoverableRun = repository.discoverRecoverableRun()
        }
        await layoutRuntime.unload()
        isRunning = false
        workTask = nil
    }

    private func process(_ inputs: [PageWorkInput], profile: RunProfile, paths: RunPaths, modelDirectory: URL?) async -> [String: PageWorkResult] {
        let maxConcurrent = max(1, profile.pageConcurrency)
        var resultMap: [String: PageWorkResult] = [:]
        await withTaskGroup(of: PageWorkResult.self) { group in
            var next = 0
            while next < min(maxConcurrent, inputs.count) {
                let input = inputs[next]
                let enqueued = ProcessInfo.processInfo.systemUptime
                let runtime = self.layoutRuntime
                let formulaPipeline = self.formulaPipeline
                let qwen = self.qwenRuntime
                let gate = self.heavyGate
                group.addTask { await Self.processPage(input, enqueuedAt: enqueued, layoutRuntime: runtime, formulaPipeline: formulaPipeline, gate: gate, qwen: qwen, modelDirectory: modelDirectory, onProgress: { text in await MainActor.run { self.progressText = text } }) }
                next += 1
            }
            while let result = await group.next() {
                resultMap[result.pageID] = result
                try? await MainActor.run { try self.repository.writePage(result.pageExtraction(), to: paths) }
                let completedCount = resultMap.count
                await MainActor.run {
                    self.progressText = "\(result.pageID): \(result.layout?.regions.count ?? 0) region, OCR \(result.ocr?.observations.count ?? 0) baris; halaman \(completedCount)/\(inputs.count)."
                }
                if next < inputs.count && !Task.isCancelled {
                    let input = inputs[next]
                    let enqueued = ProcessInfo.processInfo.systemUptime
                    let runtime = self.layoutRuntime
                    let formulaPipeline = self.formulaPipeline
                let qwen = self.qwenRuntime
                    let gate = self.heavyGate
                    group.addTask { await Self.processPage(input, enqueuedAt: enqueued, layoutRuntime: runtime, formulaPipeline: formulaPipeline, gate: gate, qwen: qwen, modelDirectory: modelDirectory, onProgress: { text in await MainActor.run { self.progressText = text } }) }
                    next += 1
                }
            }
        }

        for input in inputs where resultMap[input.pageID] == nil {
            resultMap[input.pageID] = Self.cancelledResult(input)
        }
        return resultMap
    }

    nonisolated private static func processPage(_ input: PageWorkInput, enqueuedAt: Double, layoutRuntime: PPDocLayoutRuntime, formulaPipeline: FormulaPipeline, gate: HeavyInferenceGate, qwen: QwenDiagramRuntime, modelDirectory: URL?, onProgress: @Sendable @escaping (String) async -> Void) async -> PageWorkResult {
        let queueWait = max(0, ProcessInfo.processInfo.systemUptime - enqueuedAt) * 1000
        let pageRoot = input.normalizedURL.deletingLastPathComponent()
        var layout: LayoutResult?
        var ocr: VisionOCRResult?
        var visionMS: Double?
        var components: [ComponentResult] = []
        var routedRegions: [LayoutRegion]?
        await gate.acquire()
        do {
            try Task.checkCancellation()
            layout = try await layoutRuntime.detect(imageURL: input.normalizedURL, pageID: input.pageID, pageRoot: pageRoot, enqueuedAt: ProcessInfo.processInfo.systemUptime)
            components.append(ComponentResult(component: "layout", status: "succeeded", errorCode: nil, message: "PP-DocLayout-L FP32, ONNX Runtime CPU; review and numerical parity pending.", rawArtifact: "pages/\(input.pageID)/layout.raw.json", metrics: layout!.metrics.mapValues { Optional($0) }))
        } catch {
            components.append(ComponentResult(component: "layout", status: error is CancellationError ? "cancelled" : "failed", errorCode: error is CancellationError ? "run_cancelled" : "layout_runtime_failed", message: error.localizedDescription, rawArtifact: "pages/\(input.pageID)/layout.raw.json", metrics: [:]))
        }
        await layoutRuntime.unload()
        await gate.release()
        do {
            try Task.checkCancellation()
            let start = ProcessInfo.processInfo.systemUptime
            ocr = try await VisionOCRAdapter.recognize(imageURL: input.normalizedURL, pageID: input.pageID)
            if let layout {
                do {
                    let routing = DenseDocumentRegionRouter.route(regions:layout.regions,observations:ocr!.observations,
                        pageWidth:input.source.normalizedWidth,pageHeight:input.source.normalizedHeight)
                    routedRegions = routing.regions
                    let routingEncoder = JSONEncoder(); routingEncoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                    try routingEncoder.encode(routing.report).write(to:pageRoot.appendingPathComponent("document-routing.json"),options:.atomic)
                    components.append(ComponentResult(component:"document_container_routing",status:"succeeded",errorCode:nil,
                        message:"Dense full-page visual containers may enter the text/formula path; raw model predictions preserved; source coverage unassessed",
                        rawArtifact:"pages/\(input.pageID)/document-routing.json",metrics:["recovered_containers":Double(routing.report.decisions.filter(\.routedAsTextContainer).count)]))
                    let refined = try await VisionOCRAdapter.refineVisuals(ocr!,regions:routing.regions,pageID:input.pageID,pageRoot:pageRoot)
                    ocr = refined.0
                    components.append(ComponentResult(component:"visual_crop_vision_ocr",status:"succeeded",errorCode:nil,
                        message:"Working visual labels selected from dedicated crop requests; original page OCR retained in ocr.page.raw.json",
                        rawArtifact:"pages/\(input.pageID)/ocr-selection.json",metrics:["requests":Double(refined.1)]))
                    let numeric = try await VisionOCRAdapter.refineNumericLabels(ocr!,regions:routing.regions,pageID:input.pageID,pageRoot:pageRoot)
                    ocr = numeric.0
                    components.append(ComponentResult(component:"visual_numeric_vision_ocr",status:"succeeded",errorCode:nil,
                        message:"Two recorded numeric ROI variants; literal agreement required; no inferred symbols or values",
                        rawArtifact:"pages/\(input.pageID)/numeric-ocr-selection.json",metrics:["requests":Double(numeric.1)]))
                } catch {
                    components.append(ComponentResult(component:"visual_crop_vision_ocr",status:error is CancellationError ? "cancelled" : "failed",
                        errorCode:"visual_crop_ocr_failed",message:error.localizedDescription,rawArtifact:"pages/\(input.pageID)/ocr.page.raw.json",metrics:[:]))
                }
            }

            visionMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(ocr!).write(to: pageRoot.appendingPathComponent("ocr.raw.json"), options: .atomic)
            components.append(ComponentResult(component: "apple_vision_ocr", status: "succeeded", errorCode: nil, message: nil, rawArtifact: "pages/\(input.pageID)/ocr.raw.json", metrics: ["request_wall_ms": visionMS]))
        } catch {
            components.append(ComponentResult(component: "apple_vision_ocr", status: error is CancellationError ? "cancelled" : "failed", errorCode: error is CancellationError ? "run_cancelled" : "vision_request_failed", message: error.localizedDescription, rawArtifact: nil, metrics: [:]))
        }
        var effectiveRegions=routedRegions ?? layout?.regions
        if let layout, let ocr {
            do {
                let routed = routedRegions ?? layout.regions
                let proposals=try OCRMathROIProposer.propose(pageID:input.pageID,observations:ocr.observations,layout:routed,imageURL:input.normalizedURL,pageRoot:pageRoot)
                effectiveRegions=(routed+proposals).sorted(by:LayoutMerge.precedes)
                components.append(ComponentResult(component:"ocr_math_roi_proposals",status:"succeeded",errorCode:nil,message:"Whole algebraic expressions, isolated Latin variables and numeric tuples from Vision range boxes; proposals require image recognition/source review; score is OCR confidence, not detector probability",rawArtifact:"pages/\(input.pageID)/formula-roi-proposals.raw.json",metrics:["proposals":Double(proposals.count)]))
            } catch {
                components.append(ComponentResult(component:"ocr_math_roi_proposals",status:"failed",errorCode:"roi_proposal_failed",message:error.localizedDescription,rawArtifact:nil,metrics:[:]))
            }
        }
        let formulaPage: FormulaPageResult?
        if let effectiveRegions {
            formulaPage = await formulaPipeline.process(pageID:input.pageID,regions:effectiveRegions,observations:ocr?.observations ?? [],pageRoot:pageRoot,gate:gate)
        } else { formulaPage = nil }
        components += formulaPage?.components ?? ["unimernet","mathjax","mathcat"].map { ComponentResult(component:$0,status:"skipped_dependency",errorCode:"layout_unavailable",message:nil,rawArtifact:nil,metrics:[:]) }
        let formulaCount = layout?.regions.filter { $0.label == "formula" }.count
        let (diagrams, diagramComponents) = await DiagramSpokenService.process(pageID: input.pageID, regions: effectiveRegions ?? [], observations: ocr?.observations ?? [], formulas: formulaPage?.formulas ?? [], pageRoot: pageRoot, modelDirectory: modelDirectory, runtime: qwen, gate: gate, onProgress: onProgress)
        components += diagramComponents
        components += [
            ComponentResult(component: "formula_detection", status: layout == nil ? "skipped_dependency" : "succeeded", errorCode: layout == nil ? "layout_failed" : nil, message: "PP-DocLayout-L formulas plus separate Vision range proposals; MFD not used. Proposal classification and full source coverage require review.", rawArtifact: "pages/\(input.pageID)/formula-detection.raw.json", metrics: ["detected_regions": formulaCount.map(Double.init)]),
            ComponentResult(component: "table", status: "unsupported", errorCode: "table_structure_unavailable", message: "Label tabel dari layout tidak memastikan grid sel; struktur belum tersedia.", rawArtifact: nil, metrics: [:])
        ]
        return PageWorkResult(pageID: input.pageID, source: input.source, ocr: ocr, layout: layout, formulaPage: formulaPage, effectiveRegions:effectiveRegions, diagrams:diagrams, components: components, visionMilliseconds: visionMS, queueWaitMilliseconds: queueWait, error: ocr == nil && layout == nil ? "all_page_components_failed" : nil)
    }

    nonisolated private static func cancelledResult(_ input: PageWorkInput, queueWait: Double = 0) -> PageWorkResult {
        PageWorkResult(pageID: input.pageID, source: input.source, ocr: nil, layout: nil, formulaPage: nil, effectiveRegions:nil, diagrams:[], components: [ComponentResult(component: "pipeline", status: "cancelled", errorCode: "run_cancelled", message: "Pembatalan sebelum semua tahap selesai.", rawArtifact: nil, metrics: [:])], visionMilliseconds: nil, queueWaitMilliseconds: queueWait, error: "cancelled")
    }

    private static func aggregateComponents(_ pages: [PageExtraction]) -> [[String: Any]] {
        let groups = Dictionary(grouping: pages.flatMap(\.components), by: \.component)
        return groups.keys.sorted().map { name in
            let values = groups[name] ?? []
            let statuses = values.map(\.status)
            let status = statuses.allSatisfy { $0 == "succeeded" } ? "succeeded" : (statuses.contains("failed") ? "failed" : "partial")
            return ["component": name, "status": status, "attempts": values.count, "page_statuses": statuses]
        }
    }

    private static func sampledPeak(in url: URL) -> UInt64? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let values = text.split(separator: "\n").compactMap { line -> UInt64? in
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            return json["appPhysFootprintBytes"] as? UInt64
        }
        return values.max()
    }
}
