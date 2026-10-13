import AVFoundation
import CoreTransferable
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// File promises are copied while their importing closure still owns the provider URL.
/// https://developer.apple.com/documentation/coretransferable/filerepresentation
struct ImportedUploadFile: Transferable, Sendable {
    let url: URL
    let filename: String
    let contentType: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try await importMedia(at: received.file, movie: true)
        }
        FileRepresentation(importedContentType: .image) { received in
            try await importMedia(at: received.file, movie: false)
        }
    }

    static func importMedia(at url: URL, movie: Bool, directory: URL? = nil) async throws -> Self {
        try Task.checkCancellation()
        let descriptor: UploadFileDescriptor
        if movie {
            guard try await AVURLAsset(url: url).load(.isPlayable) else { throw UploadPreparationError.unavailableRepresentation }
            descriptor = try UploadFileDescriptor.movie(at: url)
        } else {
            descriptor = try UploadFileDescriptor.image(at: url)
        }
        return try await OwnedUploadInputs.shared.copy(url, descriptor: descriptor, directory: directory)
    }

    static func importFile(at url: URL, directory: URL? = nil) async throws -> Self {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let descriptor = UploadFileDescriptor(filenameExtension: url.pathExtension,
            contentType: type.preferredMIMEType ?? "application/octet-stream")
        return try await OwnedUploadInputs.shared.copy(url, descriptor: descriptor, directory: directory,
                                                      filename: url.lastPathComponent)
    }

    var payload: PreparedUploadPayload {
        .init(file: url, filename: filename, contentType: contentType, ownsInputFile: true)
    }
}

struct UploadFileDescriptor: Sendable {
    let filenameExtension: String
    let contentType: String

    static func image(at url: URL) throws -> Self {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String), type.conforms(to: .image),
              let ext = type.preferredFilenameExtension, let mime = type.preferredMIMEType,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                // HEIC decoding rejects a one-pixel thumbnail on supported OS versions.
                kCGImageSourceThumbnailMaxPixelSize: 32
              ] as CFDictionary) != nil else { throw ImageUploadError.invalidImage }
        return Self(filenameExtension: ext, contentType: mime)
    }

    static func movie(at url: URL) throws -> Self {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 32) ?? Data()
        let bytes = Array(prefix)
        if bytes.count >= 12, String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp" {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii)
            return brand == "qt  " ? .init(filenameExtension: "mov", contentType: "video/quicktime") :
                .init(filenameExtension: "mp4", contentType: "video/mp4")
        }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .movie),
           let ext = type.preferredFilenameExtension, let mime = type.preferredMIMEType {
            return Self(filenameExtension: ext, contentType: mime)
        }
        throw UploadPreparationError.unavailableRepresentation
    }
}

actor OwnedUploadInputs {
    static let shared = OwnedUploadInputs()

    func copy(_ source: URL, descriptor: UploadFileDescriptor, directory: URL?,
              filename: String? = nil) throws -> ImportedUploadFile {
        try Self.copyWhileAvailable(source, descriptor: descriptor, directory: directory, filename: filename)
    }

    /// NSItemProvider callbacks also use this before returning their temporary URL.
    nonisolated static func copyWhileAvailable(_ source: URL, descriptor: UploadFileDescriptor,
                                              directory: URL? = nil, filename: String? = nil) throws -> ImportedUploadFile {
        try Task.checkCancellation()
        let folder = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("s3-upload-inputs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = descriptor.filenameExtension
        let safeExtension = !ext.isEmpty && ext.utf8.count <= 12 && ext.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        } ? ext : "upload"
        let destination = folder.appendingPathComponent(UUID().uuidString + "." + safeExtension)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            try Task.checkCancellation()
            let name = filename ?? (source.deletingPathExtension().lastPathComponent + "." + descriptor.filenameExtension)
            return ImportedUploadFile(url: destination, filename: name, contentType: descriptor.contentType)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
