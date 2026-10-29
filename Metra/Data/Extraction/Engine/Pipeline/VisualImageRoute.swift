import Foundation
import ImageIO
import UIKit

/// Visuals are image inputs, not OCR/formula evidence. Original detector crops
/// remain in layout.raw.json; this bounded context crop retains edge labels.
enum VisualImageRoute {
    static let version = "visual_image_only_routing_v1"
    struct CropDecision: Codable {
        let regionID:String
        let originalBox:PixelBox
        let inputBox:PixelBox
        let originalCrop:String?
        let inputCrop:String
    }
    struct Suppression: Codable {
        let regionID:String
        let visualRegionID:String
        let reason:String
    }

    static func prepare(regions:[LayoutRegion],imageURL:URL,pageRoot:URL,pageID:String) throws -> [LayoutRegion] {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL,nil),let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw DiagramProbeError.invalidObject }
        try FileManager.default.createDirectory(at:pageRoot.appendingPathComponent("visual-inputs"),withIntermediateDirectories:true)
        var decisions:[CropDecision] = []
        let prose = regions.filter { ["text","paragraph_title","doc_title","table","header","footer"].contains($0.label) && $0.bboxPageXYXY.xmax-$0.bboxPageXYXY.xmin >= Double(image.width)*0.2 }
        let output = try regions.map { source -> LayoutRegion in
            guard DiagramSpokenService.visualLabels.contains(source.label) else { return source }
            let b = source.bboxPageXYXY
            let dx = max(16,min(48,(b.xmax-b.xmin)*0.04)),dy = max(16,min(48,(b.ymax-b.ymin)*0.12))
            var box = PixelBox(xmin:max(0,floor(b.xmin-dx)),ymin:max(0,floor(b.ymin-dy)),xmax:min(Double(image.width),ceil(b.xmax+dx)),ymax:min(Double(image.height),ceil(b.ymax+dy)))
            for text in prose {
                let t = text.bboxPageXYXY
                let horizontal = min(b.xmax,t.xmax)-max(b.xmin,t.xmin)
                let vertical = min(b.ymax,t.ymax)-max(b.ymin,t.ymin)
                if horizontal > 0 {
                    if t.ymax <= b.ymin { box.ymin = min(b.ymin,max(box.ymin,t.ymax+2)) }
                    if t.ymin >= b.ymax { box.ymax = max(b.ymax,min(box.ymax,t.ymin-2)) }
                }
                if vertical > 0 {
                    if t.xmax <= b.xmin { box.xmin = min(b.xmin,max(box.xmin,t.xmax+2)) }
                    if t.xmin >= b.xmax { box.xmax = max(b.xmax,min(box.xmax,t.xmin-2)) }
                }
            }
            guard let crop = image.cropping(to:CGRect(x:box.xmin,y:box.ymin,width:box.xmax-box.xmin,height:box.ymax-box.ymin)),let png = UIImage(cgImage:crop).pngData() else { throw DiagramProbeError.invalidObject }
            let relative = "pages/\(pageID)/visual-inputs/\(source.id).png"
            try png.write(to:pageRoot.appendingPathComponent("visual-inputs/\(source.id).png"),options:.atomic)
            var region = source
            region.originalLayoutBBoxPageXYXY = b
            region.bboxPageXYXY = box
            region.cropArtifact = relative
            region.roiDerivation = "\(version): bounded original-image context margin; clamped before neighboring prose; no image reconstruction"
            decisions.append(.init(regionID:source.id,originalBox:b,inputBox:box,originalCrop:source.cropArtifact,inputCrop:relative))
            return region
        }
        try DiagramArtifactStore().writeJSON(decisions,to:pageRoot.appendingPathComponent("visual-input-crops.json"))
        return output
    }

    static func hasLargeContainer(_ regions:[LayoutRegion],width:Int,height:Int) -> Bool {
        regions.contains { DiagramSpokenService.visualLabels.contains($0.label) && $0.bboxPageXYXY.area/max(1,Double(width)*Double(height)) >= 0.6 }
    }

    static func owner(of box:PixelBox,regions:[LayoutRegion]) -> LayoutRegion? {
        let visualIDs = Set(regions.filter { DiagramSpokenService.visualLabels.contains($0.label) }.map(\.id))
        return regions.filter { visualIDs.contains($0.id) && $0.bboxPageXYXY.intersection(box)/max(1,box.area) >= 0.6 }
            .min { $0.bboxPageXYXY.area < $1.bboxPageXYXY.area }
    }

    static func maskForTextOCR(imageURL:URL,regions:[LayoutRegion],pageRoot:URL) throws -> URL {
        let visuals = regions.filter { DiagramSpokenService.visualLabels.contains($0.label) }
        guard !visuals.isEmpty else { return imageURL }
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL,nil),let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw DiagramProbeError.invalidObject }
        let format = UIGraphicsImageRendererFormat();format.scale = 1
        let masked = UIGraphicsImageRenderer(size:CGSize(width:image.width,height:image.height),format:format).image { context in
            UIImage(cgImage:image).draw(at:.zero)
            context.cgContext.setFillColor(UIColor.white.cgColor)
            for region in visuals {
                let b = region.bboxPageXYXY
                context.cgContext.fill(CGRect(x:b.xmin,y:b.ymin,width:b.xmax-b.xmin,height:b.ymax-b.ymin))
            }
        }
        let url = pageRoot.appendingPathComponent("text-ocr-input.png")
        guard let png = masked.pngData() else { throw DiagramProbeError.invalidObject }
        try png.write(to:url,options:.atomic)
        try DiagramArtifactStore().writeJSON(["policy":version,"input_artifact":url.lastPathComponent,
            "input_sha256":ImageIngestor.sha256(png),"masked_visual_ids":visuals.map(\.id),"visual_ocr_requests":0,
            "source":"Original page retained; only text OCR input is masked. Foundation receives the original unmasked visual crop."] as [String:Any],to:pageRoot.appendingPathComponent("text-ocr-routing.json"))
        return url
    }

    static func textOnly(_ ocr:VisionOCRResult,regions:[LayoutRegion]) -> VisionOCRResult {
        VisionOCRResult(observations:ocr.observations.filter { owner(of:$0.bboxPageXYXY,regions:regions) == nil },requestedLanguages:ocr.requestedLanguages,
            supportedLanguages:ocr.supportedLanguages,usesLanguageCorrection:ocr.usesLanguageCorrection,recognitionLevel:ocr.recognitionLevel,
            effectiveLanguages:ocr.effectiveLanguages,requestRevision:ocr.requestRevision)
    }

    static func excludeVisualFormulas(_ regions:[LayoutRegion],pageRoot:URL) throws -> [LayoutRegion] {
        let visuals = regions.filter { DiagramSpokenService.visualLabels.contains($0.label) }
        var suppressed:[Suppression] = []
        let output = regions.filter { region in
            guard ["formula","formula_candidate"].contains(region.label),
                  let visual = visuals.first(where:{ $0.id == region.parentID }) ?? owner(of:region.bboxPageXYXY,regions:visuals) else { return true }
            suppressed.append(.init(regionID:region.id,visualRegionID:visual.id,reason:"Visual content is described directly from image; no separate OCR/UniMERNet/MathCAT route."))
            return false
        }
        try DiagramArtifactStore().writeJSON(suppressed,to:pageRoot.appendingPathComponent("visual-formula-routing.json"))
        return output
    }
}
