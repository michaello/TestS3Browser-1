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

/// Represents an S3 folder (prefix)
struct S3Folder: Identifiable {
    let prefix: String

    var id: String { prefix }

    var folderName: String {
        // Remove trailing slash and get last path component
        let cleanPrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: cleanPrefix)?.lastPathComponent ?? cleanPrefix
    }
}

/// Represents either a folder or a file in S3
enum S3Item: Identifiable {
    case folder(S3Folder)
    case file(S3Object)

    var id: String {
        switch self {
        case .folder(let folder):
            return folder.id
        case .file(let object):
            return object.id
        }
    }

    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }

    var displayName: String {
        switch self {
        case .folder(let folder):
            return folder.folderName
        case .file(let object):
            return object.fileName
        }
    }

    var sortDate: Date {
        switch self {
        case .folder:
            return Date.distantPast
        case .file(let object):
            return object.lastModified
        }
    }

    var sortSize: Int64 {
        switch self {
        case .folder:
            return 0
        case .file(let object):
            return object.size
        }
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
