import Foundation

struct LayoutRegion: Codable, Identifiable, Sendable {
    let id: String
    let classID: Int
    let label: String
    let score: Double
    let bboxPageXYXY: PixelBox
    let rawIndex: Int
    var parentID: String?
    var cropArtifact: String?
    var detectionSource: String? = nil
    var sourceObservationID: String? = nil
    var sourceRangeUTF16: [Int]? = nil
    var proposalText: String? = nil
    var rawVisionBBox: PixelBox? = nil
    var roiDerivation: String? = nil
    var originalLayoutLabel: String? = nil
    var routingPolicy: String? = nil
    /// Raw detector/proposal IDs behind a derived recognition crop.
    var proposalSourceIDs: [String]? = nil
    /// Source validation policy survives a supplemental detector crop fusion.
    var sourceNotationPolicy: String? = nil
}

/// A photographed document can be classified as one full-page image. Recover a
/// text processing container from dense OCR evidence, preserving raw model labels.
enum DenseDocumentRegionRouter {
    static let version = "dense_document_container_v1"
    struct Decision: Codable {
        let regionID:String
        let originalLabel:String
        let areaFraction:Double
        let ocrLines:Int
        let proseLines:Int
        let letterCount:Int
        let routedAsTextContainer:Bool
    }
    struct Report: Codable {
        let version:String
        let decisions:[Decision]
        let limitation:String
    }
    static func route(regions:[LayoutRegion],observations:[OCRObservation],pageWidth:Int,pageHeight:Int) -> (regions:[LayoutRegion],report:Report) {
        var decisions:[Decision] = []
        let pageArea = max(1,Double(pageWidth)*Double(pageHeight))
        let routed = regions.map { region -> LayoutRegion in
            guard DiagramSpokenService.visualLabels.contains(region.label),region.bboxPageXYXY.area/pageArea >= 0.6 else { return region }
            let lines = observations.filter { region.bboxPageXYXY.intersection($0.bboxPageXYXY)/max(1,$0.bboxPageXYXY.area) >= 0.85 }
            let prose = lines.filter { $0.selectedText.count >= 35 && $0.selectedText.filter(\.isLetter).count >= 25 }
            let letters = lines.reduce(0) { $0 + $1.selectedText.filter(\.isLetter).count }
            let existingTextRegions = regions.filter { other in
                other.id != region.id && ["text","paragraph_title","doc_title","table"].contains(other.label) &&
                    region.bboxPageXYXY.intersection(other.bboxPageXYXY)/max(1,other.bboxPageXYXY.area) >= 0.85
            }.count
            let recover = lines.count >= 12 && prose.count >= 8 && letters >= 600 && existingTextRegions <= 1
            decisions.append(.init(regionID:region.id,originalLabel:region.label,areaFraction:region.bboxPageXYXY.area/pageArea,
                ocrLines:lines.count,proseLines:prose.count,letterCount:letters,routedAsTextContainer:recover))
            guard recover else { return region }
            return LayoutRegion(id:region.id,classID:region.classID,label:"document_text_container",score:region.score,
                bboxPageXYXY:region.bboxPageXYXY,rawIndex:region.rawIndex,parentID:region.parentID,cropArtifact:region.cropArtifact,
                detectionSource:region.detectionSource,sourceObservationID:region.sourceObservationID,sourceRangeUTF16:region.sourceRangeUTF16,
                proposalText:region.proposalText,rawVisionBBox:region.rawVisionBBox,
                roiDerivation:"Dense OCR document routing only; raw PP-DocLayout label/crop unchanged; embedded visuals not assessed",
                originalLayoutLabel:region.label,routingPolicy:version)
        }
        return (routed,.init(version:version,decisions:decisions,
            limitation:"Heuristic document-container routing, not a new layout prediction. Embedded visuals and source completeness remain unassessed."))
    }
}

struct FormulaRegion: Codable, Identifiable, Sendable {
    let id: String
    let layoutRegionID: String
    let parentID: String?
    let bboxPageXYXY: PixelBox
    let score: Double
    let cropArtifact: String?
    let sourceObservationIDs: [String]
    var route: [String]
    var status: String
    var errorCode: String?
    var latex: String?
    var mathML: String?
    var spokenText: String?
    var canonicalMathML: String? = nil
    var mathCATProfile: [String:String]? = nil
    var recognitionArtifact: String? = nil
    var latexForMathJax: String? = nil
    var failureMessage: String? = nil
    var stageResults: [ComponentResult]? = nil
    var detectionSource: String? = nil
    var recognitionBBoxPageXYXY: PixelBox? = nil
    var recognitionCropArtifact: String? = nil
    var derivations: [String]? = nil
    var sourceConsistencyStatus: String? = nil
    var sourceConsistencyMessage: String? = nil
    var spokenMergeAllowed: Bool? = nil
    var unitPowerAnchors: [UnitPowerSourceAnchor]? = nil
}

extension PixelBox {
    var area: Double { max(0, xmax - xmin) * max(0, ymax - ymin) }
    func intersection(_ other: PixelBox) -> Double {
        max(0, min(xmax, other.xmax) - max(xmin, other.xmin)) *
        max(0, min(ymax, other.ymax) - max(ymin, other.ymin))
    }
    func iou(_ other: PixelBox) -> Double {
        let overlap = intersection(other)
        return overlap / max(1, area + other.area - overlap)
    }
}

enum LayoutMerge {
    // Deterministic geometry heuristic, not a trained reading order model.
    static func precedes(_ a: LayoutRegion, _ b: LayoutRegion) -> Bool {
        if a.bboxPageXYXY.ymin != b.bboxPageXYXY.ymin { return a.bboxPageXYXY.ymin < b.bboxPageXYXY.ymin }
        if a.bboxPageXYXY.xmin != b.bboxPageXYXY.xmin { return a.bboxPageXYXY.xmin < b.bboxPageXYXY.xmin }
        return a.rawIndex < b.rawIndex
    }

    static func formulas(pageID: String, regions: [LayoutRegion], observations: [OCRObservation]) -> [FormulaRegion] {
        regions.filter { $0.label == "formula" || $0.label == "formula_candidate" }.enumerated().map { index, region in
            FormulaRegion(
                id: "\(pageID).formula.\(String(format: "%04d", index + 1))",
                layoutRegionID: region.id, parentID: region.parentID,
                bboxPageXYXY: region.bboxPageXYXY, score: region.score, cropArtifact: region.cropArtifact,
                sourceObservationIDs: observations.filter { region.bboxPageXYXY.intersection($0.bboxPageXYXY) / max(1, $0.bboxPageXYXY.area) > 0.05 }.map(\.id),
                route: [region.detectionSource ?? "pp_doclayout_l", "unimernet", "mathjax", "mathcat_id"],
                status: "unresolved", errorCode: "unimernet_checkpoint_not_resolved",
                latex: nil, mathML: nil, spokenText: nil, detectionSource: region.detectionSource ?? "pp_doclayout_l"
            )
        }
    }

    static func blocks(pageID: String, regions: [LayoutRegion], observations: [OCRObservation], formulas: [FormulaRegion] = []) -> [ExtractionBlock] {
        let resolution = FormulaSpanResolver.resolveOccurrences(observations: observations, regions: regions, formulas: formulas)
        let spans = resolution.spans
        let spansByObservation = Dictionary(grouping: spans, by: \.observationID)
        let byID=Dictionary(uniqueKeysWithValues:formulas.map{($0.id,$0)})
        var emitted=Set<String>()
        var assigned:[String:[OCRObservation]]=[:]
        var unassigned:[OCRObservation]=[]
        for observation in observations {
            let candidates=regions.filter{$0.bboxPageXYXY.intersection(observation.bboxPageXYXY)/max(1,observation.bboxPageXYXY.area)>=0.5}
            let parent=DiagramSpokenService.owner(of: observation.bboxPageXYXY, regions: regions) ?? candidates.min { $0.bboxPageXYXY.area == $1.bboxPageXYXY.area ? $0.id<$1.id : $0.bboxPageXYXY.area<$1.bboxPageXYXY.area }
            if let parent { assigned[parent.id,default:[]].append(observation) } else {unassigned.append(observation)}
        }
        var ownerByObservation: [String: String] = [:]
        for (blockID, lines) in assigned { for line in lines { ownerByObservation[line.id] = blockID } }
        for line in unassigned { ownerByObservation[line.id] = "\(pageID).unassigned.\(line.rawOrder)" }
        var segmentsByBlock: [String: [TextSegment]] = [:]
        // Resolve and emit in source order before traversing nested layout regions.
        // An empty child region can no longer claim speech before its parent text.
        for observation in observations.sorted(by: { $0.rawOrder == $1.rawOrder ? $0.id < $1.id : $0.rawOrder < $1.rawOrder }) {
                guard let blockID = ownerByObservation[observation.id] else { continue }
                var output = segmentsByBlock[blockID] ?? []
                let text=observation.selectedText
                let source=text as NSString
                let sourceSpans = (spansByObservation[observation.id] ?? []).sorted {
                    if $0.method != $1.method { return $0.method < $1.method }
                    return $0.formulaID < $1.formulaID
                }
                var units:[(start:Int,end:Int,math:String?)]=[]
                for start in text.indices {
                    let end=text.index(after:start),lower=start.utf16Offset(in:text),upper=end.utf16Offset(in:text)
                    let mathID = sourceSpans.first { lower >= $0.lower && upper <= $0.upper }?.formulaID
                    units.append((lower,upper,mathID))
                }
                var runs:[(start:Int,end:Int,math:String?)]=[]
                for unit in units {
                    if let last=runs.last,last.math==unit.math {runs[runs.count-1].end=unit.end}
                    else {runs.append((unit.start,unit.end,unit.math))}
                }
                for run in runs {
                    let raw=source.substring(with:NSRange(location:run.start,length:run.end-run.start))
                    var spoken:String?=raw
                    var status="succeeded"
                    var method: String?
                    var note: String?
                    if let mathID=run.math {
                        let first=emitted.insert(mathID).inserted
                        let mappings = spans.filter { $0.formulaID == mathID }
                        let allowed=byID[mathID]?.spokenMergeAllowed != false && mappings.allSatisfy(\.allowsSpeech)
                        spoken=first && allowed ? byID[mathID]?.spokenText : nil
                        status = !allowed ? "needs_review" : (byID[mathID]?.spokenText == nil ? "unresolved" : (first ? "spoken_generated" : "linked_to_same_formula"))
                        method = sourceSpans.first { $0.formulaID == mathID }?.method
                        note = mappings.compactMap(\.note).first
                    }
                    output.append(TextSegment(id:"\(blockID).s\(String(format:"%04d",output.count+1))",kind:run.math == nil ? "text" : "math",textRaw:raw,sourceObservationID:observation.id,sourceRangeUTF16:[run.start,run.end],status:status,spokenText:spoken,formulaID:run.math,mergeMethod:method,mergeNote:note))
                }
                segmentsByBlock[blockID] = output
        }
        var blocks=regions.sorted(by:precedes).map { region in
            let lines=assigned[region.id] ?? []
            var childrenSegments=segmentsByBlock[region.id] ?? []
            if let formula=formulas.first(where:{$0.layoutRegionID==region.id}),!emitted.contains(formula.id) {
                emitted.insert(formula.id)
                let coveredBy = resolution.coveredByFormulaIDs[formula.id]
                childrenSegments.append(TextSegment(id:"\(region.id).s\(String(format:"%04d",childrenSegments.count+1))",kind:"math",textRaw:"",sourceObservationID:nil,sourceRangeUTF16:[],status:coveredBy == nil ? "needs_review" : "duplicate_detection",spokenText:nil,formulaID:formula.id,mergeMethod:coveredBy == nil ? "unmapped_occurrence" : "nested_formula_alias",mergeNote:coveredBy == nil ? "No unambiguous OCR source range; formula retained for review and speech withheld" : "Enclosing detection decomposes exactly into disjoint child formula occurrences; retained as provenance without a second reading",coveredByFormulaIDs:coveredBy))
            }
            return ExtractionBlock(id:region.id,pageID:pageID,kind:region.label,bboxPageXYXY:region.bboxPageXYXY,readingOrder:0,parentID:region.parentID,sourceRegionIDs:[region.id]+lines.map(\.id),segments:childrenSegments,children:regions.filter{$0.parentID==region.id}.map(\.id),status:"partial",uncertainties:["Whole-occurrence alignment uses OCR ranges, MathML tokens and geometry; source fidelity and reading order require review"])
        }
        blocks += unassigned.map { observation in
            let id="\(pageID).unassigned.\(observation.rawOrder)"
            return ExtractionBlock(id:id,pageID:pageID,kind:"unclassified_vision_line",bboxPageXYXY:observation.bboxPageXYXY,readingOrder:0,parentID:nil,sourceRegionIDs:[observation.id],segments:segmentsByBlock[id] ?? [],children:[],status:"partial",uncertainties:["OCR line outside layout regions"])
        }
        let anchors=Dictionary(uniqueKeysWithValues:formulas.compactMap { formula -> (String,PixelBox)? in
            formula.recognitionBBoxPageXYXY.map{(formula.layoutRegionID,$0)}
        })
        return blocks.sorted {
            let a=anchors[$0.id] ?? $0.bboxPageXYXY,b=anchors[$1.id] ?? $1.bboxPageXYXY
            if a.ymin != b.ymin {return a.ymin<b.ymin}
            if a.xmin != b.xmin {return a.xmin<b.xmin}
            return $0.id<$1.id
        }.enumerated().map { i,b in
            ExtractionBlock(id:b.id,pageID:b.pageID,kind:b.kind,bboxPageXYXY:b.bboxPageXYXY,readingOrder:i+1,parentID:b.parentID,sourceRegionIDs:b.sourceRegionIDs,segments:b.segments,children:b.children,status:b.status,uncertainties:b.uncertainties)
        }
    }
}
