import Foundation

enum SourceHeadingPath {
    static func title(_ headings:[String]) -> String? {
        let joined = headings.map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.joined(separator:" — ")
        return !joined.isEmpty && joined.count <= 160 && !joined.contains("\n") ? joined : nil
    }
}
