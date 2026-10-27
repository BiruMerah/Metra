import Foundation
import UIKit

struct RunPageEntry: Codable, Sendable {
    let pageID: String
    let source: ImportedSourcePage
}

struct RunManifest: Codable, Sendable {
    let schema: String
    let runID: String
    let profile: RunProfile
    let createdAt: String
    let modelResidency: String
    let cachePolicy: String
    let maxActivePages: Int
    let maxHeavyInference: Int
    let maxVisionRequests: Int
    let pages: [RunPageEntry]
}

struct RunPaths: Sendable {
    let root: URL
    let runID: String

    var pages: URL { root.appendingPathComponent("pages", isDirectory: true) }
    var metrics: URL { root.appendingPathComponent("metrics", isDirectory: true) }
    var report: URL { root.appendingPathComponent("report.json") }
    var sourceExtraction: URL { root.appendingPathComponent("source-extraction.json") }
    var spokenExtraction: URL { root.appendingPathComponent("spoken-extraction.json") }
    var finalExtraction: URL { root.appendingPathComponent("final-extraction.json") }
    var readyExtraction: URL { root.appendingPathComponent("final_ready.json") }
    var journal: URL { root.appendingPathComponent("journal.jsonl") }
    var memorySamples: URL { metrics.appendingPathComponent("samples.jsonl") }
    var events: URL { metrics.appendingPathComponent("events.jsonl") }
}

struct RecoverableRun: Sendable {
    let paths: RunPaths
    let manifest: RunManifest
    let completedPages: [String: PageExtraction]

    var pendingPageCount: Int { max(0, manifest.pages.count - completedPages.count) }
}

struct StoredFinalRun: Sendable {
    let paths: RunPaths
    let document: FinalExtractionDocument
}

@MainActor
final class RunRepository {
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func finalRun(id: String) throws -> StoredFinalRun {
        guard UUID(uuidString: id) != nil else { throw CocoaError(.fileReadInvalidFileName) }
        let root = try ImageIngestor.documentsURL().appendingPathComponent("metra-runs/\(id)", isDirectory: true)
        let paths = RunPaths(root: root, runID: id)
        let document = try decoder.decode(FinalExtractionDocument.self, from: Data(contentsOf: paths.finalExtraction))
        guard document.id == id, document.schema == "metra-final-extraction-v1" else { throw CocoaError(.fileReadCorruptFile) }
        return StoredFinalRun(paths: paths, document: document)
    }

    func latestFinalRun() -> StoredFinalRun? {
        guard let documents = try? ImageIngestor.documentsURL(),
              let urls = try? fileManager.contentsOfDirectory(at: documents.appendingPathComponent("metra-runs"), includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        return urls.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.compactMap { try? finalRun(id: $0.lastPathComponent) }.first
    }

    func readyDocument(at paths: RunPaths) -> ReadyExtractionDocument? {
        guard let data = try? Data(contentsOf: paths.readyExtraction), let value = try? decoder.decode(ReadyExtractionDocument.self, from: data), value.id == paths.runID else { return nil }
        return value
    }

    // Replay only an existing sandbox run; the CLI cannot choose an arbitrary file path.
    func sourcePages(forRunID runID: String) throws -> [ImportedSourcePage] {
        guard UUID(uuidString: runID) != nil else { throw CocoaError(.fileReadInvalidFileName) }
        let url = try ImageIngestor.documentsURL().appendingPathComponent("metra-runs/\(runID)/manifest.json")
        let manifest = try decoder.decode(RunManifest.self, from: Data(contentsOf: url))
        guard manifest.runID == runID else { throw CocoaError(.fileReadCorruptFile) }
        for entry in manifest.pages {
            guard fileManager.fileExists(atPath: try ImageIngestor.normalizedURL(for: entry.source).path),
                  fileManager.fileExists(atPath: try ImageIngestor.originalURL(for: entry.source).path) else { throw CocoaError(.fileNoSuchFile) }
        }
        return manifest.pages.map(\.source)
    }

    func discoverRecoverableRun() -> RecoverableRun? {
        guard let documents = try? ImageIngestor.documentsURL() else { return nil }
        let runsRoot = documents.appendingPathComponent("metra-runs", isDirectory: true)
        guard let runURLs = try? fileManager.contentsOfDirectory(
            at: runsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let newestFirst = runURLs.sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate > rightDate
        }
        for root in newestFirst {
            let reportURL = root.appendingPathComponent("report.json")
            guard let reportData = try? Data(contentsOf: reportURL),
                  let report = (try? JSONSerialization.jsonObject(with: reportData)) as? [String: Any],
                  let status = report["status"] as? String,
                  (report["mode"] as? String) != "diagram_crop_component_probe",
                  ["running", "interrupted", "cancelled", "failed"].contains(status),
                  let manifestData = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
                  let manifest = try? decoder.decode(RunManifest.self, from: manifestData) else { continue }

            let paths = RunPaths(root: root, runID: manifest.runID)
            var completedPages: [String: PageExtraction] = [:]
            for entry in manifest.pages {
                let resultURL = paths.pages.appendingPathComponent(entry.pageID, isDirectory: true).appendingPathComponent("page-result.json")
                guard let resultData = try? Data(contentsOf: resultURL),
                      let page = try? decoder.decode(PageExtraction.self, from: resultData),
                      page.runtimeStatus == .partial || page.runtimeStatus == .complete else { continue }
                completedPages[entry.pageID] = page
            }
            guard completedPages.count < manifest.pages.count else { continue }

            if status == "running" {
                var interrupted = report
                interrupted["status"] = RuntimeStatus.interrupted.rawValue
                interrupted["interrupted_at"] = ISO8601DateFormatter().string(from: Date())
                try? writeJSON(interrupted, to: reportURL)
                appendEvent(["run_id": manifest.runID, "stage": "recovery", "kind": "interrupted_run_discovered", "completed_page_count": completedPages.count], to: paths.events)
            }
            return RecoverableRun(paths: paths, manifest: manifest, completedPages: completedPages)
        }
        return nil
    }

    func markRunResuming(_ run: RecoverableRun) throws {
        var report = (try JSONSerialization.jsonObject(with: Data(contentsOf: run.paths.report))) as? [String: Any] ?? [:]
        report["status"] = RuntimeStatus.running.rawValue
        report["resume_attempt"] = ((report["resume_attempt"] as? Int) ?? 0) + 1
        report["resume_started_at"] = ISO8601DateFormatter().string(from: Date())
        report["resume_pending_page_count"] = run.pendingPageCount
        try writeJSON(report, to: run.paths.report)
        appendEvent(["run_id": run.manifest.runID, "stage": "recovery", "kind": "resume_started", "pending_page_count": run.pendingPageCount], to: run.paths.events)
    }

    func createRun(profile: RunProfile, sources: [ImportedSourcePage], mode: String = "page_extraction") throws -> (RunPaths, RunManifest) {
        let runID = UUID().uuidString.lowercased()
        let documents = try ImageIngestor.documentsURL()
        let root = documents.appendingPathComponent("metra-runs/\(runID)", isDirectory: true)
        let paths = RunPaths(root: root, runID: runID)
        try fileManager.createDirectory(at: paths.pages, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.metrics, withIntermediateDirectories: true)

        var entries: [RunPageEntry] = []
        for (index, source) in sources.enumerated() {
            let pageID = String(format: "p%04d", index + 1)
            let pageRoot = paths.pages.appendingPathComponent(pageID, isDirectory: true)
            let crops = pageRoot.appendingPathComponent("crops", isDirectory: true)
            try fileManager.createDirectory(at: crops, withIntermediateDirectories: true)
            let originalURL = try ImageIngestor.originalURL(for: source)
            let normalizedURL = try ImageIngestor.normalizedURL(for: source)
            try fileManager.copyItem(at: originalURL, to: pageRoot.appendingPathComponent(originalURL.lastPathComponent))
            try fileManager.copyItem(at: normalizedURL, to: pageRoot.appendingPathComponent("normalized.png"))
            try writeJSON(source, to: pageRoot.appendingPathComponent("source.json"))
            entries.append(RunPageEntry(pageID: pageID, source: source))
        }

        let manifest = RunManifest(
            schema: "metra-ios-run-manifest-v1",
            runID: runID,
            profile: profile,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            modelResidency: "staged",
            cachePolicy: "output_cache_disabled_for_new_run",
            maxActivePages: profile.pageConcurrency,
            maxHeavyInference: 1,
            maxVisionRequests: profile.visionConcurrency,
            pages: entries
        )
        try writeJSON(manifest, to: root.appendingPathComponent("manifest.json"))
        try writeJSON([
            "schema": "metra-run-config-v1",
            "profile": profile.rawValue,
            "page_concurrency": profile.pageConcurrency,
            "vision_concurrency": profile.visionConcurrency,
            "heavy_inference_concurrency": 1,
            "model_residency": "staged",
            "output_cache": "disabled",
            "vision": ["recognition_level": "accurate", "uses_language_correction": false, "character_range_boxes": true, "visual_crop_requests": true, "original_page_ocr_preserved": true, "numeric_recovery": "3x whole-visual context, native padded ROI plus 3x grayscale contrast 1.15 ROI; both raw saved; >=2 confidence>=0.8 numeric readings agree, no valid conflict; no generative enhancement"],
            "reading_export": ["grouping": HeadingTopicBuilder.version, "schema": "metra-ready-chunks-v4", "chunk_policy": ReadingChunkBuilder.version, "reading_normalization":QuestionReadingNormalizer.version, "qwen_topic_requests": 0, "canonical_content": "chunks[]; topicIndex and questions reference chunks; answer choices keep source blocks/slices and are read as one chunk"],
            "diagram_label_grouping": ["policy": DiagramLabelGrouper.version, "max_lines": 3, "vertical_gap_max_min_line_height": 0.9, "vertical_gap_min_min_line_height": -0.15, "height_ratio_range": [0.55,1.8], "width_ratio_range": [0.3,3.0], "horizontal_overlap_min": 0.6, "center_alignment_max_min_line_height": 0.75, "left_alignment_max_min_line_height": 0.6, "acceptance": "unique predecessor/successor; no math barrier; no ambiguous chain; retain all raw fragments; grouped labels remain review candidates"],
            "numeric_merge": ["policy": "numeric_corroboration_merge_v2", "evidence_version": "visual_numeric_ocr_agreement_v2", "required_distinct_confident_reads": 2, "confidence_min": 0.8, "retained_native_confidence_is_extra_gate": false, "conflict_policy": "withhold on any different valid value/unit; never outvote a valid native literal; legacy evidence without detailed reads stays review"],
            "document_container_routing": ["version":DenseDocumentRegionRouter.version,"min_page_area_fraction":0.6,"min_ocr_lines":12,"min_prose_lines":8,"min_letters":600,"max_existing_text_regions":1,"effect":"preserve raw prediction; route dense full-page image as text container; embedded visuals unassessed"],
            "formula_expression_proposals": ["version":"vision_math_expression_proposal_v1","role":"whole OCR expression range proposes a crop for UniMERNet; never convert OCR directly to a power","max_characters":160,"margin":"max(3px, 0.25 * target height); no largest-component tightening","existing_layout_formula_overlap":"retain existing formula route; do not create a second proposal on >=0.15 overlap"],
            "supplemental_mfd": ["model":"breezedeus/pix2text-mfd","revision":"fc3797af79391c32ed0d56f8b5f437b5a49271be","model_sha256":"51a8854743b17ae654729af8db82a630c1ccfa06debf4856c8b28055f87d02c1","proposal_version":Pix2TextMFDRuntime.proposalVersion,"merge_version":FormulaCropMerger.version,"score_threshold":0.25,"nms_same_class_iou":0.7,"target_width":768,"max_input_side":1536,"stride":32,"execution":"ONNX Runtime 1.24.2 CPU; 2 threads; heavy gate serial; unload before UniMERNet","overlap_policy":"keep existing DocLayout routes; uniquely fuse explicit Vision source crops only if no extra observed glyph; ambiguous and visual proposals withheld; plain source numbers/letters/list markers do not become new gap formulas","raw_artifact":"pages/<page>/mfd.raw.json","merge_artifact":"pages/<page>/mfd-crop-merge.json"],
            "length_unit_power_proposals": ["version":LengthUnitSource.version,"units":["mm","cm","dm","m","dam","hm","km"],"scope":"whole numeric quantity plus unit with explicit, flattened or corrupt power suffix; text regions only; no inferred exponent","crop_margin":"horizontal max(2px,0.05*height), vertical max(3px,0.25*height)","validation":"image_length_unit_consistency_v2 plus source-anchored unit normalization; exact number/separator and every unit letter; one image-recognized power 2/3; explicit and observed digit conflicts withheld","normalization":LengthUnitNormalizer.version,"artifact":"formulas/<formula-id>/unit-consistency.json","normalization_artifact":"formulas/<formula-id>/unit-normalization.json","speech":"MathCAT id on derived unit-intent MathML; original image MathML and raw MathCAT kept separately"],
            "exponent_consistency": ["version":"image_exponent_consistency_v2","policy":"explicit OCR powers must match; otherwise structured UniMERNet image powers may proceed with source quality unassessed; no power is created from linear OCR; unstructured ambiguous output stays review","artifact":"formulas/<formula-id>/exponent-consistency.json","scope":"proposal text or OCR observations >=0.8 contained by formula ROI; not a photo-fidelity audit"],
            "diagram_spoken": ["policy":DiagramSpokenService.version,"request_encoding":FoundationDiagramRequestEncoding.version,"request_fingerprint":"diagrams/<id>/generation/request.fingerprint.json","provider":"SystemLanguageModel.default","execution":"on_device_only","cloud_fallback":false,"sampling":"greedy","maximum_response_tokens":1536,"deadline_seconds":60,"schema":"@Generable FoundationDiagramPlan","image_input":true,"context":"bounded adjacent original Vision observations and source-referenced ready formula values","validation":"point/value IDs plus source-corroborated angle vertex/value; no inferred center; image overview/connections remain model candidates","measurement":"request wall time including OS preparation; app memory excludes system-model service; no separate load/inference measurement","output":"one diagram chunk; MathCAT for values; raw response/transcript and rejected facts retained"],
            "formula_pipeline": ["model": "wanderkid/unimernet_tiny", "revision": "3f09ac4b1cd583be47ea20a7d7daef839473028a", "precision": "FP32", "max_new_tokens": 512, "decoder_deadline_seconds": 30, "token_decoding": "original Nougat BPE vocabulary ByteLevel; no ftfy", "mathjax_transport": "numeric whitespace compaction v1 with raw/derivation retained", "roi_proposals": "Vision isolated Latin letter / numeric tuple plus whole numeric-like visual labels; unconfirmed", "simple_numeric_route": "literal Vision digits, optional decimal 1-2 places, degree/percent -> presentation MathML -> MathCAT; no inferred symbols; OCR agreement required for speech merge", "numeric_proposal_crop_margin": "max(3px, 0.25 * target height); rawVisionBBox is target; bboxPageXYXY includes crop padding", "crop_refinement": "exclude separately detected top prose band only with >=2 remaining OCR lines", "mathcat": "0.7.5 id SimpleSpeak Medium TTS=None, decimal comma, block dot; fixed OS thread"],
            "foundation_source": ["model":"SystemLanguageModel.default","revision":"OS-managed; not exposed","weights_bundled":false,"external_model_import":false,"legacy_qwen_removed":true],
            "degree_normalization": ["literal":"exact OCR number and explicit degree glyph to presentation MathML and MathCAT; no inferred degree","expression":"whole parenthesized source crop including degree; complete image/source token agreement required","embedded_units":EmbeddedLengthUnitNormalizer.version]

        ] as [String: Any], to: root.appendingPathComponent("config.snapshot.json"))
        copyBundledModelManifest(to: root.appendingPathComponent("model-manifest.snapshot.json"))
        if let url = Bundle.main.url(forResource:"Pix2Text-MFD.config",withExtension:"json") {
            try Data(contentsOf:url).write(to:root.appendingPathComponent("mfd-config.snapshot.json"),options:.atomic)
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let report: [String: Any] = [
            "schema": "metra-device-report-v1",
            "run_id": runID,
            "mode": mode,
            "status": RuntimeStatus.running.rawValue,
            "profile": profile.rawValue,
            "started_at": now,
            "completed_at": NSNull(),
            "device": ["model": UIDevice.current.model, "hardware_model_identifier": DeviceIdentity.hardwareModelIdentifier() as Any? ?? NSNull(), "system_name": UIDevice.current.systemName, "system_version": UIDevice.current.systemVersion],
            "build": BuildIdentity.metadata,
            "input_page_count": sources.count,
            "runtime_completed_page_count": 0,
            "source_coverage_status": "not_assessed",
            "content_quality_status": "not_assessed",
            "model_residency": "staged",
            "output_cache": "disabled",
            "spans_ms": ["input_ingest": sources.map(\.sandboxCopyMilliseconds).reduce(0, +), "normalization": sources.map(\.normalizationMilliseconds).reduce(0, +), "queue_wait": NSNull(), "model_load": NSNull(), "preprocess": NSNull(), "inference": NSNull(), "postprocess": NSNull(), "math_parsing": NSNull(), "mathcat": NSNull(), "merge": NSNull(), "export_packaging": NSNull(), "end_to_end_batch": NSNull()],
            "memory": ["sampler": "TASK_VM_INFO.phys_footprint", "interval_ms": 200, "sampled_peak_bytes": NSNull(), "scope": "app_process_only; WKWebView WebContent excluded"],
            "thermal": ["initial": ProcessInfo.processInfo.thermalState.rawValue, "final": NSNull()],
            "warnings": []
        ]
        try writeJSON(report, to: paths.report)
        appendEvent([
            "event": "run_started",
            "run_id": runID,
            "profile": profile.rawValue,
            "wall_time": now,
            "monotonic_seconds": ProcessInfo.processInfo.systemUptime
        ], to: paths.journal)
        return (paths, manifest)
    }

    func writePage(_ page: PageExtraction, to paths: RunPaths) throws {
        let pageRoot = paths.pages.appendingPathComponent(page.id, isDirectory: true)
        try writeJSON(page, to: pageRoot.appendingPathComponent("page-result.json"))
        if !fileManager.fileExists(atPath: pageRoot.appendingPathComponent("ocr.raw.json").path) {
            try writeJSON(page.rawOCR, to: pageRoot.appendingPathComponent("ocr.raw.json"))
        }
        if let formulas = page.formulaRegions {
            try writeJSON(formulas, to: pageRoot.appendingPathComponent("formula-detection.raw.json"))
        }
        for component in page.components {
            let safeName = component.component.replacingOccurrences(of: "/", with: "-")
            try writeJSON(component, to: pageRoot.appendingPathComponent("\(safeName).result.json"))
            if let rawArtifact = component.rawArtifact {
                let rawURL = paths.root.appendingPathComponent(rawArtifact)
                if !fileManager.fileExists(atPath: rawURL.path) {
                    let rawPayload: [String: Any] = [
                        "component": component.component,
                        "status": component.status,
                        "error_code": component.errorCode as Any? ?? NSNull(),
                        "message": component.message as Any? ?? NSNull(),
                        "inference_executed": false
                    ]
                    try writeJSON(rawPayload, to: rawURL)
                }
            }
        }
    }

    @discardableResult
    func writeDocuments(_ source: ExtractionDocument, spoken: ExtractionDocument, report: [String: Any], to paths: RunPaths) throws -> FinalExtractionDocument {
        try writeJSON(source, to: paths.sourceExtraction)
        try writeJSON(spoken, to: paths.spokenExtraction)
        let assemblyStart = ProcessInfo.processInfo.systemUptime
        let final = try FinalExtractionBuilder.build(spoken)
        let assemblyMS = (ProcessInfo.processInfo.systemUptime - assemblyStart) * 1000
        let writeStart = ProcessInfo.processInfo.systemUptime
        try writeJSON(final, to: paths.finalExtraction)
        let writeMS = (ProcessInfo.processInfo.systemUptime - writeStart) * 1000
        var completedReport = report
        var spans = report["spans_ms"] as? [String: Any] ?? [:]
        spans["final_document_assembly"] = assemblyMS
        spans["final_document_write"] = writeMS
        completedReport["spans_ms"] = spans
        completedReport["content_quality_status"] = final.contentQualityStatus.rawValue
        completedReport["final_export"] = [
            "schema": final.schema, "artifact": "final-extraction.json",
            "merge_policy": final.mergePolicyVersion,
            "blocks": final.pages.flatMap(\.blocks).count,
            "segments": final.pages.flatMap(\.blocks).flatMap(\.segments).count,
            "formula_occurrences": final.pages.flatMap(\.formulas).count,
            "ready_formula_occurrences": final.pages.flatMap(\.formulas).filter { $0.status == "ready" }.count,
            "needs_review_formula_occurrences": final.pages.flatMap(\.formulas).filter { $0.status == "needs_review" }.count
        ] as [String: Any]
        try writeJSON(completedReport, to: paths.report)
        return final
    }

    func appendEvent(_ event: [String: Any], to url: URL) {
        appendJSONObjectLine(event, to: url)
    }

    func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    func writeJSON(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        try data.write(to: url, options: .atomic)
    }

    private func copyBundledModelManifest(to destination: URL) {
        if let source = Bundle.main.url(forResource: "model-manifest", withExtension: "json"),
           let data = try? Data(contentsOf: source) {
            try? data.write(to: destination, options: .atomic)
        }
    }
}

func appendJSONObjectLine(_ event: [String: Any], to url: URL) {
    guard JSONSerialization.isValidJSONObject(event),
          let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8),
          let lineData = (line + "\n").data(using: .utf8) else { return }
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: lineData)
}
