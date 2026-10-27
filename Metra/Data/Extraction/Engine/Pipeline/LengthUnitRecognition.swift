import Foundation

/// A crop proposal, not a text-to-math conversion. Flattened/corrupt suffixes
/// never supply an exponent; UniMERNet must recognize that structure in the image.
struct LengthUnitSource: Codable, Sendable {
    let number: String
    let unit: String
    let explicitExponent: String?
    let rawSuffix: String

    static let version = "vision_length_unit_power_proposal_v1"
    private static let body = #"([0-9]+(?:[.,][0-9]+)*)[ \t]*(dam|km|hm|dm|cm|mm|m)[ \t]*([⁰¹²³⁴⁵⁶⁷⁸⁹]+|\^[ \t]*(?:\{[ \t]*[0-9]+[ \t]*\}|[0-9]+)|[23]|[гr'’′?]|[\p{L}\p{M}]{1,3}|-(?=[ \t]*$))"#

    static func matches(in text: String) throws -> [NSTextCheckingResult] {
        let regex = try NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])"# + body + #"(?![\p{L}\p{N}_])"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    static func parse(_ text: String) -> Self? {
        guard let regex = try? NSRegularExpression(pattern: "^" + body + "$"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let source = text as NSString
        let suffix = source.substring(with: match.range(at: 3))
        let raised = Array("⁰¹²³⁴⁵⁶⁷⁸⁹")
        let explicit: String?
        if suffix.allSatisfy({ raised.contains($0) }) {
            explicit = suffix.map { String(raised.firstIndex(of: $0)!) }.joined()
        } else if suffix.hasPrefix("^") {
            explicit = suffix.filter(\.isNumber)
        } else { explicit = nil }
        return .init(number: source.substring(with: match.range(at: 1)), unit: source.substring(with: match.range(at: 2)),
                     explicitExponent: explicit, rawSuffix: suffix)
    }
}

/// Checks a complete numeric measurement against image-recognized MathML. It
/// never strips a model token, repairs an exponent, or creates replacement speech.
final class LengthUnitImageCheck: NSObject, XMLParserDelegate {
    struct Result: Codable, Sendable {
        let version: String
        let allowed: Bool
        let source: String
        let expected: LengthUnitSource?
        let recognizedPrefix: String
        let recognizedUnit: String?
        let recognizedExponent: String?
        let recognizedSuffix: String
        let reason: String
        var structureSupported: Bool? = nil
        var structuredPowerCount: Int? = nil
    }

    private final class Node {
        let name: String
        var text = ""
        var children: [Node] = []
        init(_ name: String) { self.name = name }
        var leaf: String { text + children.map(\.leaf).joined() }
    }
    private var stack: [Node] = []
    private var roots: [Node] = []

    static func check(source: String, mathML: String) -> Result {
        let expected = LengthUnitSource.parse(source)
        let reader = LengthUnitImageCheck()
        let parser = XMLParser(data: Data(mathML.utf8))
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        let parsed = parser.parse()
        var prefix = "", suffix = "", unit: String?, exponent: String?
        var powerCount = 0, unsupported = false
        func compact(_ text: String) -> String {
            text.filter { !$0.isWhitespace && !["\u{2061}", "\u{2062}", "\u{2063}", "\u{2064}"].contains(String($0)) }
        }
        func plain(_ node: Node, leaves: Set<String>) -> Bool {
            if node.name == "mspace" { return node.children.isEmpty && node.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
            if ["mrow", "mstyle"].contains(node.name) { return node.children.allSatisfy { plain($0, leaves: leaves) } }
            if node.name == "mo" { return compact(node.leaf).isEmpty }
            return leaves.contains(node.name) && node.children.isEmpty
        }
        func walk(_ node: Node) {
            if node.name == "annotation" || node.name == "annotation-xml" { return }
            if node.name == "mspace", node.children.isEmpty, node.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return }
            if node.name == "msup" {
                powerCount += 1
                guard node.children.count == 2,
                      plain(node.children[0], leaves: ["mi", "mtext"]),
                      plain(node.children[1], leaves: ["mn"]) else { unsupported = true; return }
                unit = compact(node.children[0].leaf)
                exponent = compact(node.children[1].leaf)
                return
            }
            guard ["math", "mrow", "mstyle", "semantics", "mi", "mn", "mo", "mtext"].contains(node.name) else {
                unsupported = true; return
            }
            if ["mi", "mn", "mo", "mtext"].contains(node.name) {
                if powerCount == 0 { prefix += compact(node.leaf) }
                else { suffix += compact(node.leaf) }
                return
            }
            for child in node.children { walk(child) }
        }
        if parsed { for root in reader.roots { walk(root) } }
        let allowed = parsed && !unsupported && expected != nil && powerCount == 1 &&
            prefix == expected?.number && suffix.isEmpty && unit == expected?.unit &&
            ["2", "3"].contains(exponent ?? "") &&
            (expected?.explicitExponent == nil || exponent == expected?.explicitExponent) &&
            (!["2", "3"].contains(expected?.rawSuffix ?? "") || exponent == expected?.rawSuffix)
        return .init(version: "image_length_unit_consistency_v2", allowed: allowed, source: source, expected: expected,
                     recognizedPrefix: prefix, recognizedUnit: unit, recognizedExponent: exponent, recognizedSuffix: suffix,
                     reason: allowed ? "Whole image-recognized measurement matches the source number/unit with one structured power; no OCR power was invented; photo fidelity remains unassessed" :
                        "Withheld: number/unit mismatch, extra model token, missing/unsupported power, or explicit exponent conflict; raw model and source retained unchanged",
                     structureSupported: parsed && !unsupported, structuredPowerCount: powerCount)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = Node(elementName)
        if let parent = stack.last { parent.children.append(node) } else { roots.append(node) }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }
}

/// A typed measurement derivation with explicit provenance. Source unit letters
/// may be grouped only when the image supplies one final power and every digit,
/// unit letter and exponent agrees. A corrupt OCR suffix never supplies a power.
enum LengthUnitNormalizer {
    static let version = "source_anchored_length_unit_normalization_v1"
    struct Result: Codable, Sendable {
        let version: String
        let allowed: Bool
        let source: String
        let rawValidation: LengthUnitImageCheck.Result
        let normalizedMathML: String?
        let normalizedValidation: LengthUnitImageCheck.Result?
        let operation: String?
        let reason: String
    }

    static func normalize(source: String, mathML: String) -> Result {
        let raw = LengthUnitImageCheck.check(source: source, mathML: mathML)
        func withheld(_ reason: String) -> Result {
            .init(version: version, allowed: false, source: source, rawValidation: raw,
                  normalizedMathML: nil, normalizedValidation: nil, operation: nil, reason: reason)
        }
        guard let expected = raw.expected, raw.structureSupported == true, raw.structuredPowerCount == 1,
              let base = raw.recognizedUnit, !base.isEmpty, let exponent = raw.recognizedExponent,
              ["2", "3"].contains(exponent), raw.recognizedSuffix.isEmpty,
              expected.unit.hasSuffix(base),
              expected.explicitExponent == nil || expected.explicitExponent == exponent,
              !["2", "3"].contains(expected.rawSuffix) || expected.rawSuffix == exponent else {
            return withheld("No complete supported image power, or source exponent/unit conflict; no normalization generated")
        }
        let unitPrefix = String(expected.unit.dropLast(base.count))
        guard raw.recognizedPrefix == expected.number + unitPrefix else {
            return withheld("Image digits, separator or unit letters differ from complete source measurement; no token removed or supplied")
        }
        let normalized = "<math xmlns=\"http://www.w3.org/1998/Math/MathML\"><mrow><mn>\(expected.number)</mn><msup><mi mathvariant=\"normal\" intent=\":unit\" class=\"MathML-unit\">\(expected.unit)</mi><mn>\(exponent)</mn></msup></mrow></math>"
        let checked = LengthUnitImageCheck.check(source: source, mathML: normalized)
        guard checked.allowed else { return withheld("Derived measurement failed strict whole-unit validation") }
        return .init(version: version, allowed: true, source: source, rawValidation: raw,
                     normalizedMathML: normalized, normalizedValidation: checked,
                     operation: unitPrefix.isEmpty ? "annotate_complete_source_unit_for_mathcat" : "group_source_unit_prefix_with_image_power_base_and_annotate_unit",
                     reason: "Exact source number/separator and complete known length unit agree with all image glyphs and one structured power; unit grouping and intent are explicit derivations. Original OCR, LaTeX and MathML retained; MathCAT supplies speech.")
    }
}
