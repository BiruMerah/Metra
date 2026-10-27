import Foundation

@MainActor
protocol MaterialExtractionProtocol {
    var diagramModelIsAvailable: Bool { get }
    var diagramModelUsesSystem: Bool { get }
    var diagramModelStatus: String { get }
    func extract(
        pages: [MaterialImageInput],
        title: String,
        onProgress: @escaping @MainActor (String) -> Void
    ) async throws -> MathMaterialModel
    func organizeTopics(
        in material: MathMaterialModel,
        onProgress: @escaping @MainActor (String) -> Void
    ) async throws -> MathMaterialModel
    func cancel()
    func artifactURL(for relativePath: String) throws -> URL
}
