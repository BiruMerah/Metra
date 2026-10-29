import Foundation

/// Agreement for an isolated OCR letter. Presentation fonts do not change its
/// identity. Accept matching styled identifiers while preserving their original
/// MathCAT speech, including style semantics. Case changes and extra structure
/// still require review; no font, character or speech is rewritten.
enum FormulaIdentifierCheck {
    static let version = "literal_identifier_agreement_v4"
    struct Result: Codable {
        let allowed: Bool
        let message: String
    }
    static func check(mathML:String,expected:String) -> Result {
        guard expected.count == 1, expected.allSatisfy({ $0.isASCII && $0.isLetter }),
              let root = MathMLSourceTree.read(mathML) else {
            return .init(allowed:false,message:"Invalid single-letter source or MathML")
        }
        var identifiers:[String] = [],extraStructure = false
        func walk(_ node:MathMLSourceTree.Node) {
            if ["annotation","annotation-xml","mspace"].contains(node.name) { return }
            if node.name == "mi",node.children.isEmpty {
                identifiers.append(node.text.trimmingCharacters(in:.whitespacesAndNewlines));return
            }
            guard ["math","mrow","mstyle","semantics"].contains(node.name),
                  node.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
                extraStructure = true;return
            }
            node.children.forEach(walk)
        }
        walk(root)
        let allowed = identifiers == [expected] && !extraStructure
        return .init(allowed:allowed,message:allowed ?
            "Exact case-sensitive single identifier agrees with OCR; recognized font style alone does not withhold speech; original MathML and MathCAT style semantics retained" :
            "Vision proposed \(expected); UniMERNet MathML has identifiers \(identifiers), extra structure=\(extraStructure). Raw speech retained but withheld; no character or structure repaired")
    }
}
