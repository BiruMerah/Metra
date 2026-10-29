import Foundation
import NaturalLanguage

/// Only presentation boundaries change. Numerical signs and model wording stay
/// intact; each bullet becomes a separate reader accessibility element.
enum FoundationImageTextLayout {
    static func format(_ text:String) -> String {
        let normalized = text.trimmingCharacters(in:.whitespacesAndNewlines)
            .replacingOccurrences(of:#"\s*•\s*"#,with:"\n• ",options:.regularExpression)
            .replacingOccurrences(of:#"(?m)^\s*[-*]\s+(?=\p{L})"#,with:"• ",options:.regularExpression)
        var lines = normalized.components(separatedBy:.newlines).map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }
        if lines.count == 1 {
            let tokenizer = NLTokenizer(unit:.sentence)
            tokenizer.setLanguage(NLLanguage(rawValue:"id"));tokenizer.string = normalized
            var sentences:[String] = []
            tokenizer.enumerateTokens(in:normalized.startIndex..<normalized.endIndex) { range,_ in
                sentences.append(String(normalized[range]).trimmingCharacters(in:.whitespacesAndNewlines));return true
            }
            if !sentences.isEmpty { lines = sentences }
        }
        return lines.enumerated().map { i,line in i == 0 || line.hasPrefix("• ") ? line : "• " + line }.joined(separator:"\n")
    }
}
