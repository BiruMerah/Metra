import Foundation
import ImageIO
import MLX
import MLXGuidedGeneration
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers
import UniformTypeIdentifiers

struct QwenDiagramResult: Codable, Sendable {
    let rawText: String
    let loadMilliseconds: Double
    let preprocessMilliseconds: Double
    let inferenceMilliseconds: Double
    let timeToFirstTextMilliseconds: Double?
    let promptHash: String
    let boundedImageURL: URL
    let inputSize: [Int]
    let outputTokenCount: Int?
    let cacheLimitBytes: Int
    let modelWasWarm: Bool
    let promptTokenCount: Int
    let stopReason: String
    let visionInput: Bool
    var grammarWasWarm: Bool? = nil
    var grammarTokenizerWasWarm: Bool? = nil
    var grammarMilliseconds: Double? = nil
    var decodingMode: String? = nil
    var schemaHash: String? = nil
    var inputImageSHA256: String? = nil
    var whitespaceBiasPolicy: String? = nil
}

struct QwenTextResult: Codable, Sendable {
    let modelID: String
    let revision: String
    let rawText: String
    let promptHash: String
    let promptTokenCount: Int
    let outputTokenCount: Int?
    let stopReason: String
    let loadMilliseconds: Double
    let preprocessMilliseconds: Double
    let inferenceMilliseconds: Double
    let timeToFirstTextMilliseconds: Double?
    let modelWasWarm: Bool
    let inputMode: String
}

actor QwenDiagramRuntime {
    private var modelContainer: ModelContainer?
    private var loadedDirectory: URL?
    private let captionGrammar = CaptionGrammarCache()
    private let sourceModelID = "mlx-community/Qwen3-VL-2B-Instruct-4bit"
    private let sourceRevision = "9c4f5209e57b31f4b9dfba735de3fb983739c9cc"
    private let cacheLimitBytes = 268_435_456

    func unload() {
        modelContainer = nil
        loadedDirectory = nil
        MLX.Memory.clearCache()
    }

    /// Same pinned checkpoint; no image input or vision encoder execution for topics.
    /// The coordinator owns the heavy gate and serializes diagram/topic requests.
    func groupTopics(prompt: String, modelDirectory: URL, outputDirectory: URL) async throws -> QwenTextResult {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let rawURL = outputDirectory.appendingPathComponent("response.raw.txt")
        try "".write(to: rawURL, atomically: true, encoding: .utf8)
        try Task.checkCancellation()
        let warm = modelContainer != nil && loadedDirectory == modelDirectory
        var loadMS = 0.0
        if !warm {
            MLX.Memory.cacheLimit = cacheLimitBytes
            let start = ProcessInfo.processInfo.systemUptime
            modelContainer = try await VLMModelFactory.shared.loadContainer(from: modelDirectory, using: #huggingFaceTokenizerLoader())
            loadedDirectory = modelDirectory
            loadMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        guard let modelContainer else { throw QwenDiagramError.modelLoadFailed }
        try Task.checkCancellation()
        let parameters = GenerateParameters(maxTokens: 2048, temperature: 0, topP: 1, seed: 0)
        // Keep the generation task handle so cancellation/deadline can be drained
        // before the heavy gate is released or another model is loaded.
        // Prepare non-Sendable tensors inside ModelContainer's exclusive context.
        let (stream, generationTask, tokenCount, preprocessMS, generationStart) = try await modelContainer.perform { (context: ModelContext) in
            let inputStart = ProcessInfo.processInfo.systemUptime
            let input = try await context.processor.prepare(input: UserInput(prompt: prompt))
            let count = input.text.tokens.size
            guard count <= 6000 else { throw TopicGroupingError.inputBudgetExceeded }
            let preprocess = (ProcessInfo.processInfo.systemUptime - inputStart) * 1000
            let generationStart = ProcessInfo.processInfo.systemUptime
            let iterator = try TokenIterator(input: input, model: context.model, parameters: parameters)
            let (stream, task) = MLXLMCommon.generateTask(promptTokenCount: count, modelConfiguration: context.configuration, tokenizer: context.tokenizer, iterator: iterator, toolCallPolicy: parameters.toolCallPolicy)
            return (stream, task, count, preprocess, generationStart)
        }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(120)); generationTask.cancel() }
            catch { }
        }
        var raw = "", stopReason = "unknown"
        var outputTokens: Int?, firstTextMS: Double?
        var lastPersist = generationStart
        await withTaskCancellationHandler {
            for await item in stream {
                switch item {
                case .chunk(let text):
                    if firstTextMS == nil && !text.isEmpty { firstTextMS = (ProcessInfo.processInfo.systemUptime - generationStart) * 1000 }
                    raw += text
                    // Preserve partial generation across cancellation or app termination.
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastPersist >= 0.5 {
                        try? raw.write(to: rawURL, atomically: true, encoding: .utf8)
                        lastPersist = now
                    }
                case .info(let info):
                    outputTokens = info.generationTokenCount
                    switch info.stopReason {
                    case .stop: stopReason = "stop"
                    case .length: stopReason = "length"
                    case .cancelled: stopReason = "cancelled"
                    }
                case .toolCall, .rejectedToolCall: stopReason = "unexpected_tool_call"
                }
            }
        } onCancel: { generationTask.cancel() }
        generationTask.cancel()
        await generationTask.value
        deadline.cancel()
        try raw.write(to: rawURL, atomically: true, encoding: .utf8)
        let inferenceMS = (ProcessInfo.processInfo.systemUptime - generationStart) * 1000
        if Task.isCancelled { stopReason = "cancelled" }
        else if stopReason == "cancelled", inferenceMS >= 120_000 { stopReason = "deadline" }
        return QwenTextResult(modelID: sourceModelID, revision: sourceRevision, rawText: raw,
                              promptHash: ImageIngestor.sha256(Data(prompt.utf8)), promptTokenCount: tokenCount,
                              outputTokenCount: outputTokens, stopReason: stopReason,
                              loadMilliseconds: loadMS, preprocessMilliseconds: preprocessMS, inferenceMilliseconds: inferenceMS,
                              timeToFirstTextMilliseconds: firstTextMS, modelWasWarm: warm, inputMode: "text_only")
    }

    func observe(
        imageURL: URL,
        modelDirectory: URL,
        prompt: String,
        outputDirectory: URL
    ) async throws -> QwenDiagramResult {
        try Task.checkCancellation()
        let bounded = try Self.makeBoundedPNG(from: imageURL, outputDirectory: outputDirectory, maxSide: 1008)
        let rawURL = outputDirectory.appendingPathComponent("response.raw.txt")
        try "".write(to: rawURL, atomically: true, encoding: .utf8)
        let promptHash = ImageIngestor.sha256(Data(prompt.utf8))
        var loadMilliseconds = 0.0
        let modelWasWarm = modelContainer != nil && loadedDirectory == modelDirectory
        if modelContainer == nil || loadedDirectory != modelDirectory {
            MLX.Memory.cacheLimit = cacheLimitBytes
            let start = ProcessInfo.processInfo.systemUptime
            let loaded = try await VLMModelFactory.shared.loadContainer(
                from: modelDirectory,
                using: #huggingFaceTokenizerLoader()
            )
            modelContainer = loaded
            loadedDirectory = modelDirectory
            loadMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        guard let modelContainer else { throw QwenDiagramError.modelLoadFailed }

        try Task.checkCancellation()
        let (stream, generationTask, promptTokens, preprocessMilliseconds, generationStart) = try await modelContainer.perform { (context: ModelContext) in
            let start = ProcessInfo.processInfo.systemUptime
            var userInput = UserInput(prompt: prompt, images: [.url(bounded.url)])
            userInput.processing = .init(maxPixels: 1008 * 1008)
            let input = try await context.processor.prepare(input: userInput)
            let count = input.text.tokens.size
            guard count <= 8000 else { throw QwenDiagramError.inputBudgetExceeded }
            let prepareMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let parameters = GenerateParameters(maxTokens: 2048, temperature: 0, topP: 1, seed: 0)
            let generationStart = ProcessInfo.processInfo.systemUptime
            let iterator = try TokenIterator(input: input, model: context.model, parameters: parameters)
            let (stream, task) = MLXLMCommon.generateTask(promptTokenCount: count, modelConfiguration: context.configuration, tokenizer: context.tokenizer, iterator: iterator, toolCallPolicy: parameters.toolCallPolicy)
            return (stream, task, count, prepareMS, generationStart)
        }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(180)); generationTask.cancel() } catch { }
        }
        var raw = ""
        var firstTextAt: Double?
        var generatedTokens: Int?
        var stopReason = "unknown"
        var lastPersist = generationStart
        await withTaskCancellationHandler {
          for await item in stream {
            switch item {
            case .chunk(let text):
                if firstTextAt == nil && !text.isEmpty {
                    firstTextAt = (ProcessInfo.processInfo.systemUptime - generationStart) * 1000
                }
                raw.append(text)
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastPersist >= 0.5 {
                    try? raw.write(to: rawURL, atomically: true, encoding: .utf8)
                    lastPersist = now
                }
            case .info(let info):
                generatedTokens = info.generationTokenCount
                switch info.stopReason {
                case .stop: stopReason = "stop"
                case .length: stopReason = "length"
                case .cancelled: stopReason = "cancelled"
                }
            case .toolCall, .rejectedToolCall:
                stopReason = "unexpected_tool_call"
            }
          }
        } onCancel: { generationTask.cancel() }
        generationTask.cancel()
        await generationTask.value
        deadline.cancel()
        try raw.write(to: rawURL, atomically: true, encoding: .utf8)
        if Task.isCancelled { stopReason = "cancelled" }
        else if stopReason == "cancelled", ProcessInfo.processInfo.systemUptime - generationStart >= 180 {
            stopReason = "deadline"
        }
        let inferenceMilliseconds = (ProcessInfo.processInfo.systemUptime - generationStart) * 1000
        return QwenDiagramResult(
            rawText: raw,
            loadMilliseconds: loadMilliseconds,
            preprocessMilliseconds: preprocessMilliseconds,
            inferenceMilliseconds: inferenceMilliseconds,
            timeToFirstTextMilliseconds: firstTextAt,
            promptHash: promptHash,
            boundedImageURL: bounded.url,
            inputSize: bounded.size,
            outputTokenCount: generatedTokens,
            cacheLimitBytes: MLX.Memory.cacheLimit,
            modelWasWarm: modelWasWarm,
            promptTokenCount: promptTokens, stopReason: stopReason, visionInput: true
        )
    }

    func observeCaption(imageURL: URL, modelDirectory: URL, prompt: String, outputDirectory: URL, schemaOverride:String? = nil) async throws -> QwenDiagramResult {
        try Task.checkCancellation()
        let bounded = try Self.makeBoundedPNG(from:imageURL,outputDirectory:outputDirectory,maxSide:1008)
        let rawURL = outputDirectory.appendingPathComponent("response.raw.txt")
        try "".write(to:rawURL,atomically:true,encoding:.utf8)
        let warm = modelContainer != nil && loadedDirectory == modelDirectory
        var loadMS = 0.0
        if !warm {
            MLX.Memory.cacheLimit = cacheLimitBytes
            let start = ProcessInfo.processInfo.systemUptime
            modelContainer = try await VLMModelFactory.shared.loadContainer(from:modelDirectory,using:#huggingFaceTokenizerLoader())
            loadedDirectory = modelDirectory
            loadMS = (ProcessInfo.processInfo.systemUptime-start)*1000
        }
        guard let container = modelContainer else { throw QwenDiagramError.modelLoadFailed }
        let schema = schemaOverride ?? Self.captionSchema
        try schema.write(to:outputDirectory.appendingPathComponent("schema.json"),atomically:true,encoding:.utf8)
        let imageHash = ImageIngestor.sha256(try Data(contentsOf:bounded.url))
        let promptHash = ImageIngestor.sha256(Data(prompt.utf8))
        let cacheLimit = cacheLimitBytes
        let measuredLoad = loadMS
        let grammarCache = captionGrammar
        let grammarKey = modelDirectory.path + ImageIngestor.sha256(Data(schema.utf8))
        // This detached task owns synchronous grammar compilation/Metal generation.
        // Keep its handle and drain it on cancellation before releasing the heavy gate.
        let generationTask = Task.detached(priority:.userInitiated) {
            try await container.perform { (context: ModelContext) in
                let prepareStart = ProcessInfo.processInfo.systemUptime
                var userInput = UserInput(prompt:prompt,images:[.url(bounded.url)])
                userInput.processing = .init(maxPixels:1008*1008)
                let input = try await context.processor.prepare(input:userInput)
                let count = input.text.tokens.size
                guard count <= 8000 else { throw QwenDiagramError.inputBudgetExceeded }
                let prepareMS = (ProcessInfo.processInfo.systemUptime-prepareStart)*1000
                let grammarStart = ProcessInfo.processInfo.systemUptime
                let (constraint, vocabSize, tokenizerWarm) = try await grammarCache.constraint(key:grammarKey,tokenizer:context.tokenizer,schema:schema)
                let whitespace = schemaOverride == nil ? nil : WhitespaceTokenBias.compute(tokenizer:context.tokenizer)
                let grammarMS = (ProcessInfo.processInfo.systemUptime-grammarStart)*1000
                let start = ProcessInfo.processInfo.systemUptime
                var raw = "", reason = "stop"
                var firstText: Double?, tokenCount: Int?, lastPersist = start
                do {
                    tokenCount = try GuidedGenerationLoop.run(input:input,context:context,constraint:constraint,maxTokens:2048,vocabSize:vocabSize,
                        completionReserve:0,hardReserve:0,whitespaceBias:whitespace?.bias,whitespaceTokenIDs:whitespace?.tokenIDs ?? []) { delta in
                        if firstText == nil, !delta.isEmpty { firstText = (ProcessInfo.processInfo.systemUptime-start)*1000 }
                        raw += delta
                        let now = ProcessInfo.processInfo.systemUptime
                        if now-lastPersist >= 0.5 {
                            try? raw.write(to:rawURL,atomically:true,encoding:.utf8); lastPersist = now
                        }
                        if Self.hasStagnantSuffix(raw) { reason = "repetitive_output"; return false }
                        if raw.count > (schemaOverride == nil ? 1400 : 4096) { reason = "text_budget_exceeded"; return false }
                        if now-start > 180 { reason = "deadline"; return false }
                        return !Task.isCancelled
                    }
                } catch {
                    reason = error is CancellationError ? "cancelled" : "guided_generation_failed"
                    try? String(describing:error).write(to:outputDirectory.appendingPathComponent("error.txt"),atomically:true,encoding:.utf8)
                }
                if Task.isCancelled { reason = "cancelled" }
                try raw.write(to:rawURL,atomically:true,encoding:.utf8)
                return QwenDiagramResult(rawText:raw,loadMilliseconds:measuredLoad,preprocessMilliseconds:prepareMS,
                    inferenceMilliseconds:(ProcessInfo.processInfo.systemUptime-start)*1000,timeToFirstTextMilliseconds:firstText,
                    promptHash:promptHash,boundedImageURL:bounded.url,inputSize:bounded.size,outputTokenCount:tokenCount,
                    cacheLimitBytes:cacheLimit,modelWasWarm:warm,promptTokenCount:count,stopReason:reason,visionInput:true,
                    grammarWasWarm:false,grammarTokenizerWasWarm:tokenizerWarm,grammarMilliseconds:grammarMS,decodingMode:"xgrammar_json_schema_greedy",schemaHash:ImageIngestor.sha256(Data(schema.utf8)),inputImageSHA256:imageHash,whitespaceBiasPolicy:schemaOverride == nil ? nil : "pinned WhitespaceTokenBias -200 after three consecutive whitespace-only sampled tokens; no closing bias")
            }
        }
        let deadline = Task {
            do { try await Task.sleep(for:.seconds(180)); generationTask.cancel() } catch { }
        }
        do {
            let result = try await withTaskCancellationHandler { try await generationTask.value } onCancel: { generationTask.cancel() }
            deadline.cancel()
            return result
        } catch {
            generationTask.cancel(); _ = await generationTask.result; deadline.cancel(); throw error
        }
    }

    nonisolated private static func hasStagnantSuffix(_ text:String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        for width in 1...6 where words.count >= width*5 {
            let tail = Array(words.suffix(width*5)), unit = Array(words.suffix(width))
            if tail.indices.allSatisfy({ tail[$0] == unit[$0 % width] }) { return true }
        }
        return text.count >= 160 && text.suffix(160).allSatisfy(\.isWhitespace)
    }

    nonisolated static let captionSchema = #"{"type":"object","additionalProperties":false,"required":["visual_type","description","uncertainties"],"properties":{"visual_type":{"type":"string","enum":["pie_chart","bar_chart","line_graph","geometry","illustration","other"]},"description":{"type":"string","pattern":"^[A-Za-z ,;:()\\-]+\\.$"},"uncertainties":{"type":"array","maxItems":3,"items":{"type":"string","enum":["blurred","cropped","ambiguous_structure","unreadable_labels"]}}}}"#

    nonisolated static func makeBoundedPNG(from sourceURL: URL, outputDirectory: URL, maxSide: Int) throws -> (url: URL, size: [Int]) {
        guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide
              ] as CFDictionary) else {
            throw QwenDiagramError.imageDecodeFailed
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory.appendingPathComponent("diagram-input-1008.png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw QwenDiagramError.imageEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw QwenDiagramError.imageEncodingFailed }
        return (url, [image.width, image.height])
    }
}

enum QwenDiagramError: LocalizedError {
    case modelLoadFailed
    case imageDecodeFailed
    case imageEncodingFailed
    case inputBudgetExceeded

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed: "MLXVLM gagal memuat model lokal."
        case .imageDecodeFailed: "Crop diagram tidak dapat didekode."
        case .imageEncodingFailed: "Crop diagram 1008 piksel tidak dapat disimpan."
        case .inputBudgetExceeded: "Input diagram melampaui batas 8000 token."
        }
    }
}


private actor CaptionGrammarCache {
    private var cachedKey: String?
    private var cachedTokenizer: GrammarTokenizer?
    func constraint(key:String, tokenizer:any MLXLMCommon.Tokenizer, schema:String) throws -> (GrammarConstraint,Int,Bool) {
        try Task.checkCancellation()
        let grammarTokenizer: GrammarTokenizer
        let warm = cachedKey == key && cachedTokenizer != nil
        if warm, let cachedTokenizer { grammarTokenizer = cachedTokenizer }
        else {
            let vocab = TokenizerVocabExtractor.extractForGrammar(from:tokenizer)
            grammarTokenizer = try GrammarTokenizer(vocab:vocab.vocab,vocabType:vocab.vocabType,eosTokenId:Int32(tokenizer.eosTokenId ?? 0))
            cachedTokenizer = grammarTokenizer; cachedKey = key
        }
        // The pinned vendored xgrammar is v0.1.30: its fork shim is a stub.
        // Reuse only immutable tokenizer tables. A new grammar/matcher per crop
        // provides isolation through the API that actually works on this version.
        let constraint = try GrammarConstraint(tokenizer:grammarTokenizer,jsonSchema:schema,fastForward:true,hostTokenizer:tokenizer)
        return (constraint,grammarTokenizer.vocabSize,warm)
    }
}
