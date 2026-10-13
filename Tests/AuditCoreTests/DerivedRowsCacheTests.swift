import Foundation
import Testing
@testable import AuditCore

@MainActor
struct F34DerivedRowsCacheTests {
    @Test("Construction metrics use bounded surface names and measure only the builder")
    func viewConstructionMeasurements() {
        var time = 0.0
        let telemetry = AuditTelemetry(now: { time })
        let result = telemetry.measureViewConstruction(.recent) { time += 0.010;return [1, 2, 3] }
        #expect(result == [1, 2, 3])
        for surface in AuditViewSurface.allCases {
            _ = telemetry.measureViewConstruction(surface) { time += 0.001;return 1 }
        }
        #expect(telemetry.snapshot.viewConstruction.count == AuditViewSurface.allCases.count)
        #expect(telemetry.snapshot.viewConstruction["recent"]?.count == 2)
        #expect(abs((telemetry.snapshot.viewConstruction["recent"]?.totalMilliseconds ?? 0) - 11) < 0.001)
        #expect(telemetry.snapshot.viewConstructionScope.contains("excludes layout"))
    }

    @Test("One thousand unrelated updates reuse row derivations; source and filters each invalidate once")
    func measuredRowReuse() throws {
        let rows = (0..<10_000).map { "file-\($0)" }, cache = DerivedRowsCache<[String]>()
        let revision = UUID(), initial = DerivedRowsKey(revision: revision, fields: ["account", "bucket", "", "all"])
        let began = ContinuousClock.now
        for _ in 0..<1_000 {
            #expect(cache.value(for: initial) { rows.sorted() }.count == 10_000)
        }
        #expect(cache.derivationCount == 1)
        let filtered = DerivedRowsKey(revision: revision, fields: ["account", "bucket", "", "file-99"])
        #expect(cache.value(for: filtered) { rows.filter { $0.contains("file-99") }.sorted() }.count == 111)
        let changed = DerivedRowsKey(revision: UUID(), fields: ["account", "bucket", "", "file-99"])
        #expect(cache.value(for: changed) { ["new-row"] } == ["new-row"])
        #expect(cache.derivationCount == 3)
        let elapsed = began.duration(to: .now).components
        let proof: [String: Any] = ["input_rows": rows.count, "unrelated_updates": 1_000, "actual_derivations": cache.derivationCount,
            "derivation_milliseconds": cache.derivationMilliseconds,
            "fixture_total_milliseconds": Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15,
            "scope": "Actual macOS production-helper timing and work counts. Full Release view-body/frame measurements remain E01."]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("artifacts/audit/F34-benchmark.json")
        try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys]).write(to: path, options: .atomic)
    }

    @Test("Gallery projections are reused for index changes and rebuild only for source changes")
    func galleryProjectionReuse() {
        let projection = GalleryIdentityProjection<Int, Int>()
        projection.update(Array(0..<1_000), identity: { $0 })
        for index in 0..<100 { #expect(projection.objects[projection.identities[index]] == index) }
        #expect(projection.derivationCount == 1)
        projection.update([42, 43], identity: { $0 })
        #expect(projection.identities == [42, 43] && projection.objects.count == 2)
        #expect(projection.derivationCount == 2)
    }

    @Test("Text lines remain derived once across progress updates and exact query bytes invalidate cache")
    func linesAndExactQueries() {
        let lines = NumberedTextPreview()
        let source = PreviewTextInput(text: (0..<10_000).map(String.init).joined(separator: "\n"))
        for _ in 0..<100 { lines.update(source) }
        #expect(lines.derivationCount == 1 && lines.lines.count == 10_000)
        let revision = UUID(), cache = DerivedRowsCache<Int>()
        _ = cache.value(for: DerivedRowsKey(revision: revision, fields: ["caf\u{e9}"])) { 1 }
        #expect(cache.value(for: DerivedRowsKey(revision: revision, fields: ["cafe\u{301}"])) { 2 } == 2)
        #expect(cache.derivationCount == 2)
    }
}
