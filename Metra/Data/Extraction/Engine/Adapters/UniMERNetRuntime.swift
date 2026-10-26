import Foundation
import CryptoKit
import ImageIO
import UIKit
import OnnxRuntimeBindings

struct UniMERNetManifest: Codable, Sendable {
    struct ModelFile: Codable, Sendable { let sha256: String; let bytes: Int }
    let modelID: String
    let revision: String
    let checkpointSHA256: String
    let precision: String
    let layers: Int
    let bosTokenID: Int
    let eosTokenID: Int
    let padTokenID: Int
    let maxNewTokens: Int
    let tokenizerSHA256: String
    let files: [String: ModelFile]
    let preprocess: String
    let resizeDifference: String
}

struct FormulaRecognition: Codable, Sendable {
    let formulaID: String
    let latexRaw: String
    let tokenIDs: [Int]
    let eosReached: Bool
    let stopReason: String
    let modelWasWarm: Bool
    let model: UniMERNetManifest
    let metrics: [String: Double]
    let tokenDecoding: String
    let preprocessing: FormulaPreprocessing
}

struct FormulaPreprocessing: Codable, Sendable {
    let sourceSize: [Int]
    let marginCropXYXY: [Int]
    let resizedSize: [Int]
    let paddingLTRB: [Int]
    let modelShape: [Int]
    let resize: String
    let mean: Float
    let std: Float
}

enum FormulaRecognitionError: LocalizedError {
    case failed(String)
    var errorDescription: String? { switch self { case .failed(let reason): return "UniMERNet: \(reason)" } }
}

actor UniMERNetRuntime {
    private var environment: ORTEnv?
    private var encoder: ORTSession?
    private var decoder: ORTSession?
    private var cachedDecoder: ORTSession?
    private var tokenizer: UniMERTokenDecoder?
    private var manifest: UniMERNetManifest?

    func unload() { cachedDecoder = nil; decoder = nil; encoder = nil; environment = nil; tokenizer = nil; manifest = nil }

    func recognize(cropURL: URL, formulaID: String, artifacts: URL) throws -> FormulaRecognition {
        try Task.checkCancellation()
        let warm = encoder != nil
        let loadStart = ProcessInfo.processInfo.systemUptime
        if encoder == nil { try load() }
        let loadMS = warm ? 0 : (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
        guard let encoder, let decoder, let cachedDecoder, let tokenizer, let manifest else { throw FormulaRecognitionError.failed("Session tidak siap") }
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let preprocessStart = ProcessInfo.processInfo.systemUptime
        let prepared = try Self.prepare(cropURL, preview: artifacts.appendingPathComponent("model-input.png"))
        let input = try Self.floatTensor(prepared.values, shape: [1,1,192,672])
        let preprocessMS = (ProcessInfo.processInfo.systemUptime - preprocessStart) * 1000
        let encoderStart = ProcessInfo.processInfo.systemUptime
        let encoderOutputs = try encoder.run(withInputs: ["pixel_values": input], outputNames: ["encoder_hidden_states"], runOptions: nil)
        guard let hidden = encoderOutputs["encoder_hidden_states"] else { throw FormulaRecognitionError.failed("Encoder output kosong") }
        let encoderMS = (ProcessInfo.processInfo.systemUptime - encoderStart) * 1000
        let decodeStart = ProcessInfo.processInfo.systemUptime
        let names = Set(["logits"] + (0..<manifest.layers).flatMap { ["present_key_\($0)", "present_value_\($0)"] })
        var token = manifest.bosTokenID
        var tokens: [Int] = []
        var cache: [ORTValue] = []
        var eos = false
        var stop = "max_new_tokens"
        var stepTimes: [Double] = []
        for step in 0..<manifest.maxNewTokens {
            try Task.checkCancellation()
            if ProcessInfo.processInfo.systemUptime - decodeStart > 30 { stop = "deadline_exceeded"; break }
            let stepStart = ProcessInfo.processInfo.systemUptime
            let tokenValue = try Self.intTensor([Int64(token)], shape: [1,1])
            var inputs = ["input_ids": tokenValue, "encoder_hidden_states": hidden]
            if step > 0 {
                for layer in 0..<manifest.layers {
                    inputs["past_key_\(layer)"] = cache[layer * 2]
                    inputs["past_value_\(layer)"] = cache[layer * 2 + 1]
                }
            }
            let session = step == 0 ? decoder : cachedDecoder
            let outputs = try session.run(withInputs: inputs, outputNames: names, runOptions: nil)
            guard let logits = outputs["logits"] else { throw FormulaRecognitionError.failed("Decoder logits kosong") }
            let info = try logits.tensorTypeAndShapeInfo()
            let shape = info.shape.map(\.intValue)
            guard info.elementType == .float, shape.count == 3, shape[0] == 1, shape[1] == 1, shape[2] > 3 else { throw FormulaRecognitionError.failed("Shape logits tidak didukung: \(shape)") }
            let data = try logits.tensorData() as Data
            token = try data.withUnsafeBytes { bytes in
                let floats = bytes.bindMemory(to: Float.self)
                guard floats.count == shape[2] else { throw FormulaRecognitionError.failed("Ukuran logits berbeda dari shape") }
                var best = 0
                for i in floats.indices {
                    guard floats[i].isFinite else { throw FormulaRecognitionError.failed("Logits non-finite") }
                    if floats[i] > floats[best] { best = i }
                }
                return best
            }
            tokens.append(token)
            stepTimes.append((ProcessInfo.processInfo.systemUptime - stepStart) * 1000)
            if token == manifest.eosTokenID { eos = true; stop = "eos"; break }
            cache = try (0..<manifest.layers).flatMap { layer -> [ORTValue] in
                guard let key = outputs["present_key_\(layer)"], let value = outputs["present_value_\(layer)"] else { throw FormulaRecognitionError.failed("KV cache tidak lengkap") }
                return [key,value]
            }
        }
        let decoderMS = (ProcessInfo.processInfo.systemUptime - decodeStart) * 1000
        let filtered = tokens.filter { ![manifest.bosTokenID,manifest.eosTokenID,manifest.padTokenID].contains($0) }
        let latex = try tokenizer.decode(tokens: filtered)
        let result = FormulaRecognition(formulaID: formulaID, latexRaw: latex, tokenIDs: tokens, eosReached: eos, stopReason: stop, modelWasWarm: warm, model: manifest, metrics: ["model_load_ms": loadMS, "preprocess_ms": preprocessMS, "encoder_ms": encoderMS, "decoder_ms": decoderMS, "inference_ms": encoderMS + decoderMS, "generated_tokens": Double(tokens.count), "decoder_step_mean_ms": stepTimes.isEmpty ? 0 : stepTimes.reduce(0,+)/Double(stepTimes.count)], tokenDecoding: "Nougat BPE vocabulary + ByteLevel byte decode from original tokenizer.json; no ftfy or mathematical rewriting", preprocessing: prepared.metadata)
        let json = JSONEncoder(); json.outputFormatting = [.prettyPrinted,.sortedKeys]
        try json.encode(result).write(to: artifacts.appendingPathComponent("unimernet.raw.json"), options: .atomic)
        try latex.write(to: artifacts.appendingPathComponent("latex.raw.txt"), atomically: true, encoding: .utf8)
        return result
    }

    private func load() throws {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("UniMERNet") else { throw FormulaRecognitionError.failed("Folder bundle tidak tersedia") }
        let config = try JSONDecoder().decode(UniMERNetManifest.self, from: Data(contentsOf: root.appendingPathComponent("unimernet-manifest.json")))
        guard config.modelID == "wanderkid/unimernet_tiny", config.precision == "FP32", config.layers == 8 else { throw FormulaRecognitionError.failed("Manifest bukan checkpoint tiny FP32 yang dipin") }
        for name in ["encoder_model.onnx","decoder_model.onnx","decoder_with_past_model.onnx"] {
            guard let record = config.files[name], try Self.hash(root.appendingPathComponent(name)) == record.sha256 else { throw FormulaRecognitionError.failed("Hash tidak sesuai: \(name)") }
        }
        guard try Self.hash(root.appendingPathComponent("tokenizer.json")) == config.tokenizerSHA256 else { throw FormulaRecognitionError.failed("Hash tokenizer tidak sesuai") }
        let loadedTokenizer = try UniMERTokenDecoder(url:root.appendingPathComponent("tokenizer.json"))
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions(); try options.setIntraOpNumThreads(2); try options.setGraphOptimizationLevel(.all)
        let enc = try ORTSession(env: env, modelPath: root.appendingPathComponent("encoder_model.onnx").path, sessionOptions: options)
        let dec = try ORTSession(env: env, modelPath: root.appendingPathComponent("decoder_model.onnx").path, sessionOptions: options)
        let cached = try ORTSession(env: env, modelPath: root.appendingPathComponent("decoder_with_past_model.onnx").path, sessionOptions: options)
        environment = env; encoder = enc; decoder = dec; cachedDecoder = cached; tokenizer = loadedTokenizer; manifest = config
    }

    private static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    private static func floatTensor(_ values: [Float], shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBytes { NSMutableData(bytes:$0.baseAddress!,length:$0.count) }
        return try ORTValue(tensorData:data,elementType:.float,shape:shape.map { NSNumber(value:$0) })
    }
    private static func intTensor(_ values: [Int64], shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBytes { NSMutableData(bytes:$0.baseAddress!,length:$0.count) }
        return try ORTValue(tensorData:data,elementType:.int64,shape:shape.map { NSNumber(value:$0) })
    }

    private static func prepare(_ url: URL, preview: URL) throws -> (values:[Float],metadata:FormulaPreprocessing) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw FormulaRecognitionError.failed("Crop tidak terbaca") }
        func rgba(_ image: CGImage, width:Int, height:Int, rect:CGRect) throws -> [UInt8] {
            var pixels = [UInt8](repeating:0,count:width*height*4)
            let good = pixels.withUnsafeMutableBytes { bytes -> Bool in
                guard let ctx = CGContext(data:bytes.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                ctx.setFillColor(UIColor.black.cgColor);ctx.fill(CGRect(x:0,y:0,width:width,height:height))
                ctx.interpolationQuality = .high;ctx.draw(image,in:rect)
                return true
            }
            guard good else { throw FormulaRecognitionError.failed("Alokasi preprocessing gagal") };return pixels
        }
        let w=image.width,h=image.height
        let pixels = try rgba(image,width:w,height:h,rect:CGRect(x:0,y:0,width:w,height:h))
        func gray(_ pixels:[UInt8],_ i:Int) -> Int { Int((0.299*Double(pixels[i*4])+0.587*Double(pixels[i*4+1])+0.114*Double(pixels[i*4+2])).rounded()) }
        let grays = (0..<(w*h)).map { gray(pixels,$0) };let minVal=grays.min() ?? 0,maxVal=grays.max() ?? 255
        var x0=0,y0=0,x1=w,y1=h
        if maxVal > minVal {
            x0=w;y0=h;x1=0;y1=0
            for y in 0..<h { for x in 0..<w where Double(grays[y*w+x]-minVal)/Double(maxVal-minVal)*255 < 200 {
                x0=min(x0,x);y0=min(y0,y);x1=max(x1,x+1);y1=max(y1,y+1)
            } }
        }
        guard x1>x0,y1>y0,let cropped=image.cropping(to:CGRect(x:x0,y:y0,width:x1-x0,height:y1-y0)) else { throw FormulaRecognitionError.failed("Margin crop kosong") }
        let scale=min(192/Double(cropped.height),672/Double(cropped.width))
        let rw=max(1,min(672,Int((Double(cropped.width)*scale).rounded()))),rh=max(1,min(192,Int((Double(cropped.height)*scale).rounded())))
        let left=(672-rw)/2,top=(192-rh)/2
        let padded = try rgba(cropped,width:672,height:192,rect:CGRect(x:left,y:192-top-rh,width:rw,height:rh))
        let values=(0..<(192*672)).map { (Float(gray(padded,$0))/255 - 0.7931)/0.1738 }
        let provider=CGDataProvider(data:Data(padded) as CFData)!
        if let cg=CGImage(width:672,height:192,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:672*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent),let png=UIImage(cgImage:cg).pngData() { try png.write(to:preview,options:.atomic) }
        return (values,FormulaPreprocessing(sourceSize:[w,h],marginCropXYXY:[x0,y0,x1,y1],resizedSize:[rw,rh],paddingLTRB:[left,top,672-rw-left,192-rh-top],modelShape:[1,1,192,672],resize:"CoreGraphics high aspect fit; single resize instead of PIL two-stage resize/thumbnail",mean:0.7931,std:0.1738))
    }
}

// Generation only requires ID -> byte decoding. Keep the exact Nougat vocabulary;
// no alternative tokenizer class, encode path, or math postprocessor is selected.
private struct UniMERTokenDecoder {
    let vocabulary: [Int:String]
    let byteForScalar: [UInt32:UInt8]
    let specialIDs: Set<Int>
    init(url:URL) throws {
        guard let json=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any],
              let model=json["model"] as? [String:Any],model["type"] as? String == "BPE",
              let vocab=model["vocab"] as? [String:Int],
              let decoder=json["decoder"] as? [String:Any],decoder["type"] as? String == "ByteLevel" else {
            throw FormulaRecognitionError.failed("Tokenizer bukan Nougat BPE/ByteLevel yang diharapkan")
        }
        var reversed=Dictionary(uniqueKeysWithValues:vocab.map{($0.value,$0.key)})
        var specials=Set<Int>()
        for added in json["added_tokens"] as? [[String:Any]] ?? [] {
            if let id=added["id"] as? Int,let content=added["content"] as? String { reversed[id]=content;if added["special"] as? Bool == true {specials.insert(id)} }
        }
        vocabulary=reversed;specialIDs=specials
        let visible=Array(33...126)+Array(161...172)+Array(174...255)
        let visibleSet=Set(visible)
        var map=Dictionary(uniqueKeysWithValues:visible.map{(UInt32($0),UInt8($0))})
        var extra=0
        for byte in 0...255 where !visibleSet.contains(byte) { map[UInt32(256+extra)]=UInt8(byte);extra+=1 }
        byteForScalar=map
    }
    func decode(tokens:[Int]) throws -> String {
        var bytes:[UInt8]=[]
        for id in tokens where !specialIDs.contains(id) {
            guard let token=vocabulary[id] else {throw FormulaRecognitionError.failed("Token ID tidak ada di vocabulary: \(id)")}
            for scalar in token.unicodeScalars {
                guard let byte=byteForScalar[scalar.value] else {throw FormulaRecognitionError.failed("Unicode token tidak valid untuk ByteLevel")}
                bytes.append(byte)
            }
        }
        return String(decoding:bytes,as:UTF8.self)
    }
}
