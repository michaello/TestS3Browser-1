import SwiftUI

/// File type filter for filtering items by type
struct FileTypeFilter: OptionSet {
    let rawValue: Int

    static let log = FileTypeFilter(rawValue: 1 << 0)
    static let image = FileTypeFilter(rawValue: 1 << 1)
    static let text = FileTypeFilter(rawValue: 1 << 2)
    static let unknown = FileTypeFilter(rawValue: 1 << 3)
    static let video = FileTypeFilter(rawValue: 1 << 4)
    static let html = FileTypeFilter(rawValue: 1 << 5)

    static let all: FileTypeFilter = [.log, .image, .text, .unknown, .video, .html]
    static let none: FileTypeFilter = []

    /// Check if a file type matches the filter
    func matches(_ fileType: FileType) -> Bool {
        switch fileType {
        case .log: return contains(.log)
        case .image: return contains(.image)
        case .video: return contains(.video)
        case .text: return contains(.text)
        case .html: return contains(.html)
        case .unknown: return contains(.unknown)
        }
    }

    /// Get display name for a single filter option
    static func displayName(for fileType: FileType) -> String {
        switch fileType {
        case .log: return "Logs"
        case .image: return "Images"
        case .video: return "Videos"
        case .text: return "Text"
        case .html: return "Reports"
        case .unknown: return "Other"
        }
    }

    /// Get icon for a single filter option
    static func icon(for fileType: FileType) -> String {
        fileType.icon
    }
}

/// Extension to help filter arrays
extension Array where Element: S3ItemProtocol {
    func filtered(by typeFilter: FileTypeFilter) -> [Element] {
        guard typeFilter != .all else { return self }
        return filter { item in
            switch item.s3ItemType {
            case .folder:
                return true // Always show folders
            case .file(let object):
                return typeFilter.matches(object.fileType)
            }
        }
    }
}

/// Protocol to support filtering both S3Item and individual objects
protocol S3ItemProtocol {
    var s3ItemType: S3ItemType { get }
}

enum S3ItemType {
    case folder
    case file(S3Object)
}

extension S3Item: S3ItemProtocol {
    var s3ItemType: S3ItemType {
        switch self {
        case .folder:
            return .folder
        case .file(let object):
            return .file(object)
        }
    }
}

extension S3Object: S3ItemProtocol {
    var s3ItemType: S3ItemType {
        return .file(self)
    }
}
