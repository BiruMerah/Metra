import Foundation

@main
enum PaddleOCRChecks {
    static func main() throws {
        var checks:[String:Bool]=[:]
        let dict=["","A","∠","²"," ","°","📘"]
        let repeated=try PaddleOCRCTC.decode(indices:[1,1,0,1],scores:[0.9,0.8,1,0.7],dictionary:dict)
        checks["ctc_repeats_with_blank"]=repeated.text=="AA" && repeated.glyphs.count==2
        checks["ctc_uses_selected_step_probability"]=abs(repeated.confidence-0.8)<0.0001
        checks["ctc_all_blank_empty"] = try PaddleOCRCTC.decode(indices:[0,0],scores:[1,1],dictionary:dict).text.isEmpty
        let emoji=try PaddleOCRCTC.decode(indices:[6,0,2],scores:[1,1,1],dictionary:dict)
        checks["ctc_utf16_ranges"]=emoji.glyphs.map(\.rangeUTF16)==[[0,2],[2,3]]
        do { _=try PaddleOCRCTC.decode(indices:[99],scores:[1],dictionary:dict);checks["invalid_ctc_class_rejected"]=false }
        catch { checks["invalid_ctc_class_rejected"]=true }
        func prediction(_ text:String,probability:Float=0.99) -> PaddleCTCResult {
            let glyphs=text.indices.enumerated().map { index,start -> PaddleOCRGlyph in
                let end=text.index(after:start)
                return PaddleOCRGlyph(text:String(text[start]),confidence:probability,rangeUTF16:[start.utf16Offset(in:text),end.utf16Offset(in:text)],timestep:index,endTimestep:index+1)
            }
            return PaddleCTCResult(text:text,confidence:probability,glyphs:glyphs)
        }
        func selected(_ vision:String,_ paddle:String,probability:Float=0.99) -> PaddleMathSymbolSelector.Decision {
            PaddleMathSymbolSelector.select(vision:vision,paddle:prediction(paddle,probability:probability))
        }
        let angle=selected("Jika LDFE adalah 47°.","Jika ∠DFE adalah 47°.")
        checks["explicit_recognized_angle_selected"]=angle.accepted && angle.selectedText=="Jika ∠DFE adalah 47°."
        checks["actual_paddle_symbol_and_confidence_retained"]=angle.changes.first?.paddleGlyph=="∠" && angle.changes.first?.visionGlyph=="L" && angle.changes.first?.paddleProbability==0.99
        checks["explicit_recognized_unit_power_selected"]=selected("C. 616 cmr","C. 616 cm²").selectedText=="C. 616 cm²"
        checks["flattened_variable_power_selected"]=selected("5x2 + 2x","5x² + 2x").selectedText=="5x² + 2x"
        checks["source_digit_change_rejected"] = !selected("C. 616 cmr","C. 618 cm²").accepted
        checks["prose_change_rejected"] = !selected("Jika LDFE besarnya 47°","Jika ∠DFE besarnya 48°").accepted
        checks["explicit_power_conflict_rejected"] = !selected("x²","x³").accepted
        checks["wrong_flattened_power_conflict_rejected"] = !selected("x2","x³").accepted
        checks["low_probability_symbol_rejected"] = !selected("LDFE","∠DFE",probability:0.5).accepted
        let twoAngles=prediction("∠AOB dan ∠COD")
        let mixed=PaddleCTCResult(text:twoAngles.text,confidence:twoAngles.confidence,glyphs:twoAngles.glyphs.map { glyph in
            PaddleOCRGlyph(text:glyph.text,confidence:glyph.rangeUTF16[0]==9 ? 0.5 : glyph.confidence,rangeUTF16:glyph.rangeUTF16,timestep:glyph.timestep,endTimestep:glyph.endTimestep)
        })
        let partial=PaddleMathSymbolSelector.select(vision:"LAOB dan LCOD",paddle:mixed)
        checks["weak_second_symbol_does_not_discard_strong_first"]=partial.accepted && partial.selectedText=="∠AOB dan LCOD" && partial.changes.count==1
        checks["numeric_conflict_still_vetoes_strong_symbol"] = !selected("LAOB 45 dan LCOD 120","∠AOB 45 dan ∠COD 121").accepted
        checks["operandless_degree_rejected"] = !selected("pusat O","pusat °").accepted
        checks["no_new_unicode_no_selection"] = !selected("x + 2","x + 2").accepted
        checks["missing_character_rejected"] = !selected("DFE","∠DFE").accepted
        checks["source_spacing_preserved"]=selected(" x2  + 2","x²+2").selectedText==" x²  + 2"
        checks["choice_marker_preserved"]=selected("С. 616 cmr","C. 616 cm²").selectedText=="С. 616 cm²"
        checks["fullwidth_alignment_does_not_rewrite_digits"]=selected("47o","４７°").selectedText=="47°"
        checks["emoji_before_symbol_preserved"]=selected("📘 x2","📘 x²").selectedText=="📘 x²"
        checks["unapproved_operator_change_rejected"] = !selected("x + 2","x × 2").accepted
        let result:[String:Any]=["scope":"Synthetic decoder/alignment guard fixtures only. No image/model inference or source accuracy claim.","checks":checks,"count":checks.count,"all_passed":checks.values.allSatisfy{$0}]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]));FileHandle.standardOutput.write(Data("\n".utf8))
        guard checks.values.allSatisfy({$0}) else { throw PaddleOCRError.invalid(checks.filter{!$0.value}.keys.sorted().joined(separator:", ")) }
    }
}
