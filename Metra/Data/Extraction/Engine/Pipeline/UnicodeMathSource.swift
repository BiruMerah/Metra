import Foundation

/// Explicit OCR glyphs propose a complete source span. This does not recover an
/// angle from L/Z, an exponent from x2, or a missing glyph from surrounding prose.
enum UnicodeMathSource {
    static let version = "ocr_unicode_math_proposal_v3"
    static let validationVersion = "unicode_math_whole_source_check_v4"
    private static let raised = Array("⁰¹²³⁴⁵⁶⁷⁸⁹")
    static let triggers = Set("∠°²³⁰¹⁴⁵⁶⁷⁸⁹≤≥≠×÷±")

    struct Span: Codable, Equatable, Sendable {
        let lower: Int
        let upper: Int
        let text: String
        let symbols: [String]
        let kind: String
        var sharedTrailingPunctuation: String? = nil
    }

    /// A bounded grammar keeps the whole operand and symbol together. Prose,
    /// temperatures, primes, flattened powers and standalone glyphs stay OCR.
    static func spans(in text: String) -> [Span] {
        guard text.count <= 16_384 else { return [] }
        let number = #"[0-9]+(?:[.,][0-9]+)*"#
        let power = #"[⁰¹²³⁴⁵⁶⁷⁸⁹]+"#
        let unit = #"(?:dam|km|hm|dm|cm|mm|m)"#
        let angle = #"∠[ \t]*[A-Z](?:[ \t]*[A-Z]){0,2}(?![A-Za-z])"#
        let variable = "(?:\(number))?[A-Za-z](?:\(power))?"
        let quantity = "(?:\(number)[ \\t]*)?\(unit)\(power)"
        let simple = "(?:\(angle)|\(quantity)|\(variable)|\(number))"
        let operation = #"[+−\-=≤≥≠×÷±*/]"#
        let group = "\\([ \\t]*[+−-]?\(simple)(?:[ \\t]*\(operation)[ \\t]*\(simple))*[ \\t]*\\)"
        let degree = "(?:\(group)|\(number))[ \\t]*°(?![ \\t]*[CFK](?![A-Za-z]))"
        let atom = "(?:\(degree)|\(group)|\(simple))"
        let pattern = "(?<![\\p{L}\\p{N}_°⁰¹²³⁴⁵⁶⁷⁸⁹])(?:[+−±-][ \\t]*)?\(atom)(?:[ \\t]*\(operation)[ \\t]*\(atom))*(?![\\p{L}\\p{N}_°⁰¹²³⁴⁵⁶⁷⁸⁹])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let value = source.substring(with: match.range)
            let symbols = Array(Set(value.filter { triggers.contains($0) }.map(String.init))).sorted()
            guard !symbols.isEmpty, value.count <= 160 else { return nil }
            let kind = value.contains("∠") ? "angle" : (value.contains("°") ? "degree" :
                (value.contains(where: { raised.contains($0) }) ? "power" : "operator"))
            return Span(lower: match.range.location, upper: NSMaxRange(match.range), text: value, symbols: symbols, kind: kind)
        }
    }

    /// Vision can assign one word box to the final glyph and adjacent punctuation.
    /// Include that actual source character only when the caller proves the two
    /// boxes are identical. Raw OCR and image MathML are never edited or stripped.
    static func includingSharedPunctuation(_ span:Span,in text:String,identicalBoxes:Bool) -> Span {
        let ns = text as NSString
        guard identicalBoxes, span.upper < ns.length,
              [",",";","."].contains(ns.substring(with:NSRange(location:span.upper,length:1))) else { return span }
        var result = Span(lower:span.lower,upper:span.upper+1,
            text:ns.substring(with:NSRange(location:span.lower,length:span.upper+1-span.lower)),symbols:span.symbols,kind:span.kind)
        result.sharedTrailingPunctuation = ns.substring(with:NSRange(location:span.upper,length:1))
        return result
    }

    struct PowerBinding: Codable, Sendable {
        let base: String
        let exponent: String
        /// Position of the base in compact presentation tokens, not source OCR.
        let baseRangeTokenUTF16: [Int]
    }

    struct Check: Codable, Sendable {
        let version: String
        let allowed: Bool
        let source: String
        let expectedTokens: String
        let recognizedTokens: String
        let expectedPowers: [String]
        let recognizedPowers: [String]
        let expectedPowerBindings: [PowerBinding]
        let recognizedPowerBindings: [PowerBinding]
        let structureSupported: Bool
        let reason: String
    }

    private static func sourceTokens(_ source:String) -> String {
        MathMLSourceTree.compact(source).map { character -> String in
            if let index = raised.firstIndex(of:character) { return String(index) }
            return String(character)
        }.joined()
    }

    /// Token agreement alone would accept x² -> x2 or 5x² -> (5x)². Require the
    /// exponent, base and attachment position; unknown structure is withheld.
    static func check(source: String, mathML: String) -> Check {
        let whole = spans(in: source).contains {
            $0.lower == 0 && ($0.upper == source.utf16.count ||
                ($0.upper == source.utf16.count-1 && [",",";","."].contains(String(source.suffix(1)))))
        }
        let expected = sourceTokens(source)
        let powerRegex = try? NSRegularExpression(pattern: #"(?<![\p{L}_])(dam|km|hm|dm|cm|mm|m|[A-Za-z])([⁰¹²³⁴⁵⁶⁷⁸⁹]+)"#)
        let ns = source as NSString
        let expectedBindings = (powerRegex?.matches(in: source, range: NSRange(location: 0, length: ns.length)) ?? []).map { match in
            let base = ns.substring(with:match.range(at:1))
            let start = sourceTokens(ns.substring(to:match.range(at:1).location)).utf16.count
            return PowerBinding(base:base,
                exponent:ns.substring(with:match.range(at:2)).map { String(raised.firstIndex(of:$0)!) }.joined(),
                baseRangeTokenUTF16:[start,start+base.utf16.count])
        }
        var bindings: [PowerBinding] = []
        var tokenOffset = 0
        var supported = whole
        let root = MathMLSourceTree.read(mathML)
        func walk(_ node: MathMLSourceTree.Node) {
            if ["annotation", "annotation-xml", "mspace"].contains(node.name) { return }
            guard ["math", "mrow", "mstyle", "semantics", "mi", "mn", "mo", "mtext", "msup"].contains(node.name) else {
                supported = false; return
            }
            if node.name == "msup" {
                guard node.children.count == 2 else { supported = false; return }
                let start = tokenOffset
                walk(node.children[0])
                let end = tokenOffset
                let exponent = MathMLSourceTree.compact(node.children[1].tokens)
                if exponent != "°" {
                    guard !exponent.isEmpty, exponent.allSatisfy({ $0.isASCII && $0.isNumber }) else { supported = false; return }
                    bindings.append(PowerBinding(base:MathMLSourceTree.compact(node.children[0].tokens),exponent:exponent,
                        baseRangeTokenUTF16:[start,end]))
                }
                walk(node.children[1])
                return
            }
            if ["mi","mn","mo","mtext"].contains(node.name) {
                guard node.children.isEmpty else { supported = false; return }
                tokenOffset += MathMLSourceTree.compact(node.text).utf16.count
                return
            }
            node.children.forEach(walk)
        }
        if let root { walk(root) } else { supported = false }
        let recognized = root.map { MathMLSourceTree.compact($0.tokens) } ?? ""
        let units:Set<String> = ["dam","km","hm","dm","cm","mm","m"]
        let bindingAgreement = expectedBindings.count == bindings.count && zip(expectedBindings,bindings).allSatisfy { expected,actual in
            guard expected.exponent == actual.exponent,expected.baseRangeTokenUTF16[1] == actual.baseRangeTokenUTF16[1] else { return false }
            if expected.base == actual.base { return expected.baseRangeTokenUTF16 == actual.baseRangeTokenUTF16 }
            // UniMERNet can split cm² as c + m². The existing unit normalizer
            // checks/regroups that source unit; numeric coefficients never enter
            // this suffix allowance, and the full token string must still agree.
            return units.contains(expected.base) && !actual.base.isEmpty && expected.base.hasSuffix(actual.base) &&
                actual.base.allSatisfy({ $0.isASCII && $0.isLetter }) &&
                expected.baseRangeTokenUTF16[0] <= actual.baseRangeTokenUTF16[0]
        }
        let allowed = supported && expected == recognized && bindingAgreement
        return Check(version: validationVersion, allowed: allowed, source: source, expectedTokens: expected,
            recognizedTokens: recognized, expectedPowers: expectedBindings.map(\.exponent), recognizedPowers: bindings.map(\.exponent),
            expectedPowerBindings:expectedBindings,recognizedPowerBindings:bindings,
            structureSupported: supported,
            reason: allowed ? "Complete explicit OCR notation and image MathML agree, including Unicode operators, power bases and attachment positions; photo accuracy remains unassessed" :
                "Whole source/token/power-base disagreement or unsupported structure; original OCR and raw model output retained; no glyph, digit or exponent repaired")
    }
}
