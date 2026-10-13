import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AuditCore

@MainActor @Suite(.timeLimit(.minutes(1)))
struct F22FileImportTests {
    @Test(arguments: [UTType.png, .jpeg, .heic])
    func actualImageTypeSurvivesMisleadingProviderName(_ type: UTType) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("provider-image.wrong")
        let context = try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        let expected = SHA256.hash(data: try Data(contentsOf: source))
        let imported = try await ImportedUploadFile.importMedia(at: source, movie: false,
            directory: root.appendingPathComponent("owned"))
        try FileManager.default.removeItem(at: source)
        #expect(imported.filename == "provider-image." + (type.preferredFilenameExtension ?? ""))
        #expect(imported.contentType == type.preferredMIMEType)
        #expect(SHA256.hash(data: try Data(contentsOf: imported.url)) == expected)
        let decoded = try #require(CGImageSourceCreateWithURL(imported.url as CFURL, nil))
        #expect(CGImageSourceCreateImageAtIndex(decoded, 0, nil) != nil)
    }

    @Test(arguments: [false, true])
    func moviesRetainPlayableOriginalBytesAndMovieType(mp4: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent(mp4 ? "provider.mp4" : "provider.mov")
        try await makeFixtureVideo(at: source, fileType: mp4 ? .mp4 : .mov)
        let expected = SHA256.hash(data: try Data(contentsOf: source))
        let imported = try await ImportedUploadFile.importMedia(at: source, movie: true,
            directory: root.appendingPathComponent("owned"))
        try FileManager.default.removeItem(at: source)
        #expect(imported.filename.hasSuffix(mp4 ? ".mp4" : ".mov"))
        #expect(imported.contentType == (mp4 ? "video/mp4" : "video/quicktime"))
        #expect(SHA256.hash(data: try Data(contentsOf: imported.url)) == expected)
        #expect(try await AVURLAsset(url: imported.url).load(.isPlayable))
        guard case .file(let url) = imported.payload.body else { Issue.record("Movie became a Data payload"); return }
        #expect(url == imported.url)
    }

    @Test func cancelledOrChangedAccountCleansOwnedRepresentationWithoutSending() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("input.txt")
        try Data("original".utf8).write(to: source)
        for cancel in [false, true] {
            var importedURL: URL?
            var sends = 0
            var currentAccount = true
            let task = Task { @MainActor in
                try await UploadPreparation.perform(destination: .init(account: "A", bucket: "b", prefix: "p/"),
                    load: {
                        let imported = try await ImportedUploadFile.importFile(at: source,
                            directory: root.appendingPathComponent("owned"))
                        importedURL = imported.url
                        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                        else { currentAccount = false }
                        return imported.payload
                    }, isCurrentAccount: { currentAccount }, send: { _, _ in sends += 1 })
            }
            await #expect(throws: (any Error).self) { try await task.value }
            #expect(sends == 0)
            #expect(FileManager.default.fileExists(atPath: try #require(importedURL).path) == false)
            #expect(FileManager.default.fileExists(atPath: source.path))
        }
    }

    @Test func genericFileNameIsPreservedAndLocalNameIsBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("notes.未知文件类型")
        let bytes = Data("generic file".utf8)
        try bytes.write(to: source)
        let imported = try await ImportedUploadFile.importFile(at: source,
            directory: root.appendingPathComponent("owned"))
        #expect(imported.filename == source.lastPathComponent)
        #expect(imported.url.lastPathComponent.utf8.count < 64)
        #expect(imported.url.pathExtension == "upload")
        #expect(imported.contentType == "application/octet-stream")
        #expect(try Data(contentsOf: imported.url) == bytes)
    }

    @Test func invalidMediaIsRejectedWithoutOwnedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("fake.mov")
        try Data("invalid media".utf8).write(to: source)
        let owned = root.appendingPathComponent("owned")
        for movie in [false, true] {
            await #expect(throws: (any Error).self) {
                try await ImportedUploadFile.importMedia(at: source, movie: movie, directory: owned)
            }
        }
        #expect(FileManager.default.fileExists(atPath: owned.path) == false)
    }
}
