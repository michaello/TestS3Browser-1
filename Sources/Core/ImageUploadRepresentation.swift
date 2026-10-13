import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageUploadRepresentation: Sendable {
    let data: Data
    let filenameExtension: String
    let contentType: String

    static func decode(_ data: Data) throws -> Self {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String), type.conforms(to: .image),
              let ext = type.preferredFilenameExtension, let mime = type.preferredMIMEType,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 32,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) != nil else {
            throw ImageUploadError.invalidImage
        }
        return Self(data: data, filenameExtension: ext, contentType: mime)
    }
}

enum ImageUploadError: LocalizedError {
    case invalidImage
    var errorDescription: String? { "This item is not a supported, decodable image." }
}

enum UploadKeyFactory {
    static func image(prefix: String = "dump/", extension ext: String,
                      date: Date = Date(), uniqueID: UUID = UUID()) -> String {
        let timestamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        return prefix + timestamp + "-" + uniqueID.uuidString + "." + ext
    }
}

struct ImageDropOutcome: Sendable {
    struct Failure: Sendable { let item: Int; let message: String }
    let attempted: Int
    var uploadedKeys: [String] = []
    var failures: [Failure] = []

    var summary: String {
        var text = "Uploaded \(uploadedKeys.count) of \(attempted) images."
        if !failures.isEmpty {
            text += " Failed items: " + failures.map { "\($0.item + 1): \($0.message)" }.joined(separator: "; ")
        }
        return text
    }
}

@MainActor
enum ImageDropBatch {
    static func process(_ items: [Data],
                        upload: (ImageUploadRepresentation) async throws -> String) async -> ImageDropOutcome {
        var result = ImageDropOutcome(attempted: items.count)
        for (index, data) in items.enumerated() {
            do {
                try Task.checkCancellation()
                let representation = try ImageUploadRepresentation.decode(data)
                result.uploadedKeys.append(try await upload(representation))
            } catch {
                result.failures.append(.init(item: index, message: error.localizedDescription))
            }
        }
        return result
    }
}
