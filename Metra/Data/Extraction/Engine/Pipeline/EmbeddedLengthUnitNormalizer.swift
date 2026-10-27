import Foundation

struct UnitPowerSourceAnchor: Codable, Sendable {
    let observationID: String
    let rangeUTF16: [Int]
    let suffixRangeUTF16: [Int]
    let source: String
    let sourceSuffix: String
    let exponent: String
}

/// Normalize a complete measured quantity inside a larger image formula. Other
/// expression tokens are untouched. Geometry and exact source quantity are required.
enum EmbeddedLengthUnitNormalizer {
    static let version = "embedded_source_unit_normalization_v1"
    struct Result: Codable, Sendable {
        let version: String
        let mathML: String?
        let anchors: [UnitPowerSourceAnchor]
    }
    static func normalize(mathML:String,target:PixelBox,observations:[OCRObservation]) -> Result {
        guard let root = MathMLSourceTree.read(mathML) else { return .init(version:version,mathML:nil,anchors:[]) }
        var anchors:[UnitPowerSourceAnchor] = []
        for observation in observations {
            let ns = observation.selectedText as NSString
            for match in (try? LengthUnitSource.matches(in:observation.selectedText)) ?? [] {
                let text = ns.substring(with:match.range)
                guard let source = LengthUnitSource.parse(text) else { continue }
                let boxes = (observation.rangeBoxes ?? []).filter {
                    $0.rangeUTF16[0] >= match.range.location && $0.rangeUTF16[1] <= NSMaxRange(match.range)
                }.map(\.bboxPageXYXY)
                guard let first = boxes.first else { continue }
                let box = boxes.dropFirst().reduce(first) { PixelBox(xmin:min($0.xmin,$1.xmin),ymin:min($0.ymin,$1.ymin),xmax:max($0.xmax,$1.xmax),ymax:max($0.ymax,$1.ymax)) }
                // Vision repeats a full word/line-height box for each glyph;
                // require substantial overlap, then full-expression alignment
                // independently checks all remaining tokens and uniqueness.
                guard target.intersection(box)/max(1,box.area) >= 0.65 else { continue }
                struct Candidate { let parent:MathMLSourceTree.Node; let range:Range<Int>; let normalized:String; let exponent:String }
                var candidates:[Candidate] = []
                func visit(_ node:MathMLSourceTree.Node) {
                    guard !["annotation","annotation-xml","msup","msubsup"].contains(node.name) else { return }
                    for child in node.children { visit(child) }
                    guard ["math","mrow","mstyle"].contains(node.name), !node.children.isEmpty else { return }
                    for start in node.children.indices {
                        for end in (start+1)...min(node.children.count,start+10) {
                            let xml = "<math>" + node.children[start..<end].map(\.xml).joined() + "</math>"
                            let result = LengthUnitNormalizer.normalize(source:text,mathML:xml)
                            if result.allowed, let normalized = result.normalizedMathML, let exponent = result.normalizedValidation?.recognizedExponent {
                                candidates.append(.init(parent:node,range:start..<end,normalized:normalized,exponent:exponent))
                            }
                        }
                    }
                }
                visit(root)
                // Ignore equivalent wrappers/mspace windows, but reject distinct
                // measured occurrences. The smallest successful window owns it.
                func contains(_ node:MathMLSourceTree.Node,_ target:MathMLSourceTree.Node) -> Bool {
                    node === target || node.children.contains { contains($0,target) }
                }
                let minimal = candidates.filter { candidate in
                    !candidates.contains { other in
                        (other.parent === candidate.parent && other.range != candidate.range &&
                        other.range.lowerBound >= candidate.range.lowerBound && other.range.upperBound <= candidate.range.upperBound) ||
                        (other.parent !== candidate.parent && candidate.parent.children[candidate.range].contains { contains($0,other.parent) })
                    }
                }
                guard minimal.count == 1, let chosen = minimal.first,
                      let replacement = MathMLSourceTree.read(chosen.normalized)?.children.first else { continue }
                chosen.parent.children.replaceSubrange(chosen.range,with:[replacement])
                let suffixStart = NSMaxRange(match.range) - source.rawSuffix.utf16.count
                anchors.append(.init(observationID:observation.id,rangeUTF16:[match.range.location,NSMaxRange(match.range)],
                    suffixRangeUTF16:[suffixStart,NSMaxRange(match.range)],source:text,sourceSuffix:source.rawSuffix,exponent:chosen.exponent))
            }
        }
        return .init(version:version,mathML:anchors.isEmpty ? nil : root.xml,anchors:anchors)
    }
}
