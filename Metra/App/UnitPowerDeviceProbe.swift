#if DEBUG
import Foundation

/// One explicitly requested iPhone replay. Fixture checks are separate from
/// actual model results. The original run and saved material remain untouched.
@MainActor
enum UnitPowerDeviceProbe {
    static func run(sourceRunID: String, coordinator: AppCoordinator) async {
        guard UUID(uuidString: sourceRunID) != nil else { return }
        let attempt = UUID().uuidString.lowercased()
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let root = documents.appendingPathComponent("verification/unit-powers-v1/\(attempt)", isDirectory: true)
        let repository = RunRepository()
        var report: [String: Any] = ["schema": "metra-unit-power-probe-v1", "attempt_id": attempt,
            "source_run": sourceRunID, "build": BuildIdentity.metadata, "status": "running", "original_run_modified": false]
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let baselineURL = try coordinator.extractionService.artifactURL(for: "metra-runs/\(sourceRunID)/pages/p0001/page-result.json")
            let bytes = try Data(contentsOf: baselineURL)
            let baseline = try JSONDecoder().decode(PageExtraction.self, from: bytes)
            let fixtures = try fixtureChecks(baseline)
            report["fixture_checks"] = fixtures
            report["fixture_scope"] = "source text and cached bad model MathML plus tiny MathML validation fixtures; no accuracy claim from fixture success"
            try repository.writeJSON(report, to: root.appendingPathComponent("report.json"))
            guard fixtures.values.allSatisfy({ $0 }) else { throw ProbeError.fixtureFailed }
            let pages = try RunRepository().sourcePages(forRunID: sourceRunID)
            let inputs = try pages.map { source in
                MaterialImageInput(data: try Data(contentsOf: ImageIngestor.originalURL(for: source)),
                                   fileName: source.fileName, origin: .photoLibrary)
            }
            let material = try await coordinator.extractionService.extract(pages: inputs, title: "Materi — satuan berpangkat") { progress in
                appendJSONObjectLine(["progress": progress, "time": ISO8601DateFormatter().string(from: Date())],
                                     to: root.appendingPathComponent("progress.jsonl"))
            }
            guard let run = material.extractionRunID else { throw ProbeError.noResult }
            let freshURL = try coordinator.extractionService.artifactURL(for: "metra-runs/\(run)/pages/p0001/page-result.json")
            let fresh = try JSONDecoder().decode(PageExtraction.self, from: Data(contentsOf: freshURL))
            let proposals = (fresh.layoutRegions ?? []).filter { $0.detectionSource == LengthUnitSource.version }
            let expected = baseline.rawOCR.compactMap { observation -> (String, String)? in
                guard let match = try? LengthUnitSource.matches(in: observation.selectedText).first else { return nil }
                return (observation.id, (observation.selectedText as NSString).substring(with: match.range))
            }
            let formulas = fresh.formulaRegions ?? []
            let rows: [[String: Any]] = proposals.map { region in
                let formula = formulas.first { $0.layoutRegionID == region.id }
                return ["region_id": region.id, "source_observation_id": region.sourceObservationID as Any? ?? NSNull(),
                        "source_range": region.sourceRangeUTF16 as Any? ?? NSNull(), "source_text": region.proposalText as Any? ?? NSNull(),
                        "formula_id": formula?.id as Any? ?? NSNull(), "latex": formula?.latex as Any? ?? NSNull(),
                        "spoken": formula?.spokenText as Any? ?? NSNull(), "merge_allowed": formula?.spokenMergeAllowed as Any? ?? NSNull(),
                        "source_consistency": formula?.sourceConsistencyStatus as Any? ?? NSNull(), "crop": region.cropArtifact as Any? ?? NSNull()]
            }
            report["fresh_run"] = run
            report["source_sha256"] = fresh.source.sourceSHA256
            report["same_source_image"] = baseline.source.sourceSHA256 == fresh.source.sourceSHA256
            report["same_normalized_image"] = baseline.source.normalizedSHA256 == fresh.source.normalizedSHA256
            report["expected_unit_ranges"] = expected.count
            report["unit_proposals"] = proposals.count
            report["accepted_unit_measurements"] = rows.filter { $0["merge_allowed"] as? Bool == true }.count
            report["measurements"] = rows
            report["source_page_result_unchanged"] = try Data(contentsOf: baselineURL) == bytes
            try coordinator.mathMaterialService.addSavedMaterial(material: material)
            report["saved_material_id"] = material.id.uuidString
            report["status"] = proposals.count == expected.count && rows.allSatisfy { $0["merge_allowed"] as? Bool == true } ? "completed_all_unit_checks_passed" : "partial"
            try repository.writeJSON(report, to: root.appendingPathComponent("report.json"))
            coordinator.navigate(to: .mathMaterial(material.id))
        } catch {
            report["status"] = "failed"
            report["error"] = error.localizedDescription
            try? repository.writeJSON(report, to: root.appendingPathComponent("report.json"))
        }
    }

    private static func fixtureChecks(_ baseline: PageExtraction) throws -> [String: Bool] {
        // The source observation IDs are stable in this preserved sample.
        let ids = Set([16,17,18,19,23,24,25,26].map { String(format: "p0001.ocr.%04d", $0) })
        let sourceLines = baseline.rawOCR.filter { ids.contains($0.id) }
        var checks: [String: Bool] = ["all_eight_measurements_proposed": sourceLines.count == 8 && sourceLines.allSatisfy {
            (try? LengthUnitSource.matches(in: $0.selectedText).count) == 1
        }, "plain_prose_not_proposed": try LengthUnitSource.matches(in: "keliling 88 cm dan jari-jari 14 m").isEmpty]
        let good = "<math><mrow><mn>616</mn><msup><mi>m</mi><mn>2</mn></msup></mrow></math>"
        checks["structured_image_power_accepted"] = LengthUnitImageCheck.check(source: "616 m2", mathML: good).allowed
        checks["flattened_source_does_not_supply_exponent"] = !LengthUnitImageCheck.check(source: "616 m2", mathML: "<math><mn>616</mn><mi>m</mi><mn>2</mn></math>").allowed
        checks["explicit_power_conflict_rejected"] = !LengthUnitImageCheck.check(source: "616 m³", mathML: good).allowed
        checks["flattened_digit_conflict_rejected"] = !LengthUnitImageCheck.check(source: "616 m3", mathML: good).allowed
        checks["wrong_unit_rejected"] = !LengthUnitImageCheck.check(source: "616 cm2", mathML: good).allowed
        checks["extra_number_rejected"] = !LengthUnitImageCheck.check(source: "616 m2", mathML: good.replacingOccurrences(of: ">616<", with: ">6161<")).allowed
        checks["extra_punctuation_rejected"] = !LengthUnitImageCheck.check(source: "616 m2", mathML: good.replacingOccurrences(of: "<mn>616", with: "<mo>;</mo><mn>616")).allowed
        checks["complex_exponent_rejected"] = !LengthUnitImageCheck.check(source: "616 m2", mathML: good.replacingOccurrences(of: "<mn>2</mn>", with: "<msqrt><mn>2</mn></msqrt>")).allowed
        if let bad = baseline.formulaRegions?.first(where: { $0.id == "p0001.formula.0014" })?.mathML {
            checks["old_semicolon_measurement_rejected"] = !LengthUnitImageCheck.check(source: "616 m2", mathML: bad).allowed
        }
        if let bad = baseline.formulaRegions?.first(where: { $0.id == "p0001.formula.0016" })?.mathML {
            checks["old_extra_one_measurement_rejected"] = !LengthUnitImageCheck.check(source: "1.540 m'", mathML: bad).allowed
        }
        return checks
    }

    private enum ProbeError: LocalizedError {
        case fixtureFailed, noResult
        var errorDescription: String? { "Unit power device verification failed: \(self)" }
    }
}
#endif
