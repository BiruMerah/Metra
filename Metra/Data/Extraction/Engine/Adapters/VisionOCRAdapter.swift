import Foundation
import Dispatch
import ImageIO
import Vision

struct VisionOCRResult: Codable, Sendable {
    let observations: [OCRObservation]
    let requestedLanguages: [String]
    let supportedLanguages: [String]
    let usesLanguageCorrection: Bool
    let recognitionLevel: String
    var effectiveLanguages: [String]? = nil
    var requestRevision: Int? = nil
}

enum VisionOCRAdapter {
    private static let requestLane = DispatchQueue(label: "org.metrapoc.vision-request-lane", qos: .userInitiated)

    static func recognize(imageURL: URL, pageID: String) async throws -> VisionOCRResult {
        try await Task.detached(priority: .userInitiated) {
            try requestLane.sync { try perform(imageURL: imageURL, pageID: pageID) }
        }.value
    }

    private static func perform(imageURL: URL, pageID: String) throws -> VisionOCRResult {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw VisionOCRError.cannotDecodeImage
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let desired = ["id-ID", "en-US"]
        let effective = desired.filter { supported.contains($0) }
        request.recognitionLanguages = effective
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let observations = (request.results ?? []).enumerated().map { index, observation in
            let box = observation.boundingBox
            let pixelBox = PixelBox(
                xmin: Double(box.minX * CGFloat(image.width)),
                ymin: Double((1 - box.maxY) * CGFloat(image.height)),
                xmax: Double(box.maxX * CGFloat(image.width)),
                ymax: Double((1 - box.minY) * CGFloat(image.height))
            )
            let candidates = observation.topCandidates(5).map {
                OCRCandidate(text: $0.string, confidence: $0.confidence)
            }
            var rangeBoxes: [OCRRangeBox] = []
            if let best = observation.topCandidates(1).first {
                let text = best.string
                for start in text.indices {
                    let end = text.index(after:start)
                    if let rectangle = try? best.boundingBox(for:start..<end) {
                        let b = rectangle.boundingBox
                        let charBox=PixelBox(xmin:Double(b.minX*CGFloat(image.width)),ymin:Double((1-b.maxY)*CGFloat(image.height)),xmax:Double(b.maxX*CGFloat(image.width)),ymax:Double((1-b.minY)*CGFloat(image.height)))
                        guard charBox.area>0,charBox.intersection(pixelBox)/max(1,charBox.area)>=0.8 else {continue}
                        rangeBoxes.append(OCRRangeBox(rangeUTF16:[start.utf16Offset(in:text),end.utf16Offset(in:text)],bboxPageXYXY:PixelBox(xmin:Double(b.minX*CGFloat(image.width)),ymin:Double((1-b.maxY)*CGFloat(image.height)),xmax:Double(b.maxX*CGFloat(image.width)),ymax:Double((1-b.minY)*CGFloat(image.height)))))
                    }
                }
            }
            return OCRObservation(
                id: "\(pageID).ocr.\(String(format: "%04d", index + 1))",
                rawOrder: index + 1,
                bboxPageXYXY: pixelBox,
                candidates: candidates,
                rangeBoxes: rangeBoxes
            )
        }

        return VisionOCRResult(
            observations: observations,
            requestedLanguages: desired,
            supportedLanguages: supported,
            usesLanguageCorrection: false,
            recognitionLevel: "accurate",
            effectiveLanguages: effective,
            requestRevision: request.revision
        )
    }
}

enum VisionOCRError: LocalizedError {
    case cannotDecodeImage
    var errorDescription: String? { "Vision tidak dapat mendekode halaman kerja." }
}

extension VisionOCRAdapter {
    /// Additional requests on small visual crops. Original page OCR stays immutable;
    /// the selected working view and every replacement are separately recorded.
    static func refineVisuals(_ page: VisionOCRResult, regions: [LayoutRegion], pageID: String, pageRoot: URL) async throws -> (VisionOCRResult,Int) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(page).write(to:pageRoot.appendingPathComponent("ocr.page.raw.json"),options:.atomic)
        guard regions.contains(where: { DiagramSpokenService.visualLabels.contains($0.label) }) else { return (page,0) }
        var selected = page.observations
        var selections: [[String:Any]] = []
        var requests = 0
        for region in regions.filter({ DiagramSpokenService.visualLabels.contains($0.label) }).sorted(by:LayoutMerge.precedes) {
            try Task.checkCancellation()
            guard let cropArtifact = region.cropArtifact else { continue }
            let crop = pageRoot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(cropArtifact)
            let cropOCR = try await recognize(imageURL:crop,pageID:region.id)
            requests += 1
            let directory = pageRoot.appendingPathComponent("visual-ocr",isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try encoder.encode(cropOCR).write(to:directory.appendingPathComponent("\(region.id).raw.json"),options:.atomic)
            guard !cropOCR.observations.isEmpty else {
                selections.append(["region_id":region.id,"selection":"page_ocr_retained_crop_empty"]); continue
            }
            func translated(_ box: PixelBox) -> PixelBox {
                PixelBox(xmin:box.xmin+region.bboxPageXYXY.xmin,ymin:box.ymin+region.bboxPageXYXY.ymin,
                         xmax:box.xmax+region.bboxPageXYXY.xmin,ymax:box.ymax+region.bboxPageXYXY.ymin)
            }
            let transformed = cropOCR.observations.map { observation in
                OCRObservation(id:observation.id,rawOrder:observation.rawOrder,bboxPageXYXY:translated(observation.bboxPageXYXY),candidates:observation.candidates,
                    rangeBoxes:observation.rangeBoxes?.map { OCRRangeBox(rangeUTF16:$0.rangeUTF16,bboxPageXYXY:translated($0.bboxPageXYXY)) })
            }.filter { DiagramSpokenService.owner(of:$0.bboxPageXYXY,regions:regions)?.id == region.id }
            guard !transformed.isEmpty else { continue }
            let replaced = selected.filter { DiagramSpokenService.owner(of:$0.bboxPageXYXY,regions:regions)?.id == region.id }
            selected.removeAll { DiagramSpokenService.owner(of:$0.bboxPageXYXY,regions:regions)?.id == region.id }
            selected += transformed
            selections.append(["region_id":region.id,"selection":"crop_request_for_visual_labels",
                "replaced_page_observation_ids":replaced.map(\.id),"selected_crop_observation_ids":transformed.map(\.id),
                "crop_origin_page_xy":[region.bboxPageXYXY.xmin,region.bboxPageXYXY.ymin],
                "reason":"dedicated visual crop request reduces small-label loss; no text correction or Qwen transcription"])
        }
        selected = selected.sorted {
            if $0.bboxPageXYXY.ymin != $1.bboxPageXYXY.ymin { return $0.bboxPageXYXY.ymin < $1.bboxPageXYXY.ymin }
            if $0.bboxPageXYXY.xmin != $1.bboxPageXYXY.xmin { return $0.bboxPageXYXY.xmin < $1.bboxPageXYXY.xmin }
            return $0.id < $1.id
        }.enumerated().map { i,o in OCRObservation(id:o.id,rawOrder:i+1,bboxPageXYXY:o.bboxPageXYXY,candidates:o.candidates,rangeBoxes:o.rangeBoxes) }
        let log: [String:Any] = ["version":"visual_crop_vision_selection_v1","page_raw_artifact":"pages/\(pageID)/ocr.page.raw.json",
            "working_artifact":"pages/\(pageID)/ocr.raw.json","requests":requests,"selections":selections,
            "coverage_scope":"selected working observations only; replaced full-page observations remain in immutable page raw artifact"]
        try JSONSerialization.data(withJSONObject:log,options:[.prettyPrinted,.sortedKeys]).write(to:pageRoot.appendingPathComponent("ocr-selection.json"),options:.atomic)
        return (VisionOCRResult(observations:selected,requestedLanguages:page.requestedLanguages,supportedLanguages:page.supportedLanguages,
            usesLanguageCorrection:page.usesLanguageCorrection,recognitionLevel:page.recognitionLevel,
            effectiveLanguages:page.effectiveLanguages,requestRevision:page.requestRevision),requests)
    }
}

// Literal numeric labels only. This parser creates presentation MathML, never
// speech, inferred units, corrections, arithmetic or a replacement OCR engine.
struct VisualNumericLiteral: Codable, Sendable {
    let raw: String
    let number: String
    let unit: String
    static func parse(_ raw: String) -> Self? {
        let pattern = #"^\s*([+-]?[0-9]+(?:[.,][0-9]{1,2})?)\s*([°º%]?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern:pattern),
              let match = regex.firstMatch(in:raw,range:NSRange(raw.startIndex...,in:raw)),
              match.range.length == raw.utf16.count else { return nil }
        let text = raw as NSString
        return .init(raw:raw,number:text.substring(with:match.range(at:1)),unit:text.substring(with:match.range(at:2)))
    }
    static func looksNumeric(_ text:String) -> Bool {
        let allowed = CharacterSet(charactersIn:"0123456789+-., °º%*ЗОOIl\n\t")
        return text.count <= 14 && text.rangeOfCharacter(from:.decimalDigits) != nil && text.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
    var key: String { number + (unit == "º" ? "°" : unit) }
    var mathML: String {
        var n = number
        var sign = ""
        if n.first == "-" || n.first == "+" { sign = "<mo>\(n.removeFirst() == "-" ? "−" : "+")</mo>" }
        let value = "<mn>\(n)</mn>"
        let body: String
        if unit == "°" || unit == "º" { body = sign + "<msup>\(value)<mo>°</mo></msup>" }
        else { body = sign + value + (unit == "%" ? "<mo>%</mo>" : "") }
        return "<math xmlns=\"http://www.w3.org/1998/Math/MathML\"><mrow>\(body)</mrow></math>"
    }
}

struct VisualNumericEvidence: Codable, Sendable {
    let version: String
    let originalObservationID: String
    let originalText: String
    let selectedText: String
    let readings: [String]
    let consistent: Bool
    let reason: String
    let artifact: String
    var readingObservationIDs:[String]? = nil
    var contextArtifact:String? = nil
    var readingDetails: [VisualNumericReading]? = nil

    /// Eligibility is based on the recorded corroborating reads, including units.
    /// The confidence of the retained native observation is not a second gate.
    func mergeDecision(selectedLiteral: VisualNumericLiteral) -> VisualNumericMergeDecision {
        func decision(_ allowed: Bool, _ reason: String) -> VisualNumericMergeDecision {
            .init(version: "numeric_corroboration_merge_v2", allowed: allowed,
                  reason: reason, evidenceArtifact: artifact)
        }
        guard version == "visual_numeric_ocr_agreement_v2", let details = readingDetails else {
            return decision(false, "Detailed OCR corroboration unavailable; legacy evidence is not automatically promoted")
        }
        guard consistent, VisualNumericLiteral.parse(selectedText)?.key == selectedLiteral.key else {
            return decision(false, "Selected literal does not match consistent recorded OCR evidence")
        }
        if let original = VisualNumericLiteral.parse(originalText), original.key != selectedLiteral.key {
            return decision(false, "A different valid original literal cannot be outvoted")
        }
        let valid = details.compactMap { read -> (VisualNumericReading, VisualNumericLiteral)? in
            guard let literal = VisualNumericLiteral.parse(read.text) else { return nil }
            return (read, literal)
        }
        guard !valid.isEmpty, valid.allSatisfy({ $0.1.key == selectedLiteral.key }) else {
            return decision(false, "Conflicting numeric value or unit in recorded OCR reads")
        }
        let confident = valid.filter { $0.0.confidence.isFinite && $0.0.confidence >= 0.8 }
        guard Set(confident.map { $0.0.observationID }).count >= 2 else {
            return decision(false, "Fewer than two distinct confident OCR readings corroborate the selected literal")
        }
        return decision(true, "Two or more distinct confidence>=0.8 reads agree with the selected literal and unit; no valid conflict. Reads share source pixels; photo accuracy remains unassessed")
    }
}

struct VisualNumericReading: Codable, Sendable {
    let observationID: String
    let text: String
    let confidence: Float
}

struct VisualNumericMergeDecision: Codable, Sendable {
    let version: String
    let allowed: Bool
    let reason: String
    let evidenceArtifact: String
}

extension VisionOCRAdapter {
    /// Bounded recovery: two recorded OCR variants per numeric-looking observation.
    /// A different valid number is never silently outvoted. All valid readings must
    /// agree, and at least two confident readings are required for merge eligibility.
    static func refineNumericLabels(_ input: VisionOCRResult, regions:[LayoutRegion], pageID:String, pageRoot:URL) async throws -> (VisionOCRResult,Int) {
        guard let source=CGImageSourceCreateWithURL(pageRoot.appendingPathComponent("normalized.png") as CFURL,nil),
              let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { throw VisionOCRError.cannotDecodeImage }
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(input).write(to:pageRoot.appendingPathComponent("ocr.visual-selected.raw.json"),options:.atomic)
        var selected:[OCRObservation]=[], requests=0
        var logs:[VisualNumericEvidence]=[]
        var contextual:[String:[OCRObservation]]=[:]
        // Keep the surrounding chart as another OCR observation source. Tiny
        // isolated labels sometimes disappear entirely from Vision requests.
        for region in regions where DiagramSpokenService.visualLabels.contains(region.label) {
            guard input.observations.contains(where:{ VisualNumericLiteral.looksNumeric($0.selectedText) && DiagramSpokenService.owner(of:$0.bboxPageXYXY,regions:regions)?.id == region.id }),
                  let path=region.cropArtifact,
                  let cgSource=CGImageSourceCreateWithURL(pageRoot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(path) as CFURL,nil),
                  let crop=CGImageSourceCreateImageAtIndex(cgSource,0,nil),crop.width<=1008,crop.height<=1008 else { continue }
            try Task.checkCancellation()
            let scale=3, w=crop.width*scale,h=crop.height*scale
            guard let ctx=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.interpolationQuality = .high;ctx.draw(crop,in:CGRect(x:0,y:0,width:w,height:h))
            guard let scaled=ctx.makeImage() else { continue }
            let dir=pageRoot.appendingPathComponent("numeric-ocr-context/\(region.id)",isDirectory:true)
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            let url=dir.appendingPathComponent("scaled-3x.png")
            guard let dst=CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil) else { continue }
            CGImageDestinationAddImage(dst,scaled,nil);guard CGImageDestinationFinalize(dst) else { continue }
            let output=try await recognize(imageURL:url,pageID:"\(region.id).numeric-context")
            requests += 1
            try encoder.encode(output).write(to:dir.appendingPathComponent("ocr.raw.json"),options:.atomic)
            let originX=floor(region.bboxPageXYXY.xmin),originY=floor(region.bboxPageXYXY.ymin)
            func mapped(_ b:PixelBox)->PixelBox { .init(xmin:originX+b.xmin/3,ymin:originY+b.ymin/3,xmax:originX+b.xmax/3,ymax:originY+b.ymax/3) }
            contextual[region.id]=output.observations.map { o in .init(id:o.id,rawOrder:o.rawOrder,bboxPageXYXY:mapped(o.bboxPageXYXY),candidates:o.candidates,rangeBoxes:o.rangeBoxes?.map { .init(rangeUTF16:$0.rangeUTF16,bboxPageXYXY:mapped($0.bboxPageXYXY)) }) }
            try JSONSerialization.data(withJSONObject:["source_artifact":path,"scale":3,"contrast":1,"crop_origin_page_xy":[originX,originY]],options:[.prettyPrinted,.sortedKeys]).write(to:dir.appendingPathComponent("transform.json"),options:.atomic)
        }
        for original in input.observations {
            guard VisualNumericLiteral.looksNumeric(original.selectedText),
                  let owner=DiagramSpokenService.owner(of:original.bboxPageXYXY,regions:regions) else { selected.append(original); continue }
            try Task.checkCancellation()
            let prefix="pages/\(pageID)/numeric-ocr/\(original.id)"
            let dir=pageRoot.appendingPathComponent("numeric-ocr/\(original.id)",isDirectory:true)
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            let box=original.bboxPageXYXY, height=max(1,box.ymax-box.ymin)
            let cropBox=PixelBox(xmin:max(0,floor(box.xmin-max(3,height*0.5))),ymin:max(0,floor(box.ymin-max(3,height*0.25))),
                xmax:min(Double(image.width),ceil(box.xmax+max(3,height*0.5))),ymax:min(Double(image.height),ceil(box.ymax+max(3,height*0.25))))
            guard let crop=image.cropping(to:CGRect(x:cropBox.xmin,y:cropBox.ymin,width:cropBox.xmax-cropBox.xmin,height:cropBox.ymax-cropBox.ymin)) else { selected.append(original); continue }
            var reads:[OCRObservation]=[original]
            let contextMatches=(contextual[owner.id] ?? []).filter { o in
                VisualNumericLiteral.looksNumeric(o.selectedText) && o.bboxPageXYXY.intersection(box)/max(1,min(box.area,o.bboxPageXYXY.area))>=0.5
            }
            if contextMatches.count == 1,let context=contextMatches.first { reads.append(context) }
            for (name,scale,contrast) in [("padded",1,1.0),("scaled-contrast",3,1.15)] {
                let pad=8*scale, w=crop.width*scale+pad*2, h=crop.height*scale+pad*2
                var bytes=[UInt8](repeating:255,count:w*h)
                let generated:CGImage?=bytes.withUnsafeMutableBytes { raw in
                    guard let ctx=CGContext(data:raw.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else { return nil }
                    ctx.interpolationQuality = .high
                    ctx.draw(crop,in:CGRect(x:pad,y:pad,width:crop.width*scale,height:crop.height*scale))
                    let buffer=raw.bindMemory(to:UInt8.self)
                    for i in buffer.indices { buffer[i]=UInt8(max(0,min(255,(Double(buffer[i])-127.5)*contrast+127.5))) }
                    return ctx.makeImage()
                }
                guard let generated else { continue }
                let url=dir.appendingPathComponent("\(name).png")
                guard let destination=CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil) else { continue }
                CGImageDestinationAddImage(destination,generated,nil)
                guard CGImageDestinationFinalize(destination) else { continue }
                let result=try await recognize(imageURL:url,pageID:"\(original.id).\(name)")
                requests += 1
                try encoder.encode(result).write(to:dir.appendingPathComponent("\(name).raw.json"),options:.atomic)
                let transform:[String:Any]=["crop_bbox_page_xyxy":cropBox.array,"scale":scale,"white_border_px":pad,"contrast":contrast,"source":"normalized.png","interpolation":"high","detail_reconstruction":false]
                try JSONSerialization.data(withJSONObject:transform,options:[.prettyPrinted,.sortedKeys]).write(to:dir.appendingPathComponent("\(name).transform.json"),options:.atomic)
                let nonempty=result.observations.filter { !$0.selectedText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
                guard nonempty.count == 1, let read=nonempty.first else { continue }
                func translated(_ b:PixelBox)->PixelBox {
                    PixelBox(xmin:cropBox.xmin+(b.xmin-Double(pad))/Double(scale),ymin:cropBox.ymin+(b.ymin-Double(pad))/Double(scale),
                        xmax:cropBox.xmin+(b.xmax-Double(pad))/Double(scale),ymax:cropBox.ymin+(b.ymax-Double(pad))/Double(scale))
                }
                let mapped=translated(read.bboxPageXYXY)
                guard DiagramSpokenService.owner(of:mapped,regions:regions)?.id == owner.id,
                      mapped.intersection(box)/max(1,box.area)>=0.5 else { continue }
                reads.append(OCRObservation(id:read.id,rawOrder:original.rawOrder,bboxPageXYXY:mapped,candidates:read.candidates,
                    rangeBoxes:read.rangeBoxes?.map { .init(rangeUTF16:$0.rangeUTF16,bboxPageXYXY:translated($0.bboxPageXYXY)) }))
            }
            let valid=reads.filter { VisualNumericLiteral.parse($0.selectedText) != nil }
            let keys=Set(valid.compactMap { VisualNumericLiteral.parse($0.selectedText)?.key })
            let confident=valid.filter { ($0.candidates.first?.confidence ?? 0).isFinite && ($0.candidates.first?.confidence ?? 0)>=0.8 }
            let consistent=keys.count == 1 && Set(confident.map(\.id)).count>=2
            // A replacement is permitted only by recorded OCR agreement, never by
            // a value suggested by Qwen, the exercise, or sector-angle arithmetic.
            var winner=original
            if consistent, VisualNumericLiteral.parse(original.selectedText) == nil, let recovered=confident.first { winner=recovered }
            let evidence=VisualNumericEvidence(version:"visual_numeric_ocr_agreement_v2",originalObservationID:original.id,
                originalText:original.selectedText,selectedText:winner.selectedText,readings:reads.map(\.selectedText),consistent:consistent,
                reason:consistent ? "At least two confident literal OCR readings agree; no conflicting valid numeric reading; photo correctness unassessed" : "Missing corroboration or conflicting literal OCR values/units; withhold numeric speech",
                artifact:"\(prefix)/selection.json",readingObservationIDs:reads.map(\.id),contextArtifact:contextual[owner.id] == nil ? nil : "pages/\(pageID)/numeric-ocr-context/\(owner.id)/ocr.raw.json",
                readingDetails:reads.map { .init(observationID:$0.id,text:$0.selectedText,confidence:$0.candidates.first?.confidence ?? 0) })
            winner.numericEvidence=evidence
            try encoder.encode(evidence).write(to:dir.appendingPathComponent("selection.json"),options:.atomic)
            selected.append(winner); logs.append(evidence)
        }
        let ordered=selected.enumerated().map { index,o in OCRObservation(id:o.id,rawOrder:index+1,bboxPageXYXY:o.bboxPageXYXY,candidates:o.candidates,rangeBoxes:o.rangeBoxes,numericEvidence:o.numericEvidence) }
        try encoder.encode(logs).write(to:pageRoot.appendingPathComponent("numeric-ocr-selection.json"),options:.atomic)
        return (VisionOCRResult(observations:ordered,requestedLanguages:input.requestedLanguages,supportedLanguages:input.supportedLanguages,usesLanguageCorrection:input.usesLanguageCorrection,recognitionLevel:input.recognitionLevel,effectiveLanguages:input.effectiveLanguages,requestRevision:input.requestRevision),requests)
    }
}
