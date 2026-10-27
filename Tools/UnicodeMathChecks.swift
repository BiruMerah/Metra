import Foundation

/// Pure source/MathML checks; no OCR, model inference or iPhone timing is claimed.
/// Compile alongside UnicodeMathSource.swift and MathMLSourceTree.swift.
@main
enum UnicodeMathChecks {
    static func main() throws {
        var checks: [String:Bool] = [:]
        func found(_ source:String) -> [String] { UnicodeMathSource.spans(in:source).map(\.text) }
        func math(_ body:String) -> String { "<math><mrow>\(body)</mrow></math>" }
        let degree = math("<msup><mrow><mo>(</mo><mn>3</mn><mi>x</mi><mo>+</mo><mn>4</mn><mo>)</mo></mrow><mo>∘</mo></msup>")
        checks["complete_parenthesized_degree"] = found("adalah (3x + 4)°, maka nilai x") == ["(3x + 4)°"]
        checks["separate_angle_names_and_degree"] = found("Jika ∠DFE besarnya adalah 47° dan ∠DPE") == ["∠DFE","47°","∠DPE"]
        checks["complete_angle_equality"] = found("sehingga ∠AOB = 45° dan ∠COD = 120°.") == ["∠AOB = 45°","∠COD = 120°"]
        checks["whole_quantity_power"] = found("C. 616 cm² dan D. 1.028 cm²") == ["616 cm²","1.028 cm²"]
        checks["standalone_unit_power"] = found("satuannya cm²") == ["cm²"]
        checks["whole_polynomial_power"] = found("Contoh: 5x² + 2x") == ["5x² + 2x"]
        checks["whole_signed_degree"] = found("sudut −30° dan +45°") == ["−30°","+45°"]
        checks["explicit_unicode_operator"] = found("syarat x ≤ 5 dan y ≠ 2") == ["x ≤ 5","y ≠ 2"]
        checks["no_L_or_Z_angle_invention"] = found("LDFE dan ZDPE") == []
        checks["no_flattened_or_prime_power_invention"] = found("x2 dan x' serta cmr dan cm2") == []
        checks["no_celsius_degree_fragment"] = found("Suhu 30°C atau 30° C") == []
        checks["no_word_suffix_power"] = found("abc²") == []
        checks["no_operandless_symbol"] = found("simbol ° atau ²") == []
        let emoji = UnicodeMathSource.spans(in:"📘 ∠DFE")
        checks["utf16_offsets_with_emoji"] = emoji.count == 1 && emoji[0].lower == 3 && emoji[0].upper == 7
        checks["degree_structure_agrees"] = UnicodeMathSource.check(source:"(3x + 4)°",mathML:degree).allowed
        checks["degree_extra_token_withheld"] = !UnicodeMathSource.check(source:"(3x + 4)°",mathML:degree.replacingOccurrences(of:"<mi>x",with:"<mn>1</mn><mi>x")).allowed
        let punctuated = "(3x + 4)°, maka"
        let baseSpan = UnicodeMathSource.spans(in:punctuated)[0]
        let attached = UnicodeMathSource.includingSharedPunctuation(baseSpan,in:punctuated,identicalBoxes:true)
        checks["shared_box_punctuation_binds_actual_source"] = attached.text == "(3x + 4)°," && attached.upper == baseSpan.upper+1 && attached.sharedTrailingPunctuation == ","
        checks["separate_box_punctuation_stays_prose"] = UnicodeMathSource.includingSharedPunctuation(baseSpan,in:punctuated,identicalBoxes:false) == baseSpan
        checks["same_box_cannot_consume_a_word"] = UnicodeMathSource.includingSharedPunctuation(baseSpan,in:"(3x + 4)°x",identicalBoxes:true) == baseSpan
        let degreeWithComma = degree.replacingOccurrences(of:"</mrow></math>",with:"<mo>,</mo></mrow></math>")
        checks["source_and_image_punctuation_agree"] = UnicodeMathSource.check(source:attached.text,mathML:degreeWithComma).allowed
        checks["unexpected_model_punctuation_withheld"] = !UnicodeMathSource.check(source:baseSpan.text,mathML:degreeWithComma).allowed
        checks["missing_model_punctuation_withheld"] = !UnicodeMathSource.check(source:attached.text,mathML:degree).allowed
        checks["degree_missing_glyph_withheld"] = !UnicodeMathSource.check(source:"47°",mathML:math("<mn>47</mn>")).allowed
        checks["angle_literal_agrees"] = UnicodeMathSource.check(source:"∠DFE",mathML:math("<mo>∠</mo><mi>D</mi><mi>F</mi><mi>E</mi>")).allowed
        checks["angle_changed_vertex_withheld"] = !UnicodeMathSource.check(source:"∠DFE",mathML:math("<mo>∠</mo><mi>D</mi><mi>P</mi><mi>E</mi>")).allowed
        checks["structured_power_agrees"] = UnicodeMathSource.check(source:"x²",mathML:math("<msup><mi>x</mi><mn>2</mn></msup>")).allowed
        checks["flattened_power_withheld"] = !UnicodeMathSource.check(source:"x²",mathML:math("<mi>x</mi><mn>2</mn>")).allowed
        checks["changed_power_withheld"] = !UnicodeMathSource.check(source:"x²",mathML:math("<msup><mi>x</mi><mn>3</mn></msup>")).allowed
        checks["coefficient_outside_power_agrees"] = UnicodeMathSource.check(source:"5x²",mathML:math("<mn>5</mn><msup><mi>x</mi><mn>2</mn></msup>")).allowed
        checks["coefficient_inside_wrong_power_base_withheld"] = !UnicodeMathSource.check(source:"5x²",mathML:math("<msup><mrow><mn>5</mn><mi>x</mi></mrow><mn>2</mn></msup>")).allowed
        checks["whole_unit_power_agrees"] = UnicodeMathSource.check(source:"616 cm²",mathML:math("<mn>616</mn><msup><mi>cm</mi><mn>2</mn></msup>")).allowed
        checks["quantity_inside_wrong_power_base_withheld"] = !UnicodeMathSource.check(source:"616 cm²",mathML:math("<msup><mrow><mn>616</mn><mi>cm</mi></mrow><mn>2</mn></msup>")).allowed
        checks["subscript_not_accepted_as_power"] = !UnicodeMathSource.check(source:"x²",mathML:math("<msub><mi>x</mi><mn>2</mn></msub>")).allowed
        checks["fraction_not_flattened"] = !UnicodeMathSource.check(source:"x²",mathML:math("<mfrac><mi>x</mi><mn>2</mn></mfrac>")).allowed
        checks["quantity_source_all_tokens_agree"] = UnicodeMathSource.check(source:"616 cm²",mathML:math("<mn>616</mn><mi>c</mi><msup><mi>m</mi><mn>2</mn></msup>")).allowed
        checks["quantity_changed_number_withheld"] = !UnicodeMathSource.check(source:"616 cm²",mathML:math("<mn>6161</mn><msup><mi>cm</mi><mn>2</mn></msup>")).allowed
        checks["quantity_changed_unit_withheld"] = !UnicodeMathSource.check(source:"616 cm²",mathML:math("<mn>616</mn><msup><mi>m</mi><mn>2</mn></msup>")).allowed
        checks["not_a_supported_unicode_source"] = !UnicodeMathSource.check(source:"LDFE",mathML:math("<mo>∠</mo><mi>D</mi><mi>F</mi><mi>E</mi>")).allowed
        var result: [String:Any] = ["scope":"Pure production matcher/MathML fixtures and optional cached iPhone artifact validation; no OCR/model inference or source accuracy measurement",
            "checks":checks,"all_passed":checks.values.allSatisfy{$0},"count":checks.count,
            "samples":["angles":found("Jika ∠DFE besarnya adalah 47° dan ∠DPE"),"equality":found("sehingga ∠AOB = 45° dan ∠COD = 120°.")]]
        if let position = CommandLine.arguments.firstIndex(of:"--cached-device-run"),CommandLine.arguments.indices.contains(position+1) {
            result["cached_device_replay"] = try cachedReplay(root:URL(fileURLWithPath:CommandLine.arguments[position+1]))
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
        guard checks.values.allSatisfy({$0}) else { throw NSError(domain:"UnicodeMathChecks",code:1,userInfo:[NSLocalizedDescriptionKey:checks.filter{!$0.value}.keys.sorted().joined(separator:", ")]) }
    }

    private static func cachedReplay(root:URL) throws -> [String:Any] {
        func object(_ url:URL) throws -> [String:Any] {
            guard let value = try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any] else {
                throw NSError(domain:"UnicodeCachedReplay",code:1)
            }
            return value
        }
        let page = try object(root.appendingPathComponent("pages/p0001/page-result.json"))
        guard let observations = page["rawOCR"] as? [[String:Any]],let regions = page["layoutRegions"] as? [[String:Any]],
              let formulas = page["formulaRegions"] as? [[String:Any]] else { throw NSError(domain:"UnicodeCachedReplay",code:2) }
        var rows: [[String:Any]] = []
        for formula in formulas {
            guard let id = formula["id"] as? String,let regionID = formula["layoutRegionID"] as? String,
                  let region = regions.first(where:{$0["id"] as? String == regionID}),
                  region["sourceNotationPolicy"] != nil,
                  let sourceID = region["sourceObservationID"] as? String,
                  let oldRange = region["sourceRangeUTF16"] as? [Int],oldRange.count == 2,
                  let observation = observations.first(where:{$0["id"] as? String == sourceID}),
                  let candidates = observation["candidates"] as? [[String:Any]],let text = candidates.first?["text"] as? String,
                  let core = UnicodeMathSource.spans(in:text).first(where:{$0.lower == oldRange[0]}) else { continue }
            let boxes = observation["rangeBoxes"] as? [[String:Any]] ?? []
            let last = boxes.first { $0["rangeUTF16"] as? [Int] == [core.upper-1,core.upper] }?["bboxPageXYXY"] as? [String:Double]
            let next = boxes.first { $0["rangeUTF16"] as? [Int] == [core.upper,core.upper+1] }?["bboxPageXYXY"] as? [String:Double]
            let identical = last != nil && next != nil && last == next
            let span = UnicodeMathSource.includingSharedPunctuation(core,in:text,identicalBoxes:identical)
            let raw = try String(contentsOf:root.appendingPathComponent("pages/p0001/formulas/\(id)/mathml.xml"),encoding:.utf8)
            let old = try object(root.appendingPathComponent("pages/p0001/formulas/\(id)/unicode-source-consistency.json"))
            let check = UnicodeMathSource.check(source:span.text,mathML:raw)
            var row: [String:Any] = ["formula_id":id,"source_observation_id":sourceID,"original_source_range_utf16":oldRange,
                "current_source_range_utf16":[span.lower,span.upper],"original_source":region["proposalText"] as Any,
                "current_source":span.text,"identical_last_glyph_and_next_character_box":identical,
                "original_check_allowed":old["allowed"] as Any,"current_check_allowed":check.allowed,
                "recognized_tokens":check.recognizedTokens,"raw_mathml_modified":false]
            if let punctuation = span.sharedTrailingPunctuation { row["included_actual_source_punctuation"] = punctuation }
            rows.append(row)
        }
        let allPassed = rows.count == 8 && rows.allSatisfy { $0["current_check_allowed"] as? Bool == true }
        guard allPassed else { throw NSError(domain:"UnicodeCachedReplay",code:3,userInfo:[NSLocalizedDescriptionKey:"Cached source validation did not pass all eight recorded Unicode occurrences"] ) }
        return ["source_run":root.path,"scope":"Reapply current source span/punctuation binding and validation to unmodified OCR boxes and raw MathML captured on iPhone build 21. No detector/recognizer request or final JSON merge executed.",
            "no_model_inference_executed":true,"count":rows.count,"all_passed":allPassed,"rows":rows]
    }
}
