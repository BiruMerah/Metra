import Foundation

enum FoundationFormulaFallbackService {
    static func apply(to primary:FinalExtractionDocument,root:URL,runtime:FoundationFormulaRuntime,
        gate:HeavyInferenceGate,onProgress:@Sendable @escaping (String) async -> Void) async -> FinalExtractionDocument {
        var output = primary
        var descriptions = primary.formulaFallbacks ?? [:]
        let pending = primary.pages.flatMap { page in
            page.formulas.filter { $0.spokenText == nil && $0.coveredByFormulaIDs == nil }.map { (page.id,$0) }
        }
        for (index,item) in pending.enumerated() {
            if Task.isCancelled { break }
            let (pageID,formula) = item
            // Existing completed descriptions are retained on a derived re-export.
            if descriptions[formula.id] != nil { continue }
            await onProgress("Deskripsi alternatif rumus \(index+1)/\(pending.count)…")
            let prefix = "pages/\(pageID)/formulas/\(formula.id)/foundation-fallback"
            let directory = root.appendingPathComponent(prefix)
            var artifacts = ["result":"\(prefix)/result.json","request":"\(prefix)/request.json"]
            var status = "failed",text = "",notation = "",uncertainties:[String] = []
            try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            await gate.acquire()
            do {
                guard let crop = formula.artifacts["crop"],!crop.hasPrefix("/"),!crop.split(separator:"/").contains("..") else {
                    throw FoundationDiagramUnavailable(message:"Crop rumus belum tersedia.")
                }
                artifacts["crop"] = crop
                let reading = try await runtime.describe(imageURL:root.appendingPathComponent(crop),directory:directory)
                text = reading.spokenDescription.trimmingCharacters(in:.whitespacesAndNewlines)
                notation = reading.visibleNotation
                let note = reading.unclearParts.trimmingCharacters(in:.whitespacesAndNewlines)
                if !isNoUncertainty(note) { uncertainties = [note] }
                status = !reading.containsMath ? "not_math" : (text.isEmpty ? "unreadable" : (uncertainties.isEmpty ? "described" : "partial"))
                if text.count > 4000 { status = "invalid_output" }
                artifacts["raw_response"] = "\(prefix)/response.raw.txt"
                artifacts["transcript"] = "\(prefix)/transcript.json"
            } catch {
                uncertainties = [error.localizedDescription]
                artifacts["error"] = "\(prefix)/error.json"
                try? DiagramArtifactStore().writeJSON(["error":String(reflecting:error),"message":error.localizedDescription],to:directory.appendingPathComponent("error.json"))
            }
            await gate.release()
            let description = FormulaFallbackDescription(policy:FoundationFormulaRuntime.version,provider:"SystemLanguageModel.default",
                status:status,description:text,visibleNotation:notation,uncertainties:uncertainties,artifacts:artifacts)
            descriptions[formula.id] = description
            try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try? DiagramArtifactStore().writeJSON(description,to:directory.appendingPathComponent("result.json"))
        }
        output.formulaFallbacks = descriptions.isEmpty ? nil : descriptions
        return output
    }

    static func isNoUncertainty(_ text:String) -> Bool {
        let value = text.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        if ["","tidak ada","tidak ada.","none","-"].contains(value) { return true }
        return value.range(of:#"^tidak ada (?:bagian|unsur(?: matematika)?|informasi|elemen)(?: yang)? (?:tidak jelas|ambigu|tidak terbaca)\.?$"#,options:.regularExpression) != nil
    }
}
