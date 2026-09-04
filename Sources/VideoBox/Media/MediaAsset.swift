import Foundation

struct MediaAsset: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let url: URL

    init(id: UUID = UUID(), url: URL) {
        self.id = id
        self.url = url
    }

    var displayName: String {
        url.lastPathComponent
    }
}
