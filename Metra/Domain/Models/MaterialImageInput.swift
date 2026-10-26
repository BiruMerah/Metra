import Foundation

struct MaterialImageInput: Identifiable, Sendable {
    enum Origin: Sendable { case photoLibrary, camera }

    let id: UUID
    let data: Data
    let fileName: String
    let origin: Origin

    init(data: Data, fileName: String, origin: Origin) {
        id = UUID()
        self.data = data
        self.fileName = fileName
        self.origin = origin
    }
}
