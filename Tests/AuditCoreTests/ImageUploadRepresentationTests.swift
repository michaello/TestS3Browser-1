import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AuditCore

private func imageFixture(type: UTType = .png) throws -> Data {
    let context = try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    let image = try #require(context.makeImage())
    let buffer = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(buffer, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return buffer as Data
}

struct F21UniqueUploadKeyTests {
    @Test func sameSecondUploadsPreserveBothObjects() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let bytes = try imageFixture()
        var objects: [String: Data] = [:]
        for _ in 0..<100 {
            let key = UploadKeyFactory.image(extension: "png", date: date)
            #expect(objects.updateValue(bytes, forKey: key) == nil)
        }
        #expect(objects.count == 100)
    }
}

struct N11InvalidImageUploadTests {
    @Test func nonImagesAreRejectedBeforeUpload() {
        for bytes in [Data(), Data("not an image".utf8), Data([0, 0, 0, 24, 102, 116, 121, 112])] {
            #expect(throws: ImageUploadError.self) { try ImageUploadRepresentation.decode(bytes) }
        }
    }

    @Test(arguments: [UTType.png, .jpeg, .gif, .heic])
    func imageBytesAndActualTypeArePreserved(_ type: UTType) throws {
        let bytes = try imageFixture(type: type)
        let decoded = try ImageUploadRepresentation.decode(bytes)
        #expect(decoded.data == bytes)
        #expect(decoded.contentType == type.preferredMIMEType)
        #expect(decoded.filenameExtension == type.preferredFilenameExtension)
    }
}

@MainActor
struct N10MultiDropTests {
    @Test func everySupportedPayloadIsUploadedAndRejectedItemsAreReported() async throws {
        let bytes = try imageFixture()
        var calls = 0
        let result = await ImageDropBatch.process([bytes, Data("invalid".utf8), bytes, bytes]) { representation in
            calls += 1
            #expect(representation.data == bytes)
            return "object-\(calls)"
        }
        #expect(calls == 3)
        #expect(result.attempted == 4)
        #expect(result.uploadedKeys == ["object-1", "object-2", "object-3"])
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.item == 1)
    }

    @Test func oneUploadFailureDoesNotDiscardOtherPayloads() async throws {
        let bytes = try imageFixture()
        var calls = 0
        let result = await ImageDropBatch.process([bytes, bytes, bytes]) { _ in
            calls += 1
            if calls == 2 { throw CocoaError(.fileWriteUnknown) }
            return "object-\(calls)"
        }
        #expect(calls == 3)
        #expect(result.uploadedKeys == ["object-1", "object-3"])
        #expect(result.failures.first?.item == 1)
    }
}
