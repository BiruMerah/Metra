import Foundation
#if canImport(UIKit)
import ImageIO
import UIKit
#endif

/// Split image recognition at an explicit source connector. No formula content
/// is reconstructed from OCR or from a known answer.
enum CompoundFormulaSplitter {
    static let version = "source_connector_formula_split_v2"
    struct Part: Codable {
        let rangeUTF16: [Int]
        let cropBox: PixelBox
    }
    struct Plan: Codable {
        let version: String
        let parentRegionID: String
        let observationID: String
        let connector: String
        let connectorRangeUTF16: [Int]
        let parts: [Part]
        var cropBoundaryPolicy: String? = nil
    }

    /// Snap a noisy OCR boundary to a complete, blank inter-word gap. Never cut
    /// through foreground ink, and do not accept a gap clipped by the search.
    static func whitespaceCut(inkColumns:[Bool],target:Int,radius:Int) -> Int? {
        let lower = max(0,target-radius),upper = min(inkColumns.count,target+radius+1)
        guard lower < upper else { return nil }
        var gaps:[Range<Int>] = [],start:Int?
        for x in lower..<upper {
            if !inkColumns[x],start == nil { start = x }
            if inkColumns[x],let a = start { if a > lower,x-a >= 3 { gaps.append(a..<x) };start = nil }
        }
        let best = gaps.sorted { a,b in
            a.count == b.count ? abs((a.lowerBound+a.upperBound)/2-target) < abs((b.lowerBound+b.upperBound)/2-target) : a.count > b.count
        }.first
        return best.map { ($0.lowerBound+$0.upperBound)/2 }
    }

    struct SourceCheck: Codable {
        let allowed: Bool
        let sourceAnchors: String
        let imageAnchors: String
        let limitation: String
    }
    static func check(source:String,mathML:String) -> SourceCheck {
        let tokens = MathMLSourceTree.read(mathML)?.tokens.precomposedStringWithCompatibilityMapping ?? ""
        func anchors(_ value:String) -> String {
            String(value.filter { $0.isASCII && $0.isLetter && $0 != "x" && $0 != "X" })
        }
        let expected = anchors(source),actual = anchors(tokens)
        let first = source.first { $0.isASCII && $0.isLetter }
        let allowed = !expected.isEmpty && expected == actual && tokens.first == first &&
            tokens.filter { $0 == "=" }.count == 1 && !tokens.lowercased().contains("atau")
        return SourceCheck(allowed:allowed,sourceAnchors:expected,imageAnchors:actual,
            limitation:"Explicit source range and non-x Latin anchors only; x/X in damaged OCR may denote multiplication. Numeric/fraction fidelity remains image recognition, not an OCR reconstruction.")
    }

    struct ScalarSpeech: Codable {
        let mathML: String
        let contextObservationIDs: [String]
        let derivation: String
    }
    static func scalarSpeech(mathML:String,target:PixelBox,observations:[OCRObservation]) -> ScalarSpeech? {
        let captions = observations.filter {
            $0.selectedText.localizedCaseInsensitiveContains("luas segitiga") &&
            $0.bboxPageXYXY.ymin >= target.ymin-250 && $0.bboxPageXYXY.ymax <= target.ymax
        }
        guard !captions.isEmpty,let root = MathMLSourceTree.read(mathML),MathMLSourceTree.compact(root.tokens).hasPrefix("L=") else { return nil }
        var identifiers:[MathMLSourceTree.Node] = [],operators:[String] = [],supported = true
        func visit(_ node:MathMLSourceTree.Node) {
            guard ["math","mrow","mstyle","mi","mn","mo","mfrac","mspace"].contains(node.name) else { supported = false;return }
            if node.name == "mi" { identifiers.append(node) }
            if node.name == "mo" { operators.append(node.text) }
            node.children.forEach(visit)
        }
        visit(root)
        // Uniform bold styling of the entire scalar equation, including L,
        // must not turn the scalar product into a vector cross product.
        guard supported,!identifiers.isEmpty,identifiers.allSatisfy({ ($0.attributes["mathvariant"] ?? "").contains("bold") && $0.text.allSatisfy { $0.isASCII && $0.isLetter } }),
              operators.contains("×"),operators.allSatisfy({ ["=","×","\u{2062}"].contains($0) }) else { return nil }
        identifiers.forEach { $0.attributes.removeValue(forKey:"mathvariant") }
        return ScalarSpeech(mathML:root.xml,contextObservationIDs:captions.map(\.id),
            derivation:"captioned_triangle_area_scalar_font_v1: nearby explicit Luas segitiga caption; complete L equation uniformly bold; scalar-only structure; remove font variants for speech only. Identifiers, numbers, fractions and operators unchanged; raw MathML retained.")
    }

    static func plan(region: LayoutRegion, observation: OCRObservation) -> Plan? {
        let text = observation.selectedText as NSString
        let regex = try! NSRegularExpression(pattern: #"(?i)\batau\b"#)
        let matches = regex.matches(in: observation.selectedText, range: NSRange(location:0,length:text.length))
        guard matches.count == 1, let match = matches.first, let boxes = observation.rangeBoxes,
              observation.bboxPageXYXY.intersection(region.bboxPageXYXY)/max(1,observation.bboxPageXYXY.area) >= 0.7,
              region.bboxPageXYXY.ymax-region.bboxPageXYXY.ymin <= 2.2 * (observation.bboxPageXYXY.ymax-observation.bboxPageXYXY.ymin) else { return nil }
        func glyphs(_ range:NSRange) -> [OCRRangeBox] {
            boxes.filter { box in
                let r = box.rangeUTF16
                guard r.count == 2, r[0] >= range.location, r[1] <= NSMaxRange(range), r[1] > r[0],
                      r[1] <= text.length else { return false }
                return !text.substring(with:NSRange(location:r[0],length:r[1]-r[0])).trimmingCharacters(in:.whitespaces).isEmpty
            }
        }
        let left = glyphs(NSRange(location:0,length:match.range.location))
        let middle = glyphs(match.range)
        let right = glyphs(NSRange(location:NSMaxRange(match.range),length:text.length-NSMaxRange(match.range)))
        guard let a = left.first, let b = left.last, let c = right.first, let d = right.last,
              !middle.isEmpty else { return nil }
        let ranges = [[a.rangeUTF16[0],b.rangeUTF16[1]],[c.rangeUTF16[0],d.rangeUTF16[1]]]
        guard ranges.allSatisfy({ range in
            let source = text.substring(with:NSRange(location:range[0],length:range[1]-range[0]))
            // This deliberately narrow route covers two short equations, not
            // prose with an incidental "atau" or long textual alternatives.
            return source.count <= 80 && source.filter(\.isLetter).count <= 12 &&
                source.range(of:#"[=≤≥<>]|[-−].*[xX×]"#,options:.regularExpression) != nil
        }) else { return nil }
        let leftEnd = left.map(\.bboxPageXYXY.xmax).max()!
        let connectorStart = middle.map(\.bboxPageXYXY.xmin).min()!
        let connectorEnd = middle.map(\.bboxPageXYXY.xmax).max()!
        let rightStart = right.map(\.bboxPageXYXY.xmin).min()!
        // Vision can give every character one shared box. Such a box is not a
        // safe cut point: keep the original formula for review in that case.
        guard leftEnd+1 < connectorStart, connectorEnd+1 < rightStart else { return nil }
        let y0 = min(region.bboxPageXYXY.ymin,observation.bboxPageXYXY.ymin)
        let y1 = max(region.bboxPageXYXY.ymax,observation.bboxPageXYXY.ymax)
        let x0 = min(region.bboxPageXYXY.xmin,left.map(\.bboxPageXYXY.xmin).min()!)
        let x1 = max(region.bboxPageXYXY.xmax,right.map(\.bboxPageXYXY.xmax).max()!)
        let parts = [
            Part(rangeUTF16:ranges[0],cropBox:PixelBox(xmin:x0,ymin:y0,xmax:floor((leftEnd+connectorStart)/2),ymax:y1)),
            Part(rangeUTF16:ranges[1],cropBox:PixelBox(xmin:ceil((connectorEnd+rightStart)/2),ymin:y0,xmax:x1,ymax:y1))
        ]
        return Plan(version:version,parentRegionID:region.id,observationID:observation.id,connector:text.substring(with:match.range),
            connectorRangeUTF16:[match.range.location,NSMaxRange(match.range)],parts:parts)
    }

    #if canImport(UIKit)
    static func split(regions:[LayoutRegion],observations:[OCRObservation],imageURL:URL,pageRoot:URL,pageID:String) throws -> (regions:[LayoutRegion],plans:[Plan]) {
        var output = regions, plans:[Plan] = [], retired = Set<String>()
        let candidates = regions.filter { ["formula","formula_candidate"].contains($0.label) }.sorted { $0.bboxPageXYXY.area < $1.bboxPageXYXY.area }
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL,nil),let image = CGImageSourceCreateImageAtIndex(source,0,nil) else {
            throw LayoutRuntimeError.invalid("Gambar sumber rumus tidak tersedia.")
        }
        for region in candidates where !retired.contains(region.id) {
            let matches = observations.compactMap { plan(region:region,observation:$0) }
            guard matches.count == 1, let proposed = matches.first,
                  !plans.contains(where: { $0.observationID == proposed.observationID }) else { continue }
            let y0 = max(0,Int(floor(proposed.parts[0].cropBox.ymin)))
            let y1 = min(image.height,Int(ceil(proposed.parts[0].cropBox.ymax)))
            guard y1 > y0,let band = image.cropping(to:CGRect(x:0,y:y0,width:image.width,height:y1-y0)) else { continue }
            var pixels = [UInt8](repeating:255,count:band.width*band.height)
            let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data:bytes.baseAddress,width:band.width,height:band.height,bitsPerComponent:8,
                    bytesPerRow:band.width,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else { return false }
                context.setFillColor(gray:1,alpha:1);context.fill(CGRect(x:0,y:0,width:band.width,height:band.height))
                context.draw(band,in:CGRect(x:0,y:0,width:band.width,height:band.height));return true
            }
            guard drawn else { continue }
            let ink = (0..<band.width).map { x in (0..<band.height).contains { pixels[$0*band.width+x] < 200 } }
            let radius = max(8,Int(Double(band.height)*0.35))
            guard let left = whitespaceCut(inkColumns:ink,target:Int(proposed.parts[0].cropBox.xmax),radius:radius),
                  let right = whitespaceCut(inkColumns:ink,target:Int(proposed.parts[1].cropBox.xmin),radius:radius),left < right else { continue }
            var leftBox = proposed.parts[0].cropBox,rightBox = proposed.parts[1].cropBox
            leftBox.xmax = Double(left);rightBox.xmin = Double(right)
            let plan = Plan(version:version,parentRegionID:proposed.parentRegionID,observationID:proposed.observationID,
                connector:proposed.connector,connectorRangeUTF16:proposed.connectorRangeUTF16,
                parts:[Part(rangeUTF16:proposed.parts[0].rangeUTF16,cropBox:leftBox),Part(rangeUTF16:proposed.parts[1].rangeUTF16,cropBox:rightBox)],
                cropBoundaryPolicy:"OCR connector anchor plus widest complete zero-ink column gap within 0.35 line heights; grayscale threshold 200; no glyph reconstruction")
            var children:[LayoutRegion] = []
            for (i,part) in plan.parts.enumerated() {
                let box = part.cropBox
                let rect = CGRect(x:max(0,box.xmin),y:max(0,box.ymin),width:box.xmax-max(0,box.xmin),height:box.ymax-max(0,box.ymin)).intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
                guard let crop = image.cropping(to:rect),let png = UIImage(cgImage:crop).pngData() else { throw DiagramProbeError.invalidObject }
                let id = "\(region.id).split\(i+1)"
                let path = "pages/\(pageID)/crops/\(id).png"
                try png.write(to:pageRoot.appendingPathComponent("crops/\(id).png"),options:.atomic)
                children.append(LayoutRegion(id:id,classID:-1,label:"formula_candidate",score:region.score,bboxPageXYXY:box,rawIndex:region.rawIndex*10+i,
                    parentID:region.parentID,cropArtifact:path,detectionSource:version,sourceObservationID:plan.observationID,
                    sourceRangeUTF16:part.rangeUTF16,proposalText:observations.first(where: { $0.id == plan.observationID }).map { ($0.selectedText as NSString).substring(with:NSRange(location:part.rangeUTF16[0],length:part.rangeUTF16[1]-part.rangeUTF16[0])) },roiDerivation:plan.cropBoundaryPolicy,proposalSourceIDs:[region.id],imageDetectionSource:FormulaEvidencePolicy.imageSource(region)))
            }
            // Keep the raw parent in detector artifacts and the split report.
            // Retire overlapping recognition proposals so they cannot replace
            // the same source characters a second time.
            let covered = candidates.filter { other in
                region.bboxPageXYXY.intersection(other.bboxPageXYXY)/max(1,other.bboxPageXYXY.area) >= 0.85
            }
            retired.formUnion(covered.map(\.id));retired.insert(region.id)
            output.removeAll { retired.contains($0.id) }
            output += children
            plans.append(plan)
        }
        try DiagramArtifactStore().writeJSON(plans,to:pageRoot.appendingPathComponent("formula-connector-splits.json"))
        return (output.sorted(by:LayoutMerge.precedes),plans)
    }
    #endif
}
