import Foundation
import ImageIO
import UIKit

/// Adds MFD proposals while retaining raw detectors and Vision proposals in their
/// own artifacts. Cross-model scores are never ranked against each other.
enum FormulaCropMerger {
    static let version = "supplemental_mfd_crop_merge_v2"

    struct Decision: Codable, Sendable {
        let detectionID: String
        let action: String
        let activeRegionID: String?
        let relatedRegionIDs: [String]
        let reason: String
    }

    struct Report: Codable, Sendable {
        let version: String
        let decisions: [Decision]
        let originalVisionProposalCount: Int
        let retiredVisionProposalIDs: [String]
        let activeMFDRegionIDs: [String]
        let limitations: String
    }

    static func combine(pageID: String, layout: [LayoutRegion], vision: [LayoutRegion], mfd: [LayoutRegion],
                        observations: [OCRObservation], imageURL: URL, pageRoot: URL) throws -> (regions: [LayoutRegion], report: Report) {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL,nil),
              let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw LayoutRuntimeError.invalid("Merge crop tidak dapat membaca gambar.") }
        let ppFormulas = layout.filter { $0.label == "formula" }
        var decisions: [Decision] = [], added: [LayoutRegion] = [], retired = Set<String>()
        for candidate in mfd.sorted(by: { $0.score == $1.score ? $0.rawIndex < $1.rawIndex : $0.score > $1.score }) {
            let box = candidate.bboxPageXYXY
            let ppOverlap = ppFormulas.filter { $0.bboxPageXYXY.intersection(box)/max(1,box.area) >= 0.15 }
            if let closest = ppOverlap.max(by: { $0.bboxPageXYXY.iou(box) < $1.bboxPageXYXY.iou(box) }) {
                decisions.append(.init(detectionID:candidate.id,action:"covered_or_withheld_by_existing_doclayout_roi",activeRegionID:closest.id,
                    relatedRegionIDs:ppOverlap.map(\.id),reason:"Preserve existing DocLayout formula route; overlapping MFD remains raw evidence, not a second recognition or speech. Partial overlap is not proof of semantic duplication."))
                continue
            }
            if let previous = added.first(where: { $0.bboxPageXYXY.intersection(box)/max(1,min($0.bboxPageXYXY.area,box.area)) >= 0.8 }) {
                decisions.append(.init(detectionID:candidate.id,action:"withheld_overlapping_mfd_candidate",activeRegionID:previous.id,
                    relatedRegionIDs:[previous.id],reason:"Same-model overlapping candidates share one active crop; all raw boxes retained; no semantic equivalence claim."))
                continue
            }
            let visual = DiagramSpokenService.owner(of:box,regions:layout)
            let activeVision = vision.filter { !retired.contains($0.id) }
            let overlap = activeVision.filter { $0.bboxPageXYXY.intersection(box)/max(1,min($0.bboxPageXYXY.area,box.area)) >= 0.15 }
            // Fuse only one complete explicit source proposal. A numeric fragment
            // within a known unit range may corroborate its location, but does not
            // supply a power. The entire Vision source range remains the crop.
            let supported = overlap.filter { proposal in
                guard proposal.sourceObservationID != nil, proposal.sourceRangeUTF16 != nil,
                      proposal.detectionSource == LengthUnitSource.version || proposal.detectionSource == "vision_math_expression_proposal_v1" else { return false }
                let p = proposal.bboxPageXYXY, raw = proposal.rawVisionBBox ?? p
                let near = p.intersection(box)/max(1,box.area) >= 0.80
                let whole = box.intersection(raw)/max(1,raw.area) >= 0.85 && p.iou(box) >= 0.4
                let unitPart = proposal.detectionSource == LengthUnitSource.version && near && box.area/max(1,raw.area) >= 0.15
                return near && (whole || unitPart)
            }
            if supported.count == 1, let proposal = supported.first {
                let crop = union(proposal.bboxPageXYXY,padded(box,width:image.width,height:image.height))
                if !containsExtraSourceGlyph(crop,proposal:proposal,observations:observations) {
                    var fused = try region(candidate,box:crop,parentID:proposal.parentID,source:proposal,image:image,pageID:pageID,pageRoot:pageRoot)
                    fused.proposalSourceIDs = [candidate.id,proposal.id]
                    added.append(fused); retired.insert(proposal.id)
                    decisions.append(.init(detectionID:candidate.id,action:"fused_with_explicit_vision_range",activeRegionID:fused.id,
                        relatedRegionIDs:[proposal.id],reason:"Union of MFD image box and complete Vision source crop; no extra observed source glyph introduced. Original crops retained. Image recognition and existing source checks still required."))
                } else {
                    decisions.append(.init(detectionID:candidate.id,action:"withheld_crop_would_add_source_glyphs",activeRegionID:proposal.id,
                        relatedRegionIDs:[proposal.id],reason:"MFD union would include characters outside the explicit source range; existing Vision crop retained unchanged."))
                }
                continue
            }
            if !overlap.isEmpty {
                decisions.append(.init(detectionID:candidate.id,action:"withheld_overlap_with_vision_proposals",activeRegionID:nil,
                    relatedRegionIDs:overlap.map(\.id),reason:"No unique complete source proposal can be fused safely. Preserve existing Vision routes; MFD remains review evidence."))
                continue
            }
            if visual != nil {
                decisions.append(.init(detectionID:candidate.id,action:"withheld_visual_crop_pending_validation",activeRegionID:nil,
                    relatedRegionIDs:[visual!.id],reason:"Visual-region formula integration is not validated by this text/formula pilot; raw crop retained for review."))
                continue
            }
            let hints = sourceHints(box,observations:observations)
            if hints.count == 1, let hint = hints.first, isPlainSource(hint) {
                decisions.append(.init(detectionID:candidate.id,action:"withheld_plain_source_literal",activeRegionID:nil,
                    relatedRegionIDs:[],reason:"Observed OCR source is an ordinary number, isolated letter/list marker or length-unit token (\(hint)); keep Vision text and do not send this gap crop to formula recognition."))
                continue
            }
            let parent = layout.filter { !["formula","formula_candidate"].contains($0.label) && $0.bboxPageXYXY.intersection(box)/max(1,box.area) >= 0.8 }
                .min { $0.bboxPageXYXY.area < $1.bboxPageXYXY.area }
            let addedRegion = try region(candidate,box:padded(box,width:image.width,height:image.height),parentID:parent?.id,
                                         source:nil,image:image,pageID:pageID,pageRoot:pageRoot)
            added.append(addedRegion)
            decisions.append(.init(detectionID:candidate.id,action:"added_gap_crop",activeRegionID:addedRegion.id,relatedRegionIDs:[],
                reason:"Additional image detector crop in an uncovered area. No OCR source range forced; complete image MathML/source alignment is still required for speech merge."))
        }
        let combined = (layout + vision.filter { !retired.contains($0.id) } + added).sorted(by:LayoutMerge.precedes)
        let report = Report(version:version,decisions:decisions,originalVisionProposalCount:vision.count,
                            retiredVisionProposalIDs:retired.sorted(),activeMFDRegionIDs:added.map(\.id),
                            limitations:"Conservative proposal merge, not semantic validation. Existing DocLayout routes remain authoritative in overlaps; ambiguous and visual-region MFD proposals are withheld. Raw source and all detector/proposal crops retained.")
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(report).write(to:pageRoot.appendingPathComponent("mfd-crop-merge.json"),options:.atomic)
        try encoder.encode(combined).write(to:pageRoot.appendingPathComponent("combined-formula-regions.json"),options:.atomic)
        try overlay(image,regions:combined).write(to:pageRoot.appendingPathComponent("combined-layout-overlay.png"),options:.atomic)
        return (combined,report)
    }

    private static func region(_ candidate:LayoutRegion,box:PixelBox,parentID:String?,source:LayoutRegion?,image:CGImage,
                               pageID:String,pageRoot:URL) throws -> LayoutRegion {
        let name = "\(candidate.id).combined.png"
        guard let crop = image.cropping(to:CGRect(x:box.xmin,y:box.ymin,width:box.xmax-box.xmin,height:box.ymax-box.ymin)),
              let png = UIImage(cgImage:crop).pngData() else { throw LayoutRuntimeError.invalid("Crop gabungan MFD gagal.") }
        try png.write(to:pageRoot.appendingPathComponent("crops/\(name)"),options:.atomic)
        return LayoutRegion(id:candidate.id,classID:candidate.classID,label:"formula_candidate",score:candidate.score,bboxPageXYXY:box,
            rawIndex:candidate.rawIndex,parentID:parentID,cropArtifact:"pages/\(pageID)/crops/\(name)",detectionSource:Pix2TextMFDRuntime.proposalVersion,
            sourceObservationID:source?.sourceObservationID,sourceRangeUTF16:source?.sourceRangeUTF16,proposalText:source?.proposalText,
            rawVisionBBox:source?.rawVisionBBox,roiDerivation:"\(version): original-image crop; source text/range retained when uniquely fused; no OCR symbol/power reconstruction",
            proposalSourceIDs:source.map { [candidate.id,$0.id] } ?? [candidate.id])
    }

    private static func padded(_ b:PixelBox,width:Int,height:Int) -> PixelBox {
        let h = b.ymax-b.ymin, x = max(2,h*0.05), y = max(3,h*0.25)
        return PixelBox(xmin:max(0,floor(b.xmin-x)),ymin:max(0,floor(b.ymin-y)),
                        xmax:min(Double(width),ceil(b.xmax+x)),ymax:min(Double(height),ceil(b.ymax+y)))
    }

    private static func union(_ a:PixelBox,_ b:PixelBox) -> PixelBox {
        PixelBox(xmin:min(a.xmin,b.xmin),ymin:min(a.ymin,b.ymin),xmax:max(a.xmax,b.xmax),ymax:max(a.ymax,b.ymax))
    }

    private static func containsExtraSourceGlyph(_ crop:PixelBox,proposal:LayoutRegion,observations:[OCRObservation]) -> Bool {
        guard let sourceID = proposal.sourceObservationID, let range = proposal.sourceRangeUTF16,range.count == 2 else { return true }
        for observation in observations {
            let text = observation.selectedText as NSString
            for glyph in observation.rangeBoxes ?? [] {
                guard glyph.rangeUTF16.count == 2 else { continue }
                let lo = glyph.rangeUTF16[0], hi = glyph.rangeUTF16[1]
                guard lo >= 0,hi > lo,hi <= text.length else { continue }
                if observation.id == sourceID && lo >= range[0] && hi <= range[1] { continue }
                let value = text.substring(with:NSRange(location:lo,length:hi-lo))
                if !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                   crop.intersection(glyph.bboxPageXYXY)/max(1,glyph.bboxPageXYXY.area) >= 0.5 { return true }
            }
        }
        return false
    }

    /// Source hints only veto unnecessary recognition. They never create a
    /// formula, an OCR replacement range, or a math structure.
    private static func sourceHints(_ box:PixelBox,observations:[OCRObservation]) -> [String] {
        observations.compactMap { observation in
            let text = observation.selectedText as NSString
            let touched = (observation.rangeBoxes ?? []).filter {
                $0.rangeUTF16.count == 2 && box.intersection($0.bboxPageXYXY)/max(1,min(box.area,$0.bboxPageXYXY.area)) >= 0.5
            }
            guard let lower = touched.map({$0.rangeUTF16[0]}).min(),let upper = touched.map({$0.rangeUTF16[1]}).max(),
                  lower >= 0,upper > lower,upper <= text.length else { return nil }
            return text.substring(with:NSRange(location:lower,length:upper-lower)).trimmingCharacters(in:.whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private static func isPlainSource(_ text:String) -> Bool {
        let patterns = [#"^[+-]?[0-9]+(?:[.,][0-9]+)*[.,]?$"#,
                        #"^[A-Za-z](?:[.,]\s*[A-Za-z])*[.,)]?$"#,
                        #"^(?:dam|km|hm|dm|cm|mm|m)[,.]?$"#]
        return patterns.contains { text.range(of:$0,options:.regularExpression) != nil }
    }

    private static func overlay(_ image:CGImage,regions:[LayoutRegion]) throws -> Data {
        let format = UIGraphicsImageRendererFormat();format.scale = 1
        let rendered = UIGraphicsImageRenderer(size:CGSize(width:image.width,height:image.height),format:format).image { context in
            UIImage(cgImage:image).draw(at:.zero)
            for r in regions {
                let color:UIColor = r.detectionSource == Pix2TextMFDRuntime.proposalVersion ? .systemOrange : (r.label == "formula" ? .systemRed : (r.label == "formula_candidate" ? .systemGreen : .systemBlue))
                let b = r.bboxPageXYXY
                context.cgContext.setStrokeColor(color.cgColor);context.cgContext.setLineWidth(2)
                context.cgContext.stroke(CGRect(x:b.xmin,y:b.ymin,width:b.xmax-b.xmin,height:b.ymax-b.ymin))
                let label = r.detectionSource == Pix2TextMFDRuntime.proposalVersion ? "MFD" : r.label
                ("\(label) \(String(format:"%.2f",r.score))" as NSString).draw(at:CGPoint(x:b.xmin,y:max(0,b.ymin-14)),
                    withAttributes:[.font:UIFont.systemFont(ofSize:11,weight:.bold),.foregroundColor:color,.backgroundColor:UIColor.white])
            }
        }
        guard let data = rendered.pngData() else { throw LayoutRuntimeError.invalid("Overlay gabungan gagal.") }
        return data
    }
}
