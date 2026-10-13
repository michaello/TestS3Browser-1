import AVFoundation
import CoreVideo
import Foundation
import Testing

/// Creates a real H.264 QuickTime movie for poster and imported-file regression checks.
@MainActor
func makeFixtureVideo(at url: URL, fileType: AVFileType = .mov) async throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 480
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 480
    ])
    writer.add(input)
    try #require(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var pixel: CVPixelBuffer?
    try #require(CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32ARGB, nil, &pixel) == kCVReturnSuccess)
    let frame = try #require(pixel)
    CVPixelBufferLockBaseAddress(frame, [])
    if let address = CVPixelBufferGetBaseAddress(frame) { memset(address, 128, CVPixelBufferGetDataSize(frame)) }
    CVPixelBufferUnlockBaseAddress(frame, [])
    for _ in 0..<20_000 { if input.isReadyForMoreMediaData { break }; await Task.yield() }
    try #require(input.isReadyForMoreMediaData)
    try #require(adaptor.append(frame, withPresentationTime: .zero))
    input.markAsFinished()
    await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
    try #require(writer.status == .completed)
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    try #require((size ?? 0) > 0)
}
