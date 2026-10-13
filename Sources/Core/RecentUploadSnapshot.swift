import Foundation

struct RecentUploadPreview: Codable, Identifiable, Sendable {
    let key: String
    let size: Int64
    let lastModified: Date
    let etag: String?
    let bucket: String?
    var id: String {
        (bucket.map { "1" + Data($0.utf8).base64EncodedString() } ?? "0") + "." + Data(key.utf8).base64EncodedString()
    }
}

struct RecentUploadWidgetSnapshot: Codable, Sendable {
    let version: Int
    let account: String
    let uploads: [RecentUploadPreview]
}
