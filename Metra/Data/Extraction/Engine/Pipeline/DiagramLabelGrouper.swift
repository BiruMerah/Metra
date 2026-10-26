import Foundation

struct DiagramLabelSourcePart: Codable, Sendable {
    let labelID: String
    let observationID: String
    let rangeUTF16: [Int]
    let text: String
    let bbox: [Int]
}

struct DiagramLabelGroupingSummary: Codable, Sendable {
    let version: String
    let sourceLabelCount: Int
    let groupedLabelIDs: [String]
    let ambiguousLabelIDs: [String]
    let qualityStatus: String
}

/// Candidate line grouping only. No OCR character is corrected or discarded.
/// Each source fragment occurs once, either in a group or as a standalone label.
enum DiagramLabelGrouper {
    static let version = "spatial_label_lines_v1"

    static func group(_ labels: [DiagramSpokenInput.Label], values: [DiagramSpokenInput.Math])
        -> (labels: [DiagramSpokenInput.Label], summary: DiagramLabelGroupingSummary) {
        func valid(_ b: [Int]) -> Bool {
            b.count == 4 && b.allSatisfy { (0...1000).contains($0) } && b[0] < b[2] && b[1] < b[3]
        }
        func union(_ boxes: [[Int]]) -> [Int] {
            [boxes.map { $0[0] }.min()!, boxes.map { $0[1] }.min()!,
             boxes.map { $0[2] }.max()!, boxes.map { $0[3] }.max()!]
        }
        func canFollow(_ a: DiagramSpokenInput.Label, _ b: DiagramSpokenInput.Label) -> Bool {
            guard a.observationID != b.observationID, valid(a.bbox), valid(b.bbox),
                  a.text.filter(\.isLetter).count >= 2, b.text.filter(\.isLetter).count >= 2 else { return false }
            let x = a.bbox, y = b.bbox
            let ah = Double(x[3]-x[1]), bh = Double(y[3]-y[1]), h = min(ah,bh)
            let gap = Double(y[1]-x[3])
            guard y[1] > x[1], ah/bh >= 0.55, ah/bh <= 1.8,
                  gap >= -0.15*h, gap <= 0.9*h else { return false }
            let aw = Double(x[2]-x[0]), bw = Double(y[2]-y[0])
            guard aw/bw >= 0.3, aw/bw <= 3.0 else { return false }
            let centers = abs(Double(x[0]+x[2]-y[0]-y[2])/2) <= 0.75*h
            let leftAligned = abs(Double(x[0]-y[0])) <= 0.6*h
            let overlap = Double(min(x[2],y[2])-max(x[0],y[0]))/min(aw,bw)
            guard overlap >= 0.6, centers || leftAligned else { return false }
            let combined = union([x,y])
            // A numeric/math source between the lines is a grouping barrier.
            return !values.contains { value in
                guard valid(value.bbox) else { return false }
                let v = value.bbox, centerY = Double(v[1]+v[3])/2
                return centerY > Double(x[1]+x[3])/2 && centerY < Double(y[1]+y[3])/2 &&
                    min(v[2],combined[2]) > max(v[0],combined[0])
            }
        }
        var successors: [Int:[Int]] = [:], predecessors: [Int:[Int]] = [:]
        for a in labels.indices {
            for b in labels.indices where a != b && canFollow(labels[a],labels[b]) {
                successors[a,default:[]].append(b)
                predecessors[b,default:[]].append(a)
            }
        }
        var next: [Int:Int] = [:], previous: [Int:Int] = [:], ambiguous = Set<Int>()
        for (a, bs) in successors {
            guard bs.count == 1, let b = bs.first, predecessors[b]?.count == 1 else {
                ambiguous.insert(a); ambiguous.formUnion(bs); continue
            }
            next[a] = b; previous[b] = a
        }
        var groups: [Int:[Int]] = [:], consumed = Set<Int>()
        for start in labels.indices where previous[start] == nil {
            var chain = [start], cursor = start
            while let n = next[cursor], !chain.contains(n) { chain.append(n); cursor = n }
            guard chain.count > 1 else { continue }
            // Chains crossing another candidate's ambiguity stay fully unmerged.
            guard chain.count <= 3, chain.allSatisfy({ !ambiguous.contains($0) }) else {
                ambiguous.formUnion(chain); continue
            }
            groups[start] = chain
            consumed.formUnion(chain.dropFirst())
        }
        var result: [DiagramSpokenInput.Label] = []
        for index in labels.indices where !consumed.contains(index) {
            guard let indices = groups[index] else { result.append(labels[index]); continue }
            let members = indices.map { labels[$0] }
            let parts = members.map {
                DiagramLabelSourcePart(labelID:$0.id,observationID:$0.observationID,
                    rangeUTF16:$0.rangeUTF16,text:$0.text,bbox:$0.bbox)
            }
            let first = members[0]
            result.append(.init(id:"g_" + members.map(\.id).joined(separator:"_"),
                text:members.map { $0.text.trimmingCharacters(in:.whitespacesAndNewlines) }.joined(separator:" "),
                bbox:union(members.map(\.bbox)),observationID:first.observationID,rangeUTF16:first.rangeUTF16,
                sourceParts:parts,groupingMethod:version))
        }
        return (result,.init(version:version,sourceLabelCount:labels.count,
            groupedLabelIDs:result.filter { $0.sourceParts != nil }.map(\.id),
            ambiguousLabelIDs:ambiguous.sorted().map { labels[$0].id },qualityStatus:"not_assessed; grouped labels are review candidates"))
    }
}
