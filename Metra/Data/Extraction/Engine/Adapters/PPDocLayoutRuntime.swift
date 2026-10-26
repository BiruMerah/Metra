import Foundation
import CryptoKit
import ImageIO
import UIKit
import OnnxRuntimeBindings

struct LayoutModelMetadata: Codable, Sendable {
    let modelID: String
    let sourceRevision: String
    let exportSHA256: String
    let labels: [String]
    let inputNames: [String]
    let boxesOutputName: String
    let countOutputName: String
    let preprocessing: String
    let iosResizeDifference: String
    let scoreThreshold: Double
    let nmsSameClassIOU: Double
    let nmsDifferentClassIOU: Double
    let mergeMode: String
}

struct LayoutResult: Codable, Sendable {
    let model: LayoutModelMetadata
    let runtime: String
    let backend: String
    let intraOpThreads: Int
    let modelWasWarm: Bool
    let pageSize: [Int]
    let rawBoxes: [[Double]]
    let outputShape: [Int]
    let regions: [LayoutRegion]
    let metrics: [String: Double]
}

enum LayoutRuntimeError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let reason): return reason }
    }
}

// One session / inference lane. No network calls, CoreML fallback or host service.
actor PPDocLayoutRuntime {
    private var environment: ORTEnv?
    private var session: ORTSession?
    private var metadata: LayoutModelMetadata?

    func unload() { session = nil; environment = nil; metadata = nil }

    func detect(imageURL: URL, pageID: String, pageRoot: URL, enqueuedAt: Double) throws -> LayoutResult {
        try Task.checkCancellation()
        let enqueued = ProcessInfo.processInfo.systemUptime
        let warm = session != nil
        let loadStart = ProcessInfo.processInfo.systemUptime
        if session == nil {
            guard let modelURL = Bundle.main.url(forResource: "PP-DocLayout-L", withExtension: "onnx"),
                  let configURL = Bundle.main.url(forResource: "PP-DocLayout-L.config", withExtension: "json") else {
                throw LayoutRuntimeError.invalid("PP-DocLayout-L ONNX/config tidak ada di bundle aplikasi.")
            }
            let config = try JSONDecoder().decode(LayoutModelMetadata.self, from: Data(contentsOf: configURL))
            let actualHash = try Self.fileHash(modelURL)
            guard actualHash == config.exportSHA256 else { throw LayoutRuntimeError.invalid("SHA-256 PP-DocLayout-L tidak sesuai manifest.") }
            let env = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(2)
            try options.setGraphOptimizationLevel(.all)
            let loaded = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
            guard Set(try loaded.inputNames()) == Set(config.inputNames),
                  Set(try loaded.outputNames()) == Set([config.boxesOutputName, config.countOutputName]) else {
                throw LayoutRuntimeError.invalid("Nama tensor ekspor PP-DocLayout-L berbeda dari manifest.")
            }
            environment = env; session = loaded; metadata = config
        }
        guard let session, let metadata else { throw LayoutRuntimeError.invalid("Session layout tidak siap.") }
        let loadMS = warm ? 0 : (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
        try Task.checkCancellation()
        let preprocessStart = ProcessInfo.processInfo.systemUptime
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw LayoutRuntimeError.invalid("Layout tidak dapat membaca PNG halaman.") }
        let pixels = try Self.rgbTensor(image)
        let inputs = [
            "image": try Self.tensor(pixels, shape: [1, 3, 640, 640]),
            "im_shape": try Self.tensor([640, 640], shape: [1, 2]),
            "scale_factor": try Self.tensor([640 / Float(image.height), 640 / Float(image.width)], shape: [1, 2])
        ]
        let preprocessMS = (ProcessInfo.processInfo.systemUptime - preprocessStart) * 1000
        try Task.checkCancellation()
        let inferenceStart = ProcessInfo.processInfo.systemUptime
        let outputs = try session.run(withInputs: inputs, outputNames: Set([metadata.boxesOutputName, metadata.countOutputName]), runOptions: nil)
        let inferenceMS = (ProcessInfo.processInfo.systemUptime - inferenceStart) * 1000
        let postStart = ProcessInfo.processInfo.systemUptime
        guard let boxes = outputs[metadata.boxesOutputName], let count = outputs[metadata.countOutputName] else { throw LayoutRuntimeError.invalid("Output layout kosong.") }
        let shapeInfo = try boxes.tensorTypeAndShapeInfo()
        let shape = shapeInfo.shape.map(\.intValue)
        guard shapeInfo.elementType == .float, shape.count == 2, shape[1] == 6 else { throw LayoutRuntimeError.invalid("Shape output layout bukan [N,6] float32: \(shape).") }
        let countData = try count.tensorData() as Data
        let countInfo = try count.tensorTypeAndShapeInfo()
        guard countInfo.elementType == .int32, countData.count == MemoryLayout<Int32>.size else { throw LayoutRuntimeError.invalid("Shape bbox_num bukan satu int32.") }
        let reportedCount = countData.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard reportedCount == shape[0] else { throw LayoutRuntimeError.invalid("bbox_num tidak sama dengan jumlah baris deteksi.") }
        let data = try boxes.tensorData() as Data
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard floats.count == shape[0] * 6 else { throw LayoutRuntimeError.invalid("Panjang tensor layout tidak sesuai shape.") }
        let rows = stride(from: 0, to: floats.count, by: 6).map { offset in Array(floats[offset..<(offset + 6)]).map(Double.init) }
        guard rows.joined().allSatisfy(\.isFinite) else { throw LayoutRuntimeError.invalid("Output layout mengandung nilai non-finite.") }
        var regions = Self.postprocess(rows, metadata: metadata, pageID: pageID, width: image.width, height: image.height)
        let postMS = (ProcessInfo.processInfo.systemUptime - postStart) * 1000
        let artifactStart = ProcessInfo.processInfo.systemUptime
        for index in regions.indices {
            let box = regions[index].bboxPageXYXY
            let rect = CGRect(x: box.xmin, y: box.ymin, width: box.xmax - box.xmin, height: box.ymax - box.ymin)
            guard let crop = image.cropping(to: rect), let png = UIImage(cgImage: crop).pngData() else { throw LayoutRuntimeError.invalid("Crop \(regions[index].id) gagal.") }
            let relative = "pages/\(pageID)/crops/\(regions[index].id).png"
            try png.write(to: pageRoot.appendingPathComponent("crops/\(regions[index].id).png"), options: .atomic)
            regions[index].cropArtifact = relative
        }
        try Self.overlay(image, regions: regions).write(to: pageRoot.appendingPathComponent("layout-overlay.png"), options: .atomic)
        let artifactMS = (ProcessInfo.processInfo.systemUptime - artifactStart) * 1000
        let result = LayoutResult(model: metadata, runtime: "ONNX Runtime 1.24.2", backend: "CPUExecutionProvider", intraOpThreads: 2, modelWasWarm: warm, pageSize: [image.width, image.height], rawBoxes: rows, outputShape: shape, regions: regions, metrics: ["queue_wait_ms": max(0, enqueued - enqueuedAt) * 1000, "model_load_ms": loadMS, "preprocess_ms": preprocessMS, "inference_ms": inferenceMS, "postprocess_ms": postMS, "artifact_write_ms": artifactMS, "total_ms": (ProcessInfo.processInfo.systemUptime - enqueued) * 1000])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: pageRoot.appendingPathComponent("layout.raw.json"), options: .atomic)
        return result
    }

    private static func tensor(_ values: [Float], shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
        return try ORTValue(tensorData: data, elementType: .float, shape: shape.map { NSNumber(value: $0) })
    }

    private static func fileHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func rgbTensor(_ image: CGImage) throws -> [Float] {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            ctx.setFillColor(UIColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw LayoutRuntimeError.invalid("Tidak dapat menyiapkan pixel RGB.") }
        let side = 640, plane = side * side
        var output = [Float](repeating: 0, count: 3 * plane)
        for y in 0..<side {
            if y % 64 == 0 { try Task.checkCancellation() }
            let sy = max(0, min(Double(h - 1), (Double(y) + 0.5) * Double(h) / 640 - 0.5))
            let y0 = Int(sy), y1 = min(y0 + 1, h - 1), fy = sy - Double(y0)
            for x in 0..<side {
                let sx = max(0, min(Double(w - 1), (Double(x) + 0.5) * Double(w) / 640 - 0.5))
                let x0 = Int(sx), x1 = min(x0 + 1, w - 1), fx = sx - Double(x0)
                for c in 0..<3 {
                    let top = Double(rgba[(y0 * w + x0) * 4 + c]) * (1 - fx) + Double(rgba[(y0 * w + x1) * 4 + c]) * fx
                    let bottom = Double(rgba[(y1 * w + x0) * 4 + c]) * (1 - fx) + Double(rgba[(y1 * w + x1) * 4 + c]) * fx
                    output[c * plane + y * side + x] = Float((top * (1 - fy) + bottom * fy).rounded()) * (1 / Float(255))
                }
            }
        }
        return output
    }

    private static func postprocess(_ rows: [[Double]], metadata: LayoutModelMetadata, pageID: String, width: Int, height: Int) -> [LayoutRegion] {
        // Score filter and PaddleX layout NMS, then large-image filter. No containment deletion.
        let ranked = rows.indices.filter { rows[$0][1] > metadata.scoreThreshold && rows[$0][0] >= 0 && rows[$0][0] < Double(metadata.labels.count) }.sorted { rows[$0][1] == rows[$1][1] ? $0 < $1 : rows[$0][1] > rows[$1][1] }
        func box(_ row: [Double]) -> PixelBox { PixelBox(xmin: row[2], ymin: row[3], xmax: row[4], ymax: row[5]) }
        var kept: [Int] = []
        for i in ranked {
            if !kept.contains(where: { box(rows[i]).iou(box(rows[$0])) >= (rows[i][0] == rows[$0][0] ? metadata.nmsSameClassIOU : metadata.nmsDifferentClassIOU) }) { kept.append(i) }
        }
        let filtered = kept.filter { i in
            guard kept.count > 1, metadata.labels[Int(rows[i][0])] == "image" else { return true }
            let b = box(rows[i]); let clamped = PixelBox(xmin: max(0, b.xmin), ymin: max(0, b.ymin), xmax: min(Double(width), b.xmax), ymax: min(Double(height), b.ymax))
            return clamped.area <= (width > height ? 0.82 : 0.93) * Double(width * height)
        }
        if !filtered.isEmpty { kept = filtered }
        var regions = kept.compactMap { i -> LayoutRegion? in
            let row = rows[i], raw = box(row)
            let b = PixelBox(xmin: max(0, min(Double(width), floor(raw.xmin))), ymin: max(0, min(Double(height), floor(raw.ymin))), xmax: max(0, min(Double(width), ceil(raw.xmax))), ymax: max(0, min(Double(height), ceil(raw.ymax))))
            guard b.area > 0 else { return nil }
            return LayoutRegion(id: "\(pageID).layout.\(String(format: "%04d", i + 1))", classID: Int(row[0]), label: metadata.labels[Int(row[0])], score: row[1], bboxPageXYXY: b, rawIndex: i, parentID: nil, cropArtifact: nil)
        }.sorted(by: LayoutMerge.precedes)
        for index in regions.indices {
            let child = regions[index]
            regions[index].parentID = regions.filter { candidate in
                candidate.id != child.id && candidate.bboxPageXYXY.area > child.bboxPageXYXY.area * 1.01 && candidate.bboxPageXYXY.intersection(child.bboxPageXYXY) / max(1, child.bboxPageXYXY.area) >= 0.95
            }.min { $0.bboxPageXYXY.area == $1.bboxPageXYXY.area ? $0.id < $1.id : $0.bboxPageXYXY.area < $1.bboxPageXYXY.area }?.id
        }
        return regions
    }

    private static func overlay(_ image: CGImage, regions: [LayoutRegion]) throws -> Data {
        let size = CGSize(width: image.width, height: image.height)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIImage(cgImage: image).draw(at: .zero)
            for region in regions {
                let b = region.bboxPageXYXY
                let color: UIColor = region.label == "formula" ? .systemRed : .systemBlue
                context.cgContext.setStrokeColor(color.cgColor); context.cgContext.setLineWidth(2)
                context.cgContext.stroke(CGRect(x: b.xmin, y: b.ymin, width: b.xmax - b.xmin, height: b.ymax - b.ymin))
                let title = "\(region.label) \(String(format: "%.2f", region.score))"
                (title as NSString).draw(at: CGPoint(x: b.xmin, y: max(0, b.ymin - 16)), withAttributes: [.font: UIFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: color, .backgroundColor: UIColor.white.withAlphaComponent(0.85)])
            }
        }
        guard let data = rendered.pngData() else { throw LayoutRuntimeError.invalid("Overlay layout gagal ditulis.") }
        return data
    }
}
