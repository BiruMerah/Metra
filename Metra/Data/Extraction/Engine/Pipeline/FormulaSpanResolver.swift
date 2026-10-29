import Foundation

struct FormulaSourceSpan {
    let observationID: String
    let lower: Int
    let upper: Int
    let formulaID: String
    let method: String
    var allowsSpeech: Bool
    var note: String?
}

/// Resolves an entire occurrence before any OCR characters are replaced. Vision may
/// return the same word box for several characters; a box is only an alignment anchor.
enum FormulaSpanResolver {
    static let version = "whole_occurrence_utf16_v6"

    struct Resolution {
        let spans: [FormulaSourceSpan]
        let coveredByFormulaIDs: [String: [String]]
        let independentFormulaIDs: Set<String>
    }

    private struct Glyph {
        let value: Character
        let observationID: String
        let lower: Int
        let upper: Int
        let box: PixelBox
    }

    private struct Match {
        let spans: [FormulaSourceSpan]
        let score: Double
        let offset: Int
    }

    static func resolve(observations: [OCRObservation], regions: [LayoutRegion], formulas: [FormulaRegion]) -> [FormulaSourceSpan] {
        resolveOccurrences(observations: observations, regions: regions, formulas: formulas).spans
    }

    static func resolveOccurrences(observations: [OCRObservation], regions: [LayoutRegion], formulas: [FormulaRegion]) -> Resolution {
        let ordered = observations.sorted { $0.rawOrder == $1.rawOrder ? $0.id < $1.id : $0.rawOrder < $1.rawOrder }
        let glyphs = ordered.flatMap { observation -> [Glyph] in
            let text = observation.selectedText
            return text.indices.compactMap { start in
                let end = text.index(after: start)
                guard let value = normalized(text[start]) else { return nil }
                let lower = start.utf16Offset(in: text), upper = end.utf16Offset(in: text)
                let box = observation.rangeBoxes?.first { $0.rangeUTF16 == [lower, upper] }?.bboxPageXYXY ?? observation.bboxPageXYXY
                return Glyph(value: value, observationID: observation.id, lower: lower, upper: upper, box: box)
            }
        }
        let byObservation = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var output: [FormulaSourceSpan] = []
        var independent = Set<String>()

        for formula in formulas {
            let region = regions.first { $0.id == formula.layoutRegionID }
            let imageDetected = FormulaEvidencePolicy.imageSource(region) != nil &&
                formula.status == "spoken_generated" && formula.spokenText?.isEmpty == false &&
                formula.spokenMergeAllowed != false && FormulaEvidencePolicy.structure(formula.mathML ?? "").allowed
            // An OCR proposal already has an exact source range, even if recognition failed.
            if let region = regions.first(where: { $0.id == formula.layoutRegionID }),
               let observationID = region.sourceObservationID,
               let observation = byObservation[observationID],
               let range = region.sourceRangeUTF16, range.count == 2,
               range[0] >= 0, range[1] > range[0], range[1] <= observation.selectedText.utf16.count,
               Range(NSRange(location: range[0], length: range[1] - range[0]), in: observation.selectedText) != nil {
                output.append(FormulaSourceSpan(observationID: observationID, lower: range[0], upper: range[1], formulaID: formula.id, method: "explicit_ocr_proposal_range", allowsSpeech: true))
                continue
            }

            let target = formula.recognitionBBoxPageXYXY ?? formula.bboxPageXYXY
            let pattern = alignmentPattern(formula)
            // Alignment only: the image model has already recognized an angle.
            // Permit Vision's L/Z glyph at that operator position only when the
            // remaining complete angle/equality/degree expression matches exactly.
            // Never replace OCR, generate MathML, or infer a symbol from L/Z alone.
            let angleAlignment = pattern.contains("∠") && pattern.contains("=") && pattern.contains("°") &&
                formula.spokenText != nil && formula.spokenMergeAllowed != false
            var matches: [Match] = []
            if !pattern.isEmpty, pattern.count <= glyphs.count {
                for start in 0...(glyphs.count - pattern.count) {
                    guard pattern.indices.allSatisfy({ position in
                        let expected = pattern[position], actual = glyphs[start + position].value
                        let glyph = glyphs[start + position]
                        let unitAnchor = (formula.unitPowerAnchors ?? []).contains {
                            $0.observationID == glyph.observationID && $0.suffixRangeUTF16 == [glyph.lower,glyph.upper] &&
                            $0.exponent == String(expected) && $0.sourceSuffix == String(actual)
                        }
                        return expected == actual || unitAnchor || (angleAlignment && expected == "∠" && ["L", "Z"].contains(actual))
                    }) else { continue }
                    let slice = Array(glyphs[start..<(start + pattern.count)])
                    let usedAngleAlignment = pattern.indices.contains { pattern[$0] == "∠" && pattern[$0] != slice[$0].value }
                    let usedUnitAlignment = !usedAngleAlignment && pattern.indices.contains { pattern[$0] != slice[$0].value }
                    let matchMethod = usedAngleAlignment ? "image_angle_mathml_ocr_alignment" : (usedUnitAlignment ? "source_anchored_unit_power_alignment" : "mathml_token_match_with_geometry")
                    let box = union(slice.map(\.box))
                    // A whole textual match must also occupy the detected formula location.
                    let score = target.intersection(box) / max(1, box.area)
                    guard score >= 0.30,
                          slice.allSatisfy({ glyph in
                              guard let line = byObservation[glyph.observationID] else { return false }
                              let b = line.bboxPageXYXY
                              return min(b.ymax, target.ymax) > max(b.ymin, target.ymin)
                          }) else { continue }
                    var spans: [FormulaSourceSpan] = []
                    for glyph in slice {
                        if let previous = spans.last, previous.observationID == glyph.observationID {
                            spans[spans.count - 1] = FormulaSourceSpan(observationID: previous.observationID, lower: previous.lower, upper: glyph.upper, formulaID: formula.id, method: matchMethod, allowsSpeech: true)
                        } else {
                            spans.append(FormulaSourceSpan(observationID: glyph.observationID, lower: glyph.lower, upper: glyph.upper, formulaID: formula.id, method: matchMethod, allowsSpeech: true))
                        }
                    }
                    matches.append(Match(spans: spans, score: score, offset: start))
                }
            }
            matches.sort { $0.score == $1.score ? $0.offset < $1.offset : $0.score > $1.score }
            if let best = matches.first, matches.count == 1 || best.score - matches[1].score > 0.08 {
                output += best.spans
                continue
            }

            // Geometry places image-recognized content even when OCR omits a
            // fraction, exponent or multiplication glyph. It must own complete
            // source ranges without consuming neighboring prose/shared boxes.
            var geometric: [FormulaSourceSpan] = []
            var ambiguousBoundary = false
            for observation in ordered {
                let candidates = glyphs.filter { $0.observationID == observation.id && target.intersection($0.box) / max(1, $0.box.area) >= 0.65 }
                guard let first = candidates.first, let last = candidates.last else { continue }
                let inRange = glyphs.filter { $0.observationID == observation.id && $0.lower >= first.lower && $0.upper <= last.upper }
                if inRange.count != candidates.count { ambiguousBoundary = true }
                let raw = (observation.selectedText as NSString).substring(with:NSRange(location:first.lower,length:last.upper-first.lower))
                let imageTokens = String(pattern).lowercased()
                let words = (try? NSRegularExpression(pattern: #"[A-Za-z]{3,}"#))?.matches(in:raw,range:NSRange(raw.startIndex...,in:raw)) ?? []
                if words.contains(where: { !imageTokens.contains((raw as NSString).substring(with:$0.range).lowercased()) }) { ambiguousBoundary = true }
                geometric.append(FormulaSourceSpan(observationID:observation.id,lower:first.lower,upper:last.upper,
                    formulaID:formula.id,method:"image_detector_geometry_range",allowsSpeech:true,
                    note:"Image model owns content; geometry owns OCR replacement. OCR/MathML token equality is not required; source fidelity unassessed"))
            }
            // A word box straddling the crop edge cannot safely be split by
            // character index. The original OCR is never guessed or repaired.
            if glyphs.contains(where: { glyph in
                let x = (glyph.box.xmin+glyph.box.xmax)/2, y = (glyph.box.ymin+glyph.box.ymax)/2
                return x >= target.xmin && x <= target.xmax && y >= target.ymin && y <= target.ymax &&
                    target.intersection(glyph.box)/max(1,glyph.box.area) < 0.65
            }) { ambiguousBoundary = true }
            if imageDetected, !geometric.isEmpty, !ambiguousBoundary, matches.isEmpty {
                output += geometric
                continue
            }
            // A dedicated layout formula with no OCR at all may stand alone.
            // MFD-only empty crops and competing detections remain review cases.
            let competing = formulas.contains { other in
                other.id != formula.id && target.intersection(other.bboxPageXYXY)/max(1,min(target.area,other.bboxPageXYXY.area)) >= 0.65
            }
            if imageDetected, FormulaEvidencePolicy.imageSource(region) == "pp_doclayout_l",
               !competing, !glyphs.contains(where: { target.intersection($0.box) > 0 }) {
                independent.insert(formula.id)
                continue
            }
            output += geometric.map {
                FormulaSourceSpan(observationID:$0.observationID,lower:$0.lower,upper:$0.upper,formulaID:$0.formulaID,
                    method:"ambiguous_geometry_withheld",allowsSpeech:false,
                    note:ambiguousBoundary ? "Crop ownership ambiguous: shared boundary or nonmath source word" :
                        (matches.isEmpty ? "Formula source placement could not be established" : "Multiple source occurrences have similar spatial support"))
            }
        }

        let aliases = nestedAliases(spans: output, regions: regions, formulas: formulas)
        output.removeAll { aliases[$0.formulaID] != nil }

        // Conflicting occurrences are retained with a visible review state. No two
        // competing recognitions may both inject speech over the same source range.
        var conflicts = Set<String>()
        for i in output.indices {
            for j in output.indices where j > i {
                let a = output[i], b = output[j]
                if a.formulaID != b.formulaID, a.observationID == b.observationID,
                   max(a.lower, b.lower) < min(a.upper, b.upper) {
                    conflicts.insert(a.formulaID); conflicts.insert(b.formulaID)
                }
            }
        }
        for i in output.indices where conflicts.contains(output[i].formulaID) {
            output[i].allowsSpeech = false
            output[i].note = "Overlapping formula occurrences claim the same OCR range; speech withheld"
        }
        return Resolution(spans: output, coveredByFormulaIDs: aliases, independentFormulaIDs:independent)
    }

    /// Suppress only a proven enclosing duplicate: explicit layout parent-child,
    /// complete image MathML agreement, disjoint complete ranges on one OCR line,
    /// and no remaining math outside the children. Partial/conflicting overlaps
    /// still use the original withholding rule.
    private static func nestedAliases(spans: [FormulaSourceSpan], regions: [LayoutRegion],
                                      formulas: [FormulaRegion]) -> [String: [String]] {
        let byFormula = Dictionary(grouping: spans, by: \.formulaID)
        let byRegion = Dictionary(uniqueKeysWithValues: regions.map { ($0.id, $0) })
        func eligible(_ formula: FormulaRegion) -> FormulaSourceSpan? {
            guard formula.detectionSource == "pp_doclayout_l", formula.spokenMergeAllowed != false, formula.spokenText != nil,
                  let ranges = byFormula[formula.id], ranges.count == 1,
                  let span = ranges.first, span.allowsSpeech,
                  ["mathml_token_match_with_geometry", "image_angle_mathml_ocr_alignment"].contains(span.method) else { return nil }
            return span
        }
        func tokens(_ formula: FormulaRegion) -> String {
            String(alignmentPattern(formula))
        }
        let separators: Set<String> = ["", "dan", ",", ";"]
        var proposals: [String: [String]] = [:]
        for parent in formulas {
            guard let parentSpan = eligible(parent) else { continue }
            let children = formulas.filter { child in
                child.id != parent.id && byRegion[child.layoutRegionID]?.parentID == parent.layoutRegionID
            }
            guard children.count >= 2, children.count <= 16,
                  children.allSatisfy({ child in
                      guard let span = eligible(child) else { return false }
                      return span.observationID == parentSpan.observationID && span.lower >= parentSpan.lower &&
                          span.upper <= parentSpan.upper &&
                          parent.bboxPageXYXY.area > child.bboxPageXYXY.area &&
                          parent.bboxPageXYXY.intersection(child.bboxPageXYXY) / max(1, child.bboxPageXYXY.area) >= 0.95
                  }) else { continue }
            let ordered = children.sorted { eligible($0)!.lower < eligible($1)!.lower }
            guard zip(ordered, ordered.dropFirst()).allSatisfy({ eligible($0.0)!.upper <= eligible($0.1)!.lower }) else { continue }
            let family = Set([parent.id] + ordered.map(\.id))
            guard ordered.allSatisfy({ child in
                let span = eligible(child)!
                return !spans.contains { other in
                    !family.contains(other.formulaID) && other.observationID == span.observationID &&
                        max(other.lower, span.lower) < min(other.upper, span.upper)
                }
            }) else { continue }
            let parentText = tokens(parent)
            var cursor = parentText.startIndex
            var agrees = true
            for child in ordered {
                let text = tokens(child)
                guard !text.isEmpty, let range = parentText.range(of: text, range: cursor..<parentText.endIndex),
                      separators.contains(String(parentText[cursor..<range.lowerBound])) else { agrees = false; break }
                cursor = range.upperBound
            }
            guard agrees, separators.contains(String(parentText[cursor...])) else { continue }
            proposals[parent.id] = ordered.map(\.id)
        }
        // Keep the first implementation to one nesting level; do not guess which
        // depth should own a multi-level or competing decomposition.
        let aliasIDs = Set(proposals.keys)
        let competing = Set(proposals.values.flatMap { $0 }.filter { aliasIDs.contains($0) })
        return proposals.filter { !competing.contains($0.key) && Set($0.value).isDisjoint(with: aliasIDs) }
    }

    private static func alignmentPattern(_ formula: FormulaRegion) -> [Character] {
        let raw = MathMLLeafText.read(formula.mathML).compactMap(normalized)
        let canonical = MathMLLeafText.read(formula.canonicalMathML).compactMap(normalized)
        // MathJax's \\circ leaf is U+2218; MathCAT's canonical angle expression
        // uses U+00B0. Use the engine's existing canonical output only if every
        // other token is identical. No OCR/LaTeX/MathML/speech is rewritten.
        let angle = raw.contains("∠") && raw.contains("=")
        let numericDegree = raw.last == "∘" && raw.dropLast().contains(where: { $0.isNumber }) &&
            raw.dropLast().allSatisfy { $0.isNumber || [".",",","+","-"].contains($0) }
        if (angle || numericDegree), canonical.contains("°"), raw.count == canonical.count,
           zip(raw, canonical).allSatisfy({ $0.0 == $0.1 || ($0.0 == "∘" && $0.1 == "°") }) {
            return canonical
        }
        return raw
    }

    private static func normalized(_ character: Character) -> Character? {
        if character.isWhitespace || ["\u{2061}", "\u{2062}", "\u{2063}", "\u{2064}"].contains(String(character)) { return nil }
        // Matching only: preserve the original OCR and MathML characters in storage.
        // FormulaPipeline checks explicit powers before speech may replace OCR.
        if let index = Array("⁰¹²³⁴⁵⁶⁷⁸⁹").firstIndex(of:character) { return Character(String(index)) }
        return character == "−" ? "-" : character
    }

    private static func union(_ boxes: [PixelBox]) -> PixelBox {
        PixelBox(xmin: boxes.map(\.xmin).min() ?? 0, ymin: boxes.map(\.ymin).min() ?? 0,
                 xmax: boxes.map(\.xmax).max() ?? 0, ymax: boxes.map(\.ymax).max() ?? 0)
    }
}

/// Reads presentation tokens, ignoring layout commands, semantic annotations and
/// invisible operators. This is alignment data, never a speech or LaTeX converter.
private final class MathMLLeafText: NSObject, XMLParserDelegate {
    private var token: String?
    private var text = ""
    private var output = ""

    static func read(_ mathML: String?) -> String {
        guard let mathML, let data = mathML.data(using: .utf8) else { return "" }
        let reader = MathMLLeafText(), parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        return parser.parse() ? reader.output : ""
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if ["mi", "mn", "mo", "mtext"].contains(elementName) { token = elementName; text = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if token != nil { text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if token == elementName { output += text; token = nil; text = "" }
    }
}
