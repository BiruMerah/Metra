import Foundation
import ImageIO
import UIKit

// A separate, explicit proposal source for gaps observed in the layout pilot.
// No reference answer or page-specific vocabulary enters this code.
enum OCRMathROIProposer {
    static func propose(pageID:String, observations:[OCRObservation], layout:[LayoutRegion], imageURL:URL, pageRoot:URL) throws -> [LayoutRegion] {
        guard let source=CGImageSourceCreateWithURL(imageURL as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { throw FormulaRecognitionError.failed("Proposal ROI tidak dapat membaca halaman") }
        let pattern=#"(?<![\p{L}\p{N}_])[A-Za-z](?![\p{L}\p{N}_])|\(\s*[-+]?\d[\d.,]*(?:\s*[,;]\s*[-+]?\d[\d.,]*)+\s*\)"#
        let regex=try NSRegularExpression(pattern:pattern)
        let visualNumbers = try NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])[-+]?\d+(?:[.,]\d+)?(?:\s*[°º%*])?(?![\p{L}\p{N}_])"#)
        let wholeNumeric = try NSRegularExpression(pattern: #"(?s)^.+$"#)
        // These patterns propose image crops only; they never manufacture LaTeX.
        let number = #"[0-9]+(?:[.,][0-9]+)?"#
        let power = #"(?:[⁰¹²³⁴⁵⁶⁷⁸⁹]+|\s*\^\s*(?:\{\s*[+-]?[0-9]+\s*\}|[+-]?[0-9]+)|[ \t]*[0-9]+|['’′?%⅓⅔])?"#
        let variable = "(?:\(number))?[A-Za-z]\(power)"
        let term = "(?:\(variable)|\(number))"
        let expressionRegex = try NSRegularExpression(pattern:"(?<![\\p{L}\\p{N}_])\(term)(?:\\s*[+−=\\-]\\s*\(term))*(?![\\p{L}\\p{N}_])")
        var proposed:[LayoutRegion]=[]
        for observation in observations {
            let text=observation.selectedText as NSString
            let isVisual = DiagramSpokenService.owner(of:observation.bboxPageXYXY,regions:layout) != nil
            let numericMatches: [NSTextCheckingResult]
            if isVisual, VisualNumericLiteral.looksNumeric(text as String) {
                numericMatches = wholeNumeric.matches(in:text as String,range:NSRange(location:0,length:text.length))
            } else { numericMatches = isVisual ? visualNumbers.matches(in:text as String,range:NSRange(location:0,length:text.length)) : [] }
            // Prefer the complete quantity over a unit-only crop. This retains
            // numeric context and prevents a clipped neighbouring digit becoming
            // an extra model token before m². Corrupt suffixes only propose crops.
            let unitMatches: [NSTextCheckingResult] = isVisual ? [] : (try LengthUnitSource.matches(in: text as String))
            let expressionMatches = isVisual ? [] : expressionRegex.matches(in:text as String,range:NSRange(location:0,length:text.length)).filter { expression in
                let value = text.substring(with:expression.range)
                return value.count > 1 && value.count <= 160 && value.rangeOfCharacter(from:.letters) != nil &&
                    !unitMatches.contains { unit in NSIntersectionRange(unit.range, expression.range).length > 0 }
            }
            let otherMatches = (regex.matches(in:text as String,range:NSRange(location:0,length:text.length)) + numericMatches).filter { other in
                !expressionMatches.contains { NSIntersectionRange($0.range,other.range).length > 0 } &&
                    !unitMatches.contains { NSIntersectionRange($0.range,other.range).length > 0 }
            }
            let matches = unitMatches + expressionMatches + otherMatches
            for match in matches {
                let visualNumeric = numericMatches.contains { $0.range == match.range }
                let expression = expressionMatches.contains { $0.range == match.range }
                let lengthUnit = unitMatches.contains { $0.range == match.range }
                let ranges=(observation.rangeBoxes ?? []).filter { $0.rangeUTF16[0]>=match.range.location && $0.rangeUTF16[1]<=NSMaxRange(match.range) }
                guard let first=ranges.first else {continue}
                let box=ranges.dropFirst().reduce(first.bboxPageXYXY) { a,b in PixelBox(xmin:min(a.xmin,b.bboxPageXYXY.xmin),ymin:min(a.ymin,b.bboxPageXYXY.ymin),xmax:max(a.xmax,b.bboxPageXYXY.xmax),ymax:max(a.ymax,b.bboxPageXYXY.ymax)) }
                guard box.area>0,(visualNumeric || expression || lengthUnit || box.xmax-box.xmin <= (observation.bboxPageXYXY.xmax-observation.bboxPageXYXY.xmin)*0.8) else {continue}
                let candidateText=text.substring(with:match.range)
                if !visualNumeric,candidateText.count==1,box.xmax-box.xmin>1.5*(box.ymax-box.ymin) {continue}
                if layout.contains(where:{$0.label=="formula" && $0.bboxPageXYXY.intersection(box)/max(1,box.area)>=0.15}) {continue}
                if proposed.contains(where:{$0.bboxPageXYXY.iou(box)>0.8}) {continue}
                let id="\(pageID).ocrmath.\(observation.rawOrder).\(match.range.location)"
                let refined=(!visualNumeric && candidateText.count==1) ? (tightenGlyph(box,image:image) ?? box) : box
                let margin = visualNumeric || expression ? max(3,(refined.ymax-refined.ymin)*0.25) : 1
                let horizontalMargin = lengthUnit ? max(2, (refined.ymax-refined.ymin)*0.05) : margin
                let verticalMargin = lengthUnit ? max(3, (refined.ymax-refined.ymin)*0.25) : margin
                let padded=PixelBox(xmin:max(0,floor(refined.xmin-horizontalMargin)),ymin:max(0,floor(refined.ymin-verticalMargin)),xmax:min(Double(image.width),ceil(refined.xmax+horizontalMargin)),ymax:min(Double(image.height),ceil(refined.ymax+verticalMargin)))
                guard let crop=image.cropping(to:CGRect(x:padded.xmin,y:padded.ymin,width:padded.xmax-padded.xmin,height:padded.ymax-padded.ymin)),let png=UIImage(cgImage:crop).pngData() else {continue}
                try png.write(to:pageRoot.appendingPathComponent("crops/\(id).png"),options:.atomic)
                let parent=layout.filter{$0.label != "formula" && $0.bboxPageXYXY.intersection(box)/max(1,box.area)>=0.8}.min{$0.bboxPageXYXY.area<$1.bboxPageXYXY.area}
                let proposalSource = lengthUnit ? LengthUnitSource.version : (visualNumeric ? "vision_visual_numeric_proposal_v2" : (expression ? "vision_math_expression_proposal_v1" : "vision_range_math_proposal_v1"))
                let derivation = lengthUnit ? "Whole numeric quantity plus known length-unit OCR range; corrupt/flattened suffix is a crop hint only; no inferred exponent; horizontal margin max(2px,0.05*height), vertical margin max(3px,0.25*height); original source range retained" : (expression ? "Whole OCR math-expression character-box union; no largest-glyph tightening; margin max(3px, 0.25 * target height); image recognition required, no inferred power" : ((!visualNumeric && candidateText.count==1) ? "largest connected foreground glyph; retain vertically aligned components (i/j dots); one pixel padding; original Vision range retained" : (visualNumeric ? "valid Vision character box union; numeric margin max(3px, 0.25 * target height); source glyph bbox retained" : "valid Vision character box union; one pixel padding")))
                proposed.append(LayoutRegion(id:id,classID:-1,label:"formula_candidate",score:Double(observation.candidates.first?.confidence ?? 0),bboxPageXYXY:padded,rawIndex:300+observation.rawOrder*1000+match.range.location,parentID:parent?.id,cropArtifact:"pages/\(pageID)/crops/\(id).png",detectionSource:proposalSource,sourceObservationID:observation.id,sourceRangeUTF16:[match.range.location,NSMaxRange(match.range)],proposalText:text.substring(with:match.range),rawVisionBBox:box,roiDerivation:derivation))
            }
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(proposed).write(to:pageRoot.appendingPathComponent("formula-roi-proposals.raw.json"),options:.atomic)
        return proposed
    }
    private static func tightenGlyph(_ box:PixelBox,image:CGImage) -> PixelBox? {
        let rect=CGRect(x:floor(box.xmin),y:floor(box.ymin),width:ceil(box.xmax)-floor(box.xmin),height:ceil(box.ymax)-floor(box.ymin))
        guard let crop=image.cropping(to:rect) else {return nil}
        let w=crop.width,h=crop.height
        guard w>0,h>0,w*h<100000 else {return nil}
        var bytes=[UInt8](repeating:255,count:w*h)
        let ok=bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx=CGContext(data:raw.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else {return false}
            ctx.setFillColor(gray:1,alpha:1);ctx.fill(CGRect(x:0,y:0,width:w,height:h));ctx.draw(crop,in:CGRect(x:0,y:0,width:w,height:h));return true
        }
        guard ok,let low=bytes.min(),let high=bytes.max(),high>low else {return nil}
        var seen=[Bool](repeating:false,count:bytes.count)
        var components:[(area:Int,x0:Int,y0:Int,x1:Int,y1:Int)]=[]
        func foreground(_ i:Int)->Bool {Double(Int(bytes[i])-Int(low))/Double(Int(high)-Int(low))*255<200}
        for seed in bytes.indices where !seen[seed] && foreground(seed) {
            var queue=[seed],head=0,x0=seed%w,y0=seed/w,x1=x0+1,y1=y0+1
            seen[seed]=true
            while head<queue.count {
                let i=queue[head];head+=1;let x=i%w,y=i/w
                x0=min(x0,x);y0=min(y0,y);x1=max(x1,x+1);y1=max(y1,y+1)
                for dy in -1...1 {for dx in -1...1 {
                    let nx=x+dx,ny=y+dy
                    if nx>=0,nx<w,ny>=0,ny<h {
                        let next=ny*w+nx
                        if !seen[next],foreground(next) {seen[next]=true;queue.append(next)}
                    }
                }}
            }
            components.append((queue.count,x0,y0,x1,y1))
        }
        guard let largest=components.max(by:{$0.area<$1.area}),largest.area>=4 else {return nil}
        let aligned=components.filter { component in
            component.area>=max(2,largest.area/12) && min(component.x1,largest.x1)-max(component.x0,largest.x0)>0
        }
        let x0=aligned.map(\.x0).min() ?? largest.x0,y0=aligned.map(\.y0).min() ?? largest.y0
        let x1=aligned.map(\.x1).max() ?? largest.x1,y1=aligned.map(\.y1).max() ?? largest.y1
        return PixelBox(xmin:Double(rect.minX)+Double(x0),ymin:Double(rect.minY)+Double(y0),xmax:Double(rect.minX)+Double(x1),ymax:Double(rect.minY)+Double(y1))
    }

}
