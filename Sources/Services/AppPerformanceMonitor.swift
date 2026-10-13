import UIKit

/// Samples app frame cadence and process peak resident memory without network export.
@MainActor
final class AppPerformanceMonitor: NSObject {
    static let shared = AppPerformanceMonitor()
    private var displayLink: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?
    private var lastMemorySample: CFTimeInterval = 0

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        previousTimestamp = nil
        saveFixtureSnapshot()
    }

    @objc private func frame(_ link: CADisplayLink) {
        if let previousTimestamp { AuditTelemetry.shared.frameGap(seconds: link.timestamp - previousTimestamp) }
        previousTimestamp = link.timestamp
        guard link.timestamp - lastMemorySample >= 1 else { return }
        lastMemorySample = link.timestamp
        if let peak = ProcessResidentMemory.peakBytes() { AuditTelemetry.shared.residentMemory(peakBytes: peak) }
        saveFixtureSnapshot()
    }

    private func saveFixtureSnapshot() {
        guard AuditAppFixture.isEnabled,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? AuditTelemetry.shared.encodedSnapshot().write(to: documents.appendingPathComponent("audit-runtime-\(AuditAppFixture.caseName).json"), options: .atomic)
    }
}
