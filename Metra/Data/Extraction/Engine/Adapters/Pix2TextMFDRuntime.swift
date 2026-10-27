import Foundation
import CryptoKit
import ImageIO
import UIKit
import OnnxRuntimeBindings

struct MFDModelMetadata: Codable, Sendable {
    let modelID: String
    let sourceRevision: String
    let sourceFile: String
    let sha256: String
    let bytes: Int
    let precision: String
    let inputName: String
    let outputName: String
    let labels: [String]
    let targetWidth: Int
    let maxInputSide: Int
    let stride: Int
    let scoreThreshold: Double
    let nmsSameClassIOU: Double
    let maxDetections: Int
    let paddingValue: Int
    let preprocessing: String
}

struct MFDResult: Codable, Sendable {
    let model: MFDModelMetadata
    let runtime: String
    let backend: String
    let modelWasWarm: Bool
    let pageSize: [Int]
    let inputShape: [Int]
    let outputShape: [Int]
    let scale: Double
    let padding: [Int]
    /// Every raw YOLO prediction, before score filtering or NMS.
    let rawPredictions: [[Double]]
    let regions: [LayoutRegion]
    let metrics: [String: Double]
}

/// A separate detector lane. It outputs crop proposals, never LaTeX or speech.
actor Pix2TextMFDRuntime {
    static let proposalVersion = "pix2text_mfd_image_proposal_v1"
    private var environment: ORTEnv?
    private var session: ORTSession?
    private var metadata: MFDModelMetadata?

    func unload() { session = nil; environment = nil; metadata = nil }

    func detect(imageURL: URL, pageID: String, pageRoot: URL, enqueuedAt: Double) throws -> MFDResult {
        try Task.checkCancellation()
        let start = ProcessInfo.processInfo.systemUptime
        let warm = session != nil
        let loadStart = ProcessInfo.processInfo.systemUptime
        if session == nil {
            guard let model = Bundle.main.url(forResource: "Pix2Text-MFD", withExtension: "onnx"),
                  let config = Bundle.main.url(forResource: "Pix2Text-MFD.config", withExtension: "json") else {
                throw LayoutRuntimeError.invalid("Pix2Text-MFD ONNX/config tidak tersedia; jalur DocLayout tetap dapat dilanjutkan.")
            }
            let meta = try JSONDecoder().decode(MFDModelMetadata.self, from: Data(contentsOf: config))
            let handle = try FileHandle(forReadingFrom: model)
            defer { try? handle.close() }
            var hash = SHA256(), byteCount = 0
            while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                try Task.checkCancellation(); hash.update(data: bytes); byteCount += bytes.count
            }
            guard byteCount == meta.bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == meta.sha256 else {
                throw LayoutRuntimeError.invalid("SHA-256/ukuran Pix2Text-MFD tidak sesuai manifest.")
            }
            let env = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(2)
            try options.setGraphOptimizationLevel(.all)
            let loaded = try ORTSession(env: env, modelPath: model.path, sessionOptions: options)
            guard try loaded.inputNames() == [meta.inputName], try loaded.outputNames() == [meta.outputName] else {
                throw LayoutRuntimeError.invalid("Nama tensor Pix2Text-MFD tidak sesuai manifest.")
            }
            environment = env; session = loaded; metadata = meta
        }
        guard let session, let meta = metadata else { throw LayoutRuntimeError.invalid("Session MFD tidak siap.") }
        let loadMS = warm ? 0 : (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
        let preprocessStart = ProcessInfo.processInfo.systemUptime
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw LayoutRuntimeError.invalid("MFD tidak dapat membaca halaman.") }
        let input = try Self.preprocess(image, metadata: meta)
        let data = input.pixels.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
        let tensor = try ORTValue(tensorData: data, elementType: .float, shape: input.shape.map { NSNumber(value: $0) })
        let preprocessMS = (ProcessInfo.processInfo.systemUptime - preprocessStart) * 1000
        try Task.checkCancellation()
        let inferenceStart = ProcessInfo.processInfo.systemUptime
        let outputs = try session.run(withInputs: [meta.inputName: tensor], outputNames: [meta.outputName], runOptions: nil)
        let inferenceMS = (ProcessInfo.processInfo.systemUptime - inferenceStart) * 1000
        let postStart = ProcessInfo.processInfo.systemUptime
        guard let output = outputs[meta.outputName] else { throw LayoutRuntimeError.invalid("Output MFD kosong.") }
        let info = try output.tensorTypeAndShapeInfo(), shape = infoShape(output)
        guard info.elementType == .float, shape.count == 3, shape[0] == 1,
              shape[1] == 4 + meta.labels.count, shape[2] > 0 else {
            throw LayoutRuntimeError.invalid("Shape MFD bukan [1,6,N]: \(shape).")
        }
        let bytes = try output.tensorData() as Data
        let floats = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let count = shape[2], channels = shape[1]
        guard floats.count == count * channels else { throw LayoutRuntimeError.invalid("Ukuran tensor MFD salah.") }
        let rows = (0..<count).map { i in (0..<channels).map { Double(floats[$0 * count + i]) } }
        guard rows.joined().allSatisfy(\.isFinite) else { throw LayoutRuntimeError.invalid("MFD menghasilkan nilai non-finite.") }
        var candidates: [LayoutRegion] = []
        for (index, row) in rows.enumerated() {
            let label = row[4] >= row[5] ? 0 : 1, score = max(row[4], row[5])
            guard score >= meta.scoreThreshold else { continue }
            let box = PixelBox(
                xmin: max(0, floor((row[0] - row[2] / 2 - Double(input.left)) / input.scale)),
                ymin: max(0, floor((row[1] - row[3] / 2 - Double(input.top)) / input.scale)),
                xmax: min(Double(image.width), ceil((row[0] + row[2] / 2 - Double(input.left)) / input.scale)),
                ymax: min(Double(image.height), ceil((row[1] + row[3] / 2 - Double(input.top)) / input.scale)))
            guard box.area > 0 else { continue }
            candidates.append(LayoutRegion(id: "\(pageID).mfd.\(String(format: "%05d", index))", classID: label,
                label: "formula_candidate", score: score, bboxPageXYXY: box, rawIndex: 1_000_000 + index,
                parentID: nil, cropArtifact: nil, detectionSource: Self.proposalVersion,
                roiDerivation: "Pix2Text-MFD \(meta.labels[label]) image bbox; raw index \(index); no OCR/LaTeX inferred"))
        }
        candidates.sort { $0.score == $1.score ? $0.rawIndex < $1.rawIndex : $0.score > $1.score }
        var kept: [LayoutRegion] = []
        for candidate in candidates {
            if !kept.contains(where: { $0.classID == candidate.classID && $0.bboxPageXYXY.iou(candidate.bboxPageXYXY) > meta.nmsSameClassIOU }) {
                kept.append(candidate)
                if kept.count == meta.maxDetections { break }
            }
        }
        kept.sort(by: LayoutMerge.precedes)
        let postMS = (ProcessInfo.processInfo.systemUptime - postStart) * 1000
        let writeStart = ProcessInfo.processInfo.systemUptime
        try FileManager.default.createDirectory(at: pageRoot.appendingPathComponent("crops"), withIntermediateDirectories: true)
        for index in kept.indices {
            let box = kept[index].bboxPageXYXY
            guard let crop = image.cropping(to: CGRect(x: box.xmin, y: box.ymin, width: box.xmax-box.xmin, height: box.ymax-box.ymin)),
                  let png = UIImage(cgImage: crop).pngData() else { throw LayoutRuntimeError.invalid("Crop MFD gagal.") }
            try png.write(to: pageRoot.appendingPathComponent("crops/\(kept[index].id).png"), options: .atomic)
            kept[index].cropArtifact = "pages/\(pageID)/crops/\(kept[index].id).png"
        }
        try Self.overlay(image, regions: kept).write(to: pageRoot.appendingPathComponent("mfd-overlay.png"), options: .atomic)
        let result = MFDResult(model: meta, runtime: "ONNX Runtime 1.24.2", backend: "CPUExecutionProvider; 2 intra-op threads",
            modelWasWarm: warm, pageSize: [image.width,image.height], inputShape: input.shape, outputShape: shape,
            scale: input.scale, padding: [input.left,input.top], rawPredictions: rows, regions: kept,
            metrics: ["queue_wait_ms": max(0,start-enqueuedAt)*1000, "model_load_ms": loadMS, "preprocess_ms": preprocessMS,
                      "inference_ms": inferenceMS, "postprocess_ms": postMS,
                      "artifact_write_ms": (ProcessInfo.processInfo.systemUptime-writeStart)*1000,
                      "total_ms": (ProcessInfo.processInfo.systemUptime-start)*1000])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(result).write(to: pageRoot.appendingPathComponent("mfd.raw.json"), options: .atomic)
        return result
    }

    private func infoShape(_ output: ORTValue) -> [Int] { (try? output.tensorTypeAndShapeInfo().shape.map(\.intValue)) ?? [] }

    private struct Input {
        let pixels: [Float]
        let shape: [Int]
        let scale: Double
        let left: Int
        let top: Int
    }

    private static func preprocess(_ image: CGImage, metadata: MFDModelMetadata) throws -> Input {
        let w = image.width, h = image.height, stride = metadata.stride
        let targetW = metadata.targetWidth
        let targetH = min(metadata.maxInputSide, Int(ceil(Double(h) * Double(targetW) / Double(w) / Double(stride))) * stride)
        let scale = min(Double(targetW) / Double(w), Double(targetH) / Double(h))
        let rw = max(1,Int((Double(w)*scale).rounded())), rh = max(1,Int((Double(h)*scale).rounded()))
        let left = (targetW-rw)/2, top = (targetH-rh)/2, plane = targetW*targetH
        var rgba = [UInt8](repeating: 0, count: w*h*4)
        let ok = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            ctx.setFillColor(UIColor.white.cgColor); ctx.fill(CGRect(x: 0,y: 0,width: w,height: h))
            ctx.draw(image,in: CGRect(x: 0,y: 0,width: w,height: h)); return true
        }
        guard ok else { throw LayoutRuntimeError.invalid("Decode RGB MFD gagal.") }
        var pixels = [Float](repeating: Float(metadata.paddingValue)/255, count: 3*plane)
        for y in 0..<rh {
            if y % 64 == 0 { try Task.checkCancellation() }
            let sy = max(0,min(Double(h-1),(Double(y)+0.5)*Double(h)/Double(rh)-0.5))
            let y0 = Int(sy), y1 = min(y0+1,h-1), fy = sy-Double(y0)
            for x in 0..<rw {
                let sx = max(0,min(Double(w-1),(Double(x)+0.5)*Double(w)/Double(rw)-0.5))
                let x0 = Int(sx), x1 = min(x0+1,w-1), fx = sx-Double(x0)
                for c in 0..<3 {
                    let a = Double(rgba[(y0*w+x0)*4+c])*(1-fx)+Double(rgba[(y0*w+x1)*4+c])*fx
                    let b = Double(rgba[(y1*w+x0)*4+c])*(1-fx)+Double(rgba[(y1*w+x1)*4+c])*fx
                    pixels[c*plane+(y+top)*targetW+x+left] = Float((a*(1-fy)+b*fy).rounded())/255
                }
            }
        }
        return Input(pixels: pixels, shape: [1,3,targetH,targetW], scale: scale, left: left, top: top)
    }

    private static func overlay(_ image: CGImage, regions: [LayoutRegion]) throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: image.width,height: image.height),format: format).image { context in
            UIImage(cgImage: image).draw(at: .zero)
            for r in regions {
                let b = r.bboxPageXYXY
                context.cgContext.setStrokeColor(UIColor.systemOrange.cgColor); context.cgContext.setLineWidth(2)
                context.cgContext.stroke(CGRect(x: b.xmin,y: b.ymin,width: b.xmax-b.xmin,height: b.ymax-b.ymin))
                ("MFD \(String(format: "%.2f",r.score))" as NSString).draw(at: CGPoint(x: b.xmin,y: max(0,b.ymin-15)),
                    withAttributes: [.font:UIFont.systemFont(ofSize: 12,weight: .bold),.foregroundColor:UIColor.systemOrange,.backgroundColor:UIColor.white])
            }
        }
        guard let data = rendered.pngData() else { throw LayoutRuntimeError.invalid("Overlay MFD gagal.") }
        return data
    }
}
