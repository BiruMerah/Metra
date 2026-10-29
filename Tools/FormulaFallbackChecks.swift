import Foundation

@main
enum FormulaFallbackChecks {
    static func main() throws {
        func fallback(_ status:String = "described",_ text:String = "x pangkat dua",_ notes:[String] = []) -> FormulaFallbackDescription {
            .init(policy:"fixture",provider:"fixture",status:status,description:text,visibleNotation:"x²",uncertainties:notes,artifacts:[:])
        }
        func chunk(primary:String? = nil,preview:String? = nil,ids:[String]? = nil,kind:String = "formula") -> MathChunkModel {
            .init(id:"c1",order:0,pageID:"p1",kind:kind,status:"needs_review",sourceText:"x²",spokenText:primary,
                spokenPreview:preview,sourceReference:"fixture",imagePath:nil,unresolvedFormulaIDs:["f1"],uncertainties:[],formulaFallbackIDs:ids)
        }
        var checks:[String:Bool] = [:]
        let full = fallback().readerText!
        checks["description_has_alternative_label"] = full == "Deskripsi alternatif rumus, belum dipastikan: x pangkat dua"
        checks["partial_uncertainty_retained"] = fallback("partial","pecahan",["Penyebut tidak terbaca"]).readerText?.contains("Penyebut tidak terbaca") == true
        checks["failed_output_not_published"] = fallback("failed").readerText == nil
        checks["non_math_not_published_as_formula"] = fallback("not_math").readerText == nil
        checks["unreadable_not_published"] = fallback("unreadable").readerText == nil
        checks["empty_description_not_published"] = fallback("described"," \n ").readerText == nil
        checks["reader_shows_explicit_fallback"] = ReadingPresentation.text(for:chunk(preview:full,ids:["f1"])) == full
        checks["reader_accessibility_shows_fallback"] = ReadingPresentation.accessibilityLabel(for:chunk(preview:full,ids:["f1"])) == full
        checks["primary_speech_preferred"] = ReadingPresentation.text(for:chunk(primary:"x kuadrat",preview:full,ids:["f1"])) == "x kuadrat"
        checks["legacy_raw_preview_still_withheld"] = ReadingPresentation.text(for:chunk(preview:"_x")) == "Rumus belum dapat dibaca."
        checks["text_prefix_alone_does_not_bypass_gate"] = ReadingPresentation.text(for:chunk(preview:full)) == "Rumus belum dapat dibaca."
        checks["saved_old_fallback_gains_qualification"] = ReadingPresentation.text(for:chunk(preview:"Deskripsi alternatif rumus: x pangkat dua",ids:["f1"])) == full
        checks["inline_old_fallback_gains_qualification"] = ReadingPresentation.text(for:chunk(preview:"Contoh. Deskripsi alternatif rumus: x pangkat dua",ids:["f1"],kind:"paragraph")) == "Contoh. " + full
        checks["review_status_not_promoted"] = chunk(preview:full,ids:["f1"]).needsReview
        checks["primary_unresolved_id_retained"] = chunk(preview:full,ids:["f1"]).unresolvedFormulaIDs == ["f1"]
        let legacy = chunk(preview:"_x")
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(MathChunkModel.self,from:data)
        checks["legacy_model_remains_decodable"] = decoded.formulaFallbackIDs == nil && decoded.sourceText == legacy.sourceText
        let current = chunk(preview:full,ids:["f1"])
        checks["fallback_metadata_round_trip"] = try JSONDecoder().decode(MathChunkModel.self,from:JSONEncoder().encode(current)).formulaFallbackIDs == ["f1"]
        let report:[String:Any] = ["schema":"metra-formula-fallback-host-v1","checks":checks,
            "passed":checks.values.filter{$0}.count,"total":checks.count,"scope":"Production fallback formatting and reader projection; no model inference or source-accuracy claim"]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]))
        guard checks.values.allSatisfy({$0}) else { throw NSError(domain:"FormulaFallbackChecks",code:1,userInfo:[NSLocalizedDescriptionKey:checks.filter{!$0.value}.keys.joined(separator:", ")]) }
    }
}
