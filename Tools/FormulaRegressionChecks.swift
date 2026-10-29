import Foundation

@main
enum FormulaRegressionChecks {
    static func main() throws {
        func math(_ body:String) -> String { "<math>\(body)</math>" }
        func letter(_ body:String,_ expected:String = "x") -> Bool {
            FormulaIdentifierCheck.check(mathML:math(body),expected:expected).allowed
        }
        var checks:[String:Bool] = [:]
        checks["plain_letter"] = letter("<mi>x</mi>")
        checks["sans_serif_is_presentation"] = letter("<mi mathvariant=\"sans-serif\">L</mi>","L")
        checks["inherited_sans_serif"] = letter("<mstyle mathvariant=\"sans-serif\"><mi>x</mi></mstyle>")
        checks["monospace_is_presentation"] = letter("<mi mathvariant=\"monospace\">x</mi>")
        checks["different_letter_rejected"] = !letter("<mi>y</mi>")
        checks["case_change_rejected"] = !letter("<mi>X</mi>")
        checks["bold_semantics_preserved"] = letter("<mi mathvariant=\"bold\">x</mi>")
        checks["script_semantics_preserved"] = letter("<mi mathvariant=\"script\">x</mi>")
        checks["blackboard_semantics_preserved"] = letter("<mi mathvariant=\"double-struck\">x</mi>")
        checks["bold_italic_n_accepted"] = letter("<mi mathvariant=\"bold-italic\">n</mi>","n")
        checks["styled_case_change_rejected"] = !letter("<mi mathvariant=\"bold-script\">X</mi>","x")
        checks["styled_wrong_letter_rejected"] = !letter("<mi mathvariant=\"script\">m</mi>","n")
        checks["font_variant_does_not_block_speech"] = letter("<mi mathvariant=\"unknown\">x</mi>")
        checks["styled_power_rejected"] = !letter("<msup><mi mathvariant=\"bold\">x</mi><mn>2</mn></msup>")
        checks["subscript_not_deleted"] = !letter("<msub><mi></mi><mi>x</mi></msub>")
        checks["power_not_deleted"] = !letter("<msup><mi>x</mi><mn>2</mn></msup>")
        checks["fraction_not_deleted"] = !letter("<mfrac><mi>x</mi><mi>y</mi></mfrac>")
        checks["duplicate_letter_rejected"] = !letter("<mi>x</mi><mi>x</mi>")
        checks["unexpected_operator_rejected"] = !letter("<mi>x</mi><mo>+</mo>")
        checks["malformed_xml_rejected"] = !FormulaIdentifierCheck.check(mathML:"<math><mi>x",expected:"x").allowed
        let source = "lebih dari 90°."
        let span = UnicodeMathSource.spans(in:source)[0]
        let shared = UnicodeMathSource.includingSharedPunctuation(span,in:source,identicalBoxes:true)
        let degree = "<msup><mn>90</mn><mo>°</mo></msup>"
        checks["period_requires_actual_ocr_character"] = shared.text == "90°."
        checks["period_requires_shared_geometry"] = UnicodeMathSource.includingSharedPunctuation(span,in:source,identicalBoxes:false).text == "90°"
        checks["source_period_and_image_agree"] = UnicodeMathSource.check(source:shared.text,mathML:math(degree+"<mo>.</mo>")).allowed
        checks["invented_period_still_rejected"] = !UnicodeMathSource.check(source:"90°",mathML:math(degree+"<mo>.</mo>")).allowed
        checks["changed_angle_still_rejected"] = !UnicodeMathSource.check(source:shared.text,mathML:math("<msup><mn>99</mn><mo>°</mo></msup><mo>.</mo>")).allowed
        checks["missing_period_still_rejected"] = !UnicodeMathSource.check(source:shared.text,mathML:math(degree)).allowed
        func chunk(_ speech:String?,preview:String? = nil) -> MathChunkModel {
            .init(id:"fixture.c0001",order:0,pageID:"p1",kind:"formula",status:speech == nil ? "needs_review" : "ready",
                sourceText:"x",spokenText:speech,spokenPreview:preview,sourceReference:"fixture",imagePath:nil,
                unresolvedFormulaIDs:speech == nil ? ["f1"] : [],uncertainties:[])
        }
        checks["reader_keeps_accepted_x"] = ReadingPresentation.text(for:chunk("x")) == "x"
        checks["reader_keeps_accepted_L"] = ReadingPresentation.text(for:chunk("huruf besar l")) == "huruf besar l"
        checks["reader_keeps_degree_speech"] = ReadingPresentation.accessibilityLabel(for:chunk("90 derajat")) == "90 derajat"
        checks["reader_keeps_complete_fraction"] = ReadingPresentation.text(for:chunk("l sama dengan, 1 perdua kali a kali t")).contains("1 perdua kali a kali t")
        checks["reader_does_not_accept_raw_dangling_subscript"] = ReadingPresentation.text(for:chunk(nil,preview:"_x")) == "Rumus belum dapat dibaca."
        if CommandLine.arguments.count > 1 {
            let root = URL(fileURLWithPath:CommandLine.arguments[1])
            for (id,expected,allowed) in [("0004","n",true),("0012","n",true),("0013","m",true),("0025","x",false)] {
                let path = root.appendingPathComponent("pages/p0005/formulas/p0005.formula.\(id)/mathml.xml")
                let mathML = try String(contentsOf:path,encoding:.utf8)
                checks["saved_page5_\(id)"] = FormulaIdentifierCheck.check(mathML:mathML,expected:expected).allowed == allowed
            }
        }
        let report:[String:Any] = ["schema":"metra-formula-regression-host-v1","scope":"Production identifier/Unicode checks and final reader projection; no model inference or listening study",
            "checks":checks,"passed":checks.values.filter{$0}.count,"total":checks.count]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]))
        guard checks.values.allSatisfy({$0}) else { throw NSError(domain:"FormulaRegressionChecks",code:1,userInfo:[NSLocalizedDescriptionKey:checks.filter{!$0.value}.keys.joined(separator:", ")]) }
    }
}
