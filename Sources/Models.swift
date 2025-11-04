import Foundation

struct S3Object: Identifiable {
    let key: String
    let size: Int64
    let lastModified: Date
    let etag: String?

    var id: String { key }

    var fileName: String {
        URL(string: key)?.lastPathComponent ?? key
    }

    var fileType: FileType {
        let ext = fileName.lowercased().split(separator: ".").last.map(String.init) ?? ""
        switch ext {
        case "txt", "log":
            return .log
        case "png", "jpg", "jpeg", "gif", "heic":
            return .image
        case "json", "xml":
            return .text
        default:
            return .unknown
        }
    }

    var formattedSize: String {
        let kb = Double(size) / 1024.0
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        let mb = kb / 1024.0
        return String(format: "%.1f MB", mb)
    }
}

enum FileType {
    case log
    case image
    case text
    case unknown

    var icon: String {
        switch self {
        case .log: return "doc.text"
        case .image: return "photo"
        case .text: return "doc.plaintext"
        case .unknown: return "doc"
        }
    }
}

struct S3Config: Codable, Equatable {
    var bucketName: String
    var region: String
    var accessKey: String
    var secretKey: String
    var prefix: String

    static let `default` = S3Config(
        bucketName: "clarityvoice",
        region: "ap-southeast-1",
        accessKey: "REDACTED_KEY",
        secretKey: "REDACTED_SECRET",
        prefix: ""
    )
}
