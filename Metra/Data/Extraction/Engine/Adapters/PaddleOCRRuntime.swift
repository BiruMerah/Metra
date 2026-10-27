import Foundation
import CryptoKit
import ImageIO
import UIKit
import OnnxRuntimeBindings

struct PaddleOCRModel: Codable, Sendable {
    let modelID:String
    let sourceRevision:String
    let sha256:String
    let bytes:Int
    let dictionaryFile:String
    let dictionarySHA256:String
    let dictionaryClasses:Int
    let inputName:String
    let outputName:String
    let height:Int
    let minimumWidth:Int
    let maximumWidth:Int
    let blankID:Int
    let intraOpThreads:Int
    let preprocessing:String
    let resizeDifference:String
}

struct PaddleOCRRecognition: Codable, Sendable {
    let id:String
    let model:PaddleOCRModel
    let runtime:String
    let backend:String
    let modelWasWarm:Bool
    let sourceSize:[Int]
    let resizedSize:[Int]
    let inputShape:[Int]
    let outputShape:[Int]
    let argmaxIndices:[Int]
    let argmaxProbabilities:[Float]
    let decoded:PaddleCTCResult
    let metrics:[String:Double]
    let geometryScope:String
}

/// Pinned text-line recognizer, batch 1 on the existing native ORT CPU backend.
/// It consumes a real image crop; no OCR string or expected answer is a model input.
actor PaddleOCRRuntime {
    private var environment:ORTEnv?
    private var session:ORTSession?
    private var model:PaddleOCRModel?
    private var dictionary:[String] = []

    func unload() { session=nil;environment=nil;model=nil;dictionary=[] }

    func recognize(cropURL:URL,id:String,artifacts:URL) throws -> PaddleOCRRecognition {
        try Task.checkCancellation()
        let totalStart=ProcessInfo.processInfo.systemUptime,warm=session != nil,loadStart=ProcessInfo.processInfo.systemUptime
        if session == nil { try load() }
        let loadMS=warm ? 0 : (ProcessInfo.processInfo.systemUptime-loadStart)*1000
        guard let session,let model else { throw PaddleOCRError.invalid("Session unavailable") }
        let preprocessStart=ProcessInfo.processInfo.systemUptime
        guard let source=CGImageSourceCreateWithURL(cropURL as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { throw PaddleOCRError.invalid("Cannot decode line crop") }
        let prepared=try Self.prepare(image,model:model)
        let tensorData=prepared.values.withUnsafeBytes { NSMutableData(bytes:$0.baseAddress!,length:$0.count) }
        let input=try ORTValue(tensorData:tensorData,elementType:.float,shape:[1,3,model.height,prepared.width].map { NSNumber(value:$0) })
        let preprocessMS=(ProcessInfo.processInfo.systemUptime-preprocessStart)*1000
        try Task.checkCancellation()
        let inferenceStart=ProcessInfo.processInfo.systemUptime
        let outputs=try session.run(withInputs:[model.inputName:input],outputNames:[model.outputName],runOptions:nil)
        let inferenceMS=(ProcessInfo.processInfo.systemUptime-inferenceStart)*1000,postStart=ProcessInfo.processInfo.systemUptime
        guard let output=outputs[model.outputName] else { throw PaddleOCRError.invalid("Output missing") }
        let info=try output.tensorTypeAndShapeInfo(),shape=info.shape.map(\.intValue)
        guard info.elementType == .float,shape.count==3,shape[0]==1,shape[1]>0,shape[2]==dictionary.count else { throw PaddleOCRError.invalid("Expected [1,T,\(dictionary.count)] float32, got \(shape)") }
        let data=try output.tensorData() as Data
        let trace:([Int],[Float])=try data.withUnsafeBytes { raw in
            let values=raw.bindMemory(to:Float.self)
            guard values.count==shape[1]*shape[2] else { throw PaddleOCRError.invalid("Output byte count mismatch") }
            var indices:[Int]=[],scores:[Float]=[]
            for t in 0..<shape[1] {
                if t % 32 == 0 { try Task.checkCancellation() }
                let offset=t*shape[2];var best=0
                for c in 0..<shape[2] {
                    let value=values[offset+c]
                    guard value.isFinite,value>=0,value<=1.0001 else { throw PaddleOCRError.invalid("Output is not a finite probability tensor") }
                    if value>values[offset+best] { best=c }
                }
                indices.append(best);scores.append(values[offset+best])
            }
            return (indices,scores)
        }
        let decoded=try PaddleOCRCTC.decode(indices:trace.0,scores:trace.1,dictionary:dictionary,blankID:model.blankID)
        let result=PaddleOCRRecognition(id:id,model:model,runtime:"ONNX Runtime 1.24.2",backend:"CPUExecutionProvider",modelWasWarm:warm,
            sourceSize:[image.width,image.height],resizedSize:[prepared.resizedWidth,model.height],inputShape:[1,3,model.height,prepared.width],outputShape:shape,
            argmaxIndices:trace.0,argmaxProbabilities:trace.1,decoded:decoded,
            metrics:["model_load_ms":loadMS,"preprocess_ms":preprocessMS,"inference_ms":inferenceMS,"postprocess_ms":(ProcessInfo.processInfo.systemUptime-postStart)*1000,"total_ms":(ProcessInfo.processInfo.systemUptime-totalStart)*1000],
            geometryScope:"CTC timesteps are alignment metadata, not detected character boxes. Raw trace stores argmax IDs/probabilities, not the full class-probability matrix.")
        try FileManager.default.createDirectory(at:artifacts,withIntermediateDirectories:true)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(result).write(to:artifacts.appendingPathComponent("recognition.raw.json"),options:.atomic)
        return result
    }

    private func load() throws {
        let base="PaddleOCR-PP-OCRv5-mobile-rec"
        guard let modelURL=Bundle.main.url(forResource:base,withExtension:"onnx"),let configURL=Bundle.main.url(forResource:base+".config",withExtension:"json") else { throw PaddleOCRError.invalid("Bundled model/config missing") }
        let config=try JSONDecoder().decode(PaddleOCRModel.self,from:Data(contentsOf:configURL))
        guard config.modelID=="PaddlePaddle/PP-OCRv5_mobile_rec_onnx",config.height==48,config.blankID==0,
              config.sha256=="da72dc72ca4dc220df0dfde68c1dedc31c58d3e76a25871122e5056227d50092",
              try Self.hash(modelURL)==config.sha256,let resource=Bundle.main.resourceURL else { throw PaddleOCRError.invalid("Pinned model identity/hash mismatch") }
        let dictURL=resource.appendingPathComponent(config.dictionaryFile)
        guard try Self.hash(dictURL)==config.dictionarySHA256 else { throw PaddleOCRError.invalid("Dictionary hash mismatch") }
        let chars=try JSONDecoder().decode([String].self,from:Data(contentsOf:dictURL))
        guard chars.count==config.dictionaryClasses,chars.first=="",["∠","°","²","³"].allSatisfy(chars.contains) else { throw PaddleOCRError.invalid("CTC dictionary mismatch") }
        let env=try ORTEnv(loggingLevel:.warning),options=try ORTSessionOptions()
        guard (1...8).contains(config.intraOpThreads) else { throw PaddleOCRError.invalid("Invalid CPU thread count") }
        try options.setIntraOpNumThreads(Int32(config.intraOpThreads));try options.setGraphOptimizationLevel(.all)
        let loaded=try ORTSession(env:env,modelPath:modelURL.path,sessionOptions:options)
        guard try loaded.inputNames()==[config.inputName],try loaded.outputNames()==[config.outputName] else { throw PaddleOCRError.invalid("Tensor names mismatch") }
        environment=env;session=loaded;dictionary=chars;model=config
    }

    private static func hash(_ url:URL) throws -> String {
        let handle=try FileHandle(forReadingFrom:url);defer { try? handle.close() };var sha=SHA256()
        while let data=try handle.read(upToCount:1024*1024),!data.isEmpty { sha.update(data:data) }
        return sha.finalize().map { String(format:"%02x",$0) }.joined()
    }

    private static func prepare(_ image:CGImage,model:PaddleOCRModel) throws -> (values:[Float],width:Int,resizedWidth:Int) {
        let w=image.width,h=image.height,height=model.height
        guard w>0,h>0,w*h<=40_000_000 else { throw PaddleOCRError.invalid("Invalid source crop dimensions") }
        let ratio=Double(w)/Double(h)
        let width=min(model.maximumWidth,max(model.minimumWidth,Int(Double(height)*ratio)))
        let resizedWidth=min(width,Int(ceil(Double(height)*ratio)))
        var rgba=[UInt8](repeating:255,count:w*h*4)
        let drawn=rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx=CGContext(data:raw.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            ctx.setFillColor(UIColor.white.cgColor);ctx.fill(CGRect(x:0,y:0,width:w,height:h));ctx.draw(image,in:CGRect(x:0,y:0,width:w,height:h));return true
        }
        guard drawn else { throw PaddleOCRError.invalid("Pixel decode failed") }
        let plane=height*width;var tensor=[Float](repeating:0,count:3*plane)
        for y in 0..<height {
            let sy=max(0,min(Double(h-1),(Double(y)+0.5)*Double(h)/Double(height)-0.5)),y0=Int(sy),y1=min(h-1,y0+1),fy=sy-Double(y0)
            for x in 0..<resizedWidth {
                let sx=max(0,min(Double(w-1),(Double(x)+0.5)*Double(w)/Double(resizedWidth)-0.5)),x0=Int(sx),x1=min(w-1,x0+1),fx=sx-Double(x0)
                for channel in 0..<3 {
                    let c=2-channel
                    let top=Double(rgba[(y0*w+x0)*4+c])*(1-fx)+Double(rgba[(y0*w+x1)*4+c])*fx
                    let bottom=Double(rgba[(y1*w+x0)*4+c])*(1-fx)+Double(rgba[(y1*w+x1)*4+c])*fx
                    tensor[channel*plane+y*width+x]=Float((top*(1-fy)+bottom*fy).rounded())/127.5-1
                }
            }
        }
        return (tensor,width,resizedWidth)
    }
}
