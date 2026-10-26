import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

struct ImageIngestor {
    private let fileManager = FileManager.default

    func ingestPhotoData(_ data: Data, fileName: String) throws -> ImportedSourcePage {
        try ingest(
            data,
            fileName: fileName,
            origin: .photoLibrary,
            captureRepresentation: "PhotosPicker preferredItemEncoding=current representation; delivered bytes preserved before normalization; original camera asset bytes are not asserted"
        )
    }

    func ingestFile(_ sourceURL: URL) throws -> ImportedSourcePage {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        var readError: NSError?
        var sourceData: Data?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &readError) { safeURL in
            sourceData = try? Data(contentsOf: safeURL, options: [.mappedIfSafe])
        }
        if let readError { throw readError }
        guard let sourceData else { throw CocoaError(.fileReadUnknown) }
        return try ingest(
            sourceData,
            fileName: sourceURL.lastPathComponent,
            origin: .files,
            captureRepresentation: nil
        )
    }

    func ingestCameraImage(_ image: UIImage) throws -> ImportedSourcePage {
        guard let bytes = image.jpegData(compressionQuality: 0.95) else {
            throw IngestError.cameraEncodingFailed
        }
        return try ingest(
            bytes,
            fileName: "camera-\(Self.timestampName()).jpg",
            origin: .camera,
            captureRepresentation: "UIImagePickerController originalImage re-encoded with jpegData(0.95); source EXIF is not asserted"
        )
    }

    /// The presentation adapter already encoded UIImagePicker's image once.
    /// Preserve those delivered JPEG bytes rather than encoding them a second time.
    func ingestCameraData(_ data: Data, fileName: String) throws -> ImportedSourcePage {
        try ingest(data, fileName: fileName, origin: .camera,
                   captureRepresentation: "UIImagePickerController originalImage re-encoded with jpegData(0.95); source EXIF is not asserted")
    }

    private func ingest(
        _ sourceData: Data,
        fileName: String,
        origin: SourceOrigin,
        captureRepresentation: String?
    ) throws -> ImportedSourcePage {
        let ingestStart = ProcessInfo.processInfo.systemUptime
        guard let imageSource = CGImageSourceCreateWithData(sourceData as CFData, nil),
              let sourceCGImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw IngestError.unsupportedImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
        let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? sourceCGImage.width
        let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? sourceCGImage.height
        let exifOrientation = properties[kCGImagePropertyOrientation] as? Int
        let uti = CGImageSourceGetType(imageSource).map { $0 as String }
        let normalizedImage = try Self.normalizeOrientation(sourceData)
        guard let normalizedCGImage = normalizedImage.cgImage,
              let normalizedPNG = normalizedImage.pngData() else {
            throw IngestError.normalizationFailed
        }

        let pageID = UUID().uuidString.lowercased()
        let relativeDirectory = "metra-inputs/\(pageID)"
        let inputRoot = try Self.documentsURL().appendingPathComponent(relativeDirectory, isDirectory: true)
        let normalizationMilliseconds = (ProcessInfo.processInfo.systemUptime - ingestStart) * 1000
        let copyStart = ProcessInfo.processInfo.systemUptime
        try fileManager.createDirectory(at: inputRoot, withIntermediateDirectories: true)

        let ext = Self.fileExtension(for: uti, fallback: URL(fileURLWithPath: fileName).pathExtension)
        let originalName = "original.\(ext)"
        try sourceData.write(to: inputRoot.appendingPathComponent(originalName), options: .atomic)
        let normalizedName = "normalized.png"
        try normalizedPNG.write(to: inputRoot.appendingPathComponent(normalizedName), options: .atomic)
        let sandboxCopyMilliseconds = (ProcessInfo.processInfo.systemUptime - copyStart) * 1000

        return ImportedSourcePage(
            id: pageID,
            fileName: fileName,
            relativeDirectory: relativeDirectory,
            origin: origin,
            sourceSHA256: Self.sha256(sourceData),
            sourceByteCount: Int64(sourceData.count),
            sourceUTI: uti,
            sourceWidth: pixelWidth,
            sourceHeight: pixelHeight,
            sourceEXIFOrientation: exifOrientation,
            captureRepresentation: captureRepresentation,
            normalizedFileName: normalizedName,
            normalizedSHA256: Self.sha256(normalizedPNG),
            normalizedWidth: normalizedCGImage.width,
            normalizedHeight: normalizedCGImage.height,
            ingestedAt: ISO8601DateFormatter().string(from: Date()),
            normalizationMilliseconds: normalizationMilliseconds,
            sandboxCopyMilliseconds: sandboxCopyMilliseconds
        )
    }

    static func normalizedURL(for page: ImportedSourcePage) throws -> URL {
        try documentsURL()
            .appendingPathComponent(page.relativeDirectory, isDirectory: true)
            .appendingPathComponent(page.normalizedFileName)
    }

    static func originalURL(for page: ImportedSourcePage) throws -> URL {
        try documentsURL()
            .appendingPathComponent(page.relativeDirectory, isDirectory: true)
            .appendingPathComponent("original.\(fileExtension(for: page.sourceUTI, fallback: URL(fileURLWithPath: page.fileName).pathExtension))")
    }

    static func documentsURL() throws -> URL {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizeOrientation(_ data: Data) throws -> UIImage {
        guard let image = UIImage(data: data) else { throw IngestError.unsupportedImage }
        if image.imageOrientation == .up { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
    }

    private static func fileExtension(for uti: String?, fallback: String) -> String {
        if let uti, let type = UTType(uti), let ext = type.preferredFilenameExtension { return ext }
        let trimmed = fallback.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? "bin" : trimmed.lowercased()
    }

    private static func timestampName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

enum IngestError: LocalizedError {
    case photoDataUnavailable
    case unsupportedImage
    case normalizationFailed
    case cameraEncodingFailed

    var errorDescription: String? {
        switch self {
        case .photoDataUnavailable: "Data foto dari galeri tidak tersedia. Coba pilih ulang foto tersebut."
        case .unsupportedImage: "File tidak dapat dibaca sebagai gambar raster."
        case .normalizationFailed: "Gambar tidak dapat dinormalisasi tanpa kehilangan sumber."
        case .cameraEncodingFailed: "Foto kamera tidak dapat disimpan sebagai JPEG."
        }
    }
}
