import Foundation

struct S3Object: Identifiable, Hashable, Codable, Sendable {
    let key: String
    let size: Int64
    let lastModified: Date
    let etag: String?
    /// The bucket this object belongs to (optional for backward compatibility)
    var bucket: String?

    var id: String {
        S3TransferKeys.identifier(bucket: bucket, key: key)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.size == rhs.size && lhs.lastModified == rhs.lastModified &&
            lhs.etag.map { Data($0.utf8) } == rhs.etag.map { Data($0.utf8) }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(size)
        hasher.combine(lastModified)
        hasher.combine(etag.map { Data($0.utf8) })
    }

    var fileName: String {
        S3TransferKeys.fileName(of: key)
    }

    var fileType: FileType {
        let ext = fileName.lowercased().split(separator: ".").last.map(String.init) ?? ""
        switch ext {
        case "txt", "log":
            return .log
        case "png", "jpg", "jpeg", "gif", "heic", "webp":
            return .image
        case "mp4", "mov", "avi", "m4v":
            return .video
        case "json", "xml":
            return .text
        case "html", "htm":
            return .html
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
struct S3Folder: Identifiable, Sendable {
    let prefix: String

    var id: String { "folder." + Data(prefix.utf8).base64EncodedString() }

    var folderName: String {
        // Remove trailing slash and get last path component
        S3PrefixPath.folderName(prefix)
    }
}

/// Represents either a folder or a file in S3
enum S3Item: Identifiable, Sendable {
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

enum FileType: Sendable {
    case log
    case image
    case video
    case text
    case html
    case unknown

    var icon: String {
        switch self {
        case .log: return "doc.text"
        case .image: return "photo"
        case .video: return "film"
        case .text: return "doc.plaintext"
        case .html: return "doc.richtext"
        case .unknown: return "doc"
        }
    }

    var displayName: String {
        switch self {
        case .log: return "Log File"
        case .image: return "Image"
        case .video: return "Video"
        case .text: return "Text File"
        case .html: return "Report"
        case .unknown: return "File"
        }
    }
}

/// Metadata returned by a HeadObject call for a single S3 object.
struct S3ObjectMetadata: Sendable {
    let contentType: String?
    let contentLength: Int?
    let lastModified: Date?
    let etag: String?
    let storageClass: String?
    let cacheControl: String?
    let contentEncoding: String?
    let versionId: String?
    /// Expiration date parsed from the x-amz-expiration header, or nil if none is set.
    let expirationDate: String?
    /// User-defined metadata keys (x-amz-meta-* headers), with the "x-amz-meta-" prefix stripped.
    let userMetadata: [String: String]
    var replicationStatus: String? = nil
}

/// Per-bucket object count and total storage size, returned by S3Service.fetchBucketStats().
struct BucketStats: Identifiable {
    let bucket: String
    let objectCount: Int
    let totalBytes: Int64

    var id: String { bucket }

    var formattedSize: String {
        let gb = Double(totalBytes) / 1_073_741_824.0
        if gb >= 1.0 { return String(format: "%.2f GB", gb) }
        let mb = Double(totalBytes) / 1_048_576.0
        if mb >= 1.0 { return String(format: "%.1f MB", mb) }
        let kb = Double(totalBytes) / 1024.0
        return String(format: "%.1f KB", kb)
    }

    var formattedCount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return (formatter.string(from: NSNumber(value: objectCount)) ?? "\(objectCount)") + " object\(objectCount == 1 ? "" : "s")"
    }
}

/// A single ACL grant entry returned by GetObjectAcl.
struct ACLGrant: Identifiable, Sendable {
    let grantee: String
    let permission: String
    var id: String { "\(grantee)-\(permission)" }
}

/// ACL information for an S3 object, returned by S3Service.getObjectAcl(key:bucket:).
struct S3ObjectACL: Sendable {
    /// Human-readable summary: "Public (read)", "Private", or "Custom (N grants)".
    let summary: String
    let grants: [ACLGrant]
}

struct ReplicationRuleDisplay: Identifiable, Sendable {
    let id: String
    let status: String
    let destinationBucket: String
    let storageClass: String?
    let priority: Int?

    var isEnabled: Bool { status.lowercased() == "enabled" }
}

struct CORSRuleDisplay: Identifiable, Sendable {
    let id: String
    let allowedOrigins: [String]
    let allowedMethods: [String]
    let allowedHeaders: [String]
    let exposeHeaders: [String]
    let maxAgeSeconds: Int?
}

struct BucketMetric: Identifiable, Sendable {
    let name: String
    let value: String
    let unit: String
    var id: String { name }
}

struct S3Config: Decodable, Equatable, Sendable {
    var bucketName: String
    var region: String
    var accessKey: String
    var secretKey: String
    var prefix: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        zip([lhs.bucketName, lhs.region, lhs.accessKey, lhs.secretKey, lhs.prefix],
            [rhs.bucketName, rhs.region, rhs.accessKey, rhs.secretKey, rhs.prefix])
            .allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }

    static let `default` = S3Config(
        bucketName: "hairforceone-pro",
        region: "ap-southeast-1",
        accessKey: "",
        secretKey: "",
        prefix: "previews/"
    )
}
