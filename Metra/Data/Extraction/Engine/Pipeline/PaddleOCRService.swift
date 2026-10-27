import Foundation
import ImageIO
import UIKit

enum PaddleOCRService {
    struct Result {
        let ocr:VisionOCRResult
        let components:[ComponentResult]
    }
    /// Supplemental recognition on existing Vision line ROIs; no Paddle text
    /// detector is claimed. Raw Vision and every actual Paddle result are retained.
    static func supplement(_ original:VisionOCRResult,pageID:String,pageRoot:URL,imageURL:URL) async throws -> Result {
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let root=pageRoot.appendingPathComponent("paddleocr",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        guard let source=CGImageSourceCreateWithURL(imageURL as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { throw PaddleOCRError.invalid("Cannot decode working page") }
        let hint=try NSRegularExpression(pattern:#"∠|[LZ][A-Z]{3}|[°º⁰¹²³⁴⁵⁶⁷⁸⁹]|[0-9][ \t]*(?:dam|km|hm|dm|cm|mm|m)[23rг'’′?]|[A-Za-z][23'’′]"#)
        let eligible=original.observations.indices.filter {
            let text=original.observations[$0].selectedText
            return hint.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)) != nil
        }
        var selected=original.observations,rows:[[String:Any]]=[],changed=0,failed=0
        let runtime=PaddleOCRRuntime(),start=ProcessInfo.processInfo.systemUptime
        var totals:[String:Double]=[:]
        do {
            for index in eligible.prefix(80) {
                try Task.checkCancellation()
                let observation=original.observations[index],b=observation.bboxPageXYXY
                let margin=max(2,(b.ymax-b.ymin)*0.12)
                let cropBox=PixelBox(xmin:max(0,floor(b.xmin-2)),ymin:max(0,floor(b.ymin-margin)),xmax:min(Double(image.width),ceil(b.xmax+2)),ymax:min(Double(image.height),ceil(b.ymax+margin)))
                let directory=root.appendingPathComponent(observation.id,isDirectory:true)
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                let cropURL=directory.appendingPathComponent("line.png")
                var row:[String:Any]=["observation_id":observation.id,"vision_text":observation.selectedText,"crop_bbox_page_xyxy":cropBox.array,
                    "recognition_artifact":"pages/\(pageID)/paddleocr/\(observation.id)/recognition.raw.json"]
                do {
                    guard let crop=image.cropping(to:CGRect(x:cropBox.xmin,y:cropBox.ymin,width:cropBox.xmax-cropBox.xmin,height:cropBox.ymax-cropBox.ymin)),let png=UIImage(cgImage:crop).pngData() else { throw PaddleOCRError.invalid("Line crop failed") }
                    try png.write(to:cropURL,options:.atomic)
                    let result=try await runtime.recognize(cropURL:cropURL,id:observation.id,artifacts:directory)
                    for (key,value) in result.metrics { totals[key,default:0]+=value }
                    let decision=PaddleMathSymbolSelector.select(vision:observation.selectedText,paddle:result.decoded)
                    try encoder.encode(decision).write(to:directory.appendingPathComponent("selection.json"),options:.atomic)
                    row["paddle_text"]=result.decoded.text;row["paddle_mean_probability"]=result.decoded.confidence
                    row["selected_text"]=decision.selectedText;row["selected"]=decision.accepted;row["reason"]=decision.reason
                    if decision.accepted {
                        changed+=decision.changes.count
                        selected[index].selectedTextOverride=decision.selectedText
                        selected[index].selectionEngine="vision_with_paddle_unicode"
                        selected[index].selectionArtifact="pages/\(pageID)/paddleocr/\(observation.id)/selection.json"
                    }
                } catch {
                    if error is CancellationError { throw error }
                    failed+=1;row["error"]=error.localizedDescription
                    try encoder.encode(["error":error.localizedDescription]).write(to:directory.appendingPathComponent("error.json"),options:.atomic)
                }
                rows.append(row)
            }
        } catch { await runtime.unload();throw error }
        await runtime.unload()
        let report:[String:Any]=["version":PaddleMathSymbolSelector.version,"model":"PaddlePaddle/PP-OCRv5_mobile_rec_onnx",
            "selection_threshold":PaddleMathSymbolSelector.minimumSymbolProbability,"eligible_lines":eligible.count,"attempted_lines":rows.count,
            "failed_lines":failed,"selected_unicode_glyphs":changed,"skipped_by_budget":max(0,eligible.count-80),"rows":rows,
            "source":"Vision line ROIs; unmodified Vision candidates in ocr.vision-working.raw.json",
            "limitations":"Supplemental text recognition only, not Paddle page/text detection. Selection copies explicit high-probability Unicode glyphs only when all other non-whitespace characters align. Scores are model probabilities, not source accuracy. Source range geometry remains Vision; CTC timesteps are not character boxes."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("selection.json"),options:.atomic)
        totals["request_wall_ms"]=(ProcessInfo.processInfo.systemUptime-start)*1000;totals["attempted_lines"]=Double(rows.count)
        totals["failed_lines"]=Double(failed);totals["selected_unicode_glyphs"]=Double(changed)
        let ocr=VisionOCRResult(observations:selected,requestedLanguages:original.requestedLanguages,supportedLanguages:original.supportedLanguages,
            usesLanguageCorrection:original.usesLanguageCorrection,recognitionLevel:original.recognitionLevel,effectiveLanguages:original.effectiveLanguages,requestRevision:original.requestRevision)
        let component=ComponentResult(component:"paddleocr_text_recognition",status:rows.isEmpty ? "skipped_no_input" : (failed==0 ? "succeeded" : (failed==rows.count ? "failed" : "partial")),
            errorCode:failed==0 ? nil : "paddle_line_recognition_failed",message:"On-device supplemental PP-OCRv5 mobile recognition; \(changed) explicit Unicode glyphs selected; source accuracy unassessed",
            rawArtifact:"pages/\(pageID)/paddleocr/selection.json",metrics:totals.mapValues{Optional($0)})
        return Result(ocr:ocr,components:[component])
    }
}
