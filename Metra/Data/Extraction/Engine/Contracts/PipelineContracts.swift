import Foundation

enum SourceOrigin: String, Codable, Sendable {
    case files
    case photoLibrary = "photo_library"
    case camera

    var title: String {
        switch self {
        case .files: "Files"
        case .photoLibrary: "Galeri"
        case .camera: "Kamera"
        }
    }
}

enum RunProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case serialBaseline = "serial_baseline"
    case boundedParallel = "bounded_parallel"

    var id: String { rawValue }
    var title: String { self == .serialBaseline ? "Serial baseline" : "Paralel terbatas" }
    var pageConcurrency: Int { self == .serialBaseline ? 1 : 2 }
    var visionConcurrency: Int { 1 }
}

enum RuntimeStatus: String, Codable, Sendable {
    case running
    case complete
    case partial
    case failed
    case cancelled
    case interrupted
}

enum ReviewStatus: String, Codable, Sendable {
    case notAssessed = "not_assessed"
    case needsReview = "needs_review"
    case pass
    case fail
}

struct PixelBox: Codable, Hashable, Sendable {
    var xmin: Double
    var ymin: Double
    var xmax: Double
    var ymax: Double

    var array: [Double] { [xmin, ymin, xmax, ymax] }
}

struct ImportedSourcePage: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let fileName: String
    let relativeDirectory: String
    let origin: SourceOrigin
    let sourceSHA256: String
    let sourceByteCount: Int64
    let sourceUTI: String?
    let sourceWidth: Int?
    let sourceHeight: Int?
    let sourceEXIFOrientation: Int?
    let captureRepresentation: String?
    let normalizedFileName: String
    let normalizedSHA256: String
    let normalizedWidth: Int
    let normalizedHeight: Int
    let ingestedAt: String
    let normalizationMilliseconds: Double
    let sandboxCopyMilliseconds: Double

    var displayName: String { fileName }
}

struct OCRCandidate: Codable, Sendable {
    let text: String
    let confidence: Float
}

struct OCRRangeBox: Codable, Sendable {
    let rangeUTF16: [Int]
    let bboxPageXYXY: PixelBox
}

struct OCRObservation: Codable, Identifiable, Sendable {
    let id: String
    let rawOrder: Int
    let bboxPageXYXY: PixelBox
    let candidates: [OCRCandidate]
    var rangeBoxes: [OCRRangeBox]? = nil
    var numericEvidence: VisualNumericEvidence? = nil
    /// Explicit secondary OCR selection. Original Vision candidates/confidence
    /// and same-length UTF-16 boxes remain unchanged; derivation is separately saved.
    var selectedTextOverride: String? = nil
    var selectionEngine: String? = nil
    var selectionArtifact: String? = nil

    var selectedText: String { selectedTextOverride ?? candidates.first?.text ?? "" }
}

struct ComponentResult: Codable, Sendable {
    let component: String
    let status: String
    let errorCode: String?
    let message: String?
    let rawArtifact: String?
    let metrics: [String: Double?]
}

struct TextSegment: Codable, Sendable {
    let id: String
    let kind: String
    let textRaw: String
    let sourceObservationID: String?
    let sourceRangeUTF16: [Int]
    let status: String
    let spokenText: String?
    var formulaID: String? = nil
    var mergeMethod: String? = nil
    var mergeNote: String? = nil
    /// A redundant enclosing detection whose complete content is already owned
    /// by these disjoint formula occurrences. It has no second source range.
    var coveredByFormulaIDs: [String]? = nil
}

struct ExtractionBlock: Codable, Identifiable, Sendable {
    let id: String
    let pageID: String
    let kind: String
    let bboxPageXYXY: PixelBox
    let readingOrder: Int
    let parentID: String?
    let sourceRegionIDs: [String]
    let segments: [TextSegment]
    let children: [String]
    let status: String
    let uncertainties: [String]
}

struct PageExtraction: Codable, Identifiable, Sendable {
    let id: String
    let source: ImportedSourcePage
    let runtimeStatus: RuntimeStatus
    let sourceCoverageStatus: ReviewStatus
    let contentQualityStatus: ReviewStatus
    let readingOrderMethod: String
    let rawOCR: [OCRObservation]
    let components: [ComponentResult]
    let blocks: [ExtractionBlock]
    let formulaCounts: FormulaCounts
    var layoutRegions: [LayoutRegion]? = nil
    var formulaRegions: [FormulaRegion]? = nil
    var mergePolicyVersion: String? = nil
    var diagrams: [DiagramRegionResult]? = nil
}

struct FormulaCounts: Codable, Sendable {
    let detected: Int?
    let recognized: Int
    let spoken: Int
    let unresolved: Int?
    let missedOnReviewedPages: Int?
}

struct ExtractionDocument: Codable, Sendable {
    let schema: String
    let runID: String
    let profile: RunProfile
    let runtimeStatus: RuntimeStatus
    let sourceCoverageStatus: ReviewStatus
    let contentQualityStatus: ReviewStatus
    let startedAt: String
    let completedAt: String?
    let pages: [PageExtraction]
}

struct DiagramProbeOutput: Codable, Sendable {
    struct DiagramObject: Codable, Sendable {
        let id: String
        let kind: String
        let description: String
        let evidenceBox: [Int]
    }
    struct LabelLink: Codable, Sendable {
        let labelID: String
        let objectID: String
        let evidenceBox: [Int]
    }
    struct Relation: Codable, Sendable {
        let kind: String
        let objectIDs: [String]
        let description: String
        let evidenceBox: [Int]
    }
    struct MathLink: Codable, Sendable {
        let formulaID: String
        let objectID: String
        let evidenceBox: [Int]
    }
    struct Uncertainty: Codable, Sendable {
        let kind: String
        let description: String
        let evidenceBox: [Int]
    }

    let objects: [DiagramObject]
    let labelLinks: [LabelLink]
    let relations: [Relation]
    let mathLinks: [MathLink]
    let uncertainties: [Uncertainty]
}
