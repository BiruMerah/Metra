import CryptoKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ModelAssetManager: ObservableObject {
    @Published private(set) var modelDirectory: URL?
    @Published private(set) var isBundledModel = false
    @Published private(set) var status = "Model diagram belum tersedia di aplikasi."
    @Published private(set) var isImporting = false
    @Published private(set) var lastImportReportURL: URL?

    private let preferenceKey = "metra.qwen.model.relative-path"
    private let expectedWeightsSHA256 = "4750d95a2162829e127a94e83ac350d498d02070aab216c4687da48804a06ffb"
    private var verifiedDirectory: URL?

    var hasStagedCheckpoint: Bool {
        guard let documents = try? ImageIngestor.documentsURL() else { return false }
        return FileManager.default.fileExists(atPath:documents.appendingPathComponent("metra-model-staging/Qwen3-VL-2B-4bit/model.safetensors").path)
    }

    init() { restore() }

    func restore() {
        modelDirectory = nil
        isBundledModel = false
        verifiedDirectory = nil
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Qwen3-VL-2B-4bit", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) {
            do {
                // Startup checks structure/size; the full streamed hashes are
                // checked asynchronously before first use, without copying it.
                try Self.validateBundle(bundled, expectedHash: expectedWeightsSHA256, fullHashes: false)
                modelDirectory = bundled
                isBundledModel = true
                status = "Model diagram sudah disertakan di aplikasi."
                return
            } catch {
                status = "Model diagram bawaan belum valid: \(error.localizedDescription)"
            }
        }
        guard let relative = UserDefaults.standard.string(forKey: preferenceKey),
              let support = Self.applicationSupportURL() else { return }
        let candidate = support.appendingPathComponent(relative, isDirectory: true)
        guard Self.requiredFiles.allSatisfy({ FileManager.default.fileExists(atPath:candidate.appendingPathComponent($0).path) }) else {
            status = "Checkpoint tambahan sebelumnya tidak lengkap. Siapkan model bawaan saat build atau impor ulang folder model."
            return
        }
        guard let data = try? Data(contentsOf:candidate.appendingPathComponent("metra-import-manifest.json")),
              let manifest = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              manifest["weights_sha256"] as? String == expectedWeightsSHA256,
              let expectedBytes = manifest["weights_bytes"] as? Int, expectedBytes > 0,
              let actualBytes = try? candidate.appendingPathComponent("model.safetensors").resourceValues(forKeys:[.fileSizeKey]).fileSize,
              actualBytes == expectedBytes else {
            status = "Checkpoint di iPhone ini belum mempunyai bukti impor lengkap atau ukuran file berubah. Impor ulang folder model."
            return
        }
        modelDirectory = candidate
        status = "Qwen checkpoint siap. File bobot telah diverifikasi saat impor."
    }

    func prepareForInference() async throws {
        guard let directory = modelDirectory, verifiedDirectory != directory else { return }
        let bundled = isBundledModel
        let expectedHash = expectedWeightsSHA256
        do {
            try await Task.detached(priority: .utility) {
                if bundled {
                    try Self.validateBundle(directory, expectedHash: expectedHash, fullHashes: true)
                } else {
                    let digest = try Self.sha256(fileURL: directory.appendingPathComponent("model.safetensors"))
                    guard digest == expectedHash else { throw ModelAssetError.weightsHashMismatch(actual: digest) }
                }
            }.value
            try Task.checkCancellation()
            verifiedDirectory = directory
            status = bundled ? "Model diagram bawaan terverifikasi dan siap." : "Model diagram terverifikasi dan siap."
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            modelDirectory = nil
            isBundledModel = false
            status = "Model diagram belum dapat digunakan: \(error.localizedDescription)"
            lastImportReportURL = Self.writeImportReport(sourceName: directory.lastPathComponent, error: error)
            throw error
        }
    }

    nonisolated private static func validateBundle(_ directory: URL, expectedHash: String, fullHashes: Bool) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("metra-bundle-manifest.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["schema"] as? String == "metra-bundled-qwen-v1",
              manifest["model_id"] as? String == "mlx-community/Qwen3-VL-2B-Instruct-4bit",
              manifest["revision"] as? String == "9c4f5209e57b31f4b9dfba735de3fb983739c9cc",
              manifest["weights_sha256"] as? String == expectedHash,
              manifest["weights_bytes"] as? Int == 1_782_040_921,
              let rows = manifest["files"] as? [[String: Any]] else {
            throw ModelAssetError.invalidBundledModel
        }
        let names = Set(rows.compactMap { $0["file"] as? String })
        guard names.count == rows.count, Set(requiredFiles).isSubset(of: names),
              names.contains("chat_template.jinja") || names.contains("chat_template.json"),
              rows.contains(where: { $0["file"] as? String == "model.safetensors" && $0["sha256"] as? String == expectedHash }) else {
            throw ModelAssetError.invalidBundledModel
        }
        for row in rows {
            guard let name = row["file"] as? String, !name.contains("/"), name != ".", name != "..",
                  let size = row["bytes"] as? Int, let expected = row["sha256"] as? String else {
                throw ModelAssetError.invalidBundledModel
            }
            let file = directory.appendingPathComponent(name)
            guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == size else {
                throw ModelAssetError.invalidBundledModel
            }
            if fullHashes {
                let digest = try sha256(fileURL: file)
                guard digest == expected else { throw ModelAssetError.invalidBundledModel }
            }
        }
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as? [String: Any]
        let quantization = config?["quantization"] as? [String: Any] ?? config?["quantization_config"] as? [String: Any]
        guard config?["model_type"] as? String == "qwen3_vl", config?["vision_config"] as? [String: Any] != nil,
              quantization?["bits"] as? Int == 4, quantization?["group_size"] as? Int == 64,
              quantization?["mode"] as? String == "affine" else { throw ModelAssetError.invalidBundledModel }
    }

    func importFolder(_ folderURL: URL) {
        Task { try? await importVerifiedFolder(folderURL) }
    }

    /// Async facade for the app service; pinning, copy and verification are unchanged.
    func importVerifiedFolder(_ folderURL: URL) async throws {
        guard !isImporting else { throw CocoaError(.fileWriteFileExists) }
        isImporting = true
        status = "Menyalin dan memverifikasi checkpoint lokal..."
        let didAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            isImporting = false
            if didAccess { folderURL.stopAccessingSecurityScopedResource() }
        }
        do {
            let hash = expectedWeightsSHA256
            let imported = try await Task.detached(priority: .utility) {
                try Self.copyAndVerify(folderURL, expectedHash: hash)
            }.value
            modelDirectory = imported.directory
            isBundledModel = false
            verifiedDirectory = imported.directory
            status = "Qwen 2B 4-bit terimpor; SHA-256 bobot cocok dengan revision yang dipin."
            lastImportReportURL = Self.writeImportReport(sourceName: folderURL.lastPathComponent, error: nil)
        } catch {
            status = "Impor model gagal: \(error.localizedDescription)"
            lastImportReportURL = Self.writeImportReport(sourceName: folderURL.lastPathComponent, error: error)
            throw error
        }
    }

    /// Device preparation only: a fixed sandbox staging directory, copied offline
    /// with devicectl. The same full hash/config verification as Files import applies.
    func importStagedCheckpoint() async throws {
        guard !isImporting else { throw CocoaError(.fileWriteFileExists) }
        isImporting = true
        status = "Memverifikasi checkpoint yang disalin ke iPhone…"
        defer { isImporting = false }
        let staging = try ImageIngestor.documentsURL().appendingPathComponent("metra-model-staging/Qwen3-VL-2B-4bit", isDirectory: true)
        do {
            let hash = expectedWeightsSHA256
            let imported = try await Task.detached(priority: .utility) { try Self.copyAndVerify(staging, expectedHash: hash) }.value
            modelDirectory = imported.directory
            isBundledModel = false
            verifiedDirectory = imported.directory
            status = "Qwen siap untuk gambar dan diagram; hash checkpoint cocok."
            lastImportReportURL = Self.writeImportReport(sourceName:staging.lastPathComponent,error:nil)
            try? FileManager.default.removeItem(at: staging)
        } catch {
            status = "Aktivasi model tersalin gagal: \(error.localizedDescription)"
            lastImportReportURL = Self.writeImportReport(sourceName:staging.lastPathComponent,error:error)
            throw error
        }
    }

    nonisolated private static let requiredFiles = ["model.safetensors","config.json","tokenizer.json","tokenizer_config.json","preprocessor_config.json"]

    nonisolated private static func copyAndVerify(_ source: URL, expectedHash: String) throws -> (directory: URL, digest: String) {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath:source.path,isDirectory:&isDirectory), isDirectory.boolValue else { throw ModelAssetError.selectModelFolder }
        let missing = requiredFiles.filter { !fileManager.fileExists(atPath:source.appendingPathComponent($0).path) }
        guard missing.isEmpty else { throw ModelAssetError.missingFiles(missing) }
        guard ["chat_template.jinja","chat_template.json"].contains(where:{fileManager.fileExists(atPath:source.appendingPathComponent($0).path)}) else {
            throw ModelAssetError.missingFiles(["chat_template.jinja atau chat_template.json"])
        }
        let stagingID = UUID().uuidString.lowercased()
        guard let support = applicationSupportURL() else { throw CocoaError(.fileNoSuchFile) }
        let modelsRoot = support.appendingPathComponent("MetraModels", isDirectory: true)
        try fileManager.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        let staging = modelsRoot.appendingPathComponent("import-\(stagingID)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at:staging,withIntermediateDirectories:true)
        let children = try fileManager.contentsOfDirectory(at:source,includingPropertiesForKeys:[.isDirectoryKey],options:[.skipsHiddenFiles])
        // Copy file contents, never Hugging Face cache symlinks into the sandbox.
        for child in children where ["json","txt","jinja","safetensors"].contains(child.pathExtension.lowercased()) {
            let resolved = child.resolvingSymlinksInPath()
            guard (try resolved.resourceValues(forKeys:[.isDirectoryKey])).isDirectory != true else { continue }
            do {
                let input = try FileHandle(forReadingFrom:resolved)
                defer { try? input.close() }
                let target = staging.appendingPathComponent(child.lastPathComponent)
                guard fileManager.createFile(atPath:target.path,contents:nil) else { throw CocoaError(.fileWriteUnknown) }
                let output = try FileHandle(forWritingTo:target)
                defer { try? output.close() }
                while let data = try input.read(upToCount:8*1024*1024), !data.isEmpty { try output.write(contentsOf:data) }
            } catch { throw ModelAssetError.fileCopyFailed(child.lastPathComponent,error.localizedDescription) }
        }

        let modelURL = staging.appendingPathComponent("model.safetensors")
        let configURL = staging.appendingPathComponent("config.json")
        guard fileManager.fileExists(atPath: modelURL.path), fileManager.fileExists(atPath: configURL.path) else {
            throw ModelAssetError.incompleteFolder
        }
        let configData = try Data(contentsOf: configURL)
        guard let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
              config["model_type"] as? String == "qwen3_vl" else {
            throw ModelAssetError.wrongModelFamily
        }
        guard config["vision_config"] as? [String: Any] != nil else {
            throw ModelAssetError.missingVisionConfig
        }
        let quantization = config["quantization"] as? [String: Any] ?? config["quantization_config"] as? [String: Any]
        guard (quantization?["bits"] as? Int) == 4,
              (quantization?["group_size"] as? Int) == 64,
              (quantization?["mode"] as? String) == "affine" else {
            throw ModelAssetError.wrongQuantization
        }
        guard fileManager.fileExists(atPath: staging.appendingPathComponent("preprocessor_config.json").path),
              fileManager.fileExists(atPath: staging.appendingPathComponent("tokenizer.json").path) else {
            throw ModelAssetError.processorFilesMissing
        }

        let digest = try Self.sha256(fileURL: modelURL)
        guard digest == expectedHash else { throw ModelAssetError.weightsHashMismatch(actual: digest) }
        let weightsBytes = (try? modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        let finalDirectory = modelsRoot.appendingPathComponent("Qwen3-VL-2B-4bit-\(stagingID)", isDirectory: true)
        let manifest: [String: Any] = [
            "schema": "metra-imported-model-v1",
            "model_id": "mlx-community/Qwen3-VL-2B-Instruct-4bit",
            "revision": "9c4f5209e57b31f4b9dfba735de3fb983739c9cc",
            "model_type": "qwen3_vl",
            "vision_config_present": (config["vision_config"] as? [String: Any]) != nil,
            "quantization": ["bits": 4, "group_size": 64, "mode": "affine"],
            "weights_sha256": digest,
            "weights_bytes": weightsBytes,
            "parameter_mapping": ["temperature": "GenerateParameters.temperature", "top_p": "GenerateParameters.topP", "seed": "GenerateParameters.seed", "max_tokens": "GenerateParameters.maxTokens", "max_image_side": "adapter resize before MLXVLM preprocessing", "cache_limit": "MLX.Memory.cacheLimit"]
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: staging.appendingPathComponent("metra-import-manifest.json"), options: .atomic)
        try fileManager.moveItem(at: staging, to: finalDirectory)
        let relative = "MetraModels/\(finalDirectory.lastPathComponent)"
        UserDefaults.standard.set(relative, forKey: "metra.qwen.model.relative-path")
        return (finalDirectory, digest)
    }

    nonisolated private static func sha256(fileURL: URL) throws -> String {
        guard let stream = InputStream(url:fileURL) else { throw CocoaError(.fileReadUnknown) }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 8 * 1024 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func applicationSupportURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    nonisolated private static func writeImportReport(sourceName:String,error:Error?) -> URL? {
        do {
            let directory = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
                .appendingPathComponent("metra-model-imports/\(UUID().uuidString.lowercased())",isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let report:[String:Any] = ["schema":"metra-model-import-report-v1","date":ISO8601DateFormatter().string(from:Date()),
                "source_folder_name":sourceName,"status":error == nil ? "succeeded" : "failed",
                "error":error.map { ["description":$0.localizedDescription,"detail":String(describing:$0)] } as Any? ?? NSNull(),
                "model_id":"mlx-community/Qwen3-VL-2B-Instruct-4bit","revision":"9c4f5209e57b31f4b9dfba735de3fb983739c9cc",
                "inference_run":false]
            let url = directory.appendingPathComponent("report.json")
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
            return url
        } catch { return nil }
    }
}

enum ModelAssetError: LocalizedError {
    case invalidBundledModel
    case missingFiles([String])
    case fileCopyFailed(String,String)
    case selectModelFolder
    case incompleteFolder
    case wrongModelFamily
    case missingVisionConfig
    case wrongQuantization
    case processorFilesMissing
    case weightsHashMismatch(actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidBundledModel: "Aset model bawaan tidak cocok dengan checkpoint yang dipin. Siapkan ulang aset Qwen pada Mac dan build kembali aplikasi."
        case .missingFiles(let files): "Folder model belum lengkap atau tautannya rusak: \(files.joined(separator:", ")). Pilih folder berisi file model asli yang sudah tersalin lokal."
        case .fileCopyFailed(let name,let reason): "Gagal menyalin \(name): \(reason). Pastikan file sudah tersedia lokal dan ruang penyimpanan cukup."
        case .selectModelFolder: "Pilih folder checkpoint, bukan file tunggal."
        case .incompleteFolder: "Folder perlu memuat config.json dan model.safetensors."
        case .wrongModelFamily: "config.json bukan model_type qwen3_vl."
        case .missingVisionConfig: "config.json tidak memuat vision_config; checkpoint tidak dapat digunakan sebagai VLM."
        case .wrongQuantization: "Checkpoint bukan quantization affine 4-bit group size 64 yang dipin."
        case .processorFilesMissing: "preprocessor_config.json atau tokenizer.json tidak ada."
        case .weightsHashMismatch(let actual): "SHA-256 model.safetensors tidak cocok: \(actual). Folder tidak diaktifkan."
        }
    }
}
