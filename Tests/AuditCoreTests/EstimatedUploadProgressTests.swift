import Foundation
import Testing
@testable import AuditCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct F17UploadProgressTests {
    enum Failure: Error { case upload }

    @Test func successEndsTimerBeforeTerminalCallback() async throws {
        var values: [Double] = []
        var ticks = 0
        let value = try await EstimatedUploadProgress.perform(byteCount: 1, progress: { values.append($0) }, tick: {
            ticks += 1
            await Task.yield()
        }, operation: {
            while ticks == 0 { await Task.yield() }
            return "uploaded"
        })
        #expect(value == "uploaded")
        #expect(values.last == 1)
        #expect(values.filter { $0 == 1 }.count == 1)
        let terminalCount = values.count
        let terminalTicks = ticks
        for _ in 0..<20 { await Task.yield() }
        #expect(values.count == terminalCount)
        #expect(ticks == terminalTicks)
    }

    @Test func failureStopsTimerWithoutSuccessOrLateCallbacks() async {
        var values: [Double] = []
        var ticks = 0
        await #expect(throws: Failure.upload) {
            try await EstimatedUploadProgress.perform(byteCount: 100, progress: { values.append($0) }, tick: {
                ticks += 1
                await Task.yield()
            }, operation: {
                while ticks == 0 { await Task.yield() }
                throw Failure.upload
            })
        }
        let count = values.count
        let lastTick = ticks
        for _ in 0..<20 { await Task.yield() }
        #expect(values.count == count)
        #expect(ticks == lastTick)
        #expect(values.contains(1) == false)
    }

    @Test func cancellationStopsOwnedTimer() async {
        var values: [Double] = []
        var ticks = 0
        let task = Task { @MainActor in
            try await EstimatedUploadProgress.perform(byteCount: 100, progress: { values.append($0) }, tick: {
                ticks += 1
                await Task.yield()
            }, operation: {
                while ticks == 0 { await Task.yield() }
                withUnsafeCurrentTask { $0?.cancel() }
                try Task.checkCancellation()
            })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let count = values.count
        for _ in 0..<20 { await Task.yield() }
        #expect(values.count == count)
        #expect(values.contains(1) == false)
    }

    @Test func absentCallbackStartsNoTimer() async throws {
        var ticks = 0
        let value = try await EstimatedUploadProgress.perform(byteCount: 100, progress: nil,
            tick: { ticks += 1 }, operation: { 42 })
        #expect(value == 42)
        #expect(ticks == 0)
    }
}
